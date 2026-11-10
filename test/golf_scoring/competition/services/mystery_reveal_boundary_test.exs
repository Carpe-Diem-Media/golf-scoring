defmodule GolfScoring.Competition.Services.MysteryRevealBoundaryTest do
  use ExUnit.Case, async: false

  alias Ash.Changeset
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Competition
  alias GolfScoring.Competition.MysteryReveal
  alias GolfScoring.Competition.Services.ExcludeCompetitionSideBeforeHole
  alias GolfScoring.Competition.Services.MysteryRevealCoordinator
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures
  alias GolfScoring.Scoring.Services.SubmitGroupHole

  setup do
    Process.put(:gls34_prefix, "j1-#{Ecto.UUID.generate()}")
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  test "a transaction does not authorize legacy or empty rechecks" do
    round = Ecto.UUID.generate()
    hole = Ecto.UUID.generate()
    competition = Ecto.UUID.generate()

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               assert {:error, :unauthorized_mystery_recheck} =
                        MysteryRevealCoordinator.recheck(round, hole)

               assert {:error, :unauthorized_mystery_recheck} =
                        MysteryRevealCoordinator.recheck_many(round, competition, [])

               :checked
             end)
  end

  test "forged origin, copied context and incomplete scopes cannot authorize rechecks" do
    round = Ecto.UUID.generate()
    competition = Ecto.UUID.generate()
    hole = Ecto.UUID.generate()

    for proof <- [
          nil,
          %{},
          %{owner: __MODULE__, token: make_ref()},
          %{owner: SubmitGroupHole, token: make_ref()},
          %{owner: ExcludeCompetitionSideBeforeHole, token: make_ref()}
        ] do
      assert {:error, :unauthorized_mystery_recheck} =
               MysteryRevealCoordinator.recheck(round, hole, proof)

      for holes <- [[], [hole], [hole, Ecto.UUID.generate()]] do
        assert {:error, :unauthorized_mystery_recheck} =
                 MysteryRevealCoordinator.recheck_many(round, competition, holes, proof)
      end
    end
  end

  test "direct Ash create cannot use supplied context as creation authority" do
    f = mystery_fixture!()
    rule = f.mystery.rule.id
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")
    before = evidence_counts(f.round.id)

    for context <- [%{}, %{mystery_reveal_creation: make_ref()}] do
      assert_creation_rejected(direct_create(rule, context))
      assert evidence_counts(f.round.id) == before
      assert reveal_count(rule) == 0
      refute_receive {:mystery_reveal_changed, _}, 0
    end
  end

  test "unsupported callers fail in another process and another transaction" do
    proof = %{owner: __MODULE__, token: make_ref(), pid: self()}
    round = Ecto.UUID.generate()
    hole = Ecto.UUID.generate()
    task = Task.async(fn -> MysteryRevealCoordinator.recheck(round, hole, proof) end)
    assert {:error, :unauthorized_mystery_recheck} = Task.await(task)

    assert {:ok, {:error, :unauthorized_mystery_recheck}} =
             Repo.transaction(fn -> MysteryRevealCoordinator.recheck(round, hole, proof) end)
  end

  test "a real submission proof expires and cannot be copied, replayed or retargeted" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)

    command = %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: setup.group.id,
      round_hole_id: setup.start_hole.id,
      expected_group_score_revision: 0,
      captured_at: DateTime.utc_now(),
      results:
        Enum.map(setup.entries, &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: 4})
    }

    Code.ensure_loaded!(MysteryRevealCoordinator)
    parent = self()

    tracer =
      spawn(fn ->
        receive do
          {:trace, ^parent, :call, {MysteryRevealCoordinator, :recheck, args}} ->
            send(parent, {:observed_origin, args})
        end
      end)

    assert 1 = :erlang.trace_pattern({MysteryRevealCoordinator, :recheck, 3}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      assert {:ok, _} = SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
      assert_receive {:observed_origin, [round, hole, proof]}, 1_000
      assert Process.get({SubmitGroupHole, :mystery_recheck}) == nil
      assert Process.get({MysteryRevealCoordinator, :creation}) == nil

      assert {:error, :unauthorized_mystery_recheck} =
               MysteryRevealCoordinator.recheck(round, hole, proof)

      assert {:error, :unauthorized_mystery_recheck} =
               MysteryRevealCoordinator.recheck(Ecto.UUID.generate(), hole, proof)

      assert {:error, :unauthorized_mystery_recheck} =
               MysteryRevealCoordinator.recheck(round, Ecto.UUID.generate(), proof)

      assert {:error, :unauthorized_mystery_recheck} =
               Task.async(fn -> MysteryRevealCoordinator.recheck(round, hole, proof) end)
               |> Task.await()
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({MysteryRevealCoordinator, :recheck, 3}, false, [:local])
      if Process.alive?(tracer), do: Process.exit(tracer, :kill)
    end
  end

  test "a genuine live origin proof rejects another process without a local gate" do
    f = mystery_fixture!()
    owner = self()
    tag = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        send(owner, {:worker_ready, tag, self()})

        receive do
          {:attempt, ^tag, proof} ->
            before_gate = Process.get({SubmitGroupHole, :mystery_recheck})
            result = MysteryRevealCoordinator.recheck(proof.round_id, hd(proof.holes), proof)

            send(
              owner,
              {:worker_result, tag, self(), before_gate, result,
               Process.get({SubmitGroupHole, :mystery_recheck})}
            )
        after
          5_000 -> send(owner, {:worker_timeout, tag})
        end
      end)

    try do
      assert_receive {:worker_ready, ^tag, ^worker}

      with_probe(
        fn metadata ->
          gate = Process.get({SubmitGroupHole, :mystery_recheck})

          if metadata.query == "SELECT pg_current_xact_id()::text" and is_map(gate) and
               not gate.used? and Process.get({__MODULE__, :cross_process_seen}) != true do
            Process.put({__MODULE__, :cross_process_seen}, true)
            send(worker, {:attempt, tag, gate})

            observation =
              receive do
                {:worker_result, ^tag, ^worker, before_gate, result, after_gate} ->
                  {worker, before_gate, result, after_gate}
              after
                1_000 -> :worker_handshake_timeout
              end

            send(
              owner,
              {:live_cross_process, gate.owner, gate.pid, gate.used?, is_reference(gate.token),
               observation, Process.get({SubmitGroupHole, :mystery_recheck}) == gate}
            )
          end
        end,
        fn ->
          assert {:ok, _} =
                   SubmitGroupHole.run(f.admin, f.event.id, f.round.id, submission_command(f))
        end
      )

      assert_receive {:live_cross_process, SubmitGroupHole, ^owner, false, true,
                      {^worker, nil, {:error, :unauthorized_mystery_recheck}, nil}, true}

      refute worker == owner
      assert Process.get({SubmitGroupHole, :mystery_recheck}) == nil
      assert reveal_count(f.mystery.rule.id) == 1
      assert reveal_count(f.second_rule.id) == 0
    after
      if Process.alive?(worker), do: Process.exit(worker, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  test "a fresh authorized submission reaches an already revealed rule without another reveal" do
    f = PaperRecoveryFixtures.setup_submit_fixture!(2)
    mystery = PaperRecoveryFixtures.configure_single_group_mystery!(f)
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")
    audits_before = evidence_counts(f.round.id)

    [[side]] =
      Repo.query!(
        "SELECT competition_side_id::text FROM competition_side_memberships WHERE round_entry_id = $1::uuid",
        [Ecto.UUID.dump!(hd(f.entries).id)]
      ).rows

    assert {:ok, %{mystery_reveal_created?: true}} =
             ExcludeCompetitionSideBeforeHole.run(
               f.admin,
               f.event.id,
               f.round.id,
               f.competition.id,
               Ecto.UUID.cast!(side),
               f.group.id,
               f.start_hole.id,
               %{reason: "confirmed unplayed no-op fixture", confirm_hole_unplayed?: true}
             )

    assert reveal_count(mystery.rule.id) == 1
    assert evidence_counts(f.round.id) == audits_before + 1
    assert_receive {:mystery_reveal_changed, %{round_id: round_id}}
    assert round_id == f.round.id
    refute_receive {:mystery_reveal_changed, _}, 0

    assert [[0]] =
             Repo.query!("SELECT count(*)::int FROM hole_submissions WHERE round_id = $1::uuid", [
               Ecto.UUID.dump!(f.round.id)
             ]).rows

    command = submission_command(f)

    with_probe(
      fn metadata ->
        gate = Process.get({SubmitGroupHole, :mystery_recheck})

        if metadata.query == "SELECT pg_current_xact_id()::text" and is_map(gate) and
             not gate.used? and Process.get({__MODULE__, :submission_seen}) != true do
          Process.put({__MODULE__, :submission_seen}, true)
          send(self(), {:fresh_submission_recheck, gate.receipt_id, gate.holes})
        end
      end,
      fn ->
        assert {:ok, receipt} =
                 SubmitGroupHole.run(f.admin, f.event.id, f.round.id, command)

        assert receipt.client_submission_id == command.client_submission_id
        assert receipt.round_hole_id == mystery.rule.round_hole_id
        assert receipt.expected_group_score_revision == 0
        assert_receive {:fresh_submission_recheck, receipt_id, holes}
        assert receipt_id == receipt.id
        assert holes == [mystery.rule.round_hole_id]

        assert [[1]] =
                 Repo.query!(
                   "SELECT count(*)::int FROM hole_submissions WHERE round_id = $1::uuid AND id = $2::uuid",
                   [Ecto.UUID.dump!(f.round.id), Ecto.UUID.dump!(receipt.id)]
                 ).rows

        assert [[1]] =
                 Repo.query!(
                   "SELECT count(*)::int FROM audit_events WHERE target_id = $1::uuid AND action = 'submit_group_hole'",
                   [Ecto.UUID.dump!(receipt.id)]
                 ).rows
      end
    )

    assert reveal_count(mystery.rule.id) == 1
    assert evidence_counts(f.round.id) == audits_before + 2

    assert [[1]] =
             Repo.query!("SELECT scoring_revision FROM playing_groups WHERE id = $1::uuid", [
               Ecto.UUID.dump!(f.group.id)
             ]).rows

    assert [[count]] =
             Repo.query!(
               "SELECT count(*)::int FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id WHERE sc.round_id = $1::uuid",
               [Ecto.UUID.dump!(f.round.id)]
             ).rows

    assert count == length(f.entries)
    assert_receive {:group_hole_submitted, %{round_id: ^round_id, scoring_revision: 1}}
    refute_receive {:group_hole_submitted, _}, 0
    refute_receive {:mystery_reveal_changed, _}, 0
  end

  test "live exclusion authority rejects subsets, supersets and another competition before exact scope succeeds" do
    f = mystery_fixture!()
    other = mystery_fixture!()
    extra = Enum.at(f.route, 2).id

    [[side]] =
      Repo.query!(
        "SELECT competition_side_id::text FROM competition_side_memberships WHERE round_entry_id = $1::uuid",
        [Ecto.UUID.dump!(hd(f.entries).id)]
      ).rows

    with_probe(
      fn metadata ->
        gate = Process.get({ExcludeCompetitionSideBeforeHole, :mystery_recheck})

        if metadata.query == "SELECT pg_current_xact_id()::text" and is_map(gate) and
             not gate.used? and Process.get({__MODULE__, :scope_seen}) != true do
          Process.put({__MODULE__, :scope_seen}, true)

          attempts = [
            {:subset, gate.round_id, gate.competition_id, tl(gate.holes)},
            {:superset, gate.round_id, gate.competition_id, [extra | gate.holes]},
            {:competition, gate.round_id, other.competition.id, gate.holes},
            {:round, other.round.id, gate.competition_id, gate.holes}
          ]

          results =
            Enum.map(attempts, fn {name, round, competition, holes} ->
              result = MysteryRevealCoordinator.recheck_many(round, competition, holes, gate)

              {name, result,
               Process.get({ExcludeCompetitionSideBeforeHole, :mystery_recheck}) == gate}
            end)

          send(self(), {:live_exclusion_results, gate.holes, results})
        end
      end,
      fn ->
        assert {:ok, %{mystery_reveal_created?: true}} =
                 ExcludeCompetitionSideBeforeHole.run(
                   f.admin,
                   f.event.id,
                   f.round.id,
                   f.competition.id,
                   Ecto.UUID.cast!(side),
                   f.group.id,
                   f.start_hole.id,
                   %{reason: "confirmed unplayed test fixture", confirm_hole_unplayed?: true}
                 )
      end
    )

    assert_receive {:live_exclusion_results, holes, results}

    assert holes ==
             Enum.sort_by(
               [f.mystery.rule.round_hole_id, f.second_rule.round_hole_id],
               &Ecto.UUID.dump!/1
             )

    assert length(holes) == 2
    assert Enum.map(results, &elem(&1, 0)) == [:subset, :superset, :competition, :round]

    assert Enum.all?(results, fn {_, result, unchanged} ->
             result == {:error, :unauthorized_mystery_recheck} and unchanged
           end)

    assert reveal_count(f.mystery.rule.id) == 1
    assert reveal_count(f.second_rule.id) == 1
    assert Process.get({ExcludeCompetitionSideBeforeHole, :mystery_recheck}) == nil
  end

  test "live submission authority rejects a valid wrong Round, hole and group without consuming exact authority" do
    f = mystery_fixture!()
    other = mystery_fixture!()

    with_probe(
      fn metadata ->
        gate = Process.get({SubmitGroupHole, :mystery_recheck})

        if metadata.query == "SELECT pg_current_xact_id()::text" and is_map(gate) and
             not gate.used? and Process.get({__MODULE__, :submission_seen}) != true do
          Process.put({__MODULE__, :submission_seen}, true)

          results = [
            MysteryRevealCoordinator.recheck(other.round.id, hd(gate.holes), gate),
            MysteryRevealCoordinator.recheck(gate.round_id, f.second_rule.round_hole_id, gate),
            MysteryRevealCoordinator.recheck(gate.round_id, hd(gate.holes), %{
              gate
              | group_id: other.group.id
            })
          ]

          send(
            self(),
            {:live_submission_results, results,
             Process.get({SubmitGroupHole, :mystery_recheck}) == gate}
          )
        end
      end,
      fn ->
        assert {:ok, _} =
                 SubmitGroupHole.run(f.admin, f.event.id, f.round.id, submission_command(f))
      end
    )

    assert_receive {:live_submission_results, results, true}
    assert results == List.duplicate({:error, :unauthorized_mystery_recheck}, 3)
    assert reveal_count(f.mystery.rule.id) == 1
    assert reveal_count(f.second_rule.id) == 0
  end

  test "live creation proof rejects another existing rule and rejects reuse after legitimate consumption" do
    f = mystery_fixture!()
    refute f.mystery.rule.id == f.second_rule.id
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")

    with_probe(
      fn metadata ->
        gate = Process.get({MysteryRevealCoordinator, :creation})

        cond do
          metadata.query == "SELECT pg_current_xact_id()::text" and is_map(gate) and
              is_nil(Process.get({__MODULE__, :creation_seen})) ->
            Process.put({__MODULE__, :creation_seen}, gate)
            result = MysteryRevealCoordinator.consume_creation(gate.token, f.second_rule.id)

            send(
              self(),
              {:wrong_rule_result, result,
               Process.get({MysteryRevealCoordinator, :creation}) == gate}
            )

          String.contains?(metadata.query, "INSERT INTO") and
            String.contains?(metadata.query, "\"mystery_reveals\"") and
            is_map(Process.get({__MODULE__, :creation_seen})) and
              Process.get({__MODULE__, :reuse_seen}) != true ->
            Process.put({__MODULE__, :reuse_seen}, true)
            original = Process.get({__MODULE__, :creation_seen})
            absent = Process.get({MysteryRevealCoordinator, :creation}) == nil

            result =
              if absent,
                do: MysteryRevealCoordinator.consume_creation(original.token, original.rule_id),
                else: :unexpected_live_creation_gate

            send(
              self(),
              {:consumed_rule_result, result, absent,
               Process.get({MysteryRevealCoordinator, :creation}) == nil}
            )

          true ->
            :ok
        end
      end,
      fn ->
        assert {:ok, _} =
                 SubmitGroupHole.run(f.admin, f.event.id, f.round.id, submission_command(f))
      end
    )

    assert_receive {:wrong_rule_result, {:error, :unauthorized_mystery_creation}, true}
    assert_receive {:consumed_rule_result, {:error, :unauthorized_mystery_creation}, true, true}
    assert reveal_count(f.mystery.rule.id) == 1
    assert reveal_count(f.second_rule.id) == 0
    assert Process.get({MysteryRevealCoordinator, :creation}) == nil
    assert_receive {:mystery_reveal_changed, %{round_id: round_id}}
    assert round_id == f.round.id
    refute_receive {:mystery_reveal_changed, _}, 0
  end

  # Repo telemetry is synchronous in the real querying process. This observes
  # actual capabilities without issuing, replacing or restoring production gates.
  def observe_query(_event, _measurements, metadata, %{owner: owner, probe: probe}) do
    if self() == owner do
      if Process.get({__MODULE__, :probing}) == true do
        send(owner, {:nested_probe_query, metadata.query})
      else
        Process.put({__MODULE__, :probing}, true)

        try do
          probe.(metadata)
        after
          Process.delete({__MODULE__, :probing})
        end
      end
    end
  end

  defp with_probe(probe, operation) do
    handler = {__MODULE__, make_ref()}
    event = [:golf_scoring, :repo, :query]

    :ok =
      :telemetry.attach(handler, event, &__MODULE__.observe_query/4, %{
        owner: self(),
        probe: probe
      })

    try do
      assert Enum.any?(:telemetry.list_handlers(event), &(&1.id == handler))
      operation.()

      assert Enum.any?(:telemetry.list_handlers(event), &(&1.id == handler)),
             "telemetry observer unexpectedly detached"

      refute_receive {:nested_probe_query, _}, 0
    after
      :telemetry.detach(handler)

      for key <- [
            :scope_seen,
            :submission_seen,
            :creation_seen,
            :reuse_seen,
            :probing,
            :cross_process_seen
          ] do
        Process.delete({__MODULE__, key})
      end

      refute Enum.any?(:telemetry.list_handlers(event), &(&1.id == handler))
    end
  end

  defp mystery_fixture! do
    f = PaperRecoveryFixtures.setup_submit_fixture!(2)
    mystery = PaperRecoveryFixtures.configure_single_group_mystery!(f)
    PaperRecoveryFixtures.set_round_state!(f.round, :draft)
    second_hole = Enum.at(f.route, 1)

    assert {:ok, second_rule} =
             Competition.configure_mystery_hole_rule(
               f.admin,
               f.event.id,
               f.round.id,
               mystery.track.id,
               second_hole.id,
               :worst
             )

    PaperRecoveryFixtures.set_round_state!(f.round, :scoring_open)
    Map.merge(f, %{mystery: mystery, second_rule: second_rule})
  end

  defp submission_command(f) do
    %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: f.group.id,
      round_hole_id: f.start_hole.id,
      expected_group_score_revision: 0,
      captured_at: DateTime.utc_now(),
      results:
        Enum.map(f.entries, &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: 4})
    }
  end

  defp direct_create(rule, context) do
    MysteryReveal
    |> Changeset.for_create(:create_internal, %{mystery_hole_rule_id: rule})
    |> Changeset.set_context(context)
    |> Ash.create(authorize?: false)
  end

  defp assert_creation_rejected(result) do
    assert {:error, error} = result
    assert Exception.message(error) =~ "Mystery reveal requires its locked coordinator capability"
    refute Exception.message(error) =~ "unique_mystery_hole_rule"
    refute Exception.message(error) =~ "does not exist"
  end

  defp reveal_count(rule) do
    [[count]] =
      Repo.query!(
        "SELECT count(*)::int FROM mystery_reveals WHERE mystery_hole_rule_id = $1::uuid",
        [Ecto.UUID.dump!(rule)]
      ).rows

    count
  end

  defp evidence_counts(round) do
    [[count]] =
      Repo.query!("SELECT count(*)::int FROM audit_events WHERE context->>'round_id' = $1", [
        round
      ]).rows

    count
  end
end

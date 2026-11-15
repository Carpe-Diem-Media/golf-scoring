defmodule GolfScoring.Scoring.Services.LoadContributionApplicabilityTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Competition
  alias GolfScoring.Competition.Services.AcceptRoundEntryWithdrawal
  alias GolfScoring.Repo
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Services.LoadContributionApplicability
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures
  alias GolfScoring.Scoring.Services.SubmitGroupHole

  setup context do
    Process.put(:gls34_prefix, "gls42-projection-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls34_prefix) end)
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    fixture = PaperRecoveryFixtures.setup_submit_fixture!(2)
    PaperRecoveryFixtures.set_round_state!(fixture.round, :draft)

    {:ok, side} =
      Competition.create_competition_side(
        fixture.admin,
        fixture.event.id,
        fixture.round.id,
        fixture.competition.id,
        :partnership
      )

    {:ok, _} =
      PaperRecoveryFixtures.set_side_membership_for_fixture(
        fixture.admin,
        fixture.event.id,
        fixture.round.id,
        fixture.competition.id,
        side.id,
        Enum.map(fixture.entries, & &1.id)
      )

    start_order = context[:start_order] || 1
    start_hole = Enum.at(fixture.route, start_order - 1)

    Repo.query!(
      "UPDATE playing_groups SET starting_round_hole_id = $2::uuid WHERE id = $1::uuid",
      [Ecto.UUID.dump!(fixture.group.id), Ecto.UUID.dump!(start_hole.id)]
    )

    PaperRecoveryFixtures.set_round_state!(fixture.round, :scoring_open)

    {:ok, _} =
      SubmitGroupHole.run(fixture.admin, fixture.event.id, fixture.round.id, %{
        client_submission_id: Ecto.UUID.generate(),
        playing_group_id: fixture.group.id,
        round_hole_id: start_hole.id,
        expected_group_score_revision: 0,
        results:
          Enum.map(
            fixture.entries,
            &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: 5}
          ),
        captured_at: DateTime.utc_now(:microsecond)
      })

    %{fixture: fixture, side: side}
  end

  test "active members' current results are applicable to withdrawal", %{
    fixture: fixture,
    side: side
  } do
    assert {:ok, facts} =
             LoadContributionApplicability.run(fixture.event.id, fixture.round.id, side.id)

    assert length(facts) == 2

    assert Enum.all?(
             facts,
             &(&1.withdrawal_applicability == :applicable and &1.play_index == 0 and
                 &1.revision == 1)
           )
  end

  test "withdrawal keeps the earlier result and retains evidence", %{fixture: fixture, side: side} do
    entry = List.last(fixture.entries)
    effective = Enum.at(fixture.route, 1)
    observed_at = DateTime.add(DateTime.utc_now(:microsecond), -1, :second)

    attrs = %{
      reason: "withdrew",
      attestation: %{
        observed_at: observed_at,
        method: "direct_visual",
        observation_location: "starting area",
        round_id: fixture.round.id,
        playing_group_id: fixture.group.id,
        effective_round_hole_id: effective.id,
        effective_play_index: 1,
        confirms_unplayed?: true
      }
    }

    assert {:ok, accepted} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               entry.id,
               attrs
             )

    assert {:ok, facts} =
             LoadContributionApplicability.run(fixture.event.id, fixture.round.id, side.id)

    result = Enum.find(facts, &(&1.round_entry_id == entry.id))
    assert result.withdrawal_applicability == :applicable
    assert result.play_index == 0
    assert result.ruling_id == accepted.ruling_id
    assert result.unresolved_reason == nil
  end

  test "a withdrawn entry without a ruling remains unresolved", %{fixture: fixture, side: side} do
    entry = List.last(fixture.entries)

    Repo.query!(
      "UPDATE round_entries SET participation_status = 'withdrawn' WHERE id = $1::uuid",
      [Ecto.UUID.dump!(entry.id)]
    )

    assert {:ok, facts} =
             LoadContributionApplicability.run(fixture.event.id, fixture.round.id, side.id)

    assert %{withdrawal_applicability: :unresolved, unresolved_reason: :missing_withdrawal_ruling} =
             Enum.find(facts, &(&1.round_entry_id == entry.id))

    assert %{withdrawal_applicability: :applicable} =
             Enum.find(facts, &(&1.round_entry_id != entry.id))
  end

  test "rejects a mismatched event scope", %{fixture: fixture, side: side} do
    assert {:error, :invalid_scope} =
             LoadContributionApplicability.run(Ecto.UUID.generate(), fixture.round.id, side.id)
  end

  @tag start_order: 18
  test "rotates each result around a shotgun start", %{fixture: fixture, side: side} do
    assert {:ok, facts} =
             LoadContributionApplicability.run(fixture.event.id, fixture.round.id, side.id)

    assert Enum.all?(
             facts,
             &(&1.round_hole_id == List.last(fixture.route).id and &1.play_index == 0)
           )

    [entry | _] = fixture.entries
    insert_result!(entry.id, hd(fixture.route).id)

    assert {:ok, facts} =
             LoadContributionApplicability.run(fixture.event.id, fixture.round.id, side.id)

    assert %{play_index: 1, withdrawal_applicability: :applicable} =
             Enum.find(
               facts,
               &(&1.round_entry_id == entry.id and &1.round_hole_id == hd(fixture.route).id)
             )
  end

  test "the withdrawal boundary excludes that hole and later holes without deleting results", %{
    fixture: fixture,
    side: side
  } do
    entry = List.last(fixture.entries)
    effective = Enum.at(fixture.route, 1)
    assert {:ok, accepted} = accept!(fixture, entry, effective, 1)
    insert_result!(entry.id, effective.id)
    insert_result!(entry.id, Enum.at(fixture.route, 2).id)

    assert {:ok, facts} =
             LoadContributionApplicability.run(fixture.event.id, fixture.round.id, side.id)

    selected =
      facts |> Enum.filter(&(&1.round_entry_id == entry.id)) |> Enum.sort_by(& &1.play_index)

    assert Enum.map(selected, & &1.withdrawal_applicability) == [
             :applicable,
             :not_applicable,
             :not_applicable
           ]

    assert Enum.all?(selected, &(&1.ruling_id == accepted.ruling_id))

    assert {:ok, ^facts} =
             LoadContributionApplicability.run(fixture.event.id, fixture.round.id, side.id)
  end

  test "a changed group start makes accepted evidence inconsistent", %{
    fixture: fixture,
    side: side
  } do
    entry = List.last(fixture.entries)
    assert {:ok, _} = accept!(fixture, entry, Enum.at(fixture.route, 1), 1)

    Repo.query!(
      "UPDATE playing_groups SET starting_round_hole_id = $2::uuid WHERE id = $1::uuid",
      [Ecto.UUID.dump!(fixture.group.id), Ecto.UUID.dump!(Enum.at(fixture.route, 1).id)]
    )

    assert {:ok, facts} =
             LoadContributionApplicability.run(fixture.event.id, fixture.round.id, side.id)

    assert %{
             withdrawal_applicability: :unresolved,
             unresolved_reason: :inconsistent_withdrawal_evidence
           } =
             Enum.find(facts, &(&1.round_entry_id == entry.id))
  end

  test "reads the current result revision and ignores disqualification for withdrawal", %{
    fixture: fixture,
    side: side
  } do
    entry = List.last(fixture.entries)

    assert {:ok, before} =
             LoadContributionApplicability.run(fixture.event.id, fixture.round.id, side.id)

    original = Enum.find(before, &(&1.round_entry_id == entry.id))

    assert {:ok, _} =
             Scoring.correct_hole_result(fixture.admin, fixture.event.id, fixture.round.id, %{
               hole_result_id: original.hole_result_id,
               expected_revision: 1,
               new_gross_strokes: 6,
               reason: "counting correction"
             })

    Repo.query!(
      "UPDATE round_entries SET participation_status = 'disqualified' WHERE id = $1::uuid",
      [Ecto.UUID.dump!(entry.id)]
    )

    assert {:ok, facts} =
             LoadContributionApplicability.run(fixture.event.id, fixture.round.id, side.id)

    assert %{revision: 2, withdrawal_applicability: :applicable} =
             Enum.find(facts, &(&1.round_entry_id == entry.id))
  end

  test "ambiguous confirmation audits fail closed", %{fixture: fixture, side: side} do
    entry = List.last(fixture.entries)
    assert {:ok, accepted} = accept!(fixture, entry, Enum.at(fixture.route, 1), 1)

    Repo.query!(
      "INSERT INTO audit_events (action, target_type, target_id, actor_staff_user_id, context, changes, reason, occurred_at) SELECT action, target_type, target_id, actor_staff_user_id, context, changes, reason, occurred_at FROM audit_events WHERE target_id = $1::uuid AND action = 'accept_round_entry_withdrawal'",
      [Ecto.UUID.dump!(accepted.ruling_id)]
    )

    assert {:ok, facts} =
             LoadContributionApplicability.run(fixture.event.id, fixture.round.id, side.id)

    assert %{
             withdrawal_applicability: :unresolved,
             unresolved_reason: :inconsistent_withdrawal_evidence
           } = Enum.find(facts, &(&1.round_entry_id == entry.id))
  end

  test "route ambiguity stops the read", %{fixture: fixture, side: side} do
    Repo.query!("UPDATE round_holes SET play_order = 19 WHERE id = $1::uuid", [
      Ecto.UUID.dump!(List.last(fixture.route).id)
    ])

    assert {:error, :ambiguous_route} =
             LoadContributionApplicability.run(fixture.event.id, fixture.round.id, side.id)
  end

  test "later withdrawal preserves all earlier results", %{fixture: fixture, side: side} do
    second = Enum.at(fixture.route, 1)

    assert {:ok, _} =
             SubmitGroupHole.run(fixture.admin, fixture.event.id, fixture.round.id, %{
               client_submission_id: Ecto.UUID.generate(),
               playing_group_id: fixture.group.id,
               round_hole_id: second.id,
               expected_group_score_revision: 1,
               results:
                 Enum.map(
                   fixture.entries,
                   &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: 5}
                 ),
               captured_at: DateTime.utc_now(:microsecond)
             })

    entry = List.last(fixture.entries)
    assert {:ok, _} = accept!(fixture, entry, Enum.at(fixture.route, 2), 2)

    assert {:ok, facts} =
             LoadContributionApplicability.run(fixture.event.id, fixture.round.id, side.id)

    prior =
      facts |> Enum.filter(&(&1.round_entry_id == entry.id)) |> Enum.sort_by(& &1.play_index)

    assert Enum.map(prior, & &1.play_index) == [0, 1]
    assert Enum.all?(prior, &(&1.withdrawal_applicability == :applicable))
  end

  test "uses a single query regardless of result count", %{fixture: fixture, side: side} do
    [entry | _] = fixture.entries
    Enum.each(Enum.drop(fixture.route, 1), &insert_result!(entry.id, &1.id))
    handler = "gls42-query-#{Ecto.UUID.generate()}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:golf_scoring, :repo, :query],
        &__MODULE__.observe_query/4,
        parent
      )

    try do
      assert {:ok, facts} =
               LoadContributionApplicability.run(fixture.event.id, fixture.round.id, side.id)

      assert length(facts) == 19
      assert_receive :projection_query
      refute_receive :projection_query
    after
      :telemetry.detach(handler)
    end
  end

  def observe_query(_event, _measurements, _metadata, parent) do
    if self() == parent, do: send(parent, :projection_query)
  end

  defp accept!(fixture, entry, effective, index) do
    attrs = %{
      reason: "withdrew",
      attestation: %{
        observed_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second),
        method: "direct_visual",
        observation_location: "starting area",
        round_id: fixture.round.id,
        playing_group_id: fixture.group.id,
        effective_round_hole_id: effective.id,
        effective_play_index: index,
        confirms_unplayed?: true
      }
    }

    AcceptRoundEntryWithdrawal.run(
      fixture.admin,
      fixture.event.id,
      fixture.round.id,
      fixture.group.id,
      entry.id,
      attrs
    )
  end

  defp insert_result!(entry_id, hole_id) do
    Repo.query!(
      "INSERT INTO hole_results (round_id, scorecard_id, round_hole_id, outcome, gross_strokes) SELECT round_id, id, $2::uuid, 'holed_out', 5 FROM scorecards WHERE round_entry_id = $1::uuid",
      [Ecto.UUID.dump!(entry_id), Ecto.UUID.dump!(hole_id)]
    )
  end
end

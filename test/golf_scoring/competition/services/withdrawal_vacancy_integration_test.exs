defmodule GolfScoring.Competition.Services.WithdrawalVacancyIntegrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Competition.Services.AcceptRoundEntryWithdrawal
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures
  alias GolfScoring.Scoring.Services.SubmitGroupHole

  @reason "participant withdrew before starting the next hole"

  setup do
    Process.put(:gls34_prefix, "gls42a-t4-#{Ecto.UUID.generate()}")
    owner = Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      Process.delete(:gls34_prefix)
      if Process.alive?(owner), do: Sandbox.stop_owner(owner)
    end)

    :ok
  end

  test "committed withdrawal survives a failed vacancy fill and scoring resumes after recovery" do
    Sandbox.unboxed_run(Repo, fn ->
      fixture = vacancy_fixture!(:primary_scorer)
      ruling_id = fixture.withdrawal.ruling_id
      group_id = fixture.group.id
      round_id = fixture.round.id
      revoked_id = assignment_for_role!(group_id, :primary_scorer)
      revoked = assignment_row!(revoked_id)
      replacement = Enum.at(fixture.entries, 2)
      memberships = membership_rows(group_id)
      assert revoked.state == "revoked"
      assert group_state(group_id) == "attention_required"
      assert side_result_state(fixture.side.id) == "review_required"
      assert score_rows(group_id) == fixture.prior_results
      assert fixture.withdrawal.checkpoint_play_index == 0
      assert fixture.withdrawal.effective_play_index == 1
      assert fixture.withdrawal.checkpoint_round_hole_id == hd(fixture.route).id
      assert fixture.withdrawal.effective_round_hole_id == Enum.at(fixture.route, 1).id
      assert fixture.withdrawal.revoked_assignment_ids == [revoked_id]

      [[withdrawal_audit]] =
        Repo.query!(
          "SELECT context FROM audit_events WHERE action = 'accept_round_entry_withdrawal' AND target_id = $1::uuid",
          [Ecto.UUID.dump!(ruling_id)]
        ).rows

      [[ruling]] =
        Repo.query!(
          "SELECT to_jsonb(r) FROM round_entry_participation_rulings r WHERE id = $1::uuid",
          [Ecto.UUID.dump!(ruling_id)]
        ).rows

      assert ruling["checkpoint_hole_submission_id"] ==
               fixture.withdrawal.checkpoint_hole_submission_id

      assert ruling["checkpoint_round_hole_id"] == hd(fixture.route).id
      assert ruling["checkpoint_play_index"] == 0
      assert ruling["effective_round_hole_id"] == Enum.at(fixture.route, 1).id
      assert ruling["effective_play_index"] == 1
      assert ruling["preplay_boundary_confirmed"]
      assert withdrawal_audit["ruling_id"] == ruling_id

      assert withdrawal_audit["checkpoint"]["hole_submission_id"] ==
               fixture.withdrawal.checkpoint_hole_submission_id

      assert withdrawal_audit["effective_boundary"] == %{
               "round_hole_id" => Enum.at(fixture.route, 1).id,
               "play_index" => 1
             }

      assert withdrawal_audit["attestation"]["observed_at"] ==
               DateTime.to_iso8601(fixture.withdrawal_attrs.attestation.observed_at)

      assert withdrawal_audit["attestation"]["method"] == "direct_visual"

      assert Enum.any?(
               withdrawal_audit["revoked_assignments"],
               &(&1["assignment_id"] == revoked_id and &1["assignment_version"] == 1)
             )

      assert_receive {:round_entry_withdrawn, %{round_id: ^round_id, ruling_id: ^ruling_id}}

      assert_receive {:playing_group_attention_required,
                      %{playing_group_id: ^group_id, ruling_id: ^ruling_id}}

      assert_receive {:competition_side_readiness_changed, %{ruling_id: ^ruling_id}}

      assert {:ok, %{grant: grant}} =
               Accounts.issue_player_access(
                 fixture.admin,
                 fixture.event.id,
                 replacement.player_id
               )

      assert {:error, :no_active_primary_scorer} =
               SubmitGroupHole.run(
                 grant,
                 fixture.event.id,
                 round_id,
                 next_submission_command(fixture, replacement.id, 2)
               )

      assert score_rows(group_id) == fixture.prior_results
      refute_receive {:group_hole_submitted, _}, 50
      before_count = assignment_count(group_id)

      with_failure_trigger!(group_id, fn ->
        assert {:error, _} = fill(fixture, fixture.admin, replacement.id, :primary_scorer)
      end)

      assert assignment_count(group_id) == before_count
      assert assignment_row!(revoked_id) == revoked
      assert group_state(group_id) == "attention_required"
      assert count_fill_audits(group_id) == 0

      assert [["withdrawn"]] ==
               Repo.query!("SELECT participation_status FROM round_entries WHERE id = $1::uuid", [
                 Ecto.UUID.dump!(fixture.withdrawn_entry.id)
               ]).rows

      assert [[1]] ==
               Repo.query!(
                 "SELECT count(*)::int FROM round_entry_participation_rulings WHERE id = $1::uuid",
                 [Ecto.UUID.dump!(ruling_id)]
               ).rows

      assert score_rows(group_id) == fixture.prior_results
      refute_receive {:group_role_vacancy_filled, _}, 50
      refute_receive {:playing_group_attention_cleared, _}, 50

      assert {:ok, filled} = fill(fixture, fixture.admin, replacement.id, :primary_scorer)

      assert [[^ruling]] =
               Repo.query!(
                 "SELECT to_jsonb(r) FROM round_entry_participation_rulings r WHERE id = $1::uuid",
                 [Ecto.UUID.dump!(ruling_id)]
               ).rows

      assert filled.withdrawal_ruling_id == ruling_id
      assert filled.assignment.id != revoked_id
      assert filled.assignment.assignment_version == 2
      assert filled.attention_cleared?
      assert assignment_row!(revoked_id) == revoked
      assert group_state(group_id) == "playing"
      assert side_result_state(fixture.side.id) == "review_required"
      assert membership_rows(group_id) == memberships
      context = fill_audit_context!(group_id)
      assert context["withdrawal_ruling_id"] == ruling_id
      assert context["vacancy"]["revoked_assignment_id"] == revoked_id
      assert context["replacement"]["assignment_id"] == filled.assignment.id
      assert context["verification"]["independent_verification_available"]
      assert context["verification"]["result_mappings"] != []
      assert_receive {:group_role_vacancy_filled, %{withdrawal_ruling_id: ^ruling_id}}
      assert_receive {:playing_group_attention_cleared, %{withdrawal_ruling_id: ^ruling_id}}

      second_hole_id = Enum.at(fixture.route, 1).id
      assert group_scoring_revision(group_id) == 1
      assert submissions_for_hole(group_id, second_hole_id) == []
      assert result_entries_for_hole(group_id, second_hole_id) == []

      assert {:error, :stale_role_assignment} =
               SubmitGroupHole.run(
                 grant,
                 fixture.event.id,
                 round_id,
                 next_submission_command(fixture, replacement.id, 1)
               )

      assert score_rows(group_id) == fixture.prior_results
      assert group_scoring_revision(group_id) == 1
      assert submissions_for_hole(group_id, second_hole_id) == []
      assert result_entries_for_hole(group_id, second_hole_id) == []
      refute_receive {:group_hole_submitted, _}, 50

      command = next_submission_command(fixture, replacement.id, 2)

      assert {:ok, receipt} =
               SubmitGroupHole.run(
                 grant,
                 fixture.event.id,
                 round_id,
                 command
               )

      assert receipt.role_assignment_version == 2
      assert group_scoring_revision(group_id) == 2

      assert submissions_for_hole(group_id, second_hole_id) == [
               [receipt.id, command.client_submission_id, filled.assignment.id, 2]
             ]

      expected_entries =
        fixture.entries
        |> Enum.reject(&(&1.id == fixture.withdrawn_entry.id))
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert result_entries_for_hole(group_id, second_hole_id) == expected_entries

      assert Enum.filter(score_rows(group_id), fn [row] ->
               row["round_hole_id"] == hd(fixture.route).id
             end) == fixture.prior_results

      assert_receive {:group_hole_submitted,
                      %{
                        round_id: ^round_id,
                        playing_group_id: ^group_id,
                        round_hole_id: ^second_hole_id,
                        scoring_revision: 2
                      }}

      refute_receive {:group_hole_submitted, _}, 50
      assert side_result_state(fixture.side.id) == "review_required"
    end)
  end

  defp vacancy_fixture!(:primary_scorer) do
    fixture = PaperRecoveryFixtures.setup_submit_fixture!(4)
    on_exit(fn -> cleanup_committed_fixture!(fixture) end)
    PaperRecoveryFixtures.set_round_state!(fixture.round, :draft)

    assert {:ok, _} =
             PaperRecoveryFixtures.assign_designated_verifier_for_fixture(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               Enum.at(fixture.entries, 1).id
             )

    assert {:ok, side} =
             Competition.create_competition_side(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.competition.id,
               :partnership
             )

    assert {:ok, _} =
             PaperRecoveryFixtures.set_side_membership_for_fixture(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.competition.id,
               side.id,
               fixture.entries |> Enum.take(2) |> Enum.map(& &1.id)
             )

    fixture = Map.put(fixture, :side, side)
    PaperRecoveryFixtures.set_round_state!(fixture.round, :scoring_open)

    assert {:ok, _} =
             SubmitGroupHole.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               first_submission_command(fixture)
             )

    subscribe(fixture.round.id)
    prior_results = score_rows(fixture.group.id)
    target = hd(fixture.entries)
    attrs = withdrawal_attrs(fixture)

    assert {:ok, withdrawal} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               attrs
             )

    Map.merge(fixture, %{
      withdrawal: withdrawal,
      withdrawn_entry: target,
      prior_results: prior_results,
      withdrawal_attrs: attrs
    })
  end

  defp cleanup_committed_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, :cleaned} =
               Repo.transaction(fn ->
                 Repo.query!(
                   "DROP TRIGGER round_entry_participation_rulings_reject_mutation ON public.round_entry_participation_rulings"
                 )

                 Repo.query!(
                   "ALTER TABLE public.score_revisions DISABLE TRIGGER score_revisions_immutable_rows"
                 )

                 try do
                   player_ids =
                     Repo.query!(
                       "SELECT player_id::text FROM round_entries WHERE round_id = $1::uuid",
                       [
                         Ecto.UUID.dump!(fixture.round.id)
                       ]
                     ).rows
                     |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end)

                   statements = [
                     {"DELETE FROM audit_events WHERE context->>'round_id' = $1",
                      [fixture.round.id]},
                     {"DELETE FROM round_entry_participation_rulings WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM score_verifications WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM score_revisions WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM score_queries WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM hole_results WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM hole_submissions WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM scorecards WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM competition_handicaps WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM handicap_snapshots WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM competition_side_results WHERE competition_side_id IN (SELECT id FROM competition_sides WHERE round_id = $1::uuid)",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM competition_side_memberships WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM competition_sides WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM group_role_assignments WHERE playing_group_id IN (SELECT id FROM playing_groups WHERE round_id = $1::uuid)",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM round_entries WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM playing_groups WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM round_competitions WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM round_tee_hole_snapshots WHERE round_tee_profile_snapshot_id IN (SELECT id FROM round_tee_profile_snapshots WHERE round_id = $1::uuid)",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM round_tee_profile_snapshots WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM round_holes WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM rounds WHERE id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM tee_rating_profiles WHERE id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.tee_profile.id)]},
                     {"DELETE FROM tee_sets WHERE id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.tee_set.id)]},
                     {"DELETE FROM course_holes WHERE course_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.course.id)]},
                     {"DELETE FROM courses WHERE id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.course.id)]},
                     {"DELETE FROM event_staff_assignments WHERE event_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.event.id)]},
                     {"DELETE FROM player_access_grants WHERE event_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.event.id)]},
                     {"DELETE FROM events WHERE id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.event.id)]},
                     {"DELETE FROM staff_users WHERE id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.admin.id)]}
                   ]

                   Enum.each(statements, fn {sql, args} -> Repo.query!(sql, args) end)

                   Enum.each(
                     player_ids,
                     &Repo.query!("DELETE FROM players WHERE id = $1::uuid", [Ecto.UUID.dump!(&1)])
                   )
                 after
                   Repo.query!(
                     "ALTER TABLE public.score_revisions ENABLE ALWAYS TRIGGER score_revisions_immutable_rows"
                   )

                   Repo.query!(
                     "ALTER TABLE public.score_revisions ENABLE ALWAYS TRIGGER score_revisions_immutable_truncate"
                   )

                   Repo.query!("""
                   CREATE TRIGGER round_entry_participation_rulings_reject_mutation
                   BEFORE UPDATE OR DELETE ON public.round_entry_participation_rulings
                   FOR EACH ROW EXECUTE FUNCTION public.reject_round_entry_participation_ruling_mutation()
                   """)

                   Repo.query!(
                     "ALTER TABLE public.round_entry_participation_rulings ENABLE ALWAYS TRIGGER round_entry_participation_rulings_reject_mutation"
                   )

                   Repo.query!(
                     "ALTER TABLE public.round_entry_participation_rulings ENABLE ALWAYS TRIGGER round_entry_participation_rulings_reject_truncate"
                   )
                 end

                 assert [["A"], ["A"]] ==
                          Repo.query!("""
                          SELECT tgenabled::text
                          FROM pg_trigger
                          WHERE tgrelid = 'public.round_entry_participation_rulings'::regclass
                            AND tgname IN (
                              'round_entry_participation_rulings_reject_mutation',
                              'round_entry_participation_rulings_reject_truncate'
                            )
                          ORDER BY tgname
                          """).rows

                 assert [["A"], ["A"]] ==
                          Repo.query!("""
                          SELECT tgenabled::text
                          FROM pg_trigger
                          WHERE tgrelid = 'public.score_revisions'::regclass
                            AND tgname IN (
                              'score_revisions_immutable_rows',
                              'score_revisions_immutable_truncate'
                            )
                          ORDER BY tgname
                          """).rows

                 :cleaned
               end)
    end)
  end

  defp first_submission_command(fixture) do
    %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: fixture.group.id,
      round_hole_id: hd(fixture.route).id,
      expected_group_score_revision: 0,
      results:
        Enum.map(fixture.entries, fn entry ->
          %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 5}
        end),
      captured_at: DateTime.utc_now(:microsecond)
    }
  end

  defp next_submission_command(fixture, _replacement_entry_id, role_version) do
    %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: fixture.group.id,
      round_hole_id: Enum.at(fixture.route, 1).id,
      expected_group_score_revision: 1,
      role_assignment_version: role_version,
      results:
        fixture.entries
        |> Enum.reject(&(&1.id == fixture.withdrawn_entry.id))
        |> Enum.map(fn entry ->
          %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 5}
        end),
      captured_at: DateTime.utc_now(:microsecond)
    }
  end

  defp withdrawal_attrs(fixture) do
    attested_at = DateTime.utc_now(:microsecond)

    %{
      reason: @reason,
      attestation: %{
        observed_at: DateTime.add(attested_at, -1, :second),
        method: "direct_visual",
        observation_location: "starting area for the next hole",
        round_id: fixture.round.id,
        playing_group_id: fixture.group.id,
        effective_round_hole_id: Enum.at(fixture.route, 1).id,
        effective_play_index: 1,
        confirms_unplayed?: true
      }
    }
  end

  defp fill(fixture, actor, replacement_id, role) do
    Competition.fill_group_role_vacancy(
      actor,
      fixture.event.id,
      fixture.round.id,
      fixture.group.id,
      replacement_id,
      role
    )
  end

  defp subscribe(round_id), do: Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{round_id}")

  defp assignment_for_role!(group_id, role) do
    [[id]] =
      Repo.query!(
        "SELECT id::text FROM group_role_assignments WHERE playing_group_id = $1::uuid AND role = $2 AND state = 'revoked' ORDER BY assignment_version DESC LIMIT 1",
        [Ecto.UUID.dump!(group_id), Atom.to_string(role)]
      ).rows

    Ecto.UUID.cast!(id)
  end

  defp assignment_row!(id) do
    [[row_id, state, version, entry_id]] =
      Repo.query!(
        "SELECT id::text, state, assignment_version, round_entry_id::text FROM group_role_assignments WHERE id = $1::uuid",
        [Ecto.UUID.dump!(id)]
      ).rows

    %{
      id: Ecto.UUID.cast!(row_id),
      state: state,
      assignment_version: version,
      round_entry_id: Ecto.UUID.cast!(entry_id)
    }
  end

  defp assignment_count(group_id) do
    [[count]] =
      Repo.query!(
        "SELECT count(*)::int FROM group_role_assignments WHERE playing_group_id = $1::uuid",
        [Ecto.UUID.dump!(group_id)]
      ).rows

    count
  end

  defp group_state(group_id) do
    [[state]] =
      Repo.query!("SELECT state FROM playing_groups WHERE id = $1::uuid", [
        Ecto.UUID.dump!(group_id)
      ]).rows

    state
  end

  defp group_scoring_revision(group_id) do
    [[revision]] =
      Repo.query!("SELECT scoring_revision FROM playing_groups WHERE id = $1::uuid", [
        Ecto.UUID.dump!(group_id)
      ]).rows

    revision
  end

  defp submissions_for_hole(group_id, hole_id) do
    Repo.query!(
      "SELECT id::text, client_submission_id::text, group_role_assignment_id::text, role_assignment_version FROM hole_submissions WHERE playing_group_id = $1::uuid AND round_hole_id = $2::uuid ORDER BY id",
      [Ecto.UUID.dump!(group_id), Ecto.UUID.dump!(hole_id)]
    ).rows
  end

  defp result_entries_for_hole(group_id, hole_id) do
    Repo.query!(
      "SELECT sc.round_entry_id::text FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id JOIN round_entries re ON re.id = sc.round_entry_id WHERE re.playing_group_id = $1::uuid AND hr.round_hole_id = $2::uuid ORDER BY sc.round_entry_id",
      [Ecto.UUID.dump!(group_id), Ecto.UUID.dump!(hole_id)]
    ).rows
    |> List.flatten()
  end

  defp score_rows(group_id) do
    Repo.query!(
      "SELECT to_jsonb(hr) FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id JOIN round_entries re ON re.id = sc.round_entry_id WHERE re.playing_group_id = $1::uuid ORDER BY sc.round_entry_id, hr.round_hole_id",
      [Ecto.UUID.dump!(group_id)]
    ).rows
  end

  defp membership_rows(group_id) do
    Repo.query!(
      "SELECT csm.id::text, csm.competition_side_id::text, csm.round_entry_id::text FROM competition_side_memberships csm JOIN competition_sides cs ON cs.id = csm.competition_side_id WHERE cs.round_id = (SELECT round_id FROM playing_groups WHERE id = $1::uuid) ORDER BY csm.competition_side_id, csm.round_entry_id",
      [Ecto.UUID.dump!(group_id)]
    ).rows
  end

  defp side_result_state(side_id) do
    case Repo.query!(
           "SELECT state FROM competition_side_results WHERE competition_side_id = $1::uuid",
           [Ecto.UUID.dump!(side_id)]
         ).rows do
      [[state]] -> state
      [] -> nil
    end
  end

  defp fill_audit_context!(group_id) do
    [[context]] =
      Repo.query!(
        "SELECT context FROM audit_events WHERE action = 'fill_group_role_vacancy' AND target_type = 'PlayingGroup' AND target_id = $1::uuid",
        [Ecto.UUID.dump!(group_id)]
      ).rows

    context
  end

  defp count_fill_audits(group_id) do
    [[count]] =
      Repo.query!(
        "SELECT count(*)::int FROM audit_events WHERE action = 'fill_group_role_vacancy' AND target_type = 'PlayingGroup' AND target_id = $1::uuid",
        [Ecto.UUID.dump!(group_id)]
      ).rows

    count
  end

  defp with_failure_trigger!(group_id, fun) do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    function = "gls42a_t4_failure_fn_#{suffix}"
    trigger = "gls42a_t4_failure_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.action = 'fill_group_role_vacancy' AND NEW.target_id = '#{group_id}'::uuid THEN
        RAISE EXCEPTION 'injected vacancy audit failure';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!(
      "CREATE TRIGGER #{trigger} BEFORE INSERT ON audit_events FOR EACH ROW EXECUTE FUNCTION #{function}()"
    )

    try do
      fun.()
    after
      Repo.query!("DROP TRIGGER IF EXISTS #{trigger} ON audit_events")
      Repo.query!("DROP FUNCTION IF EXISTS #{function}()")
    end
  end
end

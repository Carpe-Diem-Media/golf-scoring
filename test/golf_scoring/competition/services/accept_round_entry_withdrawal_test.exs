defmodule GolfScoring.Competition.Services.AcceptRoundEntryWithdrawalTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Competition
  alias GolfScoring.Competition.RoundEntry
  alias GolfScoring.Competition.Services.AcceptRoundEntryWithdrawal
  alias GolfScoring.Competition.Services.HandoverGroupRole
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures
  alias GolfScoring.Scoring.Services.SubmitGroupHole

  @reason "participant withdrew before starting the next hole"

  setup do
    Process.put(:gls34_prefix, "gls42a-withdrawal-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls34_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> if Process.alive?(owner), do: Sandbox.stop_owner(owner) end)
    %{sandbox_owner: owner}
  end

  test "accepts an active participant withdrawal after scoring and preserves prior results" do
    fixture = scored_fixture!(2)
    target = Enum.at(fixture.entries, 2)
    prior_results = results_for_entry(target.id)
    attrs = withdrawal_attrs(fixture)
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{fixture.round.id}")

    assert {:ok, accepted} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               attrs
             )

    assert accepted.round_entry_id == target.id
    assert accepted.effective_round_hole_id == Enum.at(fixture.route, 1).id
    assert accepted.effective_play_index == 1
    assert accepted.checkpoint_play_index == 0

    assert [["withdrawn"]] ==
             Repo.query!("SELECT participation_status FROM round_entries WHERE id = $1::uuid", [
               Ecto.UUID.dump!(target.id)
             ]).rows

    assert [["playing"]] ==
             Repo.query!("SELECT state FROM playing_groups WHERE id = $1::uuid", [
               Ecto.UUID.dump!(fixture.group.id)
             ]).rows

    assert [["provisional"]] ==
             Repo.query!(
               "SELECT csr.state FROM competition_side_results csr JOIN competition_side_memberships csm ON csm.competition_side_id = csr.competition_side_id WHERE csm.round_entry_id = $1::uuid",
               [Ecto.UUID.dump!(target.id)]
             ).rows

    assert count_rulings(target.id) == 1
    assert count_withdrawal_audits(accepted.ruling_id) == 1
    audit_context = withdrawal_audit_context(accepted.ruling_id)

    assert Map.take(audit_context, [
             "event_id",
             "authorized_by_event_staff_assignment_id",
             "authorized_by_role",
             "round_id",
             "playing_group_id",
             "round_entry_id",
             "ruling_id",
             "attestation",
             "checkpoint",
             "effective_boundary"
           ]) == %{
             "event_id" => fixture.event.id,
             "authorized_by_event_staff_assignment_id" =>
               audit_staff_assignment_id(accepted.ruling_id),
             "authorized_by_role" => "event_admin",
             "round_id" => fixture.round.id,
             "playing_group_id" => fixture.group.id,
             "round_entry_id" => target.id,
             "ruling_id" => accepted.ruling_id,
             "attestation" => %{
               "observed_at" => DateTime.to_iso8601(attrs.attestation.observed_at),
               "attested_at" => audit_attested_at(accepted.ruling_id),
               "method" => "direct_visual",
               "observation_location" => "starting area for the next hole",
               "confirms_unplayed" => true,
               "round_id" => fixture.round.id,
               "playing_group_id" => fixture.group.id,
               "effective_round_hole_id" => Enum.at(fixture.route, 1).id,
               "effective_play_index" => 1
             },
             "checkpoint" => %{
               "hole_submission_id" => accepted.checkpoint_hole_submission_id,
               "round_hole_id" => hd(fixture.route).id,
               "play_index" => 0,
               "scoring_revision" => 1
             },
             "effective_boundary" => %{
               "round_hole_id" => Enum.at(fixture.route, 1).id,
               "play_index" => 1
             }
           }

    assert length(audit_context["verification"]["active_role_assignments"]) == 2
    assert length(audit_context["verification"]["group_participants"]) == 3
    assert audit_context["group_attention"]["blocker"] == nil

    assert results_for_entry(target.id) == prior_results

    assert Enum.all?(prior_results, fn [_id, hole_id, _strokes, _revision] ->
             route_index = Enum.find_index(fixture.route, &(&1.id == Ecto.UUID.cast!(hole_id)))
             not is_nil(route_index) and route_index < accepted.effective_play_index
           end)

    assert side_membership_count(target.id) == 1

    assert_receive {:round_entry_withdrawn,
                    %{round_id: round_id, round_entry_id: entry_id, ruling_id: ruling_id}}

    assert round_id == fixture.round.id
    assert entry_id == target.id
    assert ruling_id == accepted.ruling_id

    refute_receive {:playing_group_attention_required, _}, 50
  end

  test "accepts a same-event Competition Manager assignment" do
    fixture = scored_fixture!(2)
    target = Enum.at(fixture.entries, 2)

    Repo.query!(
      "UPDATE event_staff_assignments SET role = 'competition_manager' WHERE event_id = $1::uuid AND staff_user_id = $2::uuid AND role = 'event_admin' AND status = 'active'",
      [Ecto.UUID.dump!(fixture.event.id), Ecto.UUID.dump!(fixture.admin.id)]
    )

    assert {:ok, accepted} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    assert withdrawal_audit_context(accepted.ruling_id)["authorized_by_role"] ==
             "competition_manager"
  end

  test "revokes the withdrawn scorer and blocks group scoring when independent verification is lost" do
    fixture = scored_fixture!(0)
    target = hd(fixture.entries)
    assignment = assignment_for_entry!(fixture.group.id, target.id, :primary_scorer)
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{fixture.round.id}")

    assert {:ok, accepted} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    assert role_assignment_state(assignment) == "revoked"
    assert group_state(fixture.group.id) == "attention_required"
    assert side_result_state(fixture.side.id) == "review_required"
    assert accepted.revoked_assignment_ids == [assignment]
    audit_context = withdrawal_audit_context(accepted.ruling_id)

    assert audit_context["group_attention"]["blocker"] ==
             "independent_verification_unavailable"

    assert Enum.any?(audit_context["revoked_assignments"], fn revoked ->
             revoked["assignment_version"] == 1
           end)

    command = %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: fixture.group.id,
      round_hole_id: Enum.at(fixture.route, 1).id,
      expected_group_score_revision: 1,
      results:
        Enum.map(fixture.entries, fn entry ->
          %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 5}
        end),
      captured_at: DateTime.utc_now(:microsecond)
    }

    assert {:error, _reason} =
             SubmitGroupHole.run(fixture.admin, fixture.event.id, fixture.round.id, command)

    assert_receive {:playing_group_attention_required,
                    %{round_id: round_id, playing_group_id: group_id, ruling_id: ruling_id}}

    assert round_id == fixture.round.id
    assert group_id == fixture.group.id
    assert ruling_id == accepted.ruling_id

    assert_receive {:competition_side_readiness_changed,
                    %{
                      round_id: readiness_round_id,
                      playing_group_id: readiness_group_id,
                      ruling_id: readiness_ruling_id,
                      competition_side_result_ids: [side_result_id]
                    }}

    assert readiness_round_id == fixture.round.id
    assert readiness_group_id == fixture.group.id
    assert readiness_ruling_id == accepted.ruling_id
    assert side_result_id == side_result_id_for(fixture.side.id)
  end

  test "revokes a withdrawn designated verifier and preserves no false coverage" do
    fixture = scored_fixture!(1)
    target = Enum.at(fixture.entries, 1)
    assignment = assignment_for_entry!(fixture.group.id, target.id, :designated_verifier)

    assert {:ok, accepted} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    assert role_assignment_state(assignment) == "revoked"
    assert accepted.revoked_assignment_ids == [assignment]
    assert group_state(fixture.group.id) == "attention_required"
    assert side_result_state(fixture.side.id) == "review_required"
  end

  test "rejects unauthorized staff, invalid attestations, and stale checkpoint claims without writes" do
    fixture = scored_fixture!(2)
    target = Enum.at(fixture.entries, 2)
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{fixture.round.id}")

    unauthorized = %StaffUser{id: Ecto.UUID.generate(), status: :active}

    assert {:error, :forbidden} =
             AcceptRoundEntryWithdrawal.run(
               unauthorized,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    other_event_fixture = PaperRecoveryFixtures.setup_submit_fixture!(2)

    assert {:error, :forbidden} =
             AcceptRoundEntryWithdrawal.run(
               other_event_fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    Repo.query!("UPDATE staff_users SET status = 'suspended' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(fixture.admin.id)
    ])

    assert {:error, :forbidden} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    Repo.query!("UPDATE staff_users SET status = 'active' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(fixture.admin.id)
    ])

    Repo.query!(
      "UPDATE event_staff_assignments SET status = 'revoked' WHERE event_id = $1::uuid AND staff_user_id = $2::uuid AND role = 'event_admin'",
      [Ecto.UUID.dump!(fixture.event.id), Ecto.UUID.dump!(fixture.admin.id)]
    )

    assert {:error, :forbidden} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    Repo.query!(
      "UPDATE event_staff_assignments SET status = 'active' WHERE event_id = $1::uuid AND staff_user_id = $2::uuid AND role = 'event_admin'",
      [Ecto.UUID.dump!(fixture.event.id), Ecto.UUID.dump!(fixture.admin.id)]
    )

    invalid_claim = %{
      checkpoint_round_hole_id: Ecto.UUID.generate(),
      effective_play_index: 1
    }

    invalid_attestations = [
      Map.put(withdrawal_attrs(fixture).attestation, :confirms_unplayed?, false),
      Map.put(withdrawal_attrs(fixture).attestation, :method, "second_hand"),
      Map.put(withdrawal_attrs(fixture).attestation, :observation_location, " "),
      Map.put(
        withdrawal_attrs(fixture).attestation,
        :observed_at,
        DateTime.add(DateTime.utc_now(:microsecond), -61, :second)
      ),
      Map.put(
        withdrawal_attrs(fixture).attestation,
        :effective_round_hole_id,
        hd(fixture.route).id
      ),
      Map.put(
        withdrawal_attrs(fixture).attestation,
        :playing_group_id,
        Ecto.UUID.generate()
      ),
      Map.put(
        withdrawal_attrs(fixture).attestation,
        :effective_play_index,
        2
      )
    ]

    for attestation <- invalid_attestations do
      assert {:error, _reason} =
               AcceptRoundEntryWithdrawal.run(
                 fixture.admin,
                 fixture.event.id,
                 fixture.round.id,
                 fixture.group.id,
                 target.id,
                 %{reason: @reason, attestation: attestation}
               )
    end

    assert {:error, :stale_checkpoint_claim} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               Map.put(withdrawal_attrs(fixture), :checkpoint, invalid_claim)
             )

    assert count_rulings(target.id) == 0
    assert count_withdrawal_audits_for_entry(target.id) == 0

    assert Repo.query!("SELECT participation_status FROM round_entries WHERE id = $1::uuid", [
             Ecto.UUID.dump!(target.id)
           ]).rows == [["active"]]

    assert group_state(fixture.group.id) == "playing"

    assert role_assignment_state(
             assignment_for_entry!(fixture.group.id, hd(fixture.entries).id, :primary_scorer)
           ) == "active"

    assert side_result_state(fixture.side.id) == "provisional"
    refute_receive {:round_entry_withdrawn, _}, 50
    refute_receive {:playing_group_attention_required, _}, 50
    refute_receive {:competition_side_readiness_changed, _}, 50
  end

  test "rejects inconsistent participation states, incomplete checkpoints, and invalid routes" do
    fixture = scored_fixture!(2)
    target = Enum.at(fixture.entries, 2)
    receipt_id = latest_submission_id!(fixture)

    for state <- ["not_started", "completed", "disqualified", "withdrawn"] do
      Repo.query!("UPDATE round_entries SET participation_status = $2 WHERE id = $1::uuid", [
        Ecto.UUID.dump!(target.id),
        state
      ])

      assert {:error, {:invalid_participation_state, _}} =
               AcceptRoundEntryWithdrawal.run(
                 fixture.admin,
                 fixture.event.id,
                 fixture.round.id,
                 fixture.group.id,
                 target.id,
                 withdrawal_attrs(fixture)
               )
    end

    Repo.query!("UPDATE round_entries SET participation_status = 'active' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(target.id)
    ])

    Repo.query!(
      "UPDATE playing_groups SET starting_round_hole_id = NULL, starting_position = NULL WHERE id = $1::uuid",
      [
        Ecto.UUID.dump!(fixture.group.id)
      ]
    )

    assert {:error, :starting_hole_not_assigned} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    Repo.query!(
      "UPDATE playing_groups SET starting_round_hole_id = $2::uuid, starting_position = 1 WHERE id = $1::uuid",
      [
        Ecto.UUID.dump!(fixture.group.id),
        Ecto.UUID.dump!(fixture.start_hole.id)
      ]
    )

    Repo.query!("UPDATE round_holes SET play_order = 19 WHERE id = $1::uuid", [
      Ecto.UUID.dump!(List.last(fixture.route).id)
    ])

    assert {:error, :invalid_round_route} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    Repo.query!("UPDATE round_holes SET play_order = 18 WHERE id = $1::uuid", [
      Ecto.UUID.dump!(List.last(fixture.route).id)
    ])

    Repo.query!("UPDATE hole_submissions SET round_hole_id = $2::uuid WHERE id = $1::uuid", [
      Ecto.UUID.dump!(receipt_id),
      Ecto.UUID.dump!(Enum.at(fixture.route, 1).id)
    ])

    assert {:error, :checkpoint_route_mismatch} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    Repo.query!("UPDATE hole_submissions SET round_hole_id = $2::uuid WHERE id = $1::uuid", [
      Ecto.UUID.dump!(receipt_id),
      Ecto.UUID.dump!(hd(fixture.route).id)
    ])

    Repo.query!("UPDATE playing_groups SET state = 'finished_playing' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(fixture.group.id)
    ])

    assert {:error, :playing_group_completed} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    Repo.query!("UPDATE playing_groups SET state = 'playing' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(fixture.group.id)
    ])

    Repo.query!(
      """
      INSERT INTO hole_submissions (
        client_submission_id, expected_group_score_revision, payload_fingerprint,
        submitted_payload, captured_at, accepted_at, round_id, playing_group_id,
        round_hole_id, submitted_by_staff_user_id
      )
      SELECT gen_random_uuid(), expected_group_score_revision, payload_fingerprint,
             submitted_payload, captured_at, accepted_at, round_id, playing_group_id,
             $2::uuid, submitted_by_staff_user_id
      FROM hole_submissions WHERE id = $1::uuid
      """,
      [Ecto.UUID.dump!(receipt_id), Ecto.UUID.dump!(Enum.at(fixture.route, 1).id)]
    )

    assert {:error, :checkpoint_submission_ambiguous} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    Repo.query!(
      "DELETE FROM hole_submissions WHERE id <> $1::uuid AND round_id = $2::uuid AND playing_group_id = $3::uuid",
      [
        Ecto.UUID.dump!(receipt_id),
        Ecto.UUID.dump!(fixture.round.id),
        Ecto.UUID.dump!(fixture.group.id)
      ]
    )

    insert_submission_receipt!(fixture, Enum.at(fixture.route, 1).id, 1)

    assert {:error, :checkpoint_submission_stale} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    Repo.query!(
      "DELETE FROM hole_submissions WHERE id <> $1::uuid AND round_id = $2::uuid AND playing_group_id = $3::uuid",
      [
        Ecto.UUID.dump!(receipt_id),
        Ecto.UUID.dump!(fixture.round.id),
        Ecto.UUID.dump!(fixture.group.id)
      ]
    )

    Repo.query!("DELETE FROM hole_submissions WHERE id = $1::uuid", [Ecto.UUID.dump!(receipt_id)])

    assert {:error, :checkpoint_submission_missing} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    Repo.query!("UPDATE playing_groups SET scoring_revision = 18 WHERE id = $1::uuid", [
      Ecto.UUID.dump!(fixture.group.id)
    ])

    assert {:error, :group_scoring_complete} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    Repo.query!("UPDATE playing_groups SET scoring_revision = 0 WHERE id = $1::uuid", [
      Ecto.UUID.dump!(fixture.group.id)
    ])

    assert {:error, :accepted_scoring_checkpoint_required} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    assert count_rulings(target.id) == 0
    assert count_withdrawal_audits_for_entry(target.id) == 0
    assert participation_status(target.id) == "active"
    assert group_state(fixture.group.id) == "playing"
  end

  test "rejects every terminal side result and preserves an existing review state" do
    fixture = scored_fixture!(0)
    target = hd(fixture.entries)

    for state <- ["ready_to_finalize", "finalized"] do
      set_side_result_state!(fixture, "provisional")
      set_side_result_state!(fixture, state)

      assert {:error, :competition_side_result_terminal} =
               AcceptRoundEntryWithdrawal.run(
                 fixture.admin,
                 fixture.event.id,
                 fixture.round.id,
                 fixture.group.id,
                 target.id,
                 withdrawal_attrs(fixture)
               )

      assert side_result_state(fixture.side.id) == state
      assert count_rulings(target.id) == 0
    end

    set_side_result_state!(fixture, "provisional")
    set_side_result_state!(fixture, "excluded")

    assert {:error, :competition_side_result_terminal} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    assert side_result_state(fixture.side.id) == "excluded"
    assert count_rulings(target.id) == 0

    review_fixture = scored_fixture!(0)
    review_target = hd(review_fixture.entries)
    set_side_result_state!(review_fixture, "review_required")

    assert {:ok, _accepted} =
             AcceptRoundEntryWithdrawal.run(
               review_fixture.admin,
               review_fixture.event.id,
               review_fixture.round.id,
               review_fixture.group.id,
               review_target.id,
               withdrawal_attrs(review_fixture)
             )

    assert side_result_state(review_fixture.side.id) == "review_required"
  end

  test "a second withdrawal request creates no duplicate ruling or side effects" do
    fixture = scored_fixture!(2)
    target = Enum.at(fixture.entries, 2)

    assert {:ok, accepted} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    before =
      {count_rulings(target.id), count_withdrawal_audits(accepted.ruling_id),
       side_membership_count(target.id)}

    assert {:error, {:invalid_participation_state, :withdrawn}} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    assert before ==
             {count_rulings(target.id), count_withdrawal_audits(accepted.ruling_id),
              side_membership_count(target.id)}
  end

  test "preserves a group's preexisting attention state and does not claim to clear it" do
    fixture = scored_fixture!(2)
    target = Enum.at(fixture.entries, 2)

    Repo.query!("UPDATE playing_groups SET state = 'attention_required' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(fixture.group.id)
    ])

    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{fixture.round.id}")

    assert {:ok, accepted} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    assert accepted.attention_required?
    assert group_state(fixture.group.id) == "attention_required"
    assert side_result_state(fixture.side.id) == "provisional"
    refute_receive {:playing_group_attention_required, _}, 50
  end

  test "failure at each persisted write rolls back the withdrawal and publishes no notifications" do
    tables = [
      "round_entry_participation_rulings",
      "round_entries",
      "group_role_assignments",
      "playing_groups",
      "competition_side_results",
      "audit_events"
    ]

    for table <- tables do
      fixture = scored_fixture!(0)
      target = hd(fixture.entries)
      assignment = assignment_for_entry!(fixture.group.id, target.id, :primary_scorer)
      trigger = install_withdrawal_write_failure_trigger!(table)
      Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{fixture.round.id}")

      try do
        assert {:error, _reason} =
                 AcceptRoundEntryWithdrawal.run(
                   fixture.admin,
                   fixture.event.id,
                   fixture.round.id,
                   fixture.group.id,
                   target.id,
                   withdrawal_attrs(fixture)
                 )

        assert count_rulings(target.id) == 0
        assert count_withdrawal_audits_for_entry(target.id) == 0

        assert Repo.query!("SELECT participation_status FROM round_entries WHERE id = $1::uuid", [
                 Ecto.UUID.dump!(target.id)
               ]).rows == [["active"]]

        assert role_assignment_state(assignment) == "active"
        assert group_state(fixture.group.id) == "playing"
        assert side_result_state(fixture.side.id) == "provisional"
        refute_receive {:round_entry_withdrawn, _}, 50
        refute_receive {:playing_group_attention_required, _}, 50
        refute_receive {:competition_side_readiness_changed, _}, 50
      after
        remove_withdrawal_write_failure_trigger!(trigger)
      end
    end
  end

  test "withdrawal leaves mystery rules, reveals, and side memberships unchanged" do
    fixture = scored_fixture!(2, 1, mystery?: true)
    target = Enum.at(fixture.entries, 2)
    mystery_before = mystery_snapshot(fixture.round.id)
    memberships_before = side_membership_count(target.id)

    assert {:ok, _accepted} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    assert mystery_snapshot(fixture.round.id) == mystery_before
    assert side_membership_count(target.id) == memberships_before
  end

  test "rejects invocation inside a caller-owned transaction" do
    fixture = scored_fixture!(2)
    target = Enum.at(fixture.entries, 2)

    assert {:ok, :rejected} =
             Repo.transaction(fn ->
               Repo.query!("SELECT id FROM round_entries WHERE id = $1::uuid FOR UPDATE", [
                 Ecto.UUID.dump!(target.id)
               ])

               assert {:error, :transaction_already_open} =
                        AcceptRoundEntryWithdrawal.run(
                          fixture.admin,
                          fixture.event.id,
                          fixture.round.id,
                          fixture.group.id,
                          target.id,
                          withdrawal_attrs(fixture)
                        )

               :rejected
             end)

    assert count_rulings(target.id) == 0
    assert group_state(fixture.group.id) == "playing"
  end

  test "the private participation transition rejects writes without coordinator evidence" do
    fixture = scored_fixture!(2)
    target = Enum.at(fixture.entries, 2)
    entry = Ash.get!(RoundEntry, target.id, authorize?: false)

    assert {:error, %Ash.Error.Invalid{}} =
             entry
             |> Ash.Changeset.for_update(:mark_participation_withdrawn_internal, %{})
             |> Ash.update(authorize?: false)

    assert participation_status(target.id) == "active"
    assert count_rulings(target.id) == 0
  end

  @tag :real_concurrency
  test "withdrawal and hole submission serialize in both Round-lock winner orders", %{
    sandbox_owner: owner
  } do
    submit_first_fixture = committed_fixture!(2, 1)
    register_committed_cleanup!(owner, submit_first_fixture)
    submit_command = submission_command(submit_first_fixture, 1)

    {submission, withdrawal} =
      race_with_audit_barrier!(
        "submit_group_hole",
        fn ->
          SubmitGroupHole.run(
            submit_first_fixture.admin,
            submit_first_fixture.event.id,
            submit_first_fixture.round.id,
            submit_command
          )
        end,
        fn ->
          AcceptRoundEntryWithdrawal.run(
            submit_first_fixture.admin,
            submit_first_fixture.event.id,
            submit_first_fixture.round.id,
            submit_first_fixture.group.id,
            Enum.at(submit_first_fixture.entries, 2).id,
            withdrawal_attrs_for_play(submit_first_fixture, 2)
          )
        end
      )

    assert match?({:ok, _}, submission)
    assert {:ok, accepted_after_submission} = withdrawal
    assert accepted_after_submission.scoring_revision == 2

    assert accepted_after_submission.effective_round_hole_id ==
             Enum.at(submit_first_fixture.route, 2).id

    assert count_submissions(submit_first_fixture) == 2
    assert participation_status(Enum.at(submit_first_fixture.entries, 2).id) == "withdrawn"
    withdrawal_first_fixture = committed_fixture!(2, 1)
    register_committed_cleanup!(owner, withdrawal_first_fixture)
    target = Enum.at(withdrawal_first_fixture.entries, 2)

    stale_submission = submission_command(withdrawal_first_fixture, 1)

    {withdrawal_result, submission_result} =
      race_with_audit_barrier!(
        "accept_round_entry_withdrawal",
        fn ->
          AcceptRoundEntryWithdrawal.run(
            withdrawal_first_fixture.admin,
            withdrawal_first_fixture.event.id,
            withdrawal_first_fixture.round.id,
            withdrawal_first_fixture.group.id,
            target.id,
            withdrawal_attrs_for_play(withdrawal_first_fixture, 1)
          )
        end,
        fn ->
          SubmitGroupHole.run(
            withdrawal_first_fixture.admin,
            withdrawal_first_fixture.event.id,
            withdrawal_first_fixture.round.id,
            stale_submission
          )
        end
      )

    assert match?({:ok, _}, withdrawal_result)
    assert {:error, _reason} = submission_result
    assert count_submissions(withdrawal_first_fixture) == 1
    assert count_rulings(target.id) == 1
    assert participation_status(target.id) == "withdrawn"
  end

  @tag :real_concurrency
  test "withdrawal and scorer handover serialize in both Round-lock winner orders", %{
    sandbox_owner: owner
  } do
    handover_first_fixture = committed_fixture!(0, 2)
    register_committed_cleanup!(owner, handover_first_fixture)
    scorer = hd(handover_first_fixture.entries)
    successor = Enum.at(handover_first_fixture.entries, 1)

    {handover, withdrawal} =
      race_with_audit_barrier!(
        "handover_group_role",
        fn ->
          HandoverGroupRole.run(
            handover_first_fixture.admin,
            handover_first_fixture.event.id,
            handover_first_fixture.round.id,
            handover_first_fixture.group.id,
            successor.id,
            :primary_scorer
          )
        end,
        fn ->
          AcceptRoundEntryWithdrawal.run(
            handover_first_fixture.admin,
            handover_first_fixture.event.id,
            handover_first_fixture.round.id,
            handover_first_fixture.group.id,
            scorer.id,
            withdrawal_attrs_for_play(handover_first_fixture, 1)
          )
        end
      )

    assert match?({:ok, _}, handover)
    assert {:ok, _accepted_after_handover} = withdrawal
    assert participation_status(scorer.id) == "withdrawn"
    assert group_state(handover_first_fixture.group.id) == "playing"

    assert role_state_for_entry(handover_first_fixture.group.id, scorer.id, :primary_scorer) ==
             "handed_over"

    assert active_role_holder(handover_first_fixture.group.id, :primary_scorer) == successor.id
    withdrawal_first_fixture = committed_fixture!(0, 2)
    register_committed_cleanup!(owner, withdrawal_first_fixture)
    scorer = hd(withdrawal_first_fixture.entries)
    successor = Enum.at(withdrawal_first_fixture.entries, 1)

    {withdrawal_result, handover_result} =
      race_with_audit_barrier!(
        "accept_round_entry_withdrawal",
        fn ->
          AcceptRoundEntryWithdrawal.run(
            withdrawal_first_fixture.admin,
            withdrawal_first_fixture.event.id,
            withdrawal_first_fixture.round.id,
            withdrawal_first_fixture.group.id,
            scorer.id,
            withdrawal_attrs_for_play(withdrawal_first_fixture, 1)
          )
        end,
        fn ->
          HandoverGroupRole.run(
            withdrawal_first_fixture.admin,
            withdrawal_first_fixture.event.id,
            withdrawal_first_fixture.round.id,
            withdrawal_first_fixture.group.id,
            successor.id,
            :primary_scorer
          )
        end
      )

    assert match?({:ok, _}, withdrawal_result)
    assert {:error, _reason} = handover_result
    assert participation_status(scorer.id) == "withdrawn"

    assert role_state_for_entry(withdrawal_first_fixture.group.id, scorer.id, :primary_scorer) ==
             "revoked"

    assert active_role_holder(withdrawal_first_fixture.group.id, :primary_scorer) == nil
    assert group_state(withdrawal_first_fixture.group.id) == "attention_required"
  end

  defp scored_fixture!(target_index, verifier_index \\ 1, options \\ []) do
    fixture = PaperRecoveryFixtures.setup_submit_fixture!(3)

    PaperRecoveryFixtures.set_round_state!(fixture.round, :draft)

    assert {:ok, _assignment} =
             PaperRecoveryFixtures.assign_designated_verifier_for_fixture(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               Enum.at(fixture.entries, verifier_index).id
             )

    member_ids =
      if target_index in [0, 1] do
        Enum.map(Enum.take(fixture.entries, 2), & &1.id)
      else
        [hd(fixture.entries).id, Enum.at(fixture.entries, target_index).id]
      end

    {side, mystery} =
      if Keyword.get(options, :mystery?, false) do
        side_members = Enum.filter(fixture.entries, &(&1.id in member_ids))

        mystery =
          PaperRecoveryFixtures.configure_mystery_for_groups!(
            fixture,
            [{fixture.group, side_members}]
          )

        [[side_id]] =
          Repo.query!(
            "SELECT cs.id::text FROM competition_sides cs JOIN competition_side_memberships csm ON csm.competition_side_id = cs.id WHERE cs.round_id = $1::uuid AND csm.round_entry_id = $2::uuid",
            [
              Ecto.UUID.dump!(fixture.round.id),
              Ecto.UUID.dump!(Enum.at(fixture.entries, target_index).id)
            ]
          ).rows

        {%{id: Ecto.UUID.cast!(side_id)}, mystery}
      else
        assert {:ok, side} =
                 Competition.create_competition_side(
                   fixture.admin,
                   fixture.event.id,
                   fixture.round.id,
                   fixture.competition.id,
                   :partnership
                 )

        assert {:ok, _memberships} =
                 PaperRecoveryFixtures.set_side_membership_for_fixture(
                   fixture.admin,
                   fixture.event.id,
                   fixture.round.id,
                   fixture.competition.id,
                   side.id,
                   member_ids
                 )

        {side, nil}
      end

    PaperRecoveryFixtures.set_round_state!(fixture.round, :scoring_open)

    checkpoint = hd(fixture.route)

    assert {:ok, _submission} =
             SubmitGroupHole.run(fixture.admin, fixture.event.id, fixture.round.id, %{
               client_submission_id: Ecto.UUID.generate(),
               playing_group_id: fixture.group.id,
               round_hole_id: checkpoint.id,
               expected_group_score_revision: 0,
               results:
                 Enum.map(fixture.entries, fn entry ->
                   %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 5}
                 end),
               captured_at: DateTime.utc_now(:microsecond)
             })

    Map.merge(fixture, %{side: side, checkpoint: checkpoint, mystery: mystery})
  end

  defp withdrawal_attrs(fixture, overrides \\ %{}),
    do: withdrawal_attrs_for_play(fixture, 1, overrides)

  defp withdrawal_attrs_for_play(fixture, effective_play_index, overrides \\ %{}) do
    attested_at = DateTime.utc_now(:microsecond)

    attestation = %{
      observed_at: DateTime.add(attested_at, -1, :second),
      method: "direct_visual",
      observation_location: "starting area for the next hole",
      round_id: fixture.round.id,
      playing_group_id: fixture.group.id,
      effective_round_hole_id: Enum.at(fixture.route, effective_play_index).id,
      effective_play_index: effective_play_index,
      confirms_unplayed?: true
    }

    Map.merge(%{reason: @reason, attestation: attestation}, overrides)
  end

  defp submission_command(fixture, expected_revision) do
    %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: fixture.group.id,
      round_hole_id: Enum.at(fixture.route, expected_revision).id,
      expected_group_score_revision: expected_revision,
      results:
        Enum.map(fixture.entries, fn entry ->
          %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 5}
        end),
      captured_at: DateTime.utc_now(:microsecond)
    }
  end

  defp committed_fixture!(target_index, verifier_index) do
    Sandbox.unboxed_run(Repo, fn -> scored_fixture!(target_index, verifier_index) end)
  end

  defp register_committed_cleanup!(owner, fixture) do
    on_exit(fn ->
      if Process.alive?(owner), do: Sandbox.stop_owner(owner)
      cleanup_committed_fixture!(fixture)
    end)
  end

  defp race_with_audit_barrier!(winner_action, winner_fun, waiter_fun) do
    barrier = install_audit_barrier!(winner_action)
    parent = self()

    lock_holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!("SELECT pg_advisory_lock($1)", [barrier.key])
          send(parent, {:gls42a_barrier_held, pg_backend_pid!()})

          receive do
            :gls42a_release_barrier ->
              Repo.query!("SELECT pg_advisory_unlock($1)", [barrier.key])
          after
            20_000 -> Repo.query!("SELECT pg_advisory_unlock($1)", [barrier.key])
          end
        end)
      end)

    winner =
      Task.async(fn ->
        receive do
          :gls42a_run_winner ->
            Sandbox.unboxed_run(Repo, fn ->
              pid = pg_backend_pid!()
              send(parent, {:gls42a_race_started, :winner, pid})
              winner_fun.()
            end)
        end
      end)

    waiter =
      Task.async(fn ->
        receive do
          :gls42a_run_waiter ->
            Sandbox.unboxed_run(Repo, fn ->
              pid = pg_backend_pid!()
              send(parent, {:gls42a_race_started, :waiter, pid})
              waiter_fun.()
            end)
        end
      end)

    try do
      assert_receive {:gls42a_barrier_held, _holder_pid}, 5_000
      send(winner.pid, :gls42a_run_winner)

      assert_receive {:gls42a_race_started, :winner, winner_pid}, 10_000
      await_advisory_wait!(winner_pid, System.monotonic_time(:millisecond) + 10_000)

      send(waiter.pid, :gls42a_run_waiter)

      assert_receive {:gls42a_race_started, :waiter, waiter_pid}, 10_000
      await_blocked_by!(waiter_pid, winner_pid, System.monotonic_time(:millisecond) + 10_000)

      send(lock_holder.pid, :gls42a_release_barrier)

      winner_result = Task.await(winner, 25_000)
      waiter_result = Task.await(waiter, 25_000)
      Task.await(lock_holder, 5_000)
      {winner_result, waiter_result}
    after
      send(lock_holder.pid, :gls42a_release_barrier)
      Task.shutdown(winner, :brutal_kill)
      Task.shutdown(waiter, :brutal_kill)
      Task.shutdown(lock_holder, :brutal_kill)
      remove_audit_barrier!(barrier)
    end
  end

  defp install_audit_barrier!(action) do
    key = 42_000_000 + System.unique_integer([:positive])
    suffix = Integer.to_string(System.unique_integer([:positive]))
    function_name = "gls42a_audit_barrier_fn_#{suffix}"
    trigger_name = "gls42a_audit_barrier_#{suffix}"

    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("""
      CREATE FUNCTION #{function_name}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.action = '#{action}' THEN
          PERFORM pg_advisory_lock(#{key});
          PERFORM pg_advisory_unlock(#{key});
        END IF;
        RETURN NEW;
      END;
      $$
      """)

      Repo.query!("""
      CREATE TRIGGER #{trigger_name}
      BEFORE INSERT ON audit_events
      FOR EACH ROW EXECUTE FUNCTION #{function_name}()
      """)
    end)

    %{key: key, function_name: function_name, trigger_name: trigger_name}
  end

  defp remove_audit_barrier!(barrier) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{barrier.trigger_name} ON audit_events")
      Repo.query!("DROP FUNCTION IF EXISTS #{barrier.function_name}()")
    end)
  end

  defp await_advisory_wait!(backend_pid, deadline) do
    wait_event =
      case Repo.query!(
             "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE pid = $1",
             [backend_pid]
           ).rows do
        [["Lock", "advisory"]] -> :advisory
        _ -> nil
      end

    cond do
      wait_event == :advisory ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected backend #{backend_pid} to wait on the withdrawal audit barrier")

      true ->
        Process.sleep(5)
        await_advisory_wait!(backend_pid, deadline)
    end
  end

  defp await_blocked_by!(waiting_pid, blocking_pid, deadline) do
    [[blocked?]] =
      Repo.query!(
        "SELECT $1::integer = ANY(pg_blocking_pids($2::integer))",
        [blocking_pid, waiting_pid]
      ).rows

    cond do
      blocked? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected PostgreSQL lock blocking between #{waiting_pid} and #{blocking_pid}")

      true ->
        Process.sleep(5)
        await_blocked_by!(waiting_pid, blocking_pid, deadline)
    end
  end

  defp pg_backend_pid! do
    Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
  end

  defp cleanup_committed_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      cleanup_committed_fixture_transaction!(fixture)
    end)
  end

  defp cleanup_committed_fixture_transaction!(fixture) do
    round = Ecto.UUID.dump!(fixture.round.id)
    event = Ecto.UUID.dump!(fixture.event.id)
    staff = Ecto.UUID.dump!(fixture.admin.id)

    Repo.transaction(fn ->
      Repo.query!(
        "DROP TRIGGER round_entry_participation_rulings_reject_mutation ON round_entry_participation_rulings"
      )

      cleanup_committed_fixture_rows!(fixture, round, event, staff)

      Repo.query!("""
      CREATE TRIGGER round_entry_participation_rulings_reject_mutation
      BEFORE UPDATE OR DELETE ON round_entry_participation_rulings
      FOR EACH ROW EXECUTE FUNCTION public.reject_round_entry_participation_ruling_mutation()
      """)
    end)
  end

  defp cleanup_committed_fixture_rows!(fixture, round, event, staff) do
    player_ids =
      Repo.query!("SELECT player_id::text FROM round_entries WHERE round_id = $1::uuid", [round]).rows
      |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end)

    cleanup_statements = [
      {"DELETE FROM audit_events WHERE context->>'round_id' = $1", [fixture.round.id]},
      {"DELETE FROM round_entry_participation_rulings WHERE round_id = $1::uuid", [round]},
      {"DELETE FROM hole_results WHERE round_id = $1::uuid", [round]},
      {"DELETE FROM hole_submissions WHERE round_id = $1::uuid", [round]},
      {"DELETE FROM scorecards WHERE round_id = $1::uuid", [round]},
      {"DELETE FROM competition_handicaps WHERE round_id = $1::uuid", [round]},
      {"DELETE FROM handicap_snapshots WHERE round_id = $1::uuid", [round]},
      {"DELETE FROM competition_side_results WHERE competition_side_id IN (SELECT id FROM competition_sides WHERE round_id = $1::uuid)",
       [round]},
      {"DELETE FROM competition_side_memberships WHERE round_id = $1::uuid", [round]},
      {"DELETE FROM competition_sides WHERE round_id = $1::uuid", [round]},
      {"DELETE FROM group_role_assignments WHERE playing_group_id IN (SELECT id FROM playing_groups WHERE round_id = $1::uuid)",
       [round]},
      {"DELETE FROM round_entries WHERE round_id = $1::uuid", [round]},
      {"DELETE FROM playing_groups WHERE round_id = $1::uuid", [round]},
      {"DELETE FROM round_competitions WHERE round_id = $1::uuid", [round]},
      {"DELETE FROM round_tee_hole_snapshots WHERE round_tee_profile_snapshot_id IN (SELECT id FROM round_tee_profile_snapshots WHERE round_id = $1::uuid)",
       [round]},
      {"DELETE FROM round_tee_profile_snapshots WHERE round_id = $1::uuid", [round]},
      {"DELETE FROM round_holes WHERE round_id = $1::uuid", [round]},
      {"DELETE FROM rounds WHERE id = $1::uuid", [round]},
      {"DELETE FROM tee_rating_profiles WHERE id = $1::uuid",
       [Ecto.UUID.dump!(fixture.tee_profile.id)]},
      {"DELETE FROM tee_sets WHERE id = $1::uuid", [Ecto.UUID.dump!(fixture.tee_set.id)]},
      {"DELETE FROM course_holes WHERE course_id = $1::uuid",
       [Ecto.UUID.dump!(fixture.course.id)]},
      {"DELETE FROM courses WHERE id = $1::uuid", [Ecto.UUID.dump!(fixture.course.id)]},
      {"DELETE FROM event_staff_assignments WHERE event_id = $1::uuid", [event]},
      {"DELETE FROM player_access_grants WHERE event_id = $1::uuid", [event]},
      {"DELETE FROM events WHERE id = $1::uuid", [event]},
      {"DELETE FROM staff_users WHERE id = $1::uuid", [staff]}
    ]

    Enum.each(cleanup_statements, fn {sql, args} -> Repo.query!(sql, args) end)

    Enum.each(
      player_ids,
      &Repo.query!("DELETE FROM players WHERE id = $1::uuid", [Ecto.UUID.dump!(&1)])
    )
  end

  defp results_for_entry(entry_id) do
    Repo.query!(
      "SELECT hr.id::text, hr.round_hole_id::text, hr.gross_strokes, hr.revision FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id WHERE sc.round_entry_id = $1::uuid ORDER BY hr.round_hole_id",
      [Ecto.UUID.dump!(entry_id)]
    ).rows
  end

  defp count_rulings(entry_id) do
    Repo.query!(
      "SELECT count(*)::int FROM round_entry_participation_rulings WHERE round_entry_id = $1::uuid",
      [Ecto.UUID.dump!(entry_id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp count_withdrawal_audits(ruling_id) do
    Repo.query!(
      "SELECT count(*)::int FROM audit_events WHERE action = 'accept_round_entry_withdrawal' AND target_id = $1::uuid",
      [Ecto.UUID.dump!(ruling_id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp side_membership_count(entry_id) do
    Repo.query!(
      "SELECT count(*)::int FROM competition_side_memberships WHERE round_entry_id = $1::uuid",
      [Ecto.UUID.dump!(entry_id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp assignment_for_entry!(group_id, entry_id, role) do
    [[id]] =
      Repo.query!(
        "SELECT id::text FROM group_role_assignments WHERE playing_group_id = $1::uuid AND round_entry_id = $2::uuid AND role = $3 AND state = 'active'",
        [Ecto.UUID.dump!(group_id), Ecto.UUID.dump!(entry_id), Atom.to_string(role)]
      ).rows

    Ecto.UUID.cast!(id)
  end

  defp role_assignment_state(assignment_id) do
    Repo.query!("SELECT state FROM group_role_assignments WHERE id = $1::uuid", [
      Ecto.UUID.dump!(assignment_id)
    ]).rows
    |> hd()
    |> hd()
  end

  defp role_state_for_entry(group_id, entry_id, role) do
    Repo.query!(
      "SELECT state FROM group_role_assignments WHERE playing_group_id = $1::uuid AND round_entry_id = $2::uuid AND role = $3",
      [Ecto.UUID.dump!(group_id), Ecto.UUID.dump!(entry_id), Atom.to_string(role)]
    ).rows
    |> hd()
    |> hd()
  end

  defp active_role_holder(group_id, role) do
    case Repo.query!(
           "SELECT round_entry_id::text FROM group_role_assignments WHERE playing_group_id = $1::uuid AND role = $2 AND state = 'active'",
           [Ecto.UUID.dump!(group_id), Atom.to_string(role)]
         ).rows do
      [[entry_id]] -> Ecto.UUID.cast!(entry_id)
      [] -> nil
    end
  end

  defp participation_status(entry_id) do
    Repo.query!("SELECT participation_status FROM round_entries WHERE id = $1::uuid", [
      Ecto.UUID.dump!(entry_id)
    ]).rows
    |> hd()
    |> hd()
  end

  defp count_submissions(fixture) do
    Repo.query!(
      "SELECT count(*)::int FROM hole_submissions WHERE round_id = $1::uuid AND playing_group_id = $2::uuid",
      [Ecto.UUID.dump!(fixture.round.id), Ecto.UUID.dump!(fixture.group.id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp latest_submission_id!(fixture) do
    [[id]] =
      Repo.query!(
        "SELECT id::text FROM hole_submissions WHERE round_id = $1::uuid AND playing_group_id = $2::uuid ORDER BY accepted_at DESC, id DESC LIMIT 1",
        [Ecto.UUID.dump!(fixture.round.id), Ecto.UUID.dump!(fixture.group.id)]
      ).rows

    Ecto.UUID.cast!(id)
  end

  defp insert_submission_receipt!(fixture, hole_id, expected_revision) do
    Repo.query!(
      """
      INSERT INTO hole_submissions (
        client_submission_id, expected_group_score_revision, payload_fingerprint,
        submitted_payload, captured_at, accepted_at, round_id, playing_group_id,
        round_hole_id, submitted_by_staff_user_id
      )
      SELECT gen_random_uuid(), $3::bigint, payload_fingerprint,
             submitted_payload, captured_at, clock_timestamp() AT TIME ZONE 'utc',
             round_id, playing_group_id, $2::uuid, submitted_by_staff_user_id
      FROM hole_submissions
      WHERE id = $1::uuid
      """,
      [
        Ecto.UUID.dump!(latest_submission_id!(fixture)),
        Ecto.UUID.dump!(hole_id),
        expected_revision
      ]
    )
  end

  defp group_state(group_id) do
    Repo.query!("SELECT state FROM playing_groups WHERE id = $1::uuid", [
      Ecto.UUID.dump!(group_id)
    ]).rows
    |> hd()
    |> hd()
  end

  defp side_result_state(side_id) do
    Repo.query!(
      "SELECT state FROM competition_side_results WHERE competition_side_id = $1::uuid",
      [Ecto.UUID.dump!(side_id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp side_result_id_for(side_id) do
    [[id]] =
      Repo.query!(
        "SELECT id::text FROM competition_side_results WHERE competition_side_id = $1::uuid",
        [Ecto.UUID.dump!(side_id)]
      ).rows

    Ecto.UUID.cast!(id)
  end

  defp set_side_result_state!(fixture, "excluded") do
    Repo.query!(
      "UPDATE competition_side_results SET state = 'excluded', excluded_by_staff_user_id = $2::uuid, exclusion_reason = 'test terminal state', excluded_at = now(), excluded_playing_group_id = $3::uuid, excluded_effective_round_hole_id = $4::uuid, excluded_effective_play_index = 1, excluded_preplay_confirmed = true WHERE competition_side_id = $1::uuid",
      [
        Ecto.UUID.dump!(fixture.side.id),
        Ecto.UUID.dump!(fixture.admin.id),
        Ecto.UUID.dump!(fixture.group.id),
        Ecto.UUID.dump!(Enum.at(fixture.route, 1).id)
      ]
    )
  end

  defp set_side_result_state!(fixture, state) do
    Repo.query!(
      "UPDATE competition_side_results SET state = $2, excluded_by_staff_user_id = NULL, exclusion_reason = NULL, excluded_at = NULL, excluded_playing_group_id = NULL, excluded_effective_round_hole_id = NULL, excluded_effective_play_index = NULL, excluded_preplay_confirmed = NULL WHERE competition_side_id = $1::uuid",
      [Ecto.UUID.dump!(fixture.side.id), state]
    )
  end

  defp count_withdrawal_audits_for_entry(entry_id) do
    Repo.query!(
      "SELECT count(*)::int FROM audit_events WHERE action = 'accept_round_entry_withdrawal' AND context->>'round_entry_id' = $1",
      [entry_id]
    ).rows
    |> hd()
    |> hd()
  end

  defp withdrawal_audit_context(ruling_id) do
    Repo.query!(
      "SELECT context FROM audit_events WHERE action = 'accept_round_entry_withdrawal' AND target_id = $1::uuid",
      [Ecto.UUID.dump!(ruling_id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp audit_staff_assignment_id(ruling_id) do
    withdrawal_audit_context(ruling_id)["authorized_by_event_staff_assignment_id"]
  end

  defp audit_attested_at(ruling_id) do
    withdrawal_audit_context(ruling_id)["attestation"]["attested_at"]
  end

  defp mystery_snapshot(round_id) do
    round = Ecto.UUID.dump!(round_id)

    %{
      tracks:
        Repo.query!(
          "SELECT id::text, track_type, configuration_state FROM scoring_tracks WHERE round_id = $1::uuid ORDER BY id",
          [round]
        ).rows,
      rules:
        Repo.query!(
          "SELECT id::text, round_hole_id::text, rule FROM mystery_hole_rules WHERE round_id = $1::uuid ORDER BY id",
          [round]
        ).rows,
      reveals:
        Repo.query!(
          "SELECT mr.id::text, mr.mystery_hole_rule_id::text FROM mystery_reveals mr JOIN mystery_hole_rules mhr ON mhr.id = mr.mystery_hole_rule_id WHERE mhr.round_id = $1::uuid ORDER BY mr.id",
          [round]
        ).rows
    }
  end

  defp install_withdrawal_write_failure_trigger!(table)
       when table in [
              "round_entry_participation_rulings",
              "round_entries",
              "group_role_assignments",
              "playing_groups",
              "competition_side_results",
              "audit_events"
            ] do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    function_name = "gls42a_reject_withdrawal_write_fn_#{suffix}"
    trigger_name = "gls42a_reject_withdrawal_write_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION public.#{function_name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'GLS-42A simulated #{table} failure' USING ERRCODE = '23514';
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger_name}
    BEFORE INSERT OR UPDATE ON public.#{table}
    FOR EACH ROW EXECUTE FUNCTION public.#{function_name}()
    """)

    %{table: table, function_name: function_name, trigger_name: trigger_name}
  end

  defp remove_withdrawal_write_failure_trigger!(trigger) do
    Repo.query!("DROP TRIGGER IF EXISTS #{trigger.trigger_name} ON public.#{trigger.table}")
    Repo.query!("DROP FUNCTION IF EXISTS public.#{trigger.function_name}()")
  end
end

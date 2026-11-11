defmodule GolfScoring.Scoring.ScoreVerificationBoundaryTest do
  use GolfScoring.DataCase, async: false

  alias Ash.Changeset
  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.HoleResult
  alias GolfScoring.Scoring.ScoreVerification
  alias GolfScoring.Scoring.ScoreVerificationWriteGuard, as: Guard
  alias GolfScoring.Scoring.Services.CorrectHoleResult
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures, as: Fixtures
  alias GolfScoring.Scoring.Services.VerifyHoleResult

  test "verification entrypoints reject an existing transaction before validation" do
    assert {:ok, results} =
             Repo.transaction(fn ->
               [
                 VerifyHoleResult.run(nil, nil, nil, %{}),
                 VerifyHoleResult.override(nil, nil, nil, %{})
               ]
             end)

    assert results == List.duplicate({:error, :outer_transaction_required}, 2)
  end

  test "nested verification and override preserve score and certification evidence" do
    f = fixture!()

    assert {:ok, %{grant: verifier_grant}} =
             Accounts.issue_player_access(f.admin, f.event.id, Enum.at(f.entries, 1).player_id)

    before_result = Ash.get!(HoleResult, f.result.id, authorize?: false)
    before_verifications = verification_rows(f)

    command = %{
      hole_result_id: f.result.id,
      hole_result_revision: f.result.revision,
      playing_group_id: f.group.id,
      role_assignment_id: f.assignment.id,
      role_assignment_version: f.assignment.assignment_version,
      reason: "marker unavailable"
    }

    assert {:ok, results} =
             Repo.transaction(fn ->
               [
                 VerifyHoleResult.run(verifier_grant, f.event.id, f.round.id, command),
                 VerifyHoleResult.override(f.admin, f.event.id, f.round.id, command)
               ]
             end)

    assert results == List.duplicate({:error, :outer_transaction_required}, 2)
    assert verification_rows(f) == before_verifications
    assert Ash.get!(HoleResult, f.result.id, authorize?: false) == before_result
    assert {:ok, certified} = override(f)
    assert certified.hole_result_revision == f.result.revision
  end

  test "direct pending creation rejects real scope and forged context, including authorization bypass" do
    f = fixture!()

    for authorize? <- [true, false], context <- forged_contexts() do
      changeset =
        ScoreVerification
        |> Changeset.for_create(:create_pending_internal, pending_scope(f))
        |> Changeset.set_context(context)

      assert_denied(Ash.create(changeset, authorize?: authorize?))
      assert verification_rows(f) == []
    end
  end

  test "pending rows created by correction cannot be directly certified or overridden" do
    f = fixture!()
    assert {:ok, correction} = correct(f)
    pending = correction.verification
    before = verification_rows(f)

    for authorize? <- [true, false],
        context <- forged_contexts(),
        {action, attrs} <- [
          {:verify_internal,
           %{
             verifier_round_entry_id: Enum.at(f.entries, 1).id,
             role_assignment_id: f.assignment.id,
             role_assignment_version: f.assignment.assignment_version
           }},
          {:override_internal,
           %{overridden_by_staff_user_id: f.admin.id, override_reason: "forged exception"}}
        ] do
      changeset =
        pending |> Changeset.for_update(action, attrs) |> Changeset.set_context(context)

      assert_denied(Ash.update(changeset, authorize?: authorize?))
      assert verification_rows(f) == before
    end

    assert pending.status == :pending
    assert pending.hole_result_revision == 2
    assert_clean_gates()
  end

  test "direct supersession rejects while authorized correction preserves certified history" do
    f = fixture!()
    assert {:ok, certified} = override(f)
    before = verification_rows(f)

    for context <- forged_contexts() do
      assert_denied(
        certified
        |> Changeset.for_update(:supersede_internal, %{})
        |> Changeset.set_context(context)
        |> Ash.update(authorize?: false)
      )

      assert verification_rows(f) == before
    end

    assert {:ok, correction} = correct(f)
    historical = Ash.get!(ScoreVerification, certified.id, authorize?: false)
    assert historical.status == :superseded
    assert historical.hole_result_revision == 1
    assert historical.override_reason == certified.override_reason
    assert correction.verification.status == :pending
    assert correction.verification.hole_result_revision == 2

    assert {:error, _} =
             historical
             |> Changeset.for_update(:override_internal, %{
               overridden_by_staff_user_id: f.admin.id,
               override_reason: "no reactivation"
             })
             |> Ash.update(authorize?: false)

    assert Ash.get!(ScoreVerification, certified.id, authorize?: false) == historical
    assert_clean_gates()
  end

  test "override audit failure rolls back new pending and certified evidence and clears capabilities" do
    f = fixture!()

    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_verification_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated verification audit failure'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER j2_reject_verification_audit BEFORE INSERT ON audit_events FOR EACH ROW WHEN (NEW.action = 'override_hole_verification') EXECUTE FUNCTION pg_temp.reject_verification_audit()"
    )

    assert {:error, _} = override(f)
    assert verification_rows(f) == []
    assert Ash.get!(HoleResult, f.result.id, authorize?: false) == f.result

    assert [[0]] =
             Repo.query!(
               "SELECT count(*)::int FROM audit_events WHERE action = 'override_hole_verification' AND context->>'round_id' = $1",
               [f.round.id]
             ).rows

    assert_clean_gates()
  end

  test "issued proof is consumed by the real write and cannot authorize post-operation replay" do
    f = fixture!()
    handler = {__MODULE__, make_ref()}
    event = [:golf_scoring, :repo, :query]
    :ok = :telemetry.attach(handler, event, &__MODULE__.observe_write/4, self())

    try do
      assert {:ok, certified} = override(f)
      assert Enum.any?(:telemetry.list_handlers(event), &(&1.id == handler))

      assert_receive {:verification_observed,
                      %{action: :create_pending_internal, used?: false} = issued}

      token = issued.token

      assert_receive {:verification_observed,
                      %{action: :create_pending_internal, used?: true, token: ^token}}

      before = verification_rows(f)

      replay =
        ScoreVerification
        |> Changeset.for_create(:create_pending_internal, pending_scope(f))
        |> Changeset.set_context(%{
          score_verification_write: %{owner: VerifyHoleResult, token: token}
        })

      assert_denied(Ash.create(replay, authorize?: false))

      assert {:error, :unauthorized_verification_write} =
               VerifyHoleResult.consume_verification_write(replay)

      assert {:error, :unauthorized_verification_write} =
               Task.async(fn -> VerifyHoleResult.consume_verification_write(replay) end)
               |> Task.await()

      assert certified.status == :overridden
      assert verification_rows(f) == before
      assert_clean_gates()
    after
      :telemetry.detach(handler)
      refute Enum.any?(:telemetry.list_handlers(event), &(&1.id == handler))
    end
  end

  # Passive observation only: no SQL, Ash writes, assertions or proof mutation.
  def observe_write(_event, _measurements, _metadata, owner) do
    if self() == owner do
      case Process.get({VerifyHoleResult, :verification_write}) do
        nil -> :ok
        proof -> send(owner, {:verification_observed, proof})
      end
    end
  end

  test "pure binding rejects wrong action, operation, revision, scope, process and consumed state" do
    f = fixture!()
    token = make_ref()

    changeset =
      ScoreVerification
      |> Changeset.for_create(:create_pending_internal, pending_scope(f))
      |> Changeset.set_context(%{
        score_verification_write: %{owner: VerifyHoleResult, token: token}
      })

    # This is a pure comparison fixture, not an issued capability or authorization.
    binding = %{
      owner: VerifyHoleResult,
      operation: :verify,
      token: token,
      pid: self(),
      used?: false,
      action: :create_pending_internal,
      record: changeset.data,
      scope: Guard.scope(changeset)
    }

    assert Guard.matches?(changeset, binding, VerifyHoleResult)

    for changed <- [
          %{binding | action: :override_internal},
          %{binding | operation: :correct},
          %{binding | used?: true},
          %{binding | scope: Map.put(binding.scope, :hole_result_revision, 2)},
          %{binding | scope: Map.put(binding.scope, :scorecard_id, Ecto.UUID.generate())}
        ] do
      refute Guard.matches?(changeset, changed, VerifyHoleResult)
    end

    assert {:error, :unauthorized_verification_write} =
             VerifyHoleResult.consume_verification_write(changeset)

    assert {:error, :unauthorized_verification_write} =
             CorrectHoleResult.consume_verification_write(changeset)

    task =
      Task.async(fn ->
        {Guard.matches?(changeset, binding, VerifyHoleResult),
         VerifyHoleResult.consume_verification_write(changeset)}
      end)

    assert {false, {:error, :unauthorized_verification_write}} = Task.await(task)
    assert verification_rows(f) == []
    assert_clean_gates()
  end

  defp forged_contexts do
    [
      %{},
      %{score_verification_write: %{owner: VerifyHoleResult, token: make_ref()}},
      %{score_verification_write: %{owner: CorrectHoleResult, token: make_ref()}}
    ]
  end

  defp assert_denied(result) do
    assert {:error, error} = result

    assert Exception.message(error) =~
             "ScoreVerification requires its owning operation capability"
  end

  defp assert_clean_gates do
    assert Process.get({VerifyHoleResult, :verification_write}) == nil
    assert Process.get({CorrectHoleResult, :verification_write}) == nil
    assert Process.get({CorrectHoleResult, :write}) == nil
  end

  defp pending_scope(f) do
    %{
      hole_result_id: f.result.id,
      hole_result_revision: f.result.revision,
      scorecard_id: f.result.scorecard_id,
      round_id: f.round.id,
      playing_group_id: f.group.id,
      subject_round_entry_id: hd(f.entries).id
    }
  end

  defp verification_rows(f) do
    Repo.query!(
      "SELECT id, hole_result_revision, status, verifier_round_entry_id, role_assignment_id, role_assignment_version, overridden_by_staff_user_id, override_reason FROM score_verifications WHERE hole_result_id = $1::uuid ORDER BY hole_result_revision",
      [Ecto.UUID.dump!(f.result.id)]
    ).rows
  end

  defp correct(f) do
    Scoring.correct_hole_result(f.admin, f.event.id, f.round.id, %{
      hole_result_id: f.result.id,
      expected_revision: 1,
      new_gross_strokes: 6,
      reason: "counted strokes"
    })
  end

  defp override(f) do
    Scoring.override_hole_verification(f.admin, f.event.id, f.round.id, %{
      hole_result_id: f.result.id,
      hole_result_revision: f.result.revision,
      playing_group_id: f.group.id,
      reason: "marker unavailable"
    })
  end

  defp fixture! do
    f = Fixtures.setup_submit_fixture!(2)
    Fixtures.set_round_state!(f.round, :draft)

    assert {:ok, side} =
             Competition.create_competition_side(
               f.admin,
               f.event.id,
               f.round.id,
               f.competition.id,
               :partnership
             )

    assert {:ok, _} =
             Competition.set_side_membership(
               f.admin,
               f.event.id,
               f.round.id,
               f.competition.id,
               side.id,
               Enum.map(f.entries, & &1.id)
             )

    assert {:ok, assignment} =
             Competition.assign_designated_verifier(
               f.admin,
               f.event.id,
               f.round.id,
               f.group.id,
               Enum.at(f.entries, 1).id
             )

    Fixtures.set_round_state!(f.round, :scoring_open)

    assert {:ok, _} =
             Scoring.submit_group_hole(f.admin, f.event.id, f.round.id, %{
               client_submission_id: Ecto.UUID.generate(),
               playing_group_id: f.group.id,
               round_hole_id: f.start_hole.id,
               expected_group_score_revision: 0,
               captured_at: DateTime.utc_now(),
               results:
                 Enum.map(
                   f.entries,
                   &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: 4}
                 )
             })

    [[id]] =
      Repo.query!(
        "SELECT hr.id::text FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id WHERE sc.round_entry_id = $1::uuid",
        [Ecto.UUID.dump!(hd(f.entries).id)]
      ).rows

    Map.merge(f, %{
      result: Ash.get!(HoleResult, Ecto.UUID.cast!(id), authorize?: false),
      assignment: assignment
    })
  end
end

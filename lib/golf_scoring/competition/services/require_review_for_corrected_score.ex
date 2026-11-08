defmodule GolfScoring.Competition.Services.RequireReviewForCorrectedScore do
  @moduledoc """
  Places every affected competitive result into review for a proven correction.

  Call `with_locked_scope/5` as the first locking operation in a caller-owned
  transaction. Its callback receives a two-argument review function accepting a
  ScoreRevision ID and expected resulting revision. A future correction writer
  can create its evidence inside that callback, after all required locks exist.

  This coordinator never starts or commits a transaction and never writes scores.
  Errors inside a transaction roll it back. The review function expires when the
  callback finishes and cannot be moved to another process or transaction.
  """

  alias Ash.Changeset
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Competition.CompetitionSideResult
  alias GolfScoring.LockProtocol
  alias GolfScoring.Repo

  @scope_key {__MODULE__, :scope}
  @proof_key {__MODULE__, :proof}

  @doc """
  Locks staff authority and gameplay scope, then invokes the callback in place.

  The trusted server-authenticated actor must currently be an Event Admin or
  Competition Manager. The Round must be scoring open or closed. All affected
  sides are discovered from membership, never supplied by the caller.

  The callback must return `{:ok, value}`. Any error or invalid result aborts the
  caller's transaction. No notifications are published by this helper.
  """
  def with_locked_scope(actor, event_id, round_id, hole_result_id, callback) do
    if Repo.in_transaction?() do
      with true <- is_nil(Process.get(@scope_key)),
           %StaffUser{id: actor_id} <- actor,
           {:ok, actor_id} <- Ecto.UUID.cast(actor_id),
           {:ok, event_id} <- Ecto.UUID.cast(event_id),
           {:ok, round_id} <- Ecto.UUID.cast(round_id),
           {:ok, hole_result_id} <- Ecto.UUID.cast(hole_result_id),
           true <- is_function(callback, 1) do
        scope = lock_scope!(actor_id, event_id, round_id, hole_result_id)
        Process.put(@scope_key, scope)

        try do
          review = fn revision_id, expected_revision ->
            require_review!(scope, revision_id, expected_revision)
          end

          case callback.(review) do
            {:ok, _} = result -> result
            {:error, reason} -> Repo.rollback(reason)
            _ -> Repo.rollback(:invalid_callback_result)
          end
        after
          Process.delete(@proof_key)
          Process.delete(@scope_key)
        end
      else
        false -> Repo.rollback(:nested_review_scope)
        _ -> Repo.rollback(:forbidden)
      end
    else
      {:error, :transaction_required}
    end
  end

  @doc false
  def correction_scope?(evidence) do
    scope = Process.get(@scope_key)

    Repo.in_transaction?() and is_map(scope) and
      scope.transaction_id == transaction_id() and
      Map.take(scope, Map.keys(evidence)) == evidence and
      scope_current?(scope) and
      Enum.all?(scope.sides, fn {side, result} -> result_state(result, side) == "provisional" end)
  end

  @doc false
  def verified_review?(context, result_id, side_id) do
    scope = Process.get(@scope_key)
    proof = Process.get(@proof_key)

    coordinator_proof?(context, scope, proof) and
      proof_targets_result?(scope, proof, result_id, side_id) and
      scope_current?(scope) and
      blocker(scope, proof.score_revision_id, proof.revision) == {:ok, proof.verification_id} and
      result_state(result_id, side_id) == "provisional"
  end

  defp coordinator_proof?(context, scope, proof) do
    Repo.in_transaction?() and is_map(scope) and is_map(proof) and
      Map.get(context, :corrected_score_review) == proof and
      proof.token == scope.token and proof.transaction_id == transaction_id()
  end

  defp proof_targets_result?(scope, proof, result_id, side_id) do
    proof.result_id == result_id and proof.side_id == side_id and
      {side_id, result_id} in scope.sides
  end

  defp lock_scope!(actor_id, event_id, round_id, hole_id) do
    with {:ok, _} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
         true <- authorized?(actor_id, event_id),
         {:ok, %{acquired: [round_lock]}} <- LockProtocol.acquire!(round: [round_id]),
         true <-
           round_lock.row.event_id == event_id and
             round_lock.row.state in ["scoring_open", "scoring_closed"],
         {:ok, subject} <- subject(hole_id, round_id),
         {:ok, %{acquired: [group_lock]}} <-
           LockProtocol.acquire!(playing_group: [subject.group_id]),
         true <- group_lock.row.round_id == round_id do
      assignments =
        Repo.query!(
          "SELECT id::text FROM group_role_assignments WHERE playing_group_id = $1::uuid AND state = 'active'",
          [uuid(subject.group_id)]
        ).rows
        |> Enum.map(&hd/1)

      acquire!(group_role_assignment: assignments)
      sides = affected_sides!(subject.entry_id, round_id)
      acquire!(competition_side: Enum.map(sides, &elem(&1, 0)))
      acquire!(competition_side_result: Enum.map(sides, &elem(&1, 1)))
      acquire!(score_row: [subject.card_id])

      scope =
        Map.merge(subject, %{
          actor_id: actor_id,
          event_id: event_id,
          round_id: round_id,
          hole_id: hole_id,
          sides: sides,
          token: make_ref(),
          transaction_id: transaction_id()
        })

      unless scope_current?(scope), do: Repo.rollback(:affected_side_scope_changed)
      require_supported_states!(scope)
      scope
    else
      false ->
        Repo.rollback(:forbidden_or_invalid_scope)

      {:error, reason}
      when reason in [:round_not_found, :playing_group_not_found, :hole_result_not_found] ->
        Repo.rollback(:invalid_scope)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp acquire!(request) do
    case LockProtocol.acquire!(request) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp subject(hole_id, round_id) do
    case Repo.query!(
           """
           SELECT sc.id::text, re.id::text, re.playing_group_id::text
           FROM hole_results hr
           JOIN scorecards sc ON sc.id = hr.scorecard_id AND sc.round_id = hr.round_id
           JOIN round_entries re ON re.id = sc.round_entry_id AND re.round_id = sc.round_id
           WHERE hr.id = $1::uuid AND hr.round_id = $2::uuid
           """,
           [uuid(hole_id), uuid(round_id)]
         ).rows do
      [[card_id, entry_id, group_id]] when not is_nil(group_id) ->
        {:ok, %{card_id: card_id, entry_id: entry_id, group_id: group_id}}

      _ ->
        {:error, :hole_result_not_found}
    end
  end

  defp side_rows(entry_id, round_id) do
    Repo.query!(
      """
      SELECT cs.id::text, csr.id::text
      FROM competition_side_memberships m
      JOIN competition_sides cs ON cs.id = m.competition_side_id AND cs.round_id = m.round_id AND cs.round_competition_id = m.round_competition_id
      JOIN round_competitions rc ON rc.id = cs.round_competition_id AND rc.round_id = cs.round_id
      LEFT JOIN competition_side_results csr ON csr.competition_side_id = cs.id
      WHERE m.round_entry_id = $1::uuid AND m.round_id = $2::uuid
      ORDER BY cs.id
      """,
      [uuid(entry_id), uuid(round_id)]
    ).rows
  end

  defp affected_sides!(entry_id, round_id) do
    rows = side_rows(entry_id, round_id)

    cond do
      rows == [] -> Repo.rollback(:no_affected_sides)
      Enum.any?(rows, fn [_, result] -> is_nil(result) end) -> Repo.rollback(:missing_side_result)
      length(rows) != length(Enum.uniq(rows)) -> Repo.rollback(:invalid_side_scope)
      true -> Enum.map(rows, &List.to_tuple/1)
    end
  end

  defp scope_current?(scope) do
    authorized?(scope.actor_id, scope.event_id) and
      subject(scope.hole_id, scope.round_id) ==
        {:ok, Map.take(scope, [:card_id, :entry_id, :group_id])} and
      side_rows(scope.entry_id, scope.round_id) == Enum.map(scope.sides, &Tuple.to_list/1) and
      Repo.query!("SELECT event_id::text, state FROM rounds WHERE id = $1::uuid", [
        uuid(scope.round_id)
      ]).rows in [[[scope.event_id, "scoring_open"]], [[scope.event_id, "scoring_closed"]]]
  end

  defp require_supported_states!(scope) do
    unless Enum.all?(scope.sides, fn {side, result} ->
             result_state(result, side) in ["provisional", "review_required"]
           end),
           do: Repo.rollback(:unsupported_side_result_state)
  end

  defp result_state(result_id, side_id) do
    case Repo.query!(
           "SELECT state FROM competition_side_results WHERE id = $1::uuid AND competition_side_id = $2::uuid",
           [uuid(result_id), uuid(side_id)]
         ).rows do
      [[state]] -> state
      _ -> nil
    end
  end

  defp require_review!(scope, revision_id, expected_revision) do
    validate_review_scope!(scope)

    with {:ok, revision_id} <- Ecto.UUID.cast(revision_id),
         true <- is_integer(expected_revision) and expected_revision > 1,
         {:ok, verification_id} <- blocker(scope, revision_id, expected_revision) do
      proof = %{
        token: scope.token,
        transaction_id: scope.transaction_id,
        score_revision_id: revision_id,
        revision: expected_revision,
        verification_id: verification_id
      }

      {:ok, Enum.map(scope.sides, &require_side_review!(&1, proof))}
    else
      _ -> Repo.rollback(:correction_blocker_not_found)
    end
  end

  defp validate_review_scope!(scope) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "review capability requires its owning transaction")

    unless Process.get(@scope_key) == scope and scope.transaction_id == transaction_id(),
      do: Repo.rollback(:invalid_review_scope)

    unless scope_current?(scope), do: Repo.rollback(:affected_side_scope_changed)
    require_supported_states!(scope)
  end

  defp require_side_review!({side_id, result_id}, proof) do
    result = Ash.get!(CompetitionSideResult, result_id, authorize?: false)

    if result.state == :review_required do
      result
    else
      update_side_review!(result, Map.merge(proof, %{side_id: side_id, result_id: result_id}))
    end
  end

  defp update_side_review!(result, proof) do
    Process.put(@proof_key, proof)

    try do
      result
      |> Changeset.for_update(:require_review_for_corrected_score_internal, %{})
      |> Changeset.set_context(%{corrected_score_review: proof})
      |> Ash.update(authorize?: false)
      |> case do
        {:ok, updated} -> updated
        {:error, error} -> Repo.rollback(error)
      end
    after
      Process.delete(@proof_key)
    end
  end

  defp blocker(scope, revision_id, revision) do
    case Repo.query!(
           """
           SELECT sv.id::text
           FROM hole_results hr
           JOIN score_revisions sr ON sr.hole_result_id = hr.id AND sr.resulting_revision = hr.revision AND sr.scorecard_id = hr.scorecard_id AND sr.round_id = hr.round_id
           JOIN score_verifications sv ON sv.hole_result_id = hr.id AND sv.hole_result_revision = hr.revision AND sv.scorecard_id = hr.scorecard_id AND sv.round_id = hr.round_id
           WHERE hr.id = $1::uuid AND hr.scorecard_id = $2::uuid AND hr.round_id = $3::uuid AND hr.revision = $4
             AND sr.id = $5::uuid AND sr.original_revision = hr.revision - 1
             AND sr.new_outcome = hr.outcome AND sr.new_gross_strokes IS NOT DISTINCT FROM hr.gross_strokes
             AND sv.status = 'pending' AND sv.subject_round_entry_id = $6::uuid AND sv.playing_group_id = $7::uuid
           """,
           [
             uuid(scope.hole_id),
             uuid(scope.card_id),
             uuid(scope.round_id),
             revision,
             uuid(revision_id),
             uuid(scope.entry_id),
             uuid(scope.group_id)
           ]
         ).rows do
      [[id]] -> {:ok, id}
      _ -> {:error, :correction_blocker_not_found}
    end
  end

  defp authorized?(actor_id, event_id),
    do: ActiveEventRole.authorized?(actor_id, event_id, [:event_admin, :competition_manager])

  defp transaction_id, do: Repo.query!("SELECT pg_current_xact_id()::text").rows |> hd() |> hd()
  defp uuid(id), do: Ecto.UUID.dump!(id)
end

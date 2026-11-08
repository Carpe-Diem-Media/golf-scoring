defmodule GolfScoring.Competition.Services.LoadSideReviewReason do
  @moduledoc """
  Reads correction-specific verification blockers for one competitive side.

  The caller must supply a trusted, server-authenticated staff actor, never a
  client-supplied identity. Event authority and evidence are evaluated in the
  same database statement snapshot. This projection does not evaluate other
  readiness blockers.
  """

  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Repo

  @doc """
  Returns current correction blockers or a neutral review status.

  Missing, unauthorized, excluded and mismatched scopes return the same error.
  Authority and evidence are checked in one PostgreSQL statement snapshot.
  Revocation after that snapshot can occur before the caller receives the result.
  In a repeatable-read transaction, the snapshot may be older than the statement.
  """
  def run(%StaffUser{id: actor_id}, event_id, round_id, result_id) do
    with {:ok, actor_id} <- Ecto.UUID.cast(actor_id),
         {:ok, event_id} <- Ecto.UUID.cast(event_id),
         {:ok, round_id} <- Ecto.UUID.cast(round_id),
         {:ok, result_id} <- Ecto.UUID.cast(result_id),
         rows when rows != [] <- read_rows(actor_id, event_id, round_id, result_id) do
      [[state | _] | _] = rows

      blockers =
        for [_, hole_id, revision, evidence_id, verification_id] <- rows, not is_nil(hole_id) do
          %{
            reason: :corrected_score_awaiting_verification,
            hole_result_id: hole_id,
            revision: revision,
            score_revision_id: evidence_id,
            score_verification_id: verification_id
          }
        end

      status =
        cond do
          blockers != [] -> :corrected_score_awaiting_verification
          state == "review_required" -> :review_reason_not_evaluated
          true -> :no_correction_blocker
        end

      {:ok, %{status: status, blockers: blockers, other_blockers_evaluated?: false}}
    else
      _ -> {:error, :not_found_or_forbidden}
    end
  end

  def run(_, _, _, _), do: {:error, :not_found_or_forbidden}

  defp read_rows(actor_id, event_id, round_id, result_id) do
    Repo.query!(
      """
      SELECT csr.state, blocker.hole_result_id, blocker.revision, blocker.score_revision_id, blocker.verification_id
      FROM competition_side_results csr
      JOIN competition_sides side ON side.id = csr.competition_side_id
      JOIN rounds r ON r.id = side.round_id
      LEFT JOIN LATERAL (
        SELECT hr.id::text AS hole_result_id, hr.revision, sr.id::text AS score_revision_id, sv.id::text AS verification_id
        FROM competition_side_memberships membership
        JOIN round_entries re ON re.id = membership.round_entry_id AND re.round_id = side.round_id
        JOIN scorecards sc ON sc.round_entry_id = re.id AND sc.round_id = side.round_id
        JOIN hole_results hr ON hr.scorecard_id = sc.id AND hr.round_id = side.round_id
        JOIN score_revisions sr ON sr.hole_result_id = hr.id AND sr.resulting_revision = hr.revision AND sr.scorecard_id = sc.id AND sr.round_id = side.round_id
        JOIN score_verifications sv ON sv.hole_result_id = hr.id AND sv.hole_result_revision = hr.revision AND sv.scorecard_id = sc.id AND sv.subject_round_entry_id = re.id AND sv.round_id = side.round_id AND sv.playing_group_id = re.playing_group_id AND sv.status = 'pending'
        WHERE membership.competition_side_id = side.id AND membership.round_id = side.round_id AND membership.round_competition_id = side.round_competition_id
      ) blocker ON true
      WHERE csr.id = $1::uuid AND side.round_id = $2::uuid AND r.event_id = $3::uuid AND csr.state <> 'excluded'
        AND EXISTS (SELECT 1 FROM staff_users staff JOIN event_staff_assignments assignment ON assignment.staff_user_id = staff.id WHERE staff.id = $4::uuid AND staff.status = 'active' AND assignment.event_id = r.event_id AND assignment.status = 'active' AND assignment.role IN ('event_admin', 'competition_manager'))
        AND EXISTS (SELECT 1 FROM competition_side_memberships m WHERE m.competition_side_id = side.id AND m.round_id = side.round_id AND m.round_competition_id = side.round_competition_id)
      ORDER BY blocker.hole_result_id
      """,
      Enum.map([result_id, round_id, event_id, actor_id], &Ecto.UUID.dump!/1)
    ).rows
  end
end

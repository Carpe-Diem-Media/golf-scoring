defmodule GolfScoring.Scoring.Services.LoadPlayerVerificationContext do
  @moduledoc false

  alias GolfScoring.Accounts.PlayerAccessGrant
  alias GolfScoring.Repo

  # One statement gives authority and result data the same PostgreSQL snapshot.
  # Only current group records and the latest older evidence status are returned.
  @sql """
  SELECT a.id::text, a.assignment_version, a.role, actor.id::text,
         hr.id::text, hr.round_hole_id::text, subject.id::text,
         hr.revision, hr.outcome, hr.gross_strokes,
         current_verification.status,
         (SELECT old.status FROM score_verifications old
          WHERE old.hole_result_id = hr.id AND old.hole_result_revision < hr.revision
          ORDER BY old.hole_result_revision DESC LIMIT 1),
         EXISTS (SELECT 1 FROM score_queries q
                 WHERE q.hole_result_id = hr.id AND q.status IN ('open', 'escalated')),
         EXISTS (SELECT 1 FROM group_role_assignments verifier
                 WHERE verifier.playing_group_id = pg.id AND verifier.state = 'active'
                   AND verifier.role = 'designated_verifier' AND verifier.round_entry_id = subject.id),
         concat_ws(' ', player.first_name, player.surname), hole.display_hole_number, hole.play_order
  FROM player_access_grants grant_row
  JOIN rounds r ON r.event_id = grant_row.event_id AND r.id = $3::uuid
  JOIN playing_groups pg ON pg.round_id = r.id AND pg.id = $4::uuid
  JOIN round_entries actor ON actor.round_id = r.id AND actor.playing_group_id = pg.id
                          AND actor.player_id = grant_row.player_id
                          AND actor.registration_status IN ('expected', 'checked_in')
                          AND actor.participation_status IN ('not_started', 'active', 'completed')
  JOIN group_role_assignments a ON a.playing_group_id = pg.id AND a.round_entry_id = actor.id
                               AND a.state = 'active'
                               AND a.role IN ('designated_verifier', 'primary_scorer')
  LEFT JOIN round_entries subject ON subject.round_id = r.id AND subject.playing_group_id = pg.id
  LEFT JOIN players player ON player.id = subject.player_id
  LEFT JOIN scorecards card ON card.round_entry_id = subject.id AND card.round_id = r.id
  LEFT JOIN hole_results hr ON hr.scorecard_id = card.id AND hr.round_id = r.id
  LEFT JOIN round_holes hole ON hole.id = hr.round_hole_id AND hole.round_id = r.id
  LEFT JOIN score_verifications current_verification ON current_verification.hole_result_id = hr.id
       AND current_verification.hole_result_revision = hr.revision
  WHERE grant_row.id = $1::uuid AND grant_row.event_id = $2::uuid
    AND grant_row.state = 'active' AND (grant_row.expires_at IS NULL OR grant_row.expires_at > now())
    AND r.state IN ('scoring_open', 'scoring_closed')
  ORDER BY a.id, hole.play_order, subject.id
  LIMIT 73
  """

  def run(%PlayerAccessGrant{id: grant_id}, event_id, round_id, group_id) do
    with {:ok, grant_id} <- Ecto.UUID.cast(grant_id),
         {:ok, event_id} <- Ecto.UUID.cast(event_id),
         {:ok, round_id} <- Ecto.UUID.cast(round_id),
         {:ok, group_id} <- Ecto.UUID.cast(group_id),
         %{rows: rows} when rows != [] and length(rows) < 73 <-
           Repo.query!(
             @sql,
             Enum.map([grant_id, event_id, round_id, group_id], &Ecto.UUID.dump!/1)
           ) do
      context(rows, event_id, round_id, group_id)
    else
      _ -> {:error, :not_authorized}
    end
  end

  def run(_, _, _, _), do: {:error, :not_authorized}

  defp context(rows, event_id, round_id, group_id) do
    assignments =
      rows |> Enum.map(fn [id, version, role | _] -> {id, version, role} end) |> Enum.uniq()

    case assignments do
      [{id, version, role}] ->
        results = rows |> Enum.filter(&(Enum.at(&1, 4) != nil)) |> Enum.map(&result/1)

        {:ok,
         %{
           event_id: event_id,
           round_id: round_id,
           group_id: group_id,
           assignment: %{id: id, version: version, role: String.to_existing_atom(role)},
           results: results
         }}

      _ ->
        {:error, :not_authorized}
    end
  end

  defp result([
         _id,
         _version,
         role,
         actor,
         id,
         hole,
         subject,
         revision,
         outcome,
         gross,
         status,
         historical,
         queried?,
         designated?,
         player_name,
         display_hole_number,
         play_order
       ]) do
    status = if status, do: String.to_existing_atom(status), else: :pending

    %{
      hole_result_id: id,
      round_hole_id: hole,
      subject_round_entry_id: subject,
      player_name: player_name,
      display_hole_number: display_hole_number,
      play_order: play_order,
      revision: revision,
      outcome: String.to_existing_atom(outcome),
      gross_strokes: gross,
      verification_status: status,
      historical_verification_status: if(historical, do: String.to_existing_atom(historical)),
      query_review?: queried?,
      actionable?:
        actor != subject and status == :pending and
          (role == "designated_verifier" or (role == "primary_scorer" and designated?))
    }
  end
end

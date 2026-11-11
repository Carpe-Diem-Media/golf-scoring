defmodule GolfScoring.Scoring.Services.LoadStaffScoreQueryReview do
  @moduledoc false

  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Repo

  @sql """
  SELECT page.id::text, page.status, page.reason, page.hole_result_revision,
         page.current_revision, page.verification_status, page.historical_status,
         page.resolution_reason, page.resolved_at, page.resolved_by_staff_user_id::text,
         page.resolved_by_round_entry_id::text, page.hole_result_id::text,
         page.scorecard_id::text, page.inserted_at, page.player_name, page.playing_group_id::text,
         page.display_hole_number, page.play_order, page.current_outcome, page.current_gross_strokes
  FROM rounds r
  JOIN staff_users staff ON staff.id = $1::uuid AND staff.status = 'active'
  LEFT JOIN LATERAL (
    SELECT q.id, q.status, q.reason, q.hole_result_revision, hr.revision AS current_revision,
           current_v.status AS verification_status,
           (SELECT old.status FROM score_verifications old
            WHERE old.hole_result_id = hr.id AND old.hole_result_revision < hr.revision
            ORDER BY old.hole_result_revision DESC LIMIT 1) AS historical_status,
           q.resolution_reason, q.resolved_at, q.resolved_by_staff_user_id,
           q.resolved_by_round_entry_id, q.hole_result_id, q.scorecard_id, q.inserted_at,
           player.first_name || ' ' || player.surname AS player_name, entry.playing_group_id,
           hole.display_hole_number, hole.play_order, hr.outcome AS current_outcome,
           hr.gross_strokes AS current_gross_strokes
    FROM (
      SELECT * FROM score_queries candidate
      WHERE candidate.round_id = r.id
        AND ($4::timestamp IS NULL OR (candidate.inserted_at, candidate.id) < ($4::timestamp, $5::uuid))
      ORDER BY candidate.inserted_at DESC, candidate.id DESC
      LIMIT $6
    ) q
    JOIN hole_results hr ON hr.id = q.hole_result_id AND hr.round_id = r.id
    JOIN scorecards card ON card.id = hr.scorecard_id AND card.id = q.scorecard_id AND card.round_id = r.id
    JOIN round_entries entry ON entry.id = card.round_entry_id AND entry.round_id = r.id
    JOIN players player ON player.id = entry.player_id
    JOIN round_holes hole ON hole.id = hr.round_hole_id AND hole.round_id = r.id
    LEFT JOIN score_verifications current_v ON current_v.hole_result_id = hr.id
      AND current_v.hole_result_revision = hr.revision
  ) page ON true
  WHERE r.id = $3::uuid AND r.event_id = $2::uuid
    AND EXISTS (SELECT 1 FROM event_staff_assignments a
                WHERE a.staff_user_id = staff.id AND a.event_id = r.event_id
                  AND a.status = 'active' AND a.role IN ('event_admin', 'competition_manager'))
  ORDER BY page.inserted_at DESC, page.id DESC
  """

  def run(%StaffUser{id: staff_id}, event_id, round_id, opts) do
    with {:ok, staff_id} <- Ecto.UUID.cast(staff_id),
         {:ok, event_id} <- Ecto.UUID.cast(event_id),
         {:ok, round_id} <- Ecto.UUID.cast(round_id),
         {:ok, limit, cursor_time, cursor_id} <- options(opts) do
      params = [uuid(staff_id), uuid(event_id), uuid(round_id), cursor_time, cursor_id, limit + 1]

      case Repo.query!(@sql, params).rows do
        [] -> {:error, :not_found_or_forbidden}
        [[nil | _]] -> {:ok, %{items: [], next_cursor: nil}}
        rows -> page(rows, limit)
      end
    else
      _ -> {:error, :invalid_input}
    end
  end

  def run(_, _, _, _), do: {:error, :invalid_input}

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:limit, :cursor] == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      limit = Keyword.get(opts, :limit, 50)

      with true <- is_integer(limit) and limit in 1..50,
           {:ok, time, id} <- cursor(Keyword.get(opts, :cursor)) do
        {:ok, limit, time, id}
      else
        _ -> {:error, :invalid_input}
      end
    else
      {:error, :invalid_input}
    end
  end

  defp options(_), do: {:error, :invalid_input}
  defp cursor(nil), do: {:ok, nil, nil}

  defp cursor(%{inserted_at: %NaiveDateTime{} = time, id: id} = cursor)
       when map_size(cursor) == 2 do
    with {:ok, ^time} <-
           NaiveDateTime.new(
             time.year,
             time.month,
             time.day,
             time.hour,
             time.minute,
             time.second,
             time.microsecond
           ),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, time, uuid(id)}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp cursor(_), do: {:error, :invalid_cursor}

  defp page(rows, limit) do
    items = rows |> Enum.take(limit) |> Enum.map(&item/1)
    last = List.last(items)
    next = if length(rows) > limit, do: %{inserted_at: last.inserted_at, id: last.id}
    {:ok, %{items: items, next_cursor: next}}
  end

  defp item([
         id,
         status,
         reason,
         recorded,
         current,
         verification,
         historical,
         resolution,
         resolved_at,
         staff_id,
         entry_id,
         result_id,
         scorecard_id,
         inserted_at,
         player_name,
         playing_group_id,
         display_hole_number,
         play_order,
         current_outcome,
         current_gross_strokes
       ]) do
    %{
      id: id,
      status: String.to_existing_atom(status),
      reason: reason,
      hole_result_id: result_id,
      scorecard_id: scorecard_id,
      recorded_revision: recorded,
      current_revision: current,
      stale?: recorded != current,
      verification_status:
        if(verification, do: String.to_existing_atom(verification), else: :pending),
      historical_verification_status: if(historical, do: String.to_existing_atom(historical)),
      resolution_reason: resolution,
      resolved_at: resolved_at,
      resolved_by_staff_user_id: staff_id,
      resolved_by_round_entry_id: entry_id,
      inserted_at: inserted_at,
      player_name: player_name,
      playing_group_id: playing_group_id,
      display_hole_number: display_hole_number,
      play_order: play_order,
      current_outcome: String.to_existing_atom(current_outcome),
      current_gross_strokes: current_gross_strokes
    }
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)
end

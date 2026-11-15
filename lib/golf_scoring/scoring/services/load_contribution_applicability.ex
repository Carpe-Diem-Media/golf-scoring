defmodule GolfScoring.Scoring.Services.LoadContributionApplicability do
  @moduledoc """
  Reads per-result withdrawal applicability for a Round and CompetitionSide.

  This internal projection does not decide any other scoring eligibility and does
  not change scoring facts. Ambiguous withdrawal evidence is unresolved.
  """

  alias GolfScoring.Repo

  @doc "Returns withdrawal applicability facts for the current results in the scoped side."
  def run(event_id, round_id, side_id) do
    with {:ok, event} <- Ecto.UUID.dump(event_id),
         {:ok, round} <- Ecto.UUID.dump(round_id),
         {:ok, side} <- Ecto.UUID.dump(side_id) do
      load(event, round, side)
    else
      :error -> {:error, :invalid_scope}
    end
  end

  defp load(event_id, round_id, side_id) do
    result =
      Repo.query!(
        """
        WITH scope AS (
          SELECT s.id, s.round_id, s.round_competition_id
          FROM competition_sides s
          JOIN rounds r ON r.id = s.round_id
          JOIN round_competitions rc ON rc.id = s.round_competition_id
            AND rc.round_id = r.id AND rc.event_id = r.event_id
          WHERE r.event_id = $1::uuid AND r.id = $2::uuid AND s.id = $3::uuid
        ), route AS (
          SELECT COALESCE(jsonb_agg(jsonb_build_object('id', rh.id::text, 'order', rh.play_order)
            ORDER BY rh.play_order), '[]'::jsonb) AS holes
          FROM round_holes rh WHERE rh.round_id = $2::uuid
        ), members AS MATERIALIZED (
          SELECT m.* FROM competition_side_memberships m JOIN scope s ON m.competition_side_id = s.id
        ), evidence AS MATERIALIZED (
          SELECT m.round_entry_id, COALESCE(jsonb_agg(jsonb_build_object(
            'id', w.id::text, 'kind', w.ruling_kind, 'event_id', w.event_id::text,
            'round_id', w.round_id::text, 'entry_id', w.round_entry_id::text,
            'group_id', w.playing_group_id::text, 'effective_hole_id', w.effective_round_hole_id::text,
            'effective_index', w.effective_play_index, 'confirmed', w.preplay_boundary_confirmed,
            'checkpoint_hole_id', w.checkpoint_round_hole_id::text,
            'checkpoint_index', w.checkpoint_play_index,
            'submission_id', w.checkpoint_hole_submission_id::text,
            'actor_id', w.authorized_by_staff_user_id::text, 'role', w.authorized_by_role,
            'assignment_id', w.authorized_by_event_staff_assignment_id::text,
            'audits', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', a.id::text,
              'actor_id', a.actor_staff_user_id::text, 'context', a.context)), '[]'::jsonb)
              FROM audit_events a WHERE a.target_type = 'RoundEntryParticipationRuling'
              AND a.target_id = w.id AND a.action = 'accept_round_entry_withdrawal')
          )) FILTER (WHERE w.id IS NOT NULL), '[]'::jsonb) AS rulings
          FROM members m LEFT JOIN round_entry_participation_rulings w ON w.round_entry_id = m.round_entry_id
          GROUP BY m.round_entry_id
        )
        SELECT route.holes, m.round_entry_id::text, e.event_id::text, e.round_id::text,
          e.playing_group_id::text, e.participation_status, g.round_id::text,
          g.starting_round_hole_id::text, h.id::text, h.revision, h.round_hole_id::text,
          h.round_id::text, sc.round_id::text,
          evidence.rulings, m.round_id::text, m.round_competition_id::text, s.round_competition_id::text
        FROM scope s CROSS JOIN route
        LEFT JOIN members m ON m.competition_side_id = s.id
        LEFT JOIN evidence ON evidence.round_entry_id = m.round_entry_id
        LEFT JOIN round_entries e ON e.id = m.round_entry_id
        LEFT JOIN playing_groups g ON g.id = e.playing_group_id
        LEFT JOIN scorecards sc ON sc.round_entry_id = e.id
        LEFT JOIN hole_results h ON h.scorecard_id = sc.id
        ORDER BY m.round_entry_id, h.id
        """,
        [event_id, round_id, side_id]
      )

    case result.rows do
      [] ->
        {:error, :invalid_scope}

      [[route | _] | _] = rows ->
        if valid_route?(route) do
          {:ok,
           rows
           |> Enum.reject(&(Enum.at(&1, 8) == nil))
           |> Enum.map(&fact(&1, event_id, round_id))}
        else
          {:error, :ambiguous_route}
        end
    end
  end

  defp valid_route?(route) do
    length(route) == 18 and Enum.map(route, & &1["order"]) == Enum.to_list(1..18) and
      length(Enum.uniq_by(route, & &1["id"])) == 18
  end

  defp fact(
         [
           route,
           entry_id,
           entry_event,
           entry_round,
           group_id,
           status,
           group_round,
           start_id,
           result_id,
           revision,
           hole_id,
           result_round,
           card_round,
           rulings,
           member_round,
           member_competition,
           side_competition
         ],
         event,
         round
       ) do
    event_id = Ecto.UUID.load!(event)
    round_id = Ecto.UUID.load!(round)
    ids = Enum.map(route, & &1["id"])
    start = Enum.find_index(ids, &(&1 == start_id))
    hole = Enum.find_index(ids, &(&1 == hole_id))
    index = if start && hole, do: Integer.mod(hole - start, 18)

    scope_valid? =
      Enum.all?([
        entry_event == event_id,
        entry_round == round_id,
        group_round == round_id,
        result_round == round_id,
        card_round == round_id,
        member_round == round_id,
        member_competition == side_competition,
        not is_nil(index)
      ])

    {applicability, reason, ruling_id} =
      if scope_valid? do
        decide(status, rulings, %{
          event: event_id,
          round: round_id,
          entry: entry_id,
          group: group_id,
          ids: ids,
          start: start,
          index: index
        })
      else
        {:unresolved, :inconsistent_scope_or_route, nil}
      end

    %{
      round_entry_id: entry_id,
      hole_result_id: result_id,
      revision: revision,
      round_hole_id: hole_id,
      play_index: index,
      withdrawal_applicability: applicability,
      ruling_id: ruling_id,
      unresolved_reason: reason
    }
  end

  defp decide("withdrawn", [ruling], scope) do
    if valid_ruling?(ruling, scope) do
      status = if scope.index < ruling["effective_index"], do: :applicable, else: :not_applicable
      {status, nil, ruling["id"]}
    else
      {:unresolved, :inconsistent_withdrawal_evidence, ruling["id"]}
    end
  end

  defp decide("withdrawn", [], _scope), do: {:unresolved, :missing_withdrawal_ruling, nil}

  defp decide("withdrawn", _rulings, _scope),
    do: {:unresolved, :ambiguous_withdrawal_rulings, nil}

  defp decide(_status, [], _scope), do: {:applicable, nil, nil}
  defp decide(_status, _rulings, _scope), do: {:unresolved, :unexpected_withdrawal_ruling, nil}

  defp valid_ruling?(ruling, scope) do
    boundary = ruling["effective_index"]
    checkpoint = ruling["checkpoint_index"]

    is_integer(boundary) and boundary in 1..17 and checkpoint == boundary - 1 and
      Enum.all?([
        ruling["kind"] == "round_withdrawal",
        ruling["event_id"] == scope.event,
        ruling["round_id"] == scope.round,
        ruling["entry_id"] == scope.entry,
        ruling["group_id"] == scope.group,
        ruling["confirmed"] == true,
        Enum.at(scope.ids, Integer.mod(scope.start + boundary, 18)) == ruling["effective_hole_id"],
        Enum.at(scope.ids, Integer.mod(scope.start + checkpoint, 18)) ==
          ruling["checkpoint_hole_id"],
        valid_audit?(ruling, scope)
      ])
  end

  defp valid_audit?(%{"audits" => [%{"context" => context} = audit]} = ruling, scope)
       when is_map(context) do
    with checkpoint when is_map(checkpoint) <- context["checkpoint"],
         boundary when is_map(boundary) <- context["effective_boundary"],
         attestation when is_map(attestation) <- context["attestation"] do
      Enum.all?([
        audit["actor_id"] == ruling["actor_id"],
        context["event_id"] == scope.event,
        context["round_id"] == scope.round,
        context["round_entry_id"] == scope.entry,
        context["playing_group_id"] == scope.group,
        context["ruling_id"] == ruling["id"],
        context["authorized_by_role"] == ruling["role"],
        context["authorized_by_event_staff_assignment_id"] == ruling["assignment_id"],
        valid_attestation?(attestation, ruling, scope),
        boundary["round_hole_id"] == ruling["effective_hole_id"],
        boundary["play_index"] == ruling["effective_index"],
        checkpoint["round_hole_id"] == ruling["checkpoint_hole_id"],
        checkpoint["play_index"] == ruling["checkpoint_index"],
        checkpoint["hole_submission_id"] == ruling["submission_id"]
      ])
    else
      _ -> false
    end
  end

  defp valid_audit?(_, _), do: false

  defp valid_attestation?(attestation, ruling, scope) do
    location = attestation["observation_location"]

    is_binary(location) and String.trim(location) != "" and
      Enum.all?([
        valid_attestation_time?(attestation),
        attestation["method"] == "direct_visual",
        attestation["confirms_unplayed"] == true,
        attestation["round_id"] == scope.round,
        attestation["playing_group_id"] == scope.group,
        attestation["effective_round_hole_id"] == ruling["effective_hole_id"],
        attestation["effective_play_index"] == ruling["effective_index"]
      ])
  end

  defp valid_attestation_time?(attestation) do
    with observed when is_binary(observed) <- attestation["observed_at"],
         received when is_binary(received) <- attestation["attested_at"],
         {:ok, observed, _} <- DateTime.from_iso8601(observed),
         {:ok, received, _} <- DateTime.from_iso8601(received) do
      DateTime.diff(received, observed, :microsecond) in 0..60_000_000
    else
      _ -> false
    end
  end
end

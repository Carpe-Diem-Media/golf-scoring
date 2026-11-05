defmodule GolfScoring.Scoring.Services.LoadGroupScorecard do
  @moduledoc false

  alias Decimal, as: D
  alias GolfScoring.Accounts.PlayerAccessGrantGuard
  alias GolfScoring.Competition.StartingPositionLabel
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Calculators.StablefordPoints
  alias GolfScoring.Scoring.Calculators.StrokeAllocation
  alias GolfScoring.Scoring.Policies.PickupEligibility

  @scheduled_holes 18
  @maximum_group_players 4
  @required_registration_statuses ["expected", "checked_in"]
  @active_participation_statuses ["not_started", "active"]
  @completed_participation_statuses ["completed"]

  @type scorecard :: %{
          required(:event_id) => Ecto.UUID.t(),
          required(:round_id) => Ecto.UUID.t(),
          required(:group_id) => Ecto.UUID.t(),
          required(:revision) => non_neg_integer(),
          required(:primary_scorer_assignment_id) => Ecto.UUID.t(),
          required(:scorer_round_entry_id) => Ecto.UUID.t(),
          required(:players) => [map()],
          required(:rotated_route) => [map()],
          required(:current_hole) => map() | nil,
          required(:lifecycle) => :scoring_active | :group_play_complete
        }

  @spec run(term(), term(), term(), term()) :: {:ok, scorecard()} | {:error, term()}
  def run(grant, event_id, round_id, group_id) do
    with {:ok, active_grant} <- reload_grant(grant),
         {:ok, ids} <- route_ids(event_id, round_id, group_id),
         :ok <- grant_matches_event(active_grant, ids.event_id),
         {:ok, rows} <- load_scorecard_rows(ids) do
      build_scorecard(active_grant, rows, ids)
    end
  end

  @spec run_for_assigned_group(term()) :: {:ok, scorecard()} | {:error, term()}
  def run_for_assigned_group(grant) do
    with {:ok, active_grant} <- reload_grant(grant),
         {:ok, ids} <- assigned_group_ids(active_grant),
         {:ok, rows} <- load_scorecard_rows(ids) do
      build_scorecard(active_grant, rows, ids)
    end
  end

  @spec preview(scorecard(), map()) :: [map()]
  def preview(%{current_hole: nil, players: players}, _result_values), do: players

  def preview(
        %{current_hole: current_hole, pickup_policy: pickup_policy, players: players},
        result_values
      )
      when is_map(result_values) do
    Enum.map(players, fn player ->
      result_value = result_values_for(result_values, player.id)
      fact = Map.fetch!(player.hole_facts, current_hole.id)
      allocated = Map.fetch!(player.strokes_by_hole, current_hole.id)
      pickup_eligible? = pickup_eligible?(result_value, fact, allocated, pickup_policy)

      player
      |> Map.put(:current_fact, fact)
      |> Map.put(:result_value, result_value)
      |> Map.put(:pickup_eligible?, pickup_eligible?)
      |> Map.put(:handicap_strokes_label, handicap_strokes_label(allocated))
      |> Map.put(:outcome_options, outcome_options(pickup_eligible?, result_value["outcome"]))
      |> Map.put(:preview, preview_result(result_value, fact.par, allocated, pickup_eligible?))
    end)
  end

  def preview(_scorecard, _result_values), do: []

  defp reload_grant(%{id: grant_id}) do
    case PlayerAccessGrantGuard.load_grant_for_session(grant_id) do
      {:ok, grant} -> {:ok, grant}
      {:error, _reason} -> {:error, :not_assigned}
    end
  end

  defp reload_grant(_), do: {:error, :not_assigned}

  defp route_ids(event_id, round_id, group_id) do
    with {:ok, event_id} <- Ecto.UUID.cast(event_id),
         {:ok, round_id} <- Ecto.UUID.cast(round_id),
         {:ok, group_id} <- Ecto.UUID.cast(group_id) do
      {:ok, %{event_id: event_id, round_id: round_id, group_id: group_id}}
    else
      _ -> {:error, :not_assigned}
    end
  end

  defp grant_matches_event(%{event_id: event_id}, event_id), do: :ok
  defp grant_matches_event(_, _), do: {:error, :not_assigned}

  defp assigned_group_ids(grant) do
    rows =
      Repo.query!(
        """
        SELECT r.event_id::text, r.id::text, pg.id::text
        FROM group_role_assignments assignment
        JOIN round_entries scorer_entry ON scorer_entry.id = assignment.round_entry_id
        JOIN playing_groups pg ON pg.id = assignment.playing_group_id
        JOIN rounds r ON r.id = pg.round_id
        WHERE scorer_entry.player_id = $1::uuid
          AND r.event_id = $2::uuid
          AND r.state = 'scoring_open'
          AND assignment.role = 'primary_scorer'
          AND assignment.state = 'active'
        ORDER BY r.id, pg.id
        """,
        [Ecto.UUID.dump!(grant.player_id), Ecto.UUID.dump!(grant.event_id)]
      ).rows

    case rows do
      [[event_id, round_id, group_id]] ->
        {:ok,
         %{
           event_id: Ecto.UUID.cast!(event_id),
           round_id: Ecto.UUID.cast!(round_id),
           group_id: Ecto.UUID.cast!(group_id)
         }}

      [] ->
        {:error, :not_assigned}

      _ ->
        {:error, :ambiguous_group_assignment}
    end
  end

  defp load_scorecard_rows(ids) do
    rows =
      Repo.query!(
        """
        SELECT r.event_id::text,
               r.id::text,
               r.state,
               course.name,
               pg.id::text,
               pg.state,
               pg.scoring_revision::int,
               pg.starting_round_hole_id::text,
               pg.starting_position::int,
               assignment.id::text,
               assignment.assignment_version::int,
               scorer_entry.id::text,
               scorer_entry.player_id::text,
               concat_ws(' ', scorer.first_name, scorer.surname),
               competition.pickup_policy_identifier,
               rh.id::text,
               rh.play_order::int,
               rh.display_hole_number::int,
               re.id::text,
               p.first_name,
               p.surname,
               re.registration_status,
               re.participation_status,
               re.round_tee_profile_snapshot_id::text,
               tee.tee_set_name,
               tee.rating_label,
               tee.course_rating::text,
               tee.slope_rating::int,
               tee.total_par::int,
               tee.applicable_par::int,
               handicap.source_handicap_index::text,
               handicap.deemed_handicap_basis::text,
               competition_handicap.playing_handicap::int,
               hole_fact.par::int,
               hole_fact.stroke_index::int,
               hole_fact.distance_m::int,
               hole_fact.plus_stroke_order::int
        FROM rounds r
        JOIN courses course ON course.id = r.course_id
        JOIN playing_groups pg ON pg.round_id = r.id
        LEFT JOIN group_role_assignments assignment
          ON assignment.playing_group_id = pg.id
          AND assignment.role = 'primary_scorer'
          AND assignment.state = 'active'
        LEFT JOIN round_entries scorer_entry ON scorer_entry.id = assignment.round_entry_id
        LEFT JOIN players scorer ON scorer.id = scorer_entry.player_id
        LEFT JOIN round_competitions competition
          ON competition.round_id = r.id AND competition.is_primary = true
        LEFT JOIN round_holes rh ON rh.round_id = r.id
        LEFT JOIN LATERAL (
          SELECT re.*
          FROM round_entries re
          WHERE re.round_id = r.id
            AND re.playing_group_id = pg.id
            AND re.registration_status = ANY($4::text[])
            AND (
              (pg.scoring_revision < 18 AND re.participation_status = ANY($5::text[]))
              OR
              (pg.scoring_revision >= 18 AND re.participation_status = ANY($6::text[]))
            )
          ORDER BY re.inserted_at, re.id
          LIMIT #{@maximum_group_players + 1}
        ) re ON true
        LEFT JOIN players p ON p.id = re.player_id
        LEFT JOIN round_tee_profile_snapshots tee
          ON tee.id = re.round_tee_profile_snapshot_id
        LEFT JOIN LATERAL (
          SELECT hs.source_handicap_index, hs.deemed_handicap_basis
          FROM handicap_snapshots hs
          WHERE hs.round_entry_id = re.id AND hs.round_id = re.round_id
          ORDER BY hs.inserted_at DESC, hs.id
          LIMIT 1
        ) handicap ON true
        LEFT JOIN competition_handicaps competition_handicap
          ON competition_handicap.round_entry_id = re.id
          AND competition_handicap.round_competition_id = competition.id
        LEFT JOIN round_tee_hole_snapshots hole_fact
          ON hole_fact.round_tee_profile_snapshot_id = re.round_tee_profile_snapshot_id
          AND hole_fact.round_hole_id = rh.id
        WHERE r.id = $1::uuid AND r.event_id = $2::uuid AND pg.id = $3::uuid
        ORDER BY re.inserted_at, re.id, rh.play_order
        """,
        [
          Ecto.UUID.dump!(ids.round_id),
          Ecto.UUID.dump!(ids.event_id),
          Ecto.UUID.dump!(ids.group_id),
          @required_registration_statuses,
          @active_participation_statuses,
          @completed_participation_statuses
        ]
      ).rows

    case rows do
      [] -> {:error, :not_found}
      rows -> {:ok, Enum.map(rows, &decode_row/1)}
    end
  end

  defp decode_row([
         event_id,
         round_id,
         round_state,
         course_name,
         group_id,
         group_state,
         revision,
         start_hole_id,
         starting_position,
         assignment_id,
         assignment_version,
         scorer_round_entry_id,
         scorer_player_id,
         scorer_name,
         pickup_policy,
         hole_id,
         play_order,
         display_hole_number,
         entry_id,
         first_name,
         surname,
         registration_status,
         participation_status,
         tee_snapshot_id,
         tee_set_name,
         rating_label,
         course_rating,
         slope_rating,
         total_par,
         applicable_par,
         source_handicap_index,
         deemed_handicap_basis,
         playing_handicap,
         par,
         stroke_index,
         distance_m,
         plus_stroke_order
       ]) do
    %{
      event_id: cast_uuid(event_id),
      round_id: cast_uuid(round_id),
      round_state: round_state,
      course_name: course_name,
      group_id: cast_uuid(group_id),
      group_state: group_state,
      revision: revision,
      start_hole_id: cast_uuid(start_hole_id),
      starting_position: starting_position,
      assignment_id: cast_uuid(assignment_id),
      assignment_version: assignment_version,
      scorer_round_entry_id: cast_uuid(scorer_round_entry_id),
      scorer_player_id: cast_uuid(scorer_player_id),
      scorer_name: scorer_name,
      pickup_policy: pickup_policy,
      hole_id: cast_uuid(hole_id),
      play_order: play_order,
      display_hole_number: display_hole_number,
      entry_id: cast_uuid(entry_id),
      player_name: player_name(first_name, surname),
      registration_status: registration_status,
      participation_status: participation_status,
      tee_snapshot_id: cast_uuid(tee_snapshot_id),
      tee_set_name: tee_set_name,
      rating_label: rating_label,
      course_rating: course_rating,
      slope_rating: slope_rating,
      total_par: total_par,
      applicable_par: applicable_par,
      handicap_index: source_handicap_index || deemed_handicap_basis,
      playing_handicap: playing_handicap,
      par: par,
      stroke_index: stroke_index,
      distance_m: distance_m,
      plus_stroke_order: plus_stroke_order
    }
  end

  defp player_name(nil, nil), do: nil
  defp player_name(first_name, surname), do: String.trim("#{first_name} #{surname}")

  defp build_scorecard(grant, rows, ids) do
    context_rows = Enum.uniq_by(rows, &context_key/1)

    case context_rows do
      [context_row] ->
        with :ok <- require_primary_scorer(context_row, grant.player_id),
             :ok <- require_open_round(context_row.round_state),
             {:ok, route} <- build_route(rows),
             {:ok, players} <- build_players(rows, context_row.revision) do
          project_scorecard(ids, context_row, route, players)
        end

      [] ->
        {:error, :not_found}

      _ ->
        {:error, :ambiguous_group_context}
    end
  end

  defp context_key(row) do
    Map.take(row, [
      :event_id,
      :round_id,
      :round_state,
      :course_name,
      :group_id,
      :group_state,
      :revision,
      :start_hole_id,
      :starting_position,
      :assignment_id,
      :assignment_version,
      :scorer_player_id,
      :scorer_name,
      :pickup_policy
    ])
  end

  defp require_primary_scorer(
         %{
           assignment_id: assignment_id,
           assignment_version: assignment_version,
           scorer_round_entry_id: round_entry_id,
           scorer_player_id: player_id
         },
         player_id
       )
       when not is_nil(assignment_id) and is_integer(assignment_version) and
              assignment_version > 0 and not is_nil(round_entry_id) and not is_nil(player_id),
       do: :ok

  defp require_primary_scorer(_, _), do: {:error, :not_primary_scorer}

  defp require_open_round("scoring_open"), do: :ok
  defp require_open_round(_), do: {:error, :round_not_open}

  defp build_route(rows) do
    route =
      rows
      |> Enum.reject(&is_nil(&1.hole_id))
      |> Enum.uniq_by(& &1.hole_id)
      |> Enum.map(fn row ->
        %{
          id: row.hole_id,
          play_order: row.play_order,
          display_hole_number: row.display_hole_number
        }
      end)
      |> Enum.sort_by(& &1.play_order)

    if length(route) == @scheduled_holes do
      {:ok, route}
    else
      {:error, :invalid_route}
    end
  end

  defp build_players(rows, revision) do
    eligible_participation_statuses =
      if revision >= @scheduled_holes do
        ["completed"]
      else
        @active_participation_statuses
      end

    entry_rows =
      rows
      |> Enum.reject(&is_nil(&1.entry_id))
      |> Enum.filter(fn row ->
        row.registration_status in @required_registration_statuses and
          row.participation_status in eligible_participation_statuses
      end)

    grouped_rows = Enum.group_by(entry_rows, & &1.entry_id)
    entry_ids = entry_rows |> Enum.map(& &1.entry_id) |> Enum.uniq()

    Enum.reduce_while(entry_ids, {:ok, []}, fn entry_id, {:ok, players} ->
      case build_player(Map.fetch!(grouped_rows, entry_id)) do
        {:ok, player} -> {:cont, {:ok, [player | players]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, players} when length(players) in 2..@maximum_group_players ->
        {:ok,
         players
         |> Enum.reverse()
         |> Enum.with_index()
         |> Enum.map(fn {player, index} -> Map.put(player, :index, index) end)}

      {:ok, _players} ->
        {:error, :invalid_group_size}

      error ->
        error
    end
  end

  defp build_player([%{tee_snapshot_id: nil} | _]), do: {:error, :tee_not_assigned}
  defp build_player([%{playing_handicap: nil} | _]), do: {:error, :handicap_unavailable}

  defp build_player([entry | entry_rows]) do
    facts =
      [entry | entry_rows]
      |> Enum.reject(&is_nil(&1.hole_id))
      |> Enum.uniq_by(& &1.hole_id)
      |> Enum.sort_by(& &1.play_order)
      |> Enum.map(fn row ->
        %{
          round_hole_id: row.hole_id,
          par: row.par,
          stroke_index: row.stroke_index,
          distance_m: row.distance_m,
          plus_stroke_order: row.plus_stroke_order
        }
      end)

    case StrokeAllocation.allocate(entry.playing_handicap, facts) do
      {:ok, %{strokes_by_round_hole_id: strokes}} ->
        {:ok,
         %{
           id: entry.entry_id,
           name: entry.player_name,
           tee_snapshot_id: entry.tee_snapshot_id,
           tee_set_name: entry.tee_set_name,
           rating_label: entry.rating_label,
           course_rating: entry.course_rating,
           slope_rating: entry.slope_rating,
           total_par: entry.total_par,
           applicable_par: entry.applicable_par,
           handicap_index: entry.handicap_index,
           handicap_index_label: format_handicap_index(entry.handicap_index),
           playing_handicap: entry.playing_handicap,
           hole_facts: Map.new(facts, &{&1.round_hole_id, &1}),
           strokes_by_hole: strokes,
           handicap_strokes_by_hole: strokes
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp project_scorecard(_ids, %{revision: revision}, _route, _players)
       when not is_integer(revision) or revision < 0,
       do: {:error, :group_unavailable}

  defp project_scorecard(ids, context, route, players) do
    with {:ok, start_index} <- route_start_index(route, context.start_hole_id),
         :ok <- validate_group_state(context) do
      rotated_route = rotate_route(route, start_index)
      complete? = context.revision >= @scheduled_holes
      current_hole = if complete?, do: nil, else: Enum.at(rotated_route, context.revision)

      if complete? or current_hole do
        starting_hole = Enum.at(route, start_index)
        starting_position = context.starting_position || 1

        {:ok,
         %{
           event_id: ids.event_id,
           round_id: ids.round_id,
           group_id: ids.group_id,
           revision: context.revision,
           primary_scorer_assignment_id: context.assignment_id,
           scorer_round_entry_id: context.scorer_round_entry_id,
           assignment_version: context.assignment_version,
           scorer_name: context.scorer_name,
           pickup_policy: context.pickup_policy,
           route: route,
           rotated_route: rotated_route,
           starting_hole: starting_hole,
           starting_hole_label:
             StartingPositionLabel.format(
               starting_hole.display_hole_number,
               starting_position
             ),
           starting_position: starting_position,
           group_label:
             StartingPositionLabel.format(
               starting_hole.display_hole_number,
               starting_position
             ),
           course_name: context.course_name,
           current_hole: current_hole,
           route_display:
             Enum.map_join(rotated_route, ", ", &Integer.to_string(&1.display_hole_number)),
           players: players,
           entry_count: length(players),
           completed_holes: min(context.revision, @scheduled_holes),
           remaining_holes: max(@scheduled_holes - min(context.revision, @scheduled_holes), 0),
           lifecycle: if(complete?, do: :group_play_complete, else: :scoring_active)
         }}
      else
        {:error, :group_play_complete}
      end
    end
  end

  defp validate_group_state(%{revision: revision}) when revision >= @scheduled_holes, do: :ok

  defp validate_group_state(%{revision: revision, group_state: state})
       when revision in 0..17 and state in ["not_started", "playing"],
       do: :ok

  defp validate_group_state(_), do: {:error, :group_unavailable}

  defp route_start_index(route, start_hole_id) do
    case Enum.find_index(route, &(&1.id == start_hole_id)) do
      nil -> {:error, :starting_hole_unavailable}
      index -> {:ok, index}
    end
  end

  defp rotate_route(route, index), do: Enum.drop(route, index) ++ Enum.take(route, index)

  defp pickup_eligible?(result_value, fact, allocated, pickup_policy) do
    case parse_optional_integer(result_value["strokes_taken"]) do
      {:ok, taken} ->
        match?(
          {:ok, %{eligible?: true}},
          PickupEligibility.decide(%{
            pickup_policy_identifier: pickup_policy,
            par: fact.par,
            allocated_strokes: allocated,
            strokes_taken: taken
          })
        )

      _ ->
        false
    end
  end

  defp preview_result(%{"outcome" => "holed_out"} = result, par, allocated, _pickup_eligible?) do
    with {:ok, gross} <- parse_integer(result["gross_strokes"]),
         true <- gross > 0,
         {:ok, %{competition_points: points, competition_net_strokes: net}} <-
           StablefordPoints.calculate(%{
             outcome: :holed_out,
             gross_strokes: gross,
             par: par,
             allocated_strokes: allocated
           }) do
      %{handicap_adjusted: net, points: points}
    else
      _ -> nil
    end
  end

  defp preview_result(%{"outcome" => "picked_up"}, _par, _allocated, true),
    do: %{handicap_adjusted: nil, points: 0}

  defp preview_result(_, _, _, _), do: nil

  defp outcome_options(pickup_eligible?, selected_outcome) do
    base = [{"Holed out", "holed_out"}]

    if pickup_eligible? or selected_outcome == "picked_up" do
      base ++ [{"Picked up, no points", "picked_up"}]
    else
      base
    end
  end

  defp result_values_for(result_values, player_id) do
    case Map.get(result_values, player_id) do
      values when is_map(values) -> values
      _ -> %{}
    end
  end

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _ -> {:error, :invalid_integer}
    end
  end

  defp parse_integer(_), do: {:error, :invalid_integer}

  defp parse_optional_integer(nil), do: :empty
  defp parse_optional_integer(""), do: :empty
  defp parse_optional_integer(value), do: parse_integer(value)

  defp handicap_strokes_label(strokes) when strokes > 0 do
    label = if strokes == 1, do: "stroke", else: "strokes"
    "#{strokes} #{label} received"
  end

  defp handicap_strokes_label(strokes) when strokes < 0 do
    count = abs(strokes)
    label = if count == 1, do: "stroke", else: "strokes"
    "#{count} #{label} given back"
  end

  defp handicap_strokes_label(_), do: "No handicap stroke"

  defp format_handicap_index(nil), do: "Not recorded"

  defp format_handicap_index(value) do
    value
    |> D.new()
    |> D.to_string(:normal)
  end

  defp cast_uuid(nil), do: nil

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end
end

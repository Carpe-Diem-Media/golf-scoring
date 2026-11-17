defmodule GolfScoring.Scoring.Services.LoadStandardStandings do
  @moduledoc """
  Internal Standard standings derived from one read-only PostgreSQL snapshot.

  The caller of `run/3` is responsible for authorization. No result certifies finality.
  """

  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Services.{Leaderboard, LoadSideHolePoints, LoadStandardSideHoles}

  @doc "Loads provisional standings for the scoped locked Standard track."
  def run(event_id, round_id, scoring_track_id) do
    with {:ok, event} <- Ecto.UUID.dump(event_id),
         {:ok, round} <- Ecto.UUID.dump(round_id),
         {:ok, track} <- Ecto.UUID.dump(scoring_track_id),
         false <- Repo.in_transaction?() do
      run_transaction(event_id, round_id, event, round, track)
    else
      :error -> {:error, :invalid_scope}
      true -> {:error, :outer_transaction_required}
    end
  end

  @doc "Loads provisional standings for staff with an active Event administration role."
  def run_for_staff(actor, event_id, round_id, scoring_track_id) do
    with %StaffUser{id: actor_id} <- actor,
         {:ok, _} <- Ecto.UUID.dump(actor_id),
         {:ok, event} <- Ecto.UUID.dump(event_id),
         {:ok, round} <- Ecto.UUID.dump(round_id),
         {:ok, track} <- Ecto.UUID.dump(scoring_track_id),
         false <- Repo.in_transaction?() do
      staff_transaction(actor_id, event_id, round_id, event, round, track)
    else
      true -> {:error, :outer_transaction_required}
      _ -> {:error, :invalid_scope}
    end
  end

  defp staff_transaction(actor_id, event_id, round_id, event, round, track) do
    case Repo.transaction(fn ->
           staff_snapshot(actor_id, event_id, round_id, event, round, track)
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp staff_snapshot(actor_id, event_id, round_id, event, round, track) do
    Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")

    if ActiveEventRole.authorized?(actor_id, event_id, [:event_admin, :competition_manager]) do
      projection(event_id, round_id, event, round, track)
    else
      {:error, :not_found_or_forbidden}
    end
  end

  defp run_transaction(event_id, round_id, event, round, track) do
    case Repo.transaction(fn -> snapshot(event_id, round_id, event, round, track) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp snapshot(event_id, round_id, event, round, track_id) do
    Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")

    projection(event_id, round_id, event, round, track_id)
  end

  defp projection(event_id, round_id, event, round, track_id) do
    with {:ok, competition, track} <- load_track(event, round, track_id),
         {:ok, sides} <- load_sides(round, competition),
         {:ok, mapping} <- load_mapping(event, round),
         {:ok, projections} <- project_sides(sides, event_id, round_id) do
      Leaderboard.project(track, projections, mapping)
    end
  end

  defp load_track(event, round, track) do
    rows =
      Repo.query!(
        """
        SELECT rc.id::text, st.track_type, st.configuration_state,
               st.visibility_policy_identifier, st.aggregation_policy_identifier,
               st.tie_break_policy_identifier
        FROM scoring_tracks st
        JOIN rounds r ON r.id = st.round_id AND r.event_id = st.event_id
        JOIN round_competitions rc ON rc.id = st.round_competition_id
          AND rc.round_id = r.id AND rc.event_id = r.event_id
        WHERE st.id = $3::uuid AND st.event_id = $1::uuid AND st.round_id = $2::uuid
        """,
        [event, round, track]
      ).rows

    case rows do
      [
        [
          competition,
          "standard_better_ball",
          "locked",
          "leaderboard_v1",
          "standard_better_ball_v1",
          "standard_countback_v1"
        ]
      ] ->
        {:ok, competition,
         %{
           track_type: :standard_better_ball,
           configuration_state: :locked,
           aggregation_policy_identifier: "standard_better_ball_v1",
           tie_break_policy_identifier: "standard_countback_v1"
         }}

      _ ->
        {:error, :invalid_scope}
    end
  end

  defp load_sides(round, competition) do
    {:ok, competition_id} = Ecto.UUID.dump(competition)

    rows =
      Repo.query!(
        """
        SELECT s.id::text, s.round_id::text, sr.id::text, sr.state
        FROM competition_sides s
        LEFT JOIN competition_side_results sr ON sr.competition_side_id = s.id
        WHERE s.round_competition_id = $1::uuid
        ORDER BY s.id
        """,
        [competition_id]
      ).rows

    {:ok, round_id} = Ecto.UUID.load(round)

    with true <- length(rows) == length(Enum.uniq_by(rows, &hd/1)),
         {:ok, sides} <- decode_sides(rows, round_id) do
      {:ok, sides}
    else
      _ -> {:error, :inconsistent_evidence}
    end
  end

  defp decode_sides(rows, round_id) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [side, ^round_id, result, state], {:ok, sides} when is_binary(result) ->
        case result_state(state) do
          {:ok, state} -> {:cont, {:ok, [%{side_id: side, side_result: %{state: state}} | sides]}}
          :error -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, sides} -> {:ok, Enum.sort_by(sides, & &1.side_id)}
      :error -> :error
    end
  end

  defp result_state("provisional"), do: {:ok, :provisional}
  defp result_state("review_required"), do: {:ok, :review_required}
  defp result_state("ready_to_finalize"), do: {:ok, :ready_to_finalize}
  defp result_state("finalized"), do: {:ok, :finalized}
  defp result_state("excluded"), do: {:ok, :excluded}
  defp result_state(_), do: :error

  defp load_mapping(event, round) do
    rows =
      Repo.query!(
        """
        SELECT rh.id::text, ch.hole_number
        FROM round_holes rh
        JOIN rounds r ON r.id = rh.round_id AND r.course_id = rh.course_id
        LEFT JOIN course_holes ch ON ch.id = rh.course_hole_id AND ch.course_id = rh.course_id
        WHERE r.id = $2::uuid AND r.event_id = $1::uuid
        """,
        [event, round]
      ).rows

    mapping = Map.new(rows, fn [id, number] -> {id, number} end)

    if length(rows) == 18 and map_size(mapping) == 18 and
         Enum.sort(Map.values(mapping)) == Enum.to_list(1..18) do
      {:ok, mapping}
    else
      {:error, :inconsistent_evidence}
    end
  end

  defp project_sides(sides, event_id, round_id) do
    Enum.reduce_while(sides, {:ok, []}, fn side, {:ok, acc} ->
      with {:ok, points} <- LoadSideHolePoints.run_in_snapshot(event_id, round_id, side.side_id),
           {:ok, holes} <- LoadStandardSideHoles.project(points) do
        {:cont, {:ok, [Map.put(side, :holes, holes) | acc]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projections} -> {:ok, Enum.reverse(projections)}
      error -> error
    end
  end
end

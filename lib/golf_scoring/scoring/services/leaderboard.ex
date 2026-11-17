defmodule GolfScoring.Scoring.Services.Leaderboard do
  @moduledoc """
  Pure provisional Standard standings from validated Side-hole projections.

  The caller owns authorization, snapshot consistency and the physical-hole mapping.
  Positions do not certify competition eligibility or finality.
  """

  alias GolfScoring.Scoring.Calculators.Countback

  @states [:provisional, :review_required, :ready_to_finalize, :finalized, :excluded]

  @doc "Projects an allowlisted standings list, or rejects inconsistent inputs."
  def project(track, sides, mapping) when is_list(sides) and is_map(mapping) do
    with true <- valid_track?(track),
         true <- valid_mapping?(mapping),
         {:ok, rows} <- collect(sides, mapping),
         true <- length(Enum.uniq_by(rows, & &1.side_id)) == length(rows) do
      {:ok, rank(rows)}
    else
      _ -> {:error, :inconsistent_evidence}
    end
  end

  def project(_, _, _), do: {:error, :inconsistent_evidence}

  defp valid_track?(%{
         track_type: :standard_better_ball,
         configuration_state: :locked,
         aggregation_policy_identifier: "standard_better_ball_v1",
         tie_break_policy_identifier: "standard_countback_v1"
       }),
       do: true

  defp valid_track?(_), do: false

  defp valid_mapping?(mapping) do
    map_size(mapping) == 18 and Enum.all?(Map.keys(mapping), &(is_binary(&1) and &1 != "")) and
      Enum.sort(Map.values(mapping)) == Enum.to_list(1..18)
  end

  defp collect(sides, mapping) do
    Enum.reduce_while(sides, {:ok, []}, fn side, {:ok, rows} ->
      case row(side, mapping) do
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp row(%{side_id: id, side_result: %{state: state}, holes: holes}, mapping)
       when is_binary(id) and id != "" and state in @states and is_list(holes) do
    if valid_schedule?(holes, mapping) do
      computed = Enum.filter(holes, &(&1.status == :computed))
      safe_holes = Enum.map(holes, &Map.take(&1, [:round_hole_id, :status, :points]))

      {:ok,
       %{
         side_id: id,
         subtotal: Enum.sum(Enum.map(computed, & &1.points)),
         holes_completed: length(computed),
         side_result_state: state,
         holes: safe_holes,
         rankable:
           state != :excluded and computed != [] and
             Enum.all?(holes, &(&1.status != :not_computable)),
         mapping: mapping
       }}
    else
      :error
    end
  end

  defp row(_, _), do: :error

  defp valid_schedule?(holes, mapping) do
    length(holes) == 18 and Enum.all?(holes, &valid_hole?/1) and
      Enum.map(holes, & &1.play_index) == Enum.to_list(0..17) and
      MapSet.new(Enum.map(holes, & &1.round_hole_id)) == MapSet.new(Map.keys(mapping))
  end

  defp valid_hole?(%{play_index: index, round_hole_id: id, status: :computed, points: points}),
    do: is_integer(index) and is_binary(id) and id != "" and is_integer(points) and points >= 0

  defp valid_hole?(%{play_index: index, round_hole_id: id, status: status, points: nil})
       when status in [:pending, :not_computable],
       do: is_integer(index) and is_binary(id) and id != ""

  defp valid_hole?(_), do: false

  defp rank(rows) do
    {eligible, unranked} = Enum.split_with(rows, & &1.rankable)
    groups = eligible |> Enum.group_by(& &1.subtotal) |> Enum.sort_by(fn {total, _} -> -total end)

    {ranked, _} =
      Enum.map_reduce(groups, 1, fn {_total, group}, position ->
        {rank_group(group, position), position + length(group)}
      end)

    Enum.flat_map(ranked, & &1) ++
      (unranked |> Enum.sort_by(& &1.side_id) |> Enum.map(&finish(&1, nil)))
  end

  defp rank_group(group, position) do
    if length(group) > 1 and Enum.all?(group, &(&1.holes_completed == 18)) do
      group
      |> Enum.map(fn row -> {countback(row), row} end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.map_reduce(position, fn {_key, tied}, place ->
        {tied |> Enum.sort_by(& &1.side_id) |> Enum.map(&finish(&1, place)), place + length(tied)}
      end)
      |> elem(0)
      |> List.flatten()
    else
      group |> Enum.sort_by(& &1.side_id) |> Enum.map(&finish(&1, position))
    end
  end

  defp countback(row) do
    contributions =
      Enum.map(row.holes, fn hole ->
        %{
          physical_hole_number: Map.fetch!(row.mapping, hole.round_hole_id),
          points: hole.points,
          mystery_hole?: false
        }
      end)

    {:ok, %{tie_break_key: key}} = Countback.calculate(contributions, :standard_countback)
    key
  end

  defp finish(row, position) do
    row
    |> Map.take([:side_id, :subtotal, :holes_completed])
    |> Map.put(:position, position)
    |> Map.put(:display_status, display_status(row))
  end

  defp display_status(%{side_result_state: :review_required}), do: :under_review
  defp display_status(%{rankable: false}), do: :unranked
  defp display_status(_), do: :provisional
end

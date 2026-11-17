defmodule GolfScoring.Scoring.Services.LoadStandardSideHoles do
  @moduledoc """
  Internal read-only Standard BEST contributions for one Side's scheduled holes.

  Computation does not establish independent verification, SideResult readiness,
  or official competition eligibility.
  """

  alias GolfScoring.Scoring.Calculators.{FourBallBest, SideHoleContributors}
  alias GolfScoring.Scoring.Services.LoadSideHolePoints

  @doc "Loads the existing points projection once and derives Standard contributions."
  def run(event_id, round_id, side_id) do
    with {:ok, holes} <- LoadSideHolePoints.run(event_id, round_id, side_id) do
      project(holes)
    end
  end

  @doc false
  def project(holes) when is_list(holes) and length(holes) == 18 do
    with true <- Enum.all?(holes, &valid_hole?/1),
         true <- Enum.map(holes, & &1.play_index) == Enum.to_list(0..17),
         facts <- Enum.flat_map(holes, & &1.members),
         true <- Enum.all?(facts, &valid_member?/1),
         {:ok, groups} <- SideHoleContributors.select(facts),
         true <- consistent_groups?(holes, groups) do
      {:ok, Enum.map(holes, &contribution/1)}
    else
      _ -> {:error, :inconsistent_evidence}
    end
  end

  def project(_), do: {:error, :inconsistent_evidence}

  defp valid_hole?(%{play_index: index, round_hole_id: hole, members: members})
       when is_integer(index) and is_binary(hole) and hole != "" and is_list(members) do
    length(members) in 1..2 and
      Enum.all?(members, fn
        %{play_index: ^index, round_hole_id: ^hole} -> true
        _ -> false
      end)
  end

  defp valid_hole?(_), do: false

  defp valid_member?(%{
         status: :recorded,
         points: points,
         withdrawal_applicability: :applicable,
         hole_result_id: result
       }) do
    is_integer(points) and points >= 0 and is_binary(result) and result != ""
  end

  defp valid_member?(%{
         status: :pending,
         points: nil,
         withdrawal_applicability: :applicable,
         hole_result_id: nil
       }),
       do: true

  defp valid_member?(%{
         status: :excluded,
         points: nil,
         withdrawal_applicability: :not_applicable
       }),
       do: true

  defp valid_member?(_), do: false

  defp consistent_groups?(holes, groups) do
    Enum.zip(holes, groups)
    |> Enum.all?(fn {hole, group} ->
      hole.round_hole_id == group.round_hole_id and
        length(hole.members) == length(group.recorded ++ group.missing ++ group.excluded)
    end)
  end

  defp contribution(hole) do
    applicable = Enum.reject(hole.members, &(&1.status == :excluded))

    {status, points} =
      cond do
        applicable == [] ->
          {:not_computable, nil}

        Enum.any?(applicable, &(&1.status == :pending)) ->
          {:pending, nil}

        length(applicable) == 1 ->
          {:computed, hd(applicable).points}

        true ->
          [a, b] = applicable
          {:ok, %{best_points: best}} = FourBallBest.calculate(a.points, b.points)
          {:computed, best}
      end

    hole |> Map.put(:status, status) |> Map.put(:points, points)
  end
end

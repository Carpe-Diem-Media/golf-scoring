defmodule GolfScoring.Scoring.Calculators.SideHoleContributors do
  @moduledoc """
  Groups scoped scheduled withdrawal applicability facts for Side-hole scoring.

  This selects candidates only on withdrawal applicability. It does not decide
  other scoring eligibility, calculate scores, or establish SideResult readiness.
  """

  @doc """
  Returns scheduled facts grouped in playing order, retaining excluded facts for
  audit. Applicable facts are separated into recorded and missing results.
  Unresolved or inconsistent schedules return `{:error, :invalid_input}`.
  """
  @spec select(term()) :: {:ok, [map()]} | {:error, :invalid_input}
  def select(facts) when is_list(facts) and facts != [] do
    with true <- Enum.all?(facts, &valid_fact?/1),
         members <- Enum.group_by(facts, & &1.round_entry_id),
         true <- map_size(members) <= 4,
         true <- Enum.all?(members, fn {_, rows} -> valid_member?(rows) end),
         true <- unique_results?(facts),
         groups <- Enum.group_by(facts, & &1.play_index),
         true <- valid_route?(groups) do
      {:ok,
       for index <- 0..17 do
         rows = groups |> Map.fetch!(index) |> Enum.sort_by(& &1.round_entry_id)

         %{
           play_index: index,
           round_hole_id: hd(rows).round_hole_id,
           recorded:
             Enum.filter(
               rows,
               &(&1.withdrawal_applicability == :applicable and not is_nil(&1.hole_result_id))
             ),
           missing:
             Enum.filter(
               rows,
               &(&1.withdrawal_applicability == :applicable and is_nil(&1.hole_result_id))
             ),
           excluded: Enum.filter(rows, &(&1.withdrawal_applicability == :not_applicable))
         }
       end}
    else
      _ -> {:error, :invalid_input}
    end
  end

  def select(_), do: {:error, :invalid_input}

  defp valid_fact?(%{
         round_entry_id: entry,
         round_hole_id: hole,
         play_index: index,
         hole_result_id: result,
         revision: revision,
         withdrawal_applicability: applicability,
         unresolved_reason: nil
       }) do
    is_binary(entry) and entry != "" and is_binary(hole) and hole != "" and
      is_integer(index) and index in 0..17 and
      applicability in [:applicable, :not_applicable] and
      valid_result?(result, revision)
  end

  defp valid_fact?(_), do: false

  defp valid_result?(nil, nil), do: true

  defp valid_result?(result, revision) do
    is_binary(result) and result != "" and is_integer(revision) and revision > 0
  end

  defp valid_member?(rows) do
    length(rows) == 18 and Enum.sort(Enum.map(rows, & &1.play_index)) == Enum.to_list(0..17) and
      length(Enum.uniq_by(rows, & &1.round_hole_id)) == 18
  end

  defp unique_results?(facts) do
    ids = facts |> Enum.map(& &1.hole_result_id) |> Enum.reject(&is_nil/1)
    length(ids) == length(Enum.uniq(ids))
  end

  defp valid_route?(groups) do
    holes =
      for index <- 0..17,
          do: groups |> Map.fetch!(index) |> Enum.map(& &1.round_hole_id) |> Enum.uniq()

    Enum.all?(holes, &(length(&1) == 1)) and length(Enum.uniq(holes)) == 18
  end
end

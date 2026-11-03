defmodule GolfScoring.Competition.Policies.MysteryRevealEligibility do
  @moduledoc "Pure policy for resolving the fixed global Mystery cohort."

  @resolution_classes [:submitted, :paper_recovered, :not_applicable, :unresolved]

  @type resolution_fact :: %{playing_group_id: String.t(), resolution: atom()}
  @type result :: %{eligible?: boolean(), unresolved_group_ids: [String.t()]}

  @spec evaluate([String.t()], [resolution_fact()]) ::
          {:ok, result()} | {:error, term()}
  def evaluate(required_group_ids, resolution_facts)
      when is_list(required_group_ids) and is_list(resolution_facts) do
    with {:ok, required_ids} <- normalize_required_ids(required_group_ids),
         {:ok, facts} <- normalize_facts(resolution_facts),
         :ok <- reject_duplicate_facts(facts),
         :ok <- reject_unexpected_facts(required_ids, facts),
         :ok <- require_all_facts(required_ids, facts) do
      fact_by_group = Map.new(facts, &{&1.playing_group_id, &1.resolution})

      unresolved_group_ids =
        Enum.reject(required_ids, fn group_id ->
          Map.fetch!(fact_by_group, group_id) in [:submitted, :paper_recovered, :not_applicable]
        end)

      {:ok,
       %{
         eligible?: unresolved_group_ids == [],
         unresolved_group_ids: unresolved_group_ids
       }}
    end
  end

  def evaluate(_required_group_ids, _resolution_facts), do: {:error, :invalid_cohort_facts}

  defp normalize_required_ids([]), do: {:error, :empty_required_cohort}

  defp normalize_required_ids(group_ids) do
    if Enum.all?(group_ids, &(is_binary(&1) and byte_size(&1) > 0)) do
      required_ids = Enum.sort(group_ids)
      duplicates = duplicate_ids(required_ids)

      if duplicates == [] do
        {:ok, required_ids}
      else
        {:error, {:duplicate_required_groups, duplicates}}
      end
    else
      {:error, :invalid_required_group_id}
    end
  end

  defp normalize_facts(facts) do
    Enum.reduce_while(facts, {:ok, []}, fn
      %{playing_group_id: group_id, resolution: resolution}, {:ok, acc}
      when is_binary(group_id) and byte_size(group_id) > 0 and resolution in @resolution_classes ->
        {:cont, {:ok, [%{playing_group_id: group_id, resolution: resolution} | acc]}}

      _fact, _acc ->
        {:halt, {:error, :invalid_resolution_fact}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp reject_duplicate_facts(facts) do
    duplicates = facts |> Enum.map(& &1.playing_group_id) |> Enum.sort() |> duplicate_ids()

    if duplicates == [],
      do: :ok,
      else: {:error, {:duplicate_resolution_facts, duplicates}}
  end

  defp reject_unexpected_facts(required_ids, facts) do
    required = MapSet.new(required_ids)

    unexpected =
      facts
      |> Enum.map(& &1.playing_group_id)
      |> Enum.reject(&MapSet.member?(required, &1))
      |> Enum.sort()

    if unexpected == [],
      do: :ok,
      else: {:error, {:unexpected_resolution_facts, unexpected}}
  end

  defp require_all_facts(required_ids, facts) do
    fact_ids = MapSet.new(facts, & &1.playing_group_id)
    missing = Enum.reject(required_ids, &MapSet.member?(fact_ids, &1))

    if missing == [],
      do: :ok,
      else: {:error, {:missing_resolution_facts, missing}}
  end

  defp duplicate_ids(sorted_ids) do
    sorted_ids
    |> Enum.chunk_by(& &1)
    |> Enum.filter(&(length(&1) > 1))
    |> Enum.map(&hd/1)
  end
end

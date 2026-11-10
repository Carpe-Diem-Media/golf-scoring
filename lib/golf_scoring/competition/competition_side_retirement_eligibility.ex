defmodule GolfScoring.Competition.CompetitionSideRetirementEligibility do
  @moduledoc """
  Read-only prospective retirement boundaries for competition consumers.

  Accepted PostgreSQL retirement evidence is the authority. No mutable cache or flag may
  compete with these lookups.
  """

  alias GolfScoring.Repo

  @spec placing_eligible?(Ecto.UUID.t()) :: boolean()
  def placing_eligible?(side_id) do
    not retired?(side_id) and not excluded?(side_id)
  end

  @spec accepted?(Ecto.UUID.t()) :: boolean()
  def accepted?(side_id), do: not is_nil(accepted_row(side_id))

  @spec effective_play_index(Ecto.UUID.t()) ::
          {:ok, integer()} | {:error, :retirement_not_accepted}
  def effective_play_index(side_id) do
    case accepted_row(side_id) do
      %{effective_play_index: index} -> {:ok, index}
      nil -> {:error, :retirement_not_accepted}
    end
  end

  @spec blocks_official_contribution?(Ecto.UUID.t(), integer()) :: boolean()
  def blocks_official_contribution?(side_id, play_index) when is_integer(play_index) do
    case accepted_row(side_id) do
      %{effective_play_index: boundary} -> play_index >= boundary
      nil -> false
    end
  end

  def blocks_official_contribution?(_side_id, _), do: false

  defp retired?(side_id), do: not is_nil(accepted_row(side_id))

  defp excluded?(side_id) do
    case Repo.query!(
           """
           SELECT state FROM competition_side_results
           WHERE competition_side_id = $1::uuid
           """,
           [Ecto.UUID.dump!(side_id)]
         ).rows do
      [["excluded"]] -> true
      _ -> false
    end
  end

  defp accepted_row(side_id) do
    case Repo.query!(
           """
           SELECT effective_play_index
           FROM competition_side_retirements
           WHERE competition_side_id = $1::uuid
           """,
           [Ecto.UUID.dump!(side_id)]
         ).rows do
      [[index]] -> %{effective_play_index: index}
      [] -> nil
    end
  end
end

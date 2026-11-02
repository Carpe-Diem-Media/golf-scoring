defmodule GolfScoring.Scoring.Services.BuildCompetitionHandicap do
  @moduledoc false

  require Ash.Query

  alias Ash.Changeset
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Calculators.PlayingHandicap
  alias GolfScoring.Scoring.CompetitionHandicap
  alias GolfScoring.Scoring.HandicapEntryLock
  alias GolfScoring.Scoring.HandicapRowLock
  alias GolfScoring.Scoring.HandicapSnapshot

  def run(round_entry_id, round_competition_id, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, entry} <- HandicapEntryLock.lock!(round_entry_id),
           {:ok, _locked_snapshot} <- HandicapRowLock.lock_handicap_snapshot!(entry.id),
           {:ok, snapshot} <- fetch_built_snapshot(entry.id),
           {:ok, competition} <-
             HandicapRowLock.lock_round_competition!(round_competition_id, entry.round_id),
           :ok <- assert_snapshot_alignment(snapshot, entry),
           {:ok, playing} <- require_field(attrs, :playing_handicap),
           {:ok, policy} <- require_policy(attrs),
           {:ok, allowance_applied} <- require_allowance_applied(attrs),
           unrounded_allowed <-
             Map.get(
               attrs,
               :unrounded_allowed_handicap,
               Map.get(attrs, "unrounded_allowed_handicap")
             ),
           :ok <- validate_output(snapshot, competition, unrounded_allowed, playing),
           {:ok, row} <-
             CompetitionHandicap
             |> Changeset.for_create(:build_internal, %{
               round_id: entry.round_id,
               round_entry_id: entry.id,
               round_competition_id: competition.id,
               handicap_snapshot_id: snapshot.id,
               handicap_allowance_percent: competition.handicap_allowance_percent,
               allowance_applied: allowance_applied,
               unrounded_allowed_handicap: unrounded_allowed,
               playing_handicap: playing,
               policy_identifier: policy
             })
             |> Ash.create(authorize?: false) do
        row
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_result()
  end

  defp validate_output(snapshot, competition, unrounded, playing) do
    {:ok, calculated} =
      PlayingHandicap.calculate(
        snapshot.course_handicap_unrounded,
        competition.handicap_allowance_percent
      )

    if playing === calculated.playing_handicap and
         valid_unrounded?(unrounded, calculated.unrounded_allowed_handicap),
       do: :ok,
       else: {:error, :stale_handicap_output}
  end

  defp valid_unrounded?(nil, _expected), do: true

  defp valid_unrounded?(unrounded, expected) do
    case Decimal.cast(unrounded) do
      {:ok, value} ->
        Decimal.equal?(value, expected)

      :error ->
        false
    end
  end

  defp fetch_built_snapshot(round_entry_id) do
    case HandicapSnapshot
         |> Ash.Query.filter(round_entry_id == ^round_entry_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, %{built_at: built_at} = snapshot} when not is_nil(built_at) -> {:ok, snapshot}
      {:ok, _} -> {:error, :handicap_snapshot_not_built}
      {:error, error} -> {:error, error}
    end
  end

  defp assert_snapshot_alignment(snapshot, entry) do
    if snapshot.round_entry_id == entry.id and snapshot.round_id == entry.round_id,
      do: :ok,
      else: {:error, :handicap_snapshot_mismatch}
  end

  defp require_field(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      nil -> {:error, {:required, key}}
      value -> {:ok, value}
    end
  end

  defp require_policy(attrs) do
    case Map.get(attrs, :policy_identifier) || Map.get(attrs, "policy_identifier") do
      nil -> {:error, :policy_identifier_required}
      "" -> {:error, :policy_identifier_required}
      value -> {:ok, String.trim(to_string(value))}
    end
  end

  defp require_allowance_applied(attrs) do
    case Map.fetch(attrs, :allowance_applied) do
      {:ok, value} when is_boolean(value) ->
        {:ok, value}

      :error ->
        case Map.fetch(attrs, "allowance_applied") do
          {:ok, value} when is_boolean(value) -> {:ok, value}
          _ -> {:error, :allowance_applied_required}
        end
    end
  end

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result({:error, :rollback, reason}), do: {:error, reason}
end

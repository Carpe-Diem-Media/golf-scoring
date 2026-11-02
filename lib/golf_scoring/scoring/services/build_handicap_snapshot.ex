defmodule GolfScoring.Scoring.Services.BuildHandicapSnapshot do
  @moduledoc false

  require Ash.Query

  alias Ash.Changeset
  alias GolfScoring.Competition.RoundTeeProfileSnapshot
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Calculators.CourseHandicap
  alias GolfScoring.Scoring.HandicapEntryLock
  alias GolfScoring.Scoring.HandicapRowLock
  alias GolfScoring.Scoring.HandicapSnapshot

  def run(round_entry_id, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, entry} <- HandicapEntryLock.lock_pre_open!(round_entry_id),
           {:ok, _locked} <- HandicapRowLock.lock_handicap_snapshot!(entry.id),
           {:ok, snapshot} <- fetch_configured_snapshot(entry.id),
           :ok <- assert_tee_alignment(snapshot, entry),
           {:ok, tee} <- load_tee_snapshot(entry.round_tee_profile_snapshot_id, entry.round_id),
           {:ok, unrounded} <- require_field(attrs, :course_handicap_unrounded),
           {:ok, rounded} <- require_field(attrs, :course_handicap_rounded),
           :ok <- validate_output(snapshot, tee, unrounded, rounded),
           {:ok, built} <-
             snapshot
             |> Changeset.for_update(:build_internal, %{
               course_rating: tee.course_rating,
               slope_rating: tee.slope_rating,
               applicable_par: tee.applicable_par,
               course_handicap_unrounded: unrounded,
               course_handicap_rounded: rounded,
               built_at: DateTime.utc_now()
             })
             |> Ash.update(authorize?: false) do
        built
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_result()
  end

  defp validate_output(snapshot, tee, unrounded, rounded) do
    basis =
      case snapshot.basis_source do
        source when source in [:official_or_preloaded, :player_declared] ->
          snapshot.source_handicap_index

        source when source in [:committee_deemed, :committee_override] ->
          snapshot.deemed_handicap_basis
      end

    {:ok, calculated} =
      CourseHandicap.calculate(basis, tee.slope_rating, tee.course_rating, tee.applicable_par)

    case Decimal.cast(unrounded) do
      {:ok, value} ->
        if Decimal.equal?(value, calculated.course_handicap_unrounded) and
             rounded === calculated.course_handicap_rounded,
           do: :ok,
           else: {:error, :stale_handicap_output}

      :error ->
        {:error, :stale_handicap_output}
    end
  end

  defp fetch_configured_snapshot(round_entry_id) do
    case HandicapSnapshot
         |> Ash.Query.filter(round_entry_id == ^round_entry_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :handicap_not_configured}
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, error} -> {:error, error}
    end
  end

  defp assert_tee_alignment(snapshot, entry) do
    if snapshot.round_tee_profile_snapshot_id == entry.round_tee_profile_snapshot_id do
      :ok
    else
      {:error, :handicap_snapshot_tee_mismatch}
    end
  end

  defp load_tee_snapshot(tee_snapshot_id, round_id) do
    case Ash.get(RoundTeeProfileSnapshot, tee_snapshot_id, authorize?: false) do
      {:ok, tee} when tee.round_id == round_id -> {:ok, tee}
      {:ok, _tee} -> {:error, :tee_snapshot_round_mismatch}
      {:error, error} -> {:error, error}
    end
  end

  defp require_field(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      nil -> {:error, {:required, key}}
      value -> {:ok, value}
    end
  end

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result({:error, :rollback, reason}), do: {:error, reason}
end

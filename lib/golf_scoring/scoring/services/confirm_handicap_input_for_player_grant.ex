defmodule GolfScoring.Scoring.Services.ConfirmHandicapInputForPlayerGrant do
  @moduledoc false

  alias Decimal, as: D
  alias GolfScoring.Accounts.PlayerAccessGrant
  alias GolfScoring.Accounts.PlayerAccessGrantGuard
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.HandicapEntryLock
  alias GolfScoring.Scoring.Services.HandicapBasisSupport

  @spec run(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, struct()} | {:error, term()}
  def run(grant_id, round_id, round_entry_id, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      with :ok <- PlayerAccessGrantGuard.apply_lazy_expiry_for_grant_id(Repo, grant_id),
           {:ok, grant} <- load_active_grant(grant_id),
           {:ok, entry} <- HandicapEntryLock.lock_pre_open!(round_entry_id),
           :ok <- validate_grant_scope(grant, entry, round_id),
           :ok <- require_assigned_tee(entry),
           {:ok, hi} <- require_handicap_index(attrs),
           {:ok, snapshot} <-
             HandicapBasisSupport.upsert_configured!(entry, %{
               basis_source: :player_declared,
               source_handicap_index: hi,
               deemed_handicap_basis: nil,
               override_reason: nil,
               confirmed_at: DateTime.utc_now(),
               confirmed_by_staff_user_id: nil,
               confirmed_by_round_entry_id: entry.id,
               source_reference: Map.get(attrs, :source_reference)
             }) do
        snapshot
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_result()
  end

  defp load_active_grant(grant_id) do
    case Ash.get(PlayerAccessGrant, grant_id, authorize?: false) do
      {:ok, %{state: :active} = grant} ->
        if PlayerAccessGrantGuard.grant_expired?(grant, DateTime.utc_now()) do
          {:error, :invalid_player_session}
        else
          {:ok, grant}
        end

      _ ->
        {:error, :invalid_player_session}
    end
  end

  defp validate_grant_scope(grant, entry, round_id) do
    cond do
      entry.round_id != round_id -> {:error, :round_entry_mismatch}
      entry.event_id != grant.event_id -> {:error, :invalid_player_session}
      entry.player_id != grant.player_id -> {:error, :invalid_player_session}
      true -> :ok
    end
  end

  defp require_assigned_tee(%{round_tee_profile_snapshot_id: nil}),
    do: {:error, :tee_not_assigned}

  defp require_assigned_tee(%{round_tee_profile_snapshot_id: _}), do: :ok

  defp require_handicap_index(%{source_handicap_index: %D{} = hi}), do: {:ok, hi}

  defp require_handicap_index(%{source_handicap_index: hi}) when not is_nil(hi), do: {:ok, hi}

  defp require_handicap_index(%{"source_handicap_index" => hi}) when not is_nil(hi),
    do: {:ok, hi}

  defp require_handicap_index(_), do: {:error, :source_handicap_index_required}

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result({:error, :rollback, reason}), do: {:error, reason}
end

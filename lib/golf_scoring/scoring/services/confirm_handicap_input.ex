defmodule GolfScoring.Scoring.Services.ConfirmHandicapInput do
  @moduledoc false

  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.HandicapEntryLock
  alias GolfScoring.Scoring.Services.HandicapBasisSupport

  @manager_roles [:event_admin, :competition_manager]

  def run(actor, event_id, round_id, round_entry_id, attrs)
      when is_map(actor) and is_map(attrs) do
    run(actor, event_id, round_id, round_entry_id, attrs, [])
  end

  def run(actor, event_id, round_id, round_entry_id, attrs, opts)
      when is_map(actor) and is_map(attrs) and is_list(opts) do
    actor_id = Map.get(actor, :id)
    source = Keyword.get(opts, :basis_source, :official_or_preloaded)

    Repo.transaction(fn ->
      with {:ok, _scope} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
           :ok <- authorize_staff(actor_id, event_id),
           {:ok, entry} <- HandicapEntryLock.lock_pre_open!(round_entry_id),
           :ok <- scope_entry(entry, round_id, event_id),
           :ok <- require_assigned_tee(entry),
           {:ok, hi} <- require_handicap_index(attrs),
           {:ok, snapshot} <-
             HandicapBasisSupport.upsert_configured!(entry, %{
               basis_source: source,
               source_handicap_index: hi,
               deemed_handicap_basis: nil,
               override_reason: nil,
               confirmed_at: DateTime.utc_now(),
               confirmed_by_staff_user_id: actor_id,
               confirmed_by_round_entry_id: nil,
               source_reference: Map.get(attrs, :source_reference)
             }) do
        snapshot
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_result()
  end

  defp authorize_staff(actor_id, event_id) do
    if ActiveEventRole.authorized?(actor_id, event_id, @manager_roles) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp scope_entry(entry, round_id, event_id) do
    if entry.round_id == round_id and entry.event_id == event_id,
      do: :ok,
      else: {:error, :round_entry_mismatch}
  end

  defp require_assigned_tee(%{round_tee_profile_snapshot_id: nil}),
    do: {:error, :tee_not_assigned}

  defp require_assigned_tee(%{round_tee_profile_snapshot_id: _}), do: :ok

  defp require_handicap_index(%{source_handicap_index: hi}) when not is_nil(hi), do: {:ok, hi}

  defp require_handicap_index(%{"source_handicap_index" => hi}) when not is_nil(hi),
    do: {:ok, hi}

  defp require_handicap_index(_), do: {:error, :source_handicap_index_required}

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result({:error, :rollback, reason}), do: {:error, reason}
end

defmodule GolfScoring.Scoring.Services.ApplyNoHiPolicy do
  @moduledoc false

  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Competition.Player
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.HandicapEntryLock
  alias GolfScoring.Scoring.Services.HandicapBasisSupport

  @manager_roles [:event_admin, :competition_manager]

  def run(actor, event_id, round_id, round_entry_id, attrs)
      when is_map(actor) and is_map(attrs) do
    actor_id = Map.get(actor, :id)

    Repo.transaction(fn ->
      with {:ok, _scope} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
           :ok <- authorize(actor_id, event_id),
           {:ok, entry} <- HandicapEntryLock.lock_pre_open!(round_entry_id),
           :ok <- scope_entry(entry, round_id, event_id),
           :ok <- require_assigned_tee(entry),
           :ok <- require_player_without_handicap_index(entry.player_id),
           {:ok, deemed} <- require_explicit_deemed(attrs),
           {:ok, provenance} <- require_provenance(attrs),
           {:ok, snapshot} <-
             HandicapBasisSupport.upsert_configured!(entry, %{
               basis_source: :committee_deemed,
               source_handicap_index: nil,
               deemed_handicap_basis: deemed,
               override_reason: nil,
               confirmed_at: DateTime.utc_now(),
               confirmed_by_staff_user_id: actor_id,
               confirmed_by_round_entry_id: nil,
               source_reference: provenance
             }) do
        snapshot
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_result()
  end

  defp authorize(actor_id, event_id) do
    if ActiveEventRole.authorized?(actor_id, event_id, @manager_roles),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp scope_entry(entry, round_id, event_id) do
    if entry.round_id == round_id and entry.event_id == event_id,
      do: :ok,
      else: {:error, :round_entry_mismatch}
  end

  defp require_assigned_tee(%{round_tee_profile_snapshot_id: nil}),
    do: {:error, :tee_not_assigned}

  defp require_assigned_tee(%{round_tee_profile_snapshot_id: _}), do: :ok

  defp require_player_without_handicap_index(player_id) do
    case Ash.get(Player, player_id, authorize?: false) do
      {:ok, %{latest_handicap_index: nil}} -> :ok
      {:ok, %{latest_handicap_index: _}} -> {:error, :player_has_handicap_index}
      {:error, error} -> {:error, error}
    end
  end

  defp require_explicit_deemed(%{deemed_handicap_basis: deemed}) when not is_nil(deemed),
    do: {:ok, deemed}

  defp require_explicit_deemed(%{"deemed_handicap_basis" => deemed}) when not is_nil(deemed),
    do: {:ok, deemed}

  defp require_explicit_deemed(_), do: {:error, :deemed_handicap_basis_required}

  defp require_provenance(attrs) do
    reference =
      Map.get(attrs, :source_reference) ||
        Map.get(attrs, "source_reference") ||
        Map.get(attrs, :policy_reference) ||
        Map.get(attrs, "policy_reference")

    case reference do
      ref when is_binary(ref) ->
        trimmed = String.trim(ref)

        if trimmed == "" do
          {:error, :provenance_reference_required}
        else
          {:ok, trimmed}
        end

      _ ->
        {:error, :provenance_reference_required}
    end
  end

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result({:error, :rollback, reason}), do: {:error, reason}
end

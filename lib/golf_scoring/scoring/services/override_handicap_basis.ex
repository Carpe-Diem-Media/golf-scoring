defmodule GolfScoring.Scoring.Services.OverrideHandicapBasis do
  @moduledoc false

  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Audit
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
           {:ok, deemed} <- require_replacement_basis(attrs),
           {:ok, reason} <- require_reason(attrs),
           {:ok, snapshot} <-
             HandicapBasisSupport.upsert_configured!(entry, %{
               basis_source: :committee_override,
               source_handicap_index: nil,
               deemed_handicap_basis: deemed,
               override_reason: reason,
               confirmed_at: DateTime.utc_now(),
               confirmed_by_staff_user_id: actor_id,
               confirmed_by_round_entry_id: nil,
               source_reference: Map.get(attrs, :source_reference)
             }),
           {:ok, _audit} <- write_audit(actor_id, round_entry_id, reason, deemed) do
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

  defp require_replacement_basis(%{deemed_handicap_basis: deemed}) when not is_nil(deemed),
    do: {:ok, deemed}

  defp require_replacement_basis(%{"deemed_handicap_basis" => deemed}) when not is_nil(deemed),
    do: {:ok, deemed}

  defp require_replacement_basis(_), do: {:error, :deemed_handicap_basis_required}

  defp require_reason(%{override_reason: reason}) when is_binary(reason) do
    trimmed = String.trim(reason)
    if trimmed == "", do: {:error, :override_reason_required}, else: {:ok, trimmed}
  end

  defp require_reason(%{"override_reason" => reason}) when is_binary(reason) do
    trimmed = String.trim(reason)
    if trimmed == "", do: {:error, :override_reason_required}, else: {:ok, trimmed}
  end

  defp require_reason(_), do: {:error, :override_reason_required}

  defp write_audit(actor_id, round_entry_id, reason, deemed) do
    deemed_string =
      case deemed do
        %Decimal{} = d -> Decimal.to_string(d)
        other -> to_string(other)
      end

    Audit.record_staff_event(
      %{
        actor_staff_user_id: actor_id,
        action: "override_handicap_basis",
        target_type: "RoundEntry",
        target_id: round_entry_id,
        context: %{round_entry_id: round_entry_id},
        changes: %{deemed_handicap_basis: deemed_string},
        reason: reason
      },
      authorize?: false
    )
  end

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result({:error, :rollback, reason}), do: {:error, reason}
end

defmodule GolfScoring.Competition.Services.AssignRoundTee do
  @moduledoc false

  alias Ash.Changeset
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Competition.RoundEntry
  alias GolfScoring.LockProtocol
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.InvalidateDerived

  @manager_roles [:event_admin, :competition_manager]

  @spec run(map(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, RoundEntry.t()} | {:error, term()}
  def run(actor, event_id, round_id, round_entry_id, round_tee_profile_snapshot_id)
      when is_map(actor) do
    actor_id = Map.get(actor, :id)

    Repo.transaction(fn ->
      with {:ok, _scope} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
           :ok <- authorize(actor_id, event_id),
           :ok <- lock_pre_open_round(round_id),
           :ok <- authorize_snapshot(round_tee_profile_snapshot_id, round_id),
           {:ok, entry} <- lock_entry(round_entry_id, round_id, event_id),
           :ok <- InvalidateDerived.realign_entry_tee!(entry.id, round_tee_profile_snapshot_id),
           {:ok, updated} <- assign_tee(entry, round_tee_profile_snapshot_id) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_result()
  end

  def run(_actor, _event_id, _round_id, _round_entry_id, _snapshot_id),
    do: {:error, :invalid_input}

  defp authorize(actor_id, event_id) do
    if ActiveEventRole.authorized?(actor_id, event_id, @manager_roles) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp lock_pre_open_round(round_id) do
    with {:ok, %{acquired: [%{row: round}]}} <- LockProtocol.acquire!(round: [round_id]) do
      if round.state in ["draft", "ready"],
        do: :ok,
        else: {:error, {:invalid_round_state, String.to_existing_atom(round.state)}}
    end
  end

  defp authorize_snapshot(snapshot_id, round_id) do
    case Repo.query!(
           "SELECT id::text FROM round_tee_profile_snapshots WHERE id = $1::uuid AND round_id = $2::uuid",
           [Ecto.UUID.dump!(snapshot_id), Ecto.UUID.dump!(round_id)]
         ).rows do
      [[_id]] -> :ok
      [] -> {:error, :tee_snapshot_not_found}
    end
  end

  defp lock_entry(round_entry_id, round_id, event_id) do
    case Repo.query!(
           """
           SELECT id::text, event_id::text, round_id::text, participation_status
           FROM round_entries
           WHERE id = $1::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(round_entry_id)]
         ).rows do
      [[id, eid, rid, participation]] ->
        entry = %{
          id: Ecto.UUID.cast!(id),
          event_id: Ecto.UUID.cast!(eid),
          round_id: Ecto.UUID.cast!(rid),
          participation_status: String.to_existing_atom(participation)
        }

        cond do
          entry.round_id != round_id -> {:error, :round_entry_mismatch}
          entry.event_id != event_id -> {:error, :event_mismatch}
          entry.participation_status != :not_started -> {:error, :entry_not_not_started}
          true -> {:ok, entry}
        end

      [] ->
        {:error, :round_entry_not_found}
    end
  end

  defp assign_tee(entry, snapshot_id) do
    case Ash.get(RoundEntry, entry.id, authorize?: false) do
      {:ok, record} ->
        record
        |> Changeset.for_update(:assign_round_tee_internal, %{
          round_tee_profile_snapshot_id: snapshot_id
        })
        |> Ash.update(authorize?: false)

      {:error, error} ->
        {:error, error}
    end
  end

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result({:error, :rollback, reason}), do: {:error, reason}
end

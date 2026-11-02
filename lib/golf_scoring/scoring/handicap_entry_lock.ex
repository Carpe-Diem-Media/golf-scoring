defmodule GolfScoring.Scoring.HandicapEntryLock do
  @moduledoc false

  alias GolfScoring.LockProtocol
  alias GolfScoring.Repo

  @spec lock!(Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :round_entry_not_found | :entry_not_not_started}
  def lock!(round_entry_id) do
    with {:ok, entry} <- lock_entry!(round_entry_id), do: require_not_started(entry)
  end

  defp lock_entry!(round_entry_id) do
    case Repo.query!(
           """
           SELECT id::text, event_id::text, round_id::text, player_id::text,
                  participation_status, round_tee_profile_snapshot_id::text
           FROM round_entries
           WHERE id = $1::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(round_entry_id)]
         ).rows do
      [[id, event_id, round_id, player_id, participation, tee_snapshot_id]] ->
        entry = %{
          id: Ecto.UUID.cast!(id),
          event_id: Ecto.UUID.cast!(event_id),
          round_id: Ecto.UUID.cast!(round_id),
          player_id: Ecto.UUID.cast!(player_id),
          participation_status: String.to_existing_atom(participation),
          round_tee_profile_snapshot_id: cast_optional_uuid(tee_snapshot_id)
        }

        {:ok, entry}

      [] ->
        {:error, :round_entry_not_found}
    end
  end

  def lock_pre_open!(round_entry_id) do
    case Repo.query!("SELECT round_id::text FROM round_entries WHERE id = $1::uuid", [
           Ecto.UUID.dump!(round_entry_id)
         ]).rows do
      [[round_id]] ->
        round_id = Ecto.UUID.cast!(round_id)

        with {:ok, %{acquired: [%{row: round}]}} <- LockProtocol.acquire!(round: [round_id]),
             :ok <- pre_open_state(round.state),
             {:ok, entry} <- lock_entry!(round_entry_id),
             true <- entry.round_id == round_id,
             {:ok, entry} <- require_not_started(entry) do
          {:ok, entry}
        else
          false -> {:error, :round_entry_mismatch}
          {:error, _} = error -> error
        end

      [] ->
        {:error, :round_entry_not_found}
    end
  end

  defp require_not_started(%{participation_status: :not_started} = entry), do: {:ok, entry}
  defp require_not_started(_entry), do: {:error, :entry_not_not_started}

  defp pre_open_state(state) when state in ["draft", "ready"], do: :ok
  defp pre_open_state(state), do: {:error, {:invalid_round_state, String.to_existing_atom(state)}}

  def cast_optional_uuid(nil), do: nil

  def cast_optional_uuid(value) do
    {:ok, uuid} = Ecto.UUID.cast(value)
    uuid
  end
end

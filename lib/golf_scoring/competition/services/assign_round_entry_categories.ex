defmodule GolfScoring.Competition.Services.AssignRoundEntryCategories do
  @moduledoc false

  require Ash.Query

  alias Ash.Changeset
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Competition.RoundEntryCategoryMembership
  alias GolfScoring.Repo

  @manager_roles [:event_admin, :competition_manager]
  @pre_open_round_states ~w(draft ready)

  @spec run(map(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, %{memberships: [RoundEntryCategoryMembership.t()]}} | {:error, term()}
  def run(actor, event_id, round_id, round_entry_id, category_ids)
      when is_map(actor) and is_list(category_ids) do
    if Repo.in_transaction?() do
      {:error, :transaction_already_open}
    else
      run_standalone(actor, event_id, round_id, round_entry_id, category_ids)
    end
  end

  def run(_actor, _event_id, _round_id, _round_entry_id, _category_ids),
    do: {:error, :invalid_input}

  defp run_standalone(actor, event_id, round_id, round_entry_id, category_ids) do
    actor_id = Map.get(actor, :id)
    category_ids = normalize_category_ids(category_ids)

    Repo.transaction(fn ->
      with {:ok, _scope} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
           :ok <- authorize(actor_id, event_id),
           {:ok, round} <- lock_round(round_id),
           :ok <- round_belongs_to_event(round, event_id),
           :ok <- round_accepts_assignment(round),
           {:ok, entry} <- lock_round_entry(round_entry_id),
           :ok <- entry_belongs_to_round(entry, round_id, event_id),
           :ok <- lock_categories(round_id, category_ids),
           {:ok, existing} <- lock_memberships(round_entry_id),
           :ok <- apply_replacement(existing, category_ids, round_id, round_entry_id),
           {:ok, memberships} <- load_memberships(round_entry_id) do
        %{memberships: memberships}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_result()
  end

  defp authorize(actor_id, event_id) do
    if ActiveEventRole.authorized?(actor_id, event_id, @manager_roles) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp normalize_category_ids(category_ids) do
    category_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&Ecto.UUID.dump!/1)
  end

  defp lock_round(round_id) do
    case Repo.query!(
           "SELECT id::text, event_id::text, state FROM rounds WHERE id = $1::uuid FOR UPDATE",
           [Ecto.UUID.dump!(round_id)]
         ).rows do
      [[id, event_id, state]] ->
        {:ok,
         %{
           id: Ecto.UUID.cast!(id),
           event_id: Ecto.UUID.cast!(event_id),
           state: state
         }}

      [] ->
        {:error, :round_not_found}
    end
  end

  defp round_belongs_to_event(%{event_id: round_event_id}, event_id) do
    if round_event_id == event_id, do: :ok, else: {:error, :event_mismatch}
  end

  defp round_accepts_assignment(%{state: state}) when state in @pre_open_round_states, do: :ok

  defp round_accepts_assignment(%{state: state}),
    do: {:error, {:invalid_round_state, state}}

  defp lock_round_entry(round_entry_id) do
    case Repo.query!(
           """
           SELECT id::text, event_id::text, round_id::text, player_id::text,
                  registration_status, participation_status
           FROM round_entries
           WHERE id = $1::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(round_entry_id)]
         ).rows do
      [[id, event_id, round_id, player_id, registration_status, participation_status]] ->
        {:ok,
         %{
           id: Ecto.UUID.cast!(id),
           event_id: Ecto.UUID.cast!(event_id),
           round_id: Ecto.UUID.cast!(round_id),
           player_id: Ecto.UUID.cast!(player_id),
           registration_status: registration_status,
           participation_status: participation_status
         }}

      [] ->
        {:error, :round_entry_not_found}
    end
  end

  defp entry_belongs_to_round(entry, round_id, event_id) do
    if entry.round_id == round_id and entry.event_id == event_id do
      :ok
    else
      {:error, :round_entry_mismatch}
    end
  end

  defp lock_categories(_round_id, []), do: :ok

  defp lock_categories(round_id, category_ids) do
    dumped_ids = Enum.map(category_ids, &Ecto.UUID.dump!/1)

    rows =
      Repo.query!(
        """
        SELECT id::text
        FROM competition_categories
        WHERE round_id = $1::uuid
          AND id = ANY($2::uuid[])
        ORDER BY id
        FOR UPDATE
        """,
        [Ecto.UUID.dump!(round_id), dumped_ids]
      ).rows

    if length(rows) == length(category_ids) do
      :ok
    else
      {:error, :missing_category}
    end
  end

  defp lock_memberships(round_entry_id) do
    rows =
      Repo.query!(
        """
        SELECT id::text, round_id::text, round_entry_id::text, competition_category_id::text
        FROM round_entry_category_memberships
        WHERE round_entry_id = $1::uuid
        ORDER BY id
        FOR UPDATE
        """,
        [Ecto.UUID.dump!(round_entry_id)]
      ).rows

    {:ok,
     Enum.map(rows, fn [id, round_id, round_entry_id, competition_category_id] ->
       %RoundEntryCategoryMembership{
         id: Ecto.UUID.cast!(id),
         round_id: Ecto.UUID.cast!(round_id),
         round_entry_id: Ecto.UUID.cast!(round_entry_id),
         competition_category_id: Ecto.UUID.cast!(competition_category_id)
       }
     end)}
  end

  defp apply_replacement(existing, desired_category_ids, round_id, round_entry_id) do
    existing_by_category = Map.new(existing, &{&1.competition_category_id, &1})
    desired_set = MapSet.new(desired_category_ids)

    to_remove =
      existing
      |> Enum.reject(fn membership ->
        MapSet.member?(desired_set, membership.competition_category_id)
      end)

    to_add =
      Enum.reject(desired_category_ids, fn category_id ->
        Map.has_key?(existing_by_category, category_id)
      end)

    case destroy_memberships(to_remove) do
      :ok -> create_memberships(to_add, round_id, round_entry_id)
      other -> other
    end
  end

  defp destroy_memberships(memberships) do
    Enum.reduce_while(memberships, :ok, fn membership, :ok ->
      case destroy_one_membership(membership) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp destroy_one_membership(membership) do
    case Ash.get(RoundEntryCategoryMembership, membership.id, authorize?: false) do
      {:ok, record} -> destroy_membership_record(record)
      {:error, error} -> {:error, error}
    end
  end

  defp destroy_membership_record(record) do
    case Ash.destroy(record, action: :destroy_internal, authorize?: false) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp create_memberships(category_ids, round_id, round_entry_id) do
    Enum.reduce_while(category_ids, :ok, fn category_id, :ok ->
      RoundEntryCategoryMembership
      |> Changeset.for_create(:create_internal, %{
        round_id: round_id,
        round_entry_id: round_entry_id,
        competition_category_id: category_id
      })
      |> Ash.create(authorize?: false)
      |> case do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp load_memberships(round_entry_id) do
    memberships =
      RoundEntryCategoryMembership
      |> Ash.Query.filter(round_entry_id == ^round_entry_id)
      |> Ash.read!(authorize?: false)
      |> Enum.sort_by(&Ecto.UUID.dump!(&1.competition_category_id))

    {:ok, memberships}
  end

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result({:error, :rollback, reason}), do: {:error, reason}
end

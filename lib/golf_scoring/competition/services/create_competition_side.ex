defmodule GolfScoring.Competition.Services.CreateCompetitionSide do
  @moduledoc false

  alias Ash.Changeset
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Audit
  alias GolfScoring.Competition.CompetitionSide
  alias GolfScoring.Repo

  @manager_roles [:event_admin, :competition_manager]
  @pre_open_round_states ~w(draft ready)

  @spec run(map(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), :partnership | :solo) ::
          {:ok, CompetitionSide.t()} | {:error, term()}
  def run(actor, event_id, round_id, round_competition_id, formation)
      when is_map(actor) and formation in [:partnership, :solo] do
    actor_id = Map.get(actor, :id)

    Repo.transaction(fn ->
      with {:ok, _scope} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
           :ok <- authorize(actor_id, event_id),
           {:ok, round} <- lock_round(round_id),
           :ok <- round_belongs_to_event(round, event_id),
           :ok <- round_accepts_configuration(round),
           :ok <- lock_round_competition(round_competition_id, round_id),
           {:ok, side} <- create_side(round_competition_id, round_id, formation),
           :ok <- write_audit_if_ready(actor_id, event_id, round, round_competition_id, side) do
        side
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_result()
  end

  def run(_actor, _event_id, _round_id, _round_competition_id, _formation),
    do: {:error, :invalid_input}

  defp authorize(actor_id, event_id) do
    if ActiveEventRole.authorized?(actor_id, event_id, @manager_roles) do
      :ok
    else
      {:error, :forbidden}
    end
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

  defp round_accepts_configuration(%{state: state}) when state in @pre_open_round_states, do: :ok

  defp round_accepts_configuration(%{state: state}),
    do: {:error, {:invalid_round_state, state}}

  defp lock_round_competition(round_competition_id, round_id) do
    case Repo.query!(
           """
           SELECT id::text FROM round_competitions
           WHERE id = $1::uuid AND round_id = $2::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(round_competition_id), Ecto.UUID.dump!(round_id)]
         ).rows do
      [[_id]] -> :ok
      [] -> {:error, :round_competition_not_found}
    end
  end

  defp create_side(round_competition_id, round_id, formation) do
    CompetitionSide
    |> Changeset.for_create(:create_competition_side_internal, %{
      round_competition_id: round_competition_id,
      round_id: round_id,
      formation: formation
    })
    |> Ash.create(authorize?: false)
  end

  defp write_audit_if_ready(
         actor_id,
         event_id,
         %{id: round_id, state: "ready"},
         round_competition_id,
         side
       ) do
    case Audit.record_staff_event(
           %{
             actor_staff_user_id: actor_id,
             action: "create_competition_side",
             target_type: "round",
             target_id: round_id,
             context: %{
               "event_id" => event_id,
               "round_id" => round_id,
               "round_competition_id" => round_competition_id
             },
             changes: %{
               "competition_side_id" => side.id,
               "round_competition_id" => round_competition_id,
               "formation" => %{"from" => nil, "to" => Atom.to_string(side.formation)}
             }
           },
           authorize?: false
         ) do
      {:ok, _audit} -> :ok
      {:ok, _audit, _notifications} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_audit_if_ready(_actor_id, _event_id, _round, _round_competition_id, _side), do: :ok

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result({:error, :rollback, reason}), do: {:error, reason}
end

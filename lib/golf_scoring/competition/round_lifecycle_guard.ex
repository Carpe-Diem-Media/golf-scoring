defmodule GolfScoring.Competition.RoundLifecycleGuard do
  @moduledoc false

  use Ash.Resource.Change

  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Audit
  alias GolfScoring.Competition.Round
  alias GolfScoring.Competition.Services.OpenRound
  alias GolfScoring.Repo

  @manager_roles [:event_admin, :competition_manager]
  @admin_only_operations [:reopen_round, :cancel_round]
  @audited_operations [
    :open_scoring,
    :close_scoring,
    :finalize_round,
    :reopen_round,
    :cancel_round
  ]

  @impl true
  def change(changeset, opts, context) do
    operation = Keyword.fetch!(opts, :operation)
    actor_id = if is_map(context.actor), do: Map.get(context.actor, :id), else: nil

    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      lock_and_transition(changeset, actor_id, operation)
    end)
    |> maybe_after_action_audit(operation)
  end

  defp maybe_after_action_audit(changeset, operation) do
    if operation in @audited_operations do
      Ash.Changeset.after_action(changeset, fn changeset, round ->
        write_audit(changeset, round, operation)
      end)
    else
      changeset
    end
  end

  defp lock_and_transition(changeset, actor_id, operation) do
    round = changeset.data
    event_id = round.event_id

    with {:ok, _scope} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
         :ok <- authorize_operation(actor_id, event_id, operation),
         {:ok, locked_round} <- lock_round(round.id),
         {:ok, next_state} <-
           transition(locked_round.state, operation, changeset.context, locked_round.id),
         :ok <- validate_reopen_reason(changeset, operation) do
      changeset
      |> Map.put(:data, locked_round)
      |> Ash.Changeset.set_context(%{
        round_lifecycle_mutation: %{
          actor_id: actor_id,
          event_id: event_id,
          round_id: round.id,
          from_state: state_string(locked_round.state),
          to_state: next_state,
          reason: reopen_reason(changeset, operation)
        }
      })
      |> Ash.Changeset.force_change_attribute(:state, state_atom(next_state))
    else
      {:error, message} -> Ash.Changeset.add_error(changeset, field: :state, message: message)
    end
  end

  defp authorize_operation(actor_id, event_id, operation)
       when operation in @admin_only_operations do
    if ActiveEventRole.authorized?(actor_id, event_id, [:event_admin]) do
      :ok
    else
      {:error, "an active EventAdmin assignment for this Event is required"}
    end
  end

  defp authorize_operation(actor_id, event_id, _operation) do
    if ActiveEventRole.authorized?(actor_id, event_id, @manager_roles) do
      :ok
    else
      {:error, "an active EventAdmin or CompetitionManager assignment for this Event is required"}
    end
  end

  defp lock_round(round_id) do
    case Repo.query!(
           "SELECT id FROM rounds WHERE id = $1::uuid FOR UPDATE",
           [Ecto.UUID.dump!(round_id)]
         ).rows do
      [_row] -> {:ok, Repo.get!(Round, round_id)}
      [] -> {:error, "Round does not exist"}
    end
  end

  defp transition(:draft, :mark_round_ready, context, round_id) do
    if OpenRound.verified_gate?(
         context,
         round_id,
         :mark_round_ready
       ),
       do: {:ok, "ready"},
       else: {:error, "cannot mark Round ready until the complete opening gate can be verified"}
  end

  defp transition(:ready, :open_scoring, context, round_id) do
    if OpenRound.verified_gate?(
         context,
         round_id,
         :open_scoring
       ),
       do: {:ok, "scoring_open"},
       else:
         {:error, "cannot open Round scoring until all hard opening invariants can be verified"}
  end

  defp transition(state, operation, _context, _round_id), do: transition(state, operation)

  defp transition(:scoring_closed, :finalize_round) do
    {:error,
     "cannot finalize Round until required CompetitionSideResult and finalization evidence can be verified"}
  end

  defp transition(:scoring_open, :close_scoring), do: {:ok, "scoring_closed"}
  defp transition(:finalized, :reopen_round), do: {:ok, "scoring_closed"}
  defp transition(state, :cancel_round) when state in [:draft, :ready], do: {:ok, "cancelled"}

  defp transition(_state, _operation) do
    {:error, "Round cannot make the requested lifecycle transition"}
  end

  defp validate_reopen_reason(changeset, :reopen_round) do
    case reopen_reason(changeset, :reopen_round) do
      reason when is_binary(reason) ->
        if String.trim(reason) == "" do
          {:error, "a nonblank reason is required to reopen a finalized Round"}
        else
          :ok
        end

      _ ->
        {:error, "a nonblank reason is required to reopen a finalized Round"}
    end
  end

  defp validate_reopen_reason(_changeset, _operation), do: :ok

  defp reopen_reason(changeset, :reopen_round) do
    Ash.Changeset.get_argument(changeset, :reason)
  end

  defp reopen_reason(_changeset, _operation), do: nil

  defp write_audit(changeset, round, operation) do
    %{round_lifecycle_mutation: mutation} = changeset.context

    context =
      %{
        "event_id" => mutation.event_id,
        "round_id" => mutation.round_id
      }
      |> maybe_put_reason(mutation.reason)

    attributes = %{
      actor_staff_user_id: mutation.actor_id,
      action: audit_action(operation),
      target_type: "round",
      target_id: mutation.round_id,
      context: context,
      changes: %{"state" => %{"from" => mutation.from_state, "to" => mutation.to_state}}
    }

    case Audit.record_staff_event(attributes, authorize?: false, return_notifications?: true) do
      {:ok, _audit, _notifications} -> {:ok, round}
      {:ok, _audit} -> {:ok, round}
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_put_reason(context, reason) when is_binary(reason) do
    Map.put(context, "reason", reason)
  end

  defp maybe_put_reason(context, _), do: context

  defp audit_action(:open_scoring), do: "round_scoring_opened"
  defp audit_action(:close_scoring), do: "round_scoring_closed"
  defp audit_action(:finalize_round), do: "round_finalized"
  defp audit_action(:reopen_round), do: "round_reopened"
  defp audit_action(:cancel_round), do: "round_cancelled"

  defp state_atom("draft"), do: :draft
  defp state_atom("ready"), do: :ready
  defp state_atom("scoring_open"), do: :scoring_open
  defp state_atom("scoring_closed"), do: :scoring_closed
  defp state_atom("finalized"), do: :finalized
  defp state_atom("cancelled"), do: :cancelled

  defp state_string(state) when is_atom(state), do: Atom.to_string(state)
  defp state_string(state) when is_binary(state), do: state
end

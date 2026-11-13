defmodule GolfScoring.Competition.RoundEntryScoringLifecycleGuard do
  @moduledoc false

  use Ash.Resource.Change

  alias GolfScoring.Competition.RoundEntry
  alias GolfScoring.Competition.Services.AcceptRoundEntryWithdrawal
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Services.SubmitGroupHole

  @impl true
  def change(changeset, opts, _context) do
    operation = Keyword.fetch!(opts, :operation)

    case operation do
      :mark_participation_withdrawn_internal -> guard_withdrawal(changeset)
      _ -> guard_scoring_progression(changeset, operation)
    end
  end

  defp guard_scoring_progression(changeset, operation) do
    Ash.Changeset.before_action(changeset, &apply_scoring_progression(&1, operation))
  end

  defp apply_scoring_progression(changeset, operation) do
    current = Ash.Changeset.get_data(changeset, :participation_status)
    entry = changeset.data

    case require_progression(changeset.context, operation, entry) do
      :ok ->
        apply_participation_transition(changeset, operation, current)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :participation_status, message: message)
    end
  end

  defp guard_withdrawal(changeset) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case AcceptRoundEntryWithdrawal.consume_internal_write(
             changeset,
             :mark_participation_withdrawn_internal
           ) do
        {:ok, %{participation_status: :withdrawn}} ->
          Ash.Changeset.force_change_attribute(changeset, :participation_status, :withdrawn)

        {:error, _reason} ->
          Ash.Changeset.add_error(changeset,
            field: :participation_status,
            message: "withdrawal requires its locked acceptance coordinator transaction"
          )
      end
    end)
  end

  defp apply_participation_transition(changeset, operation, current) do
    case {operation, current} do
      {:mark_participation_active, :not_started} ->
        Ash.Changeset.force_change_attribute(changeset, :participation_status, :active)

      {:mark_participation_completed, :active} ->
        Ash.Changeset.force_change_attribute(changeset, :participation_status, :completed)

      {:mark_participation_active, _} ->
        Ash.Changeset.add_error(changeset,
          field: :participation_status,
          message: "cannot mark active from #{current}"
        )

      {:mark_participation_completed, _} ->
        Ash.Changeset.add_error(changeset,
          field: :participation_status,
          message: "cannot mark completed from #{current}"
        )
    end
  end

  defp require_progression(context, operation, %RoundEntry{id: entry_id}) do
    playing_group_id = entry_playing_group_id(entry_id)

    cond do
      is_nil(playing_group_id) ->
        {:error, "participation lifecycle requires verified SubmitGroupHole progression"}

      not SubmitGroupHole.verified_progression?(
        context,
        playing_group_id,
        operation,
        entry_id
      ) ->
        {:error, "participation lifecycle requires verified SubmitGroupHole progression"}

      not SubmitGroupHole.round_entry_lifecycle_evidence?(operation, entry_id) ->
        {:error, "participation lifecycle lacks durable scoring evidence"}

      true ->
        :ok
    end
  end

  defp entry_playing_group_id(entry_id) do
    case Repo.get(RoundEntry, entry_id) do
      %{playing_group_id: id} when not is_nil(id) -> id
      _ -> nil
    end
  end
end

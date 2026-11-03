defmodule GolfScoring.Scoring.ScorecardScoringLifecycleGuard do
  @moduledoc false

  use Ash.Resource.Change

  alias GolfScoring.Competition.RoundEntry
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Services.SubmitGroupHole

  @impl true
  def change(changeset, opts, _context) do
    operation = Keyword.fetch!(opts, :operation)

    Ash.Changeset.before_action(changeset, fn changeset ->
      current = Ash.Changeset.get_data(changeset, :state)
      scorecard = changeset.data

      case require_progression(changeset.context, operation, scorecard) do
        :ok ->
          apply_scorecard_transition(changeset, operation, current)

        {:error, message} ->
          Ash.Changeset.add_error(changeset, field: :state, message: message)
      end
    end)
  end

  defp apply_scorecard_transition(changeset, operation, current) do
    case {operation, current} do
      {:mark_in_progress, :not_started} ->
        Ash.Changeset.force_change_attribute(changeset, :state, :in_progress)

      {:mark_complete, :in_progress} ->
        Ash.Changeset.force_change_attribute(changeset, :state, :complete)

      {:mark_in_progress, _} ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: "cannot start from #{current}"
        )

      {:mark_complete, _} ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: "cannot complete from #{current}"
        )
    end
  end

  defp require_progression(context, operation, scorecard) do
    playing_group_id = scorecard_playing_group_id(scorecard)

    cond do
      is_nil(playing_group_id) ->
        {:error, "scorecard lifecycle requires verified SubmitGroupHole progression"}

      not SubmitGroupHole.verified_progression?(
        context,
        playing_group_id,
        operation,
        scorecard.id
      ) ->
        {:error, "scorecard lifecycle requires verified SubmitGroupHole progression"}

      not SubmitGroupHole.scorecard_lifecycle_evidence?(operation, scorecard.id) ->
        {:error, "scorecard lifecycle lacks durable scoring evidence"}

      true ->
        :ok
    end
  end

  defp scorecard_playing_group_id(%{round_entry_id: entry_id}) do
    case Repo.get(RoundEntry, entry_id) do
      %{playing_group_id: id} when not is_nil(id) -> id
      _ -> nil
    end
  end
end

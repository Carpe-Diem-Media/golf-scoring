defmodule GolfScoring.Competition.PlayingGroupLifecycleGuard do
  @moduledoc false

  use Ash.Resource.Change

  alias GolfScoring.Scoring.Services.SubmitGroupHole

  @future_dependency_message "cannot transition PlayingGroup lifecycle until required HoleSubmission and completion evidence is implemented"

  @impl true
  def change(changeset, opts, _context) do
    operation = Keyword.fetch!(opts, :operation)

    Ash.Changeset.before_action(changeset, fn changeset ->
      current = Ash.Changeset.get_data(changeset, :state)
      group = changeset.data

      case require_progression(changeset.context, operation, group) do
        :ok ->
          apply_group_transition(changeset, operation, current)

        {:error, message} ->
          Ash.Changeset.add_error(changeset, field: :state, message: message)
      end
    end)
  end

  defp apply_group_transition(changeset, operation, current) do
    case {operation, current} do
      {:mark_group_playing, :not_started} ->
        Ash.Changeset.force_change_attribute(changeset, :state, :playing)

      {:mark_group_finished, :playing} ->
        Ash.Changeset.force_change_attribute(changeset, :state, :finished_playing)

      {:mark_group_playing, _} ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: "cannot mark playing from #{current}"
        )

      {:mark_group_finished, _} ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: "cannot mark finished from #{current}"
        )

      {:flag_group_attention, _} ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: transition_message(:flag_group_attention)
        )

      {:clear_group_attention, _} ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: transition_message(:clear_group_attention)
        )
    end
  end

  defp require_progression(context, operation, group)
       when operation in [:mark_group_playing, :mark_group_finished] do
    cond do
      not SubmitGroupHole.verified_progression?(context, group.id, operation, group.id) ->
        {:error, "PlayingGroup lifecycle requires verified SubmitGroupHole progression"}

      not SubmitGroupHole.playing_group_lifecycle_evidence?(operation, group.id) ->
        {:error, "PlayingGroup lifecycle lacks durable scoring evidence"}

      true ->
        :ok
    end
  end

  defp require_progression(_context, _operation, _group), do: :ok

  defp transition_message(:flag_group_attention),
    do: "#{@future_dependency_message} for flag_group_attention"

  defp transition_message(:clear_group_attention),
    do: "#{@future_dependency_message} for clear_group_attention"
end

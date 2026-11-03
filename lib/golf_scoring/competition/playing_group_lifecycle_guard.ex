defmodule GolfScoring.Competition.PlayingGroupLifecycleGuard do
  @moduledoc false

  use Ash.Resource.Change

  @future_dependency_message "cannot transition PlayingGroup lifecycle until required HoleSubmission and completion evidence is implemented"

  @impl true
  def change(changeset, opts, _context) do
    operation = Keyword.fetch!(opts, :operation)

    Ash.Changeset.before_action(changeset, fn changeset ->
      current = Ash.Changeset.get_data(changeset, :state)

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
    end)
  end

  defp transition_message(:flag_group_attention),
    do: "#{@future_dependency_message} for flag_group_attention"

  defp transition_message(:clear_group_attention),
    do: "#{@future_dependency_message} for clear_group_attention"
end

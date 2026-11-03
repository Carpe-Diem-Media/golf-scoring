defmodule GolfScoring.Scoring.ScorecardScoringLifecycleGuard do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    operation = Keyword.fetch!(opts, :operation)

    Ash.Changeset.before_action(changeset, fn changeset ->
      current = Ash.Changeset.get_data(changeset, :state)

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
    end)
  end
end

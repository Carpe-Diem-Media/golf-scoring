defmodule GolfScoring.Competition.RoundEntryScoringLifecycleGuard do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    operation = Keyword.fetch!(opts, :operation)

    Ash.Changeset.before_action(changeset, fn changeset ->
      current = Ash.Changeset.get_data(changeset, :participation_status)

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
    end)
  end
end

defmodule GolfScoring.Competition.Changes.IncrementPlayingGroupScoringRevision do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      current = Ash.Changeset.get_data(changeset, :scoring_revision) || 0

      if current >= 18 do
        Ash.Changeset.add_error(changeset,
          field: :scoring_revision,
          message: "group has already accepted all scheduled holes"
        )
      else
        Ash.Changeset.force_change_attribute(changeset, :scoring_revision, current + 1)
      end
    end)
  end
end

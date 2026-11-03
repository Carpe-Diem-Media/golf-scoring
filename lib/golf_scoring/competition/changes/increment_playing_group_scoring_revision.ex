defmodule GolfScoring.Competition.Changes.IncrementPlayingGroupScoringRevision do
  @moduledoc false

  use Ash.Resource.Change

  alias GolfScoring.Scoring.Services.SubmitGroupHole

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      group = changeset.data
      current = Ash.Changeset.get_data(changeset, :scoring_revision) || 0

      case require_progression(changeset.context, group) do
        :ok ->
          increment_or_error(changeset, current)

        {:error, message} ->
          Ash.Changeset.add_error(changeset, field: :scoring_revision, message: message)
      end
    end)
  end

  defp increment_or_error(changeset, current) do
    if current >= 18 do
      Ash.Changeset.add_error(changeset,
        field: :scoring_revision,
        message: "group has already accepted all scheduled holes"
      )
    else
      Ash.Changeset.force_change_attribute(changeset, :scoring_revision, current + 1)
    end
  end

  defp require_progression(context, group) do
    if SubmitGroupHole.verified_progression?(
         context,
         group.id,
         :increment_scoring_revision,
         group.id
       ) do
      :ok
    else
      {:error, "scoring revision increment requires verified SubmitGroupHole progression"}
    end
  end
end

defmodule GolfScoring.Scoring.CorrectionWriteGuard do
  @moduledoc false
  use Ash.Resource.Change
  alias GolfScoring.Scoring.Services.CorrectHoleResult

  @impl true
  def change(changeset, opts, _context) do
    case opts[:operation] do
      :update ->
        Ash.Changeset.around_action(changeset, &CorrectHoleResult.around_update/2)

      :evidence ->
        Ash.Changeset.before_action(changeset, &CorrectHoleResult.validate_revision_create/1)
    end
  end
end

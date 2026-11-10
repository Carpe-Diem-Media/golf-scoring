defmodule GolfScoring.Scoring.ScoreQueryDecisionGuard do
  @moduledoc false

  use Ash.Resource.Change

  alias GolfScoring.Scoring.Services.DecideScoreQuery

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.action.name do
      :resolve_no_change_internal ->
        Ash.Changeset.around_action(changeset, &DecideScoreQuery.around_resolve_no_change/2)

      :dismiss_internal ->
        Ash.Changeset.around_action(changeset, &DecideScoreQuery.around_dismiss/2)
    end
  end
end

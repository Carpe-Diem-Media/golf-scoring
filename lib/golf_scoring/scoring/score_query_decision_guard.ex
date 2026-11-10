defmodule GolfScoring.Scoring.ScoreQueryDecisionGuard do
  @moduledoc false

  use Ash.Resource.Change

  alias GolfScoring.Scoring.Services.DecideScoreQuery
  alias GolfScoring.Scoring.Services.ResolveScoreQueryWithCorrection

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.action.name do
      :resolve_no_change_internal ->
        Ash.Changeset.around_action(changeset, &DecideScoreQuery.around_resolve_no_change/2)

      :dismiss_internal ->
        Ash.Changeset.around_action(changeset, &DecideScoreQuery.around_dismiss/2)

      :resolve_with_correction_internal ->
        Ash.Changeset.around_action(
          changeset,
          &ResolveScoreQueryWithCorrection.around_resolve_with_correction/2
        )
    end
  end
end

defmodule GolfScoring.Scoring.ScorecardQueryReviewGuard do
  @moduledoc false
  use Ash.Resource.Change
  alias GolfScoring.Scoring.Services.OpenScoreQuery

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.before_action(changeset, &OpenScoreQuery.prepare_review(&1, :card))
end

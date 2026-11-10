defmodule GolfScoring.Scoring.ScoreQueryOpenGuard do
  @moduledoc false
  use Ash.Resource.Change
  alias GolfScoring.Scoring.Services.OpenScoreQuery

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.around_action(changeset, &OpenScoreQuery.around_open/2)
end

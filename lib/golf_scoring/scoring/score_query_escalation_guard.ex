defmodule GolfScoring.Scoring.ScoreQueryEscalationGuard do
  @moduledoc false
  use Ash.Resource.Change
  alias GolfScoring.Scoring.Services.EscalateScoreQuery

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.around_action(changeset, &EscalateScoreQuery.around_escalate/2)
end

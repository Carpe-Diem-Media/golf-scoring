defmodule GolfScoring.Competition.MysteryRevealGuard do
  @moduledoc false
  use Ash.Resource.Change

  alias GolfScoring.Competition.Services.MysteryRevealCoordinator

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      token = changeset.context[:mystery_reveal_creation]
      rule_id = Ash.Changeset.get_attribute(changeset, :mystery_hole_rule_id)

      case MysteryRevealCoordinator.consume_creation(token, rule_id) do
        :ok ->
          changeset

        {:error, _} ->
          Ash.Changeset.add_error(changeset,
            message: "Mystery reveal requires its locked coordinator capability"
          )
      end
    end)
  end
end

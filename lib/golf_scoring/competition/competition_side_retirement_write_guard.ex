defmodule GolfScoring.Competition.CompetitionSideRetirementWriteGuard do
  @moduledoc false

  use Ash.Resource.Change

  alias Ash.Changeset
  alias GolfScoring.Competition.CompetitionSideRetirement
  alias GolfScoring.Competition.Services.AcceptCompetitionSideRetirement

  @fields [
    :event_id,
    :round_id,
    :round_competition_id,
    :competition_side_id,
    :competition_side_result_id,
    :playing_group_id,
    :authorized_by_staff_user_id,
    :reason,
    :acceptance_command_id,
    :command_meaning_fingerprint,
    :checkpoint_hole_submission_id,
    :checkpoint_round_hole_id,
    :checkpoint_play_index,
    :effective_round_hole_id,
    :effective_play_index,
    :preplay_boundary_confirmed
  ]

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, &authorize_write/1, prepend?: true)
  end

  defp authorize_write(changeset) do
    result =
      case changeset.context[:competition_side_retirement_write] do
        %{owner: AcceptCompetitionSideRetirement, token: token} ->
          AcceptCompetitionSideRetirement.consume_retirement_write(changeset, token)

        _ ->
          {:error, :unauthorized_retirement_write}
      end

    case result do
      :ok ->
        changeset

      {:error, _} ->
        Changeset.add_error(changeset,
          message: "CompetitionSideRetirement requires its owning coordinator"
        )
    end
  end

  @doc false
  def scope(changeset), do: Map.new(@fields, &{&1, Changeset.get_attribute(changeset, &1)})

  @doc false
  def matches?(changeset, %{token: token, pid: pid, used?: false} = proof) do
    changeset.resource == CompetitionSideRetirement and pid == self() and is_reference(token) and
      changeset.action.name == :create_accepted_internal and
      changeset.context[:competition_side_retirement_write] ==
        %{owner: AcceptCompetitionSideRetirement, token: token} and
      scope(changeset) == proof.scope and only_allowed_attributes?(changeset)
  end

  def matches?(_, _), do: false

  defp only_allowed_attributes?(changeset) do
    Enum.all?(
      Map.keys(changeset.attributes),
      &(&1 in (@fields ++ [:id, :inserted_at, :updated_at, :accepted_at]))
    )
  end
end

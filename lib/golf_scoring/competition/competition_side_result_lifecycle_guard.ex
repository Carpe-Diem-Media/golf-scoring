defmodule GolfScoring.Competition.CompetitionSideResultLifecycleGuard do
  @moduledoc "Guards CompetitionSideResult transitions; only the pre-play coordinator can exclude a provisional result."

  alias GolfScoring.Competition.Services.ExcludeCompetitionSideBeforeHole

  use Ash.Resource.Change

  @future_dependency_message "cannot transition CompetitionSideResult until required scoring, verification and readiness evidence is implemented"

  @impl true
  def change(changeset, opts, _context) do
    operation = Keyword.fetch!(opts, :operation)

    if operation == :exclude_before_hole_internal do
      guard_preplay_exclusion(changeset)
    else
      Ash.Changeset.before_action(changeset, fn changeset ->
        Ash.Changeset.add_error(changeset, field: :state, message: transition_message(operation))
      end)
    end
  end

  defp guard_preplay_exclusion(changeset) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      evidence = Map.get(changeset.context, :competition_side_result_exclusion)

      if valid_exclusion_evidence?(changeset.context, evidence, changeset.data) do
        changeset
        |> Ash.Changeset.force_change_attribute(:state, :excluded)
        |> Ash.Changeset.force_change_attribute(
          :excluded_by_staff_user_id,
          evidence.actor_id
        )
        |> Ash.Changeset.force_change_attribute(:exclusion_reason, evidence.reason)
        |> Ash.Changeset.force_change_attribute(:excluded_at, evidence.excluded_at)
        |> Ash.Changeset.force_change_attribute(
          :excluded_playing_group_id,
          evidence.playing_group_id
        )
        |> Ash.Changeset.force_change_attribute(
          :excluded_effective_round_hole_id,
          evidence.effective_round_hole_id
        )
        |> Ash.Changeset.force_change_attribute(
          :excluded_effective_play_index,
          evidence.effective_play_index
        )
        |> Ash.Changeset.force_change_attribute(:excluded_preplay_confirmed, true)
      else
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: "pre-play exclusion requires a verified coordinator transaction"
        )
      end
    end)
  end

  defp valid_exclusion_evidence?(context, evidence, result) do
    verified_coordinator_transaction?(context, evidence, result) and
      provisional_result?(result) and valid_exclusion_provenance?(evidence)
  end

  defp verified_coordinator_transaction?(context, evidence, result)
       when is_map(evidence) and is_map(result) do
    ExcludeCompetitionSideBeforeHole.verified_exclusion?(
      context,
      result.id,
      result.competition_side_id
    )
  end

  defp verified_coordinator_transaction?(_context, _evidence, _result), do: false

  defp provisional_result?(%{state: state}), do: state in [:provisional, "provisional"]
  defp provisional_result?(_result), do: false

  defp valid_exclusion_provenance?(%{
         reason: reason,
         excluded_at: %DateTime{},
         effective_play_index: index,
         preplay_confirmed?: true
       })
       when is_binary(reason) and index in 0..17 do
    String.trim(reason) != ""
  end

  defp valid_exclusion_provenance?(_evidence), do: false

  defp transition_message(:mark_review_required),
    do: "#{@future_dependency_message} for mark_review_required"

  defp transition_message(:mark_ready_to_finalize),
    do: "#{@future_dependency_message} for mark_ready_to_finalize"

  defp transition_message(:finalize), do: "#{@future_dependency_message} for finalize"
  defp transition_message(:reopen), do: "#{@future_dependency_message} for reopen"
  defp transition_message(:exclude), do: "#{@future_dependency_message} for exclude"

  defp transition_message(:exclude_before_hole_internal),
    do: "pre-play exclusion requires a verified coordinator transaction"
end

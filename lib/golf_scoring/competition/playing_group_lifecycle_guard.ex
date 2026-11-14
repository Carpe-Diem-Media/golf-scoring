defmodule GolfScoring.Competition.PlayingGroupLifecycleGuard do
  @moduledoc false

  use Ash.Resource.Change

  alias GolfScoring.Competition.Services.AcceptRoundEntryWithdrawal
  alias GolfScoring.Competition.Services.FillGroupRoleVacancy
  alias GolfScoring.Scoring.Services.SubmitGroupHole

  @future_dependency_message "cannot transition PlayingGroup lifecycle until required HoleSubmission and completion evidence is implemented"

  @impl true
  def change(changeset, opts, _context) do
    operation = Keyword.fetch!(opts, :operation)

    Ash.Changeset.before_action(changeset, fn changeset ->
      current = Ash.Changeset.get_data(changeset, :state)
      group = changeset.data

      case require_progression(changeset.context, operation, group) do
        :ok ->
          apply_group_transition(changeset, operation, current)

        {:error, message} ->
          Ash.Changeset.add_error(changeset, field: :state, message: message)
      end
    end)
  end

  defp apply_group_transition(changeset, operation, current) do
    if operation == :clear_group_attention_for_vacancy_internal do
      apply_vacancy_attention_transition(changeset, current)
    else
      apply_regular_group_transition(changeset, operation, current)
    end
  end

  defp apply_vacancy_attention_transition(changeset, :attention_required),
    do: apply_vacancy_attention_clear(changeset)

  defp apply_vacancy_attention_transition(changeset, _current) do
    Ash.Changeset.add_error(changeset,
      field: :state,
      message: "vacancy recovery can clear attention only from attention_required"
    )
  end

  defp apply_regular_group_transition(changeset, operation, current) do
    case {operation, current} do
      {:mark_group_playing, :not_started} ->
        Ash.Changeset.force_change_attribute(changeset, :state, :playing)

      {:mark_group_finished, :playing} ->
        Ash.Changeset.force_change_attribute(changeset, :state, :finished_playing)

      {:mark_group_playing, _} ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: "cannot mark playing from #{current}"
        )

      {:mark_group_finished, _} ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: "cannot mark finished from #{current}"
        )

      {:flag_group_attention, _} ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: transition_message(:flag_group_attention)
        )

      {:flag_group_attention_for_withdrawal_internal, :playing} ->
        apply_withdrawal_attention(changeset)

      {:flag_group_attention_for_withdrawal_internal, _} ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: "withdrawal can flag attention only while the group is playing"
        )

      {:clear_group_attention, _} ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: transition_message(:clear_group_attention)
        )
    end
  end

  defp apply_withdrawal_attention(changeset) do
    case AcceptRoundEntryWithdrawal.consume_internal_write(
           changeset,
           :flag_group_attention_for_withdrawal_internal
         ) do
      {:ok, %{state: :attention_required}} ->
        Ash.Changeset.force_change_attribute(changeset, :state, :attention_required)

      {:error, _reason} ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: "withdrawal attention requires its locked acceptance coordinator transaction"
        )
    end
  end

  defp apply_vacancy_attention_clear(changeset) do
    case FillGroupRoleVacancy.consume_internal_write(
           changeset,
           :clear_group_attention_for_vacancy_internal
         ) do
      {:ok, %{state: :playing}} ->
        Ash.Changeset.force_change_attribute(changeset, :state, :playing)

      {:error, _reason} ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: "vacancy attention recovery requires its locked coordinator transaction"
        )
    end
  end

  defp require_progression(context, operation, group)
       when operation in [:mark_group_playing, :mark_group_finished] do
    cond do
      not SubmitGroupHole.verified_progression?(context, group.id, operation, group.id) ->
        {:error, "PlayingGroup lifecycle requires verified SubmitGroupHole progression"}

      not SubmitGroupHole.playing_group_lifecycle_evidence?(operation, group.id) ->
        {:error, "PlayingGroup lifecycle lacks durable scoring evidence"}

      true ->
        :ok
    end
  end

  defp require_progression(_context, _operation, _group), do: :ok

  defp transition_message(:flag_group_attention),
    do: "#{@future_dependency_message} for flag_group_attention"

  defp transition_message(:clear_group_attention),
    do: "#{@future_dependency_message} for clear_group_attention"
end

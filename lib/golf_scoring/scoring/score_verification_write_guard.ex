defmodule GolfScoring.Scoring.ScoreVerificationWriteGuard do
  @moduledoc """
  Requires the owning certification or correction operation for every write.

  This module does not issue authority. The two coordinators privately retain
  and consume exact, process-local write capabilities after their locked guards.
  Pure scope matching precedes transaction checks; no caller context can mint
  a capability. The owning transaction also contains every mandatory audit.
  """
  use Ash.Resource.Change

  alias Ash.Changeset
  alias GolfScoring.Scoring.ScoreVerification
  alias GolfScoring.Scoring.Services.CorrectHoleResult
  alias GolfScoring.Scoring.Services.VerifyHoleResult

  @fields [
    :round_id,
    :playing_group_id,
    :scorecard_id,
    :subject_round_entry_id,
    :hole_result_id,
    :hole_result_revision,
    :status,
    :verifier_round_entry_id,
    :role_assignment_id,
    :role_assignment_version,
    :overridden_by_staff_user_id,
    :override_reason
  ]

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, &authorize_write/1, prepend?: true)
  end

  defp authorize_write(changeset) do
    result =
      case changeset.context[:score_verification_write] do
        %{owner: owner} when owner in [VerifyHoleResult, CorrectHoleResult] ->
          owner.consume_verification_write(changeset)

        _ ->
          {:error, :unauthorized_verification_write}
      end

    case result do
      :ok ->
        changeset

      {:error, _} ->
        Changeset.add_error(changeset,
          message: "ScoreVerification requires its owning operation capability"
        )
    end
  end

  @doc false
  def scope(changeset),
    do: Map.new(@fields, &{&1, Changeset.get_attribute(changeset, &1)})

  # Matching is pure. A matching map is not authority without the owner's live
  # gate and PostgreSQL transaction identity, checked by its consumer.
  @doc false
  def matches?(changeset, %{owner: owner, token: token, pid: pid, used?: false} = proof, owner) do
    binding_matches?(changeset, owner, token, pid) and
      evidence_matches?(changeset, proof, owner) and
      valid_identity?(changeset) and
      only_allowed_attributes?(changeset)
  end

  def matches?(_, _, _), do: false

  defp binding_matches?(changeset, owner, token, pid) do
    changeset.resource == ScoreVerification and pid == self() and is_reference(token) and
      changeset.context[:score_verification_write] == %{owner: owner, token: token}
  end

  defp evidence_matches?(changeset, proof, owner) do
    changeset.action.name == proof.action and allowed?(owner, proof.operation, proof.action) and
      changeset.data == proof.record and scope(changeset) == proof.scope
  end

  defp only_allowed_attributes?(changeset) do
    Enum.all?(
      Map.keys(changeset.attributes),
      &(&1 in (@fields ++ [:id, :inserted_at, :updated_at]))
    )
  end

  defp valid_identity?(%{action_type: :create}), do: true

  defp valid_identity?(changeset),
    do: Changeset.get_attribute(changeset, :id) == changeset.data.id

  defp allowed?(VerifyHoleResult, :verify, action),
    do: action in [:create_pending_internal, :verify_internal]

  defp allowed?(VerifyHoleResult, :override, action),
    do: action in [:create_pending_internal, :override_internal]

  defp allowed?(CorrectHoleResult, :correct, action),
    do: action in [:create_pending_internal, :supersede_internal]

  defp allowed?(_, _, _), do: false
end

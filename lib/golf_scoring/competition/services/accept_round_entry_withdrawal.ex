defmodule GolfScoring.Competition.Services.AcceptRoundEntryWithdrawal do
  @moduledoc """
  Accepts one active RoundEntry withdrawal against the locked scoring checkpoint.

  The command owns a standalone transaction. It commits the immutable ruling,
  participation transition, role revocations, readiness blockers, and audit as
  one unit. Notifications run only after that transaction commits.
  """

  alias Ash.Changeset
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Audit
  alias GolfScoring.Competition.CompetitionSideResult
  alias GolfScoring.Competition.GroupRoleAssignment
  alias GolfScoring.Competition.PlayingGroup
  alias GolfScoring.Competition.RoundEntry
  alias GolfScoring.Competition.RoundEntryParticipationRuling
  alias GolfScoring.LockProtocol
  alias GolfScoring.Repo

  @authorized_roles ["event_admin", "competition_manager"]
  @eligible_registration_states ["expected", "checked_in"]
  @eligible_verifier_participation_states ["not_started", "active", "completed"]
  @scheduled_holes 18
  @freshness_limit_microseconds 60_000_000
  @gate_key {__MODULE__, :withdrawal_gate}
  @write_key {__MODULE__, :withdrawal_write}
  @write_context_key :round_entry_withdrawal_write

  @type accepted :: %{
          ruling_id: Ecto.UUID.t(),
          round_entry_id: Ecto.UUID.t(),
          playing_group_id: Ecto.UUID.t(),
          checkpoint_hole_submission_id: Ecto.UUID.t(),
          checkpoint_round_hole_id: Ecto.UUID.t(),
          checkpoint_play_index: non_neg_integer(),
          effective_round_hole_id: Ecto.UUID.t(),
          effective_play_index: pos_integer(),
          scoring_revision: pos_integer(),
          revoked_assignment_ids: [Ecto.UUID.t()],
          attention_required?: boolean(),
          changed_side_result_ids: [Ecto.UUID.t()]
        }

  @doc """
  Accept an active participant's withdrawal from the next unsubmitted hole.

  `attrs.attestation` must contain `observed_at`, `method: "direct_visual"`,
  `observation_location`, the Round and PlayingGroup IDs, the effective
  RoundHole ID and play index, and `confirms_unplayed?: true`. An optional
  `attrs.checkpoint` is treated only as a client claim and must match the
  authoritative locked checkpoint.
  """
  @spec run(StaffUser.t(), term(), term(), term(), term(), map()) ::
          {:ok, accepted()} | {:error, term()}
  def run(actor, event_id, round_id, playing_group_id, round_entry_id, attrs)
      when is_map(attrs) do
    if Repo.in_transaction?() do
      {:error, :transaction_already_open}
    else
      received_at = DateTime.utc_now(:microsecond)

      with %StaffUser{id: actor_id} <- actor,
           {:ok, actor_id} <- Ecto.UUID.cast(actor_id),
           {:ok, input} <-
             normalize_input(
               event_id,
               round_id,
               playing_group_id,
               round_entry_id,
               attrs,
               received_at
             ) do
        run_transaction(actor_id, input)
      else
        {:error, _reason} = error -> error
        _ -> {:error, :forbidden}
      end
    end
  end

  def run(_actor, _event_id, _round_id, _playing_group_id, _round_entry_id, _attrs),
    do: {:error, :invalid_input}

  @doc false
  def consume_internal_write(changeset, operation) do
    gate = Process.get(@gate_key)
    proof = Process.get(@write_key)
    context_proof = Map.get(changeset.context || %{}, @write_context_key)

    if valid_internal_write?(changeset, operation, gate, proof, context_proof) do
      Process.put(@write_key, %{proof | used?: true})
      {:ok, write_attributes(operation, proof)}
    else
      {:error, :unauthorized_round_entry_withdrawal_write}
    end
  end

  defp normalize_input(event_id, round_id, group_id, entry_id, attrs, received_at)
       when is_map(attrs) do
    with {:ok, event_id} <- Ecto.UUID.cast(event_id),
         {:ok, round_id} <- Ecto.UUID.cast(round_id),
         {:ok, group_id} <- Ecto.UUID.cast(group_id),
         {:ok, entry_id} <- Ecto.UUID.cast(entry_id),
         {:ok, reason} <- normalize_reason(Map.get(attrs, :reason)),
         {:ok, attestation} <- normalize_attestation(Map.get(attrs, :attestation), received_at),
         {:ok, checkpoint_claim} <- normalize_checkpoint_claim(Map.get(attrs, :checkpoint)),
         :ok <- reject_client_attested_at(attrs) do
      {:ok,
       %{
         event_id: event_id,
         round_id: round_id,
         playing_group_id: group_id,
         round_entry_id: entry_id,
         reason: reason,
         attestation: attestation,
         checkpoint_claim: checkpoint_claim,
         attested_at: received_at
       }}
    end
  end

  defp normalize_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :reason_required}
      value -> {:ok, value}
    end
  end

  defp normalize_reason(_), do: {:error, :reason_required}

  defp normalize_attestation(attestation, received_at) when is_map(attestation) do
    with {:ok, round_id} <- Ecto.UUID.cast(Map.get(attestation, :round_id)),
         {:ok, group_id} <- Ecto.UUID.cast(Map.get(attestation, :playing_group_id)),
         {:ok, hole_id} <- Ecto.UUID.cast(Map.get(attestation, :effective_round_hole_id)),
         index when is_integer(index) and index in 1..17 <-
           Map.get(attestation, :effective_play_index),
         %DateTime{} = observed_at <- Map.get(attestation, :observed_at),
         method when method in [:direct_visual, "direct_visual"] <-
           Map.get(attestation, :method),
         {:ok, location} <- normalize_location(Map.get(attestation, :observation_location)),
         true <- Map.get(attestation, :confirms_unplayed?) == true,
         :ok <- require_fresh_observation(observed_at, received_at) do
      {:ok,
       %{
         round_id: round_id,
         playing_group_id: group_id,
         effective_round_hole_id: hole_id,
         effective_play_index: index,
         observed_at: observed_at,
         method: "direct_visual",
         observation_location: location,
         confirms_unplayed?: true
       }}
    else
      _ -> {:error, :invalid_attestation}
    end
  end

  defp normalize_attestation(_attestation, _received_at),
    do: {:error, :preplay_attestation_required}

  defp normalize_location(location) when is_binary(location) do
    case String.trim(location) do
      "" -> {:error, :observation_location_required}
      value -> {:ok, value}
    end
  end

  defp normalize_location(_), do: {:error, :observation_location_required}

  defp require_fresh_observation(observed_at, received_at) do
    difference = DateTime.diff(received_at, observed_at, :microsecond)

    if difference >= 0 and difference <= @freshness_limit_microseconds do
      :ok
    else
      {:error, :stale_preplay_attestation}
    end
  end

  defp normalize_checkpoint_claim(nil), do: {:ok, nil}

  defp normalize_checkpoint_claim(claim) when is_map(claim) do
    allowed_keys = [
      :checkpoint_hole_submission_id,
      :checkpoint_round_hole_id,
      :checkpoint_play_index,
      :effective_round_hole_id,
      :effective_play_index,
      :scoring_revision
    ]

    if Enum.all?(Map.keys(claim), &(&1 in allowed_keys)) do
      normalize_checkpoint_claim_entries(claim)
    else
      {:error, :invalid_checkpoint_claim}
    end
  end

  defp normalize_checkpoint_claim(_), do: {:error, :invalid_checkpoint_claim}

  defp normalize_checkpoint_claim_entries(claim) do
    Enum.reduce_while(claim, {:ok, %{}}, &normalize_checkpoint_claim_entry/2)
  end

  defp normalize_checkpoint_claim_entry({key, value}, {:ok, acc}) do
    case checkpoint_claim_value(key, value) do
      {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp checkpoint_claim_value(key, value)
       when key in [
              :checkpoint_hole_submission_id,
              :checkpoint_round_hole_id,
              :effective_round_hole_id
            ],
       do: Ecto.UUID.cast(value)

  defp checkpoint_claim_value(:checkpoint_play_index, value)
       when is_integer(value) and value >= 0,
       do: {:ok, value}

  defp checkpoint_claim_value(key, value)
       when key in [:effective_play_index, :scoring_revision] and is_integer(value) and value > 0,
       do: {:ok, value}

  defp checkpoint_claim_value(_key, _value), do: {:error, :invalid_checkpoint_claim}

  defp reject_client_attested_at(attrs) do
    if Map.has_key?(attrs, :attested_at) or Map.has_key?(attrs, "attested_at"),
      do: {:error, :client_attested_at_forbidden},
      else: :ok
  end

  defp run_transaction(actor_id, input) do
    result =
      Repo.transaction(fn ->
        case accept_locked(actor_id, input) do
          {:ok, accepted} -> accepted
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, accepted} ->
        publish_notifications(accepted)
        {:ok, accepted}

      {:error, reason} ->
        {:error, reason}

      {:error, :rollback, reason} ->
        {:error, reason}
    end
  end

  defp accept_locked(actor_id, input) do
    with {:ok, authority_scope} <- EventAuthorityLock.lock_scope!(input.event_id, [actor_id]),
         {:ok, authority} <- authorize_locked_actor(authority_scope, actor_id),
         {:ok, gameplay} <- lock_gameplay_scope(input.round_id, input.playing_group_id),
         :ok <- validate_gameplay_scope(gameplay, input),
         {:ok, assignments} <- lock_active_assignments(input.playing_group_id),
         {:ok, group_entries} <- load_group_entry_states(input.playing_group_id),
         verification <-
           verification_snapshot(assignments, group_entries, input.round_entry_id),
         {:ok, side_scope} <-
           collect_affected_sides(input, verification.independent_verification_available?),
         {:ok, locked_sides} <- lock_sides_and_results(side_scope, input),
         {:ok, entry} <- lock_target_entry(input),
         :ok <- validate_target_entry(entry),
         :ok <- reject_existing_ruling(input.round_entry_id),
         {:ok, checkpoint} <- authoritative_checkpoint(gameplay.group, input),
         :ok <- validate_attestation_scope(input, checkpoint),
         :ok <- validate_checkpoint_claim(input.checkpoint_claim, checkpoint),
         :ok <- validate_side_result_states(locked_sides),
         {:ok, outcome} <-
           persist_withdrawal(%{
             actor_id: actor_id,
             authority: authority,
             input: input,
             gameplay: gameplay,
             entry: entry,
             checkpoint: checkpoint,
             assignments: assignments,
             verification: verification,
             sides: locked_sides
           }) do
      {:ok, outcome}
    else
      {:error, _reason} = error -> error
    end
  end

  defp authorize_locked_actor(scope, actor_id) do
    staff_user = EventAuthorityLock.staff_user(scope, actor_id)

    assignment =
      scope.assignments
      |> Enum.filter(fn assignment ->
        assignment.staff_user_id == actor_id and assignment.status == "active" and
          assignment.role in @authorized_roles
      end)
      |> Enum.sort_by(fn assignment ->
        Enum.find_index(@authorized_roles, &(&1 == assignment.role))
      end)
      |> List.first()

    if match?(%{status: "active"}, staff_user) and assignment do
      {:ok,
       %{
         assignment_id: assignment.id,
         role: assignment.role
       }}
    else
      {:error, :forbidden}
    end
  end

  defp lock_gameplay_scope(round_id, group_id) do
    case LockProtocol.acquire!(round: [round_id], playing_group: [group_id]) do
      {:ok, %{acquired: rows}} ->
        {:ok,
         %{
           round: Enum.find(rows, &(&1.class == :round)).row,
           group: Enum.find(rows, &(&1.class == :playing_group)).row
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_gameplay_scope(%{round: round, group: group}, input) do
    cond do
      round.event_id != input.event_id ->
        {:error, :event_mismatch}

      round.state not in ["scoring_open", :scoring_open] ->
        {:error, {:invalid_round_state, round.state}}

      group.round_id != input.round_id ->
        {:error, :playing_group_mismatch}

      group.state in ["finished_playing", :finished_playing] ->
        {:error, :playing_group_completed}

      group.state not in ["playing", :playing, "attention_required", :attention_required] ->
        {:error, {:invalid_playing_group_state, group.state}}

      group.scoring_revision == 0 ->
        {:error, :accepted_scoring_checkpoint_required}

      group.scoring_revision >= @scheduled_holes ->
        {:error, :group_scoring_complete}

      true ->
        :ok
    end
  end

  defp lock_active_assignments(group_id) do
    assignment_ids =
      Repo.query!(
        "SELECT id::text FROM group_role_assignments WHERE playing_group_id = $1::uuid AND state = 'active' ORDER BY id",
        [Ecto.UUID.dump!(group_id)]
      ).rows
      |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end)

    case LockProtocol.acquire!(group_role_assignment: assignment_ids) do
      {:ok, %{acquired: acquired}} ->
        rows = Enum.map(acquired, & &1.row)

        if Enum.all?(rows, &(&1.playing_group_id == group_id and &1.state == "active")) do
          {:ok, rows}
        else
          {:error, :active_role_assignment_scope_changed}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp load_group_entry_states(group_id) do
    rows =
      Repo.query!(
        """
        SELECT id::text, registration_status, participation_status
        FROM round_entries
        WHERE playing_group_id = $1::uuid
        ORDER BY id
        """,
        [Ecto.UUID.dump!(group_id)]
      ).rows

    {:ok,
     Map.new(rows, fn [id, registration_status, participation_status] ->
       {Ecto.UUID.cast!(id),
        %{registration_status: registration_status, participation_status: participation_status}}
     end)}
  end

  defp verification_snapshot(assignments, entry_states, withdrawing_entry_id) do
    remaining_assignments = Enum.reject(assignments, &(&1.round_entry_id == withdrawing_entry_id))

    participant_snapshot =
      entry_states
      |> Enum.sort_by(fn {entry_id, _state} -> Ecto.UUID.dump!(entry_id) end)
      |> Enum.map(fn {entry_id, state} ->
        %{
          round_entry_id: entry_id,
          registration_status: state.registration_status,
          participation_status: state.participation_status
        }
      end)

    active_role_holders =
      Map.new(remaining_assignments, fn assignment ->
        {assignment.role, Map.get(entry_states, assignment.round_entry_id)}
      end)

    primary = Map.get(active_role_holders, "primary_scorer")
    verifier = Map.get(active_role_holders, "designated_verifier")

    primary_id = role_holder_id(remaining_assignments, "primary_scorer")
    verifier_id = role_holder_id(remaining_assignments, "designated_verifier")

    available? =
      eligible_verifier_entry?(primary) and eligible_verifier_entry?(verifier) and
        not is_nil(primary_id) and not is_nil(verifier_id) and primary_id != verifier_id

    %{
      independent_verification_available?: available?,
      active_role_assignment_ids: Enum.map(assignments, & &1.id),
      remaining_active_role_assignments: remaining_assignments,
      remaining_primary_scorer_entry_id: primary_id,
      remaining_designated_verifier_entry_id: verifier_id,
      participant_snapshot: participant_snapshot,
      revoked_assignments: Enum.filter(assignments, &(&1.round_entry_id == withdrawing_entry_id))
    }
  end

  defp role_holder_id(assignments, role) do
    case Enum.find(assignments, &(&1.role == role)) do
      %{round_entry_id: entry_id} -> entry_id
      _ -> nil
    end
  end

  defp eligible_verifier_entry?(%{
         registration_status: registration,
         participation_status: participation
       }) do
    registration in @eligible_registration_states and
      participation in @eligible_verifier_participation_states
  end

  defp eligible_verifier_entry?(_), do: false

  defp collect_affected_sides(input, independent_verification_available?) do
    target_side_ids = side_ids_for_entry(input.round_entry_id, input.round_id)

    group_side_ids =
      if independent_verification_available? do
        []
      else
        side_ids_for_group(input.round_id, input.playing_group_id)
      end

    side_ids = canonical_ids(target_side_ids ++ group_side_ids)

    case side_ids do
      [] -> {:ok, %{side_ids: [], target_side_ids: [], results_by_side: %{}}}
      _ -> load_side_results(input, side_ids, target_side_ids)
    end
  end

  defp side_ids_for_entry(entry_id, round_id) do
    Repo.query!(
      """
      SELECT DISTINCT cs.id::text
      FROM competition_side_memberships csm
      JOIN competition_sides cs ON cs.id = csm.competition_side_id
      WHERE csm.round_id = $1::uuid AND csm.round_entry_id = $2::uuid
      ORDER BY cs.id::text
      """,
      [Ecto.UUID.dump!(round_id), Ecto.UUID.dump!(entry_id)]
    ).rows
    |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end)
  end

  defp side_ids_for_group(round_id, group_id) do
    Repo.query!(
      """
      SELECT DISTINCT cs.id::text
      FROM competition_side_memberships csm
      JOIN competition_sides cs ON cs.id = csm.competition_side_id
      JOIN round_entries re ON re.id = csm.round_entry_id
      WHERE csm.round_id = $1::uuid
        AND re.round_id = $1::uuid
        AND re.playing_group_id = $2::uuid
      ORDER BY cs.id::text
      """,
      [Ecto.UUID.dump!(round_id), Ecto.UUID.dump!(group_id)]
    ).rows
    |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end)
  end

  defp load_side_results(input, side_ids, target_side_ids) do
    rows =
      Repo.query!(
        """
        SELECT cs.id::text, cs.round_id::text, cs.round_competition_id::text,
               cs.formation, rc.event_id::text, rc.round_id::text,
               csr.id::text, csr.state
        FROM competition_sides cs
        JOIN round_competitions rc ON rc.id = cs.round_competition_id
        LEFT JOIN competition_side_results csr ON csr.competition_side_id = cs.id
        WHERE cs.id = ANY($1::uuid[])
        ORDER BY cs.id, csr.id
        """,
        [Enum.map(side_ids, &Ecto.UUID.dump!/1)]
      ).rows

    grouped = Enum.group_by(rows, fn [side_id | _] -> Ecto.UUID.cast!(side_id) end)

    cond do
      Enum.any?(side_ids, &(length(Map.get(grouped, &1, [])) != 1)) ->
        {:error, :competition_side_result_missing_or_ambiguous}

      Enum.any?(rows, fn [
                           _side_id,
                           _side_round,
                           _competition_id,
                           _formation,
                           _competition_event,
                           _competition_round,
                           result_id,
                           _state
                         ] ->
        is_nil(result_id)
      end) ->
        {:error, :competition_side_result_missing_or_ambiguous}

      true ->
        side_data =
          Map.new(grouped, fn {side_id,
                               [
                                 [
                                   _,
                                   side_round,
                                   _competition_id,
                                   _formation,
                                   competition_event,
                                   competition_round,
                                   result_id,
                                   result_state
                                 ]
                               ]} ->
            {side_id,
             %{
               side_id: side_id,
               round_id: Ecto.UUID.cast!(side_round),
               competition_event_id: Ecto.UUID.cast!(competition_event),
               competition_round_id: Ecto.UUID.cast!(competition_round),
               result_id: Ecto.UUID.cast!(result_id),
               state: result_state,
               target_member?: side_id in target_side_ids
             }}
          end)

        if Enum.all?(side_data, fn {_id, side} ->
             side.round_id == input.round_id and side.competition_round_id == input.round_id and
               side.competition_event_id == input.event_id
           end) do
          {:ok,
           %{
             side_ids: side_ids,
             target_side_ids: target_side_ids,
             results_by_side: side_data
           }}
        else
          {:error, :competition_side_scope_mismatch}
        end
    end
  end

  defp lock_sides_and_results(%{side_ids: []} = side_scope, _input),
    do: {:ok, Map.put(side_scope, :sides, [])}

  defp lock_sides_and_results(side_scope, input) do
    result_ids =
      side_scope.results_by_side
      |> Map.values()
      |> Enum.map(& &1.result_id)

    case LockProtocol.acquire!(
           competition_side: side_scope.side_ids,
           competition_side_result: result_ids
         ) do
      {:ok, %{acquired: acquired}} ->
        build_locked_side_scope(acquired, side_scope, input)

      {:error, _reason} = error ->
        error
    end
  end

  defp build_locked_side_scope(acquired, side_scope, input) do
    locked_sides = Enum.filter(acquired, &(&1.class == :competition_side))
    locked_results = Enum.filter(acquired, &(&1.class == :competition_side_result))
    results_by_side = Map.new(locked_results, &{&1.row.competition_side_id, &1.row})

    with {:ok, member_counts} <- side_member_counts(side_scope.side_ids, input),
         sides <-
           build_locked_sides(locked_sides, results_by_side, member_counts, side_scope),
         :ok <- validate_locked_sides(sides, side_scope, input) do
      {:ok, Map.put(side_scope, :sides, sides)}
    end
  end

  defp build_locked_sides(locked_sides, results_by_side, member_counts, side_scope) do
    Enum.map(locked_sides, fn %{row: side} ->
      result = Map.get(results_by_side, side.id)
      source = Map.fetch!(side_scope.results_by_side, side.id)

      %{
        side_id: side.id,
        round_id: side.round_id,
        round_competition_id: side.round_competition_id,
        formation: side.formation,
        result_id: result && result.id,
        state: result && result.state,
        target_member?: source.target_member?,
        member_count_after_withdrawal: Map.fetch!(member_counts, side.id)
      }
    end)
  end

  defp validate_locked_sides(sides, side_scope, input) do
    if Enum.all?(sides, &valid_locked_side?(&1, side_scope, input)) do
      :ok
    else
      {:error, :competition_side_result_scope_changed}
    end
  end

  defp valid_locked_side?(side, side_scope, input) do
    source = Map.fetch!(side_scope.results_by_side, side.side_id)

    side.round_id == input.round_id and not is_nil(side.result_id) and
      side.result_id == source.result_id
  end

  defp side_member_counts(side_ids, input) do
    rows =
      Repo.query!(
        """
        SELECT csm.competition_side_id::text,
               count(*)::int,
               count(*) FILTER (
                 WHERE re.id <> $5::uuid
                   AND re.registration_status IN ('expected', 'checked_in')
                   AND re.participation_status IN ('not_started', 'active', 'completed')
               )::int,
               bool_and(
                 re.event_id = $2::uuid AND re.round_id = $3::uuid
                 AND re.playing_group_id = $4::uuid
               )
        FROM competition_side_memberships csm
        JOIN round_entries re ON re.id = csm.round_entry_id
        WHERE csm.competition_side_id = ANY($1::uuid[])
        GROUP BY csm.competition_side_id
        ORDER BY csm.competition_side_id::text
        """,
        [
          Enum.map(side_ids, &Ecto.UUID.dump!/1),
          Ecto.UUID.dump!(input.event_id),
          Ecto.UUID.dump!(input.round_id),
          Ecto.UUID.dump!(input.playing_group_id),
          Ecto.UUID.dump!(input.round_entry_id)
        ]
      ).rows
      |> Map.new(fn [side_id, member_count, eligible_count, valid_scope?] ->
        {Ecto.UUID.cast!(side_id),
         %{member_count: member_count, eligible_count: eligible_count, valid_scope?: valid_scope?}}
      end)

    cond do
      map_size(rows) != length(side_ids) ->
        {:error, :competition_side_membership_missing}

      Enum.any?(rows, fn {_id, member} ->
        member.member_count == 0 or not member.valid_scope?
      end) ->
        {:error, :competition_side_membership_scope_mismatch}

      true ->
        {:ok, Map.new(rows, fn {id, member} -> {id, member.eligible_count} end)}
    end
  end

  defp lock_target_entry(input) do
    case Repo.query!(
           """
           SELECT id::text, event_id::text, round_id::text, player_id::text,
                  playing_group_id::text, registration_status, participation_status
           FROM round_entries
           WHERE id = $1::uuid AND event_id = $2::uuid
             AND round_id = $3::uuid AND playing_group_id = $4::uuid
           FOR UPDATE
           """,
           [
             Ecto.UUID.dump!(input.round_entry_id),
             Ecto.UUID.dump!(input.event_id),
             Ecto.UUID.dump!(input.round_id),
             Ecto.UUID.dump!(input.playing_group_id)
           ]
         ).rows do
      [[id, event_id, round_id, player_id, group_id, registration_status, participation_status]] ->
        {:ok,
         %RoundEntry{
           id: Ecto.UUID.cast!(id),
           event_id: Ecto.UUID.cast!(event_id),
           round_id: Ecto.UUID.cast!(round_id),
           player_id: Ecto.UUID.cast!(player_id),
           playing_group_id: Ecto.UUID.cast!(group_id),
           registration_status: String.to_existing_atom(registration_status),
           participation_status: String.to_existing_atom(participation_status)
         }}

      [] ->
        {:error, :round_entry_scope_mismatch}
    end
  end

  defp validate_target_entry(%RoundEntry{
         registration_status: registration,
         participation_status: :active
       })
       when registration in [:expected, :checked_in],
       do: :ok

  defp validate_target_entry(%RoundEntry{participation_status: status})
       when status in [:not_started, :completed, :withdrawn, :disqualified],
       do: {:error, {:invalid_participation_state, status}}

  defp validate_target_entry(%RoundEntry{}), do: {:error, :invalid_round_entry_registration_state}

  defp reject_existing_ruling(entry_id) do
    if Repo.query!(
         "SELECT 1 FROM round_entry_participation_rulings WHERE round_entry_id = $1::uuid LIMIT 1",
         [Ecto.UUID.dump!(entry_id)]
       ).rows == [] do
      :ok
    else
      {:error, :round_entry_already_ruled}
    end
  end

  defp authoritative_checkpoint(group, input) do
    with {:ok, route} <- load_authoritative_route(input.round_id),
         {:ok, start_index} <- start_hole_index(route, group.starting_round_hole_id),
         rotated <- rotate_route(route, start_index),
         checkpoint_index <- group.scoring_revision - 1,
         effective_index <- group.scoring_revision,
         checkpoint_hole <- Enum.at(rotated, checkpoint_index),
         effective_hole <- Enum.at(rotated, effective_index),
         {:ok, receipt} <- load_latest_receipt(input, group.scoring_revision),
         :ok <- receipt_matches_route(receipt, checkpoint_hole, checkpoint_index) do
      {:ok,
       %{
         submission_id: receipt.id,
         checkpoint_round_hole_id: checkpoint_hole.id,
         checkpoint_play_index: checkpoint_index,
         effective_round_hole_id: effective_hole.id,
         effective_play_index: effective_index,
         scoring_revision: group.scoring_revision
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  defp load_authoritative_route(round_id) do
    route =
      Repo.query!(
        "SELECT id::text, play_order::int FROM round_holes WHERE round_id = $1::uuid ORDER BY play_order",
        [Ecto.UUID.dump!(round_id)]
      ).rows
      |> Enum.map(fn [id, play_order] ->
        %{id: Ecto.UUID.cast!(id), play_order: play_order}
      end)

    if length(route) == @scheduled_holes and
         Enum.map(route, & &1.play_order) == Enum.to_list(1..@scheduled_holes) do
      {:ok, route}
    else
      {:error, :invalid_round_route}
    end
  end

  defp start_hole_index(_route, nil), do: {:error, :starting_hole_not_assigned}

  defp start_hole_index(route, starting_hole_id) do
    case Enum.find_index(route, &(&1.id == starting_hole_id)) do
      nil -> {:error, :starting_hole_not_in_route}
      index -> {:ok, index}
    end
  end

  defp rotate_route(route, start_index) do
    {before_start, from_start} = Enum.split(route, start_index)
    from_start ++ before_start
  end

  defp load_latest_receipt(input, revision) do
    rows =
      Repo.query!(
        """
        SELECT id::text, round_hole_id::text, expected_group_score_revision::int
        FROM hole_submissions
        WHERE round_id = $1::uuid AND playing_group_id = $2::uuid
        ORDER BY accepted_at, id
        """,
        [Ecto.UUID.dump!(input.round_id), Ecto.UUID.dump!(input.playing_group_id)]
      ).rows
      |> Enum.map(fn [id, hole_id, expected_revision] ->
        %{
          id: Ecto.UUID.cast!(id),
          round_hole_id: Ecto.UUID.cast!(hole_id),
          expected_group_score_revision: expected_revision
        }
      end)

    matching = Enum.filter(rows, &(&1.expected_group_score_revision == revision - 1))
    latest = List.last(rows)
    future_receipts? = Enum.any?(rows, &(&1.expected_group_score_revision >= revision))

    cond do
      matching == [] ->
        {:error, :checkpoint_submission_missing}

      length(matching) > 1 ->
        {:error, :checkpoint_submission_ambiguous}

      future_receipts? ->
        {:error, :checkpoint_submission_stale}

      latest.id != hd(matching).id ->
        {:error, :checkpoint_submission_stale}

      true ->
        {:ok, hd(matching)}
    end
  end

  defp receipt_matches_route(receipt, checkpoint_hole, checkpoint_index) do
    cond do
      is_nil(checkpoint_hole) ->
        {:error, :invalid_checkpoint_route}

      receipt.expected_group_score_revision != checkpoint_index ->
        {:error, :checkpoint_submission_stale}

      receipt.round_hole_id != checkpoint_hole.id ->
        {:error, :checkpoint_route_mismatch}

      true ->
        :ok
    end
  end

  defp validate_attestation_scope(input, checkpoint) do
    attestation = input.attestation

    if attestation.round_id == input.round_id and
         attestation.playing_group_id == input.playing_group_id and
         attestation.effective_round_hole_id == checkpoint.effective_round_hole_id and
         attestation.effective_play_index == checkpoint.effective_play_index and
         attestation.confirms_unplayed? do
      :ok
    else
      {:error, :preplay_attestation_scope_mismatch}
    end
  end

  defp validate_checkpoint_claim(nil, _checkpoint), do: :ok

  defp validate_checkpoint_claim(claim, checkpoint) do
    expected = %{
      checkpoint_hole_submission_id: checkpoint.submission_id,
      checkpoint_round_hole_id: checkpoint.checkpoint_round_hole_id,
      checkpoint_play_index: checkpoint.checkpoint_play_index,
      effective_round_hole_id: checkpoint.effective_round_hole_id,
      effective_play_index: checkpoint.effective_play_index,
      scoring_revision: checkpoint.scoring_revision
    }

    if Enum.all?(claim, fn {key, value} -> Map.get(expected, key) == value end) do
      :ok
    else
      {:error, :stale_checkpoint_claim}
    end
  end

  defp validate_side_result_states(%{sides: sides}) do
    if Enum.any?(sides, &(&1.state in ["ready_to_finalize", "finalized", "excluded"])) do
      {:error, :competition_side_result_terminal}
    else
      :ok
    end
  end

  defp persist_withdrawal(scope) do
    if Process.get(@gate_key) do
      Repo.rollback(:nested_round_entry_withdrawal)
    end

    gate = %{
      owner: __MODULE__,
      token: make_ref(),
      pid: self(),
      transaction_id: transaction_id(),
      ruling_id: nil,
      ruling_inserted?: false,
      actor_id: scope.actor_id,
      authority: scope.authority,
      input: scope.input,
      gameplay: scope.gameplay,
      entry: scope.entry,
      checkpoint: scope.checkpoint,
      verification: scope.verification,
      sides: scope.sides
    }

    Process.put(@gate_key, gate)

    try do
      with {:ok, ruling} <- insert_ruling(scope),
           :ok <- bind_ruling(ruling.id),
           {:ok, _entry} <- transition_participation(scope.entry),
           {:ok, revoked_assignments} <-
             revoke_target_roles(scope.verification.revoked_assignments),
           {:ok, attention_changed?} <- apply_group_attention(scope),
           {:ok, changed_side_result_ids} <- apply_side_review(scope.sides, scope.verification),
           :ok <-
             write_audit(
               scope,
               ruling,
               revoked_assignments,
               attention_changed?,
               changed_side_result_ids
             ) do
        {:ok,
         %{
           ruling_id: ruling.id,
           round_entry_id: scope.entry.id,
           playing_group_id: scope.input.playing_group_id,
           checkpoint_hole_submission_id: scope.checkpoint.submission_id,
           checkpoint_round_hole_id: scope.checkpoint.checkpoint_round_hole_id,
           checkpoint_play_index: scope.checkpoint.checkpoint_play_index,
           effective_round_hole_id: scope.checkpoint.effective_round_hole_id,
           effective_play_index: scope.checkpoint.effective_play_index,
           scoring_revision: scope.checkpoint.scoring_revision,
           revoked_assignment_ids: Enum.map(revoked_assignments, & &1.id),
           attention_required?:
             scope.gameplay.group.state in ["attention_required", :attention_required] or
               attention_changed?,
           group_attention_changed?: attention_changed?,
           changed_side_result_ids: changed_side_result_ids,
           round_id: scope.input.round_id
         }}
      end
    after
      Process.delete(@write_key)
      Process.delete(@gate_key)
    end
  end

  defp insert_ruling(scope) do
    input = scope.input
    checkpoint = scope.checkpoint
    authority = scope.authority

    attributes = %{
      event_id: input.event_id,
      round_id: input.round_id,
      round_entry_id: input.round_entry_id,
      playing_group_id: input.playing_group_id,
      authorized_by_event_staff_assignment_id: authority.assignment_id,
      authorized_by_staff_user_id: scope.actor_id,
      checkpoint_hole_submission_id: checkpoint.submission_id,
      checkpoint_round_hole_id: checkpoint.checkpoint_round_hole_id,
      effective_round_hole_id: checkpoint.effective_round_hole_id
    }

    guarded_write(:create_accepted_withdrawal_internal, attributes, fn context ->
      RoundEntryParticipationRuling
      |> Changeset.for_create(:create_accepted_withdrawal_internal, attributes)
      |> Changeset.set_context(%{@write_context_key => context})
      |> Ash.create(authorize?: false)
    end)
  end

  defp bind_ruling(ruling_id) do
    gate = Process.get(@gate_key)
    Process.put(@gate_key, %{gate | ruling_id: ruling_id, ruling_inserted?: true})
    :ok
  end

  defp transition_participation(entry) do
    guarded_write(
      :mark_participation_withdrawn_internal,
      %{round_entry_id: entry.id},
      fn context ->
        RoundEntry
        |> Ash.get!(entry.id, authorize?: false)
        |> Changeset.for_update(:mark_participation_withdrawn_internal, %{})
        |> Changeset.set_context(%{@write_context_key => context})
        |> Ash.update(authorize?: false)
      end
    )
  end

  defp revoke_target_roles(assignments) do
    case Enum.reduce_while(assignments, {:ok, []}, &revoke_target_role/2) do
      {:ok, revoked} -> {:ok, Enum.reverse(revoked)}
      {:error, _reason} = error -> error
    end
  end

  defp revoke_target_role(assignment, {:ok, acc}) do
    scope = %{
      assignment_id: assignment.id,
      round_id: assignment.round_id,
      playing_group_id: assignment.playing_group_id,
      round_entry_id: assignment.round_entry_id,
      role: assignment.role,
      assignment_version: assignment.assignment_version
    }

    case guarded_write(:mark_revoked_for_withdrawal_internal, scope, fn context ->
           GroupRoleAssignment
           |> Ash.get!(assignment.id, authorize?: false)
           |> Changeset.for_update(:mark_revoked_for_withdrawal_internal, %{})
           |> Changeset.set_context(%{@write_context_key => context})
           |> Ash.update(authorize?: false)
         end) do
      {:ok, revoked} -> {:cont, {:ok, [Map.put(scope, :id, revoked.id) | acc]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp apply_group_attention(scope) do
    group = scope.gameplay.group
    verification_failed? = not scope.verification.independent_verification_available?

    if verification_failed? and group.state in ["playing", :playing] do
      guarded_write(
        :flag_group_attention_for_withdrawal_internal,
        %{playing_group_id: group.id},
        fn context ->
          PlayingGroup
          |> Ash.get!(group.id, authorize?: false)
          |> Changeset.for_update(:flag_group_attention_for_withdrawal_internal, %{})
          |> Changeset.set_context(%{@write_context_key => context})
          |> Ash.update(authorize?: false)
        end
      )
      |> case do
        {:ok, _group} -> {:ok, true}
        {:error, _reason} = error -> error
      end
    else
      {:ok, false}
    end
  end

  defp apply_side_review(sides, verification) do
    reviewable_sides =
      Enum.filter(sides.sides, fn side ->
        side.state in ["provisional", :provisional] and side_blockers(side, verification) != []
      end)

    case Enum.reduce_while(reviewable_sides, {:ok, []}, fn side, acc ->
           apply_side_review_transition(side, verification, acc)
         end) do
      {:ok, result_ids} -> {:ok, Enum.reverse(result_ids)}
      {:error, _reason} = error -> error
    end
  end

  defp apply_side_review_transition(side, verification, {:ok, acc}) do
    blockers = side_blockers(side, verification)

    scope = %{
      competition_side_result_id: side.result_id,
      competition_side_id: side.side_id,
      blocker_codes: blockers
    }

    case guarded_write(:require_review_for_withdrawal_internal, scope, fn context ->
           CompetitionSideResult
           |> Ash.get!(side.result_id, authorize?: false)
           |> Changeset.for_update(:require_review_for_withdrawal_internal, %{})
           |> Changeset.set_context(%{@write_context_key => context})
           |> Ash.update(authorize?: false)
         end) do
      {:ok, result} -> {:cont, {:ok, [result.id | acc]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp side_blockers(side, verification) do
    eligibility_blocker =
      if side.target_member? and side.member_count_after_withdrawal == 0 do
        [:side_has_no_eligible_members]
      else
        []
      end

    verification_blocker =
      if verification.independent_verification_available? do
        []
      else
        [:independent_verification_unavailable]
      end

    eligibility_blocker ++ verification_blocker
  end

  defp write_audit(
         scope,
         ruling,
         revoked_assignments,
         attention_changed?,
         changed_side_result_ids
       ) do
    input = scope.input
    checkpoint = scope.checkpoint
    attestation = input.attestation

    context = %{
      "event_id" => input.event_id,
      "authorized_by_event_staff_assignment_id" => scope.authority.assignment_id,
      "authorized_by_role" => scope.authority.role,
      "round_id" => input.round_id,
      "playing_group_id" => input.playing_group_id,
      "round_entry_id" => input.round_entry_id,
      "ruling_id" => ruling.id,
      "attestation" => %{
        "observed_at" => DateTime.to_iso8601(attestation.observed_at),
        "attested_at" => DateTime.to_iso8601(input.attested_at),
        "method" => attestation.method,
        "observation_location" => attestation.observation_location,
        "confirms_unplayed" => true,
        "round_id" => attestation.round_id,
        "playing_group_id" => attestation.playing_group_id,
        "effective_round_hole_id" => attestation.effective_round_hole_id,
        "effective_play_index" => attestation.effective_play_index
      },
      "checkpoint" => %{
        "hole_submission_id" => checkpoint.submission_id,
        "round_hole_id" => checkpoint.checkpoint_round_hole_id,
        "play_index" => checkpoint.checkpoint_play_index,
        "scoring_revision" => checkpoint.scoring_revision
      },
      "effective_boundary" => %{
        "round_hole_id" => checkpoint.effective_round_hole_id,
        "play_index" => checkpoint.effective_play_index
      },
      "revoked_assignments" =>
        Enum.map(revoked_assignments, fn assignment ->
          %{
            "assignment_id" => assignment.id,
            "role" => assignment.role,
            "prior_holder_round_entry_id" => assignment.round_entry_id,
            "assignment_version" => assignment.assignment_version,
            "state" => "revoked"
          }
        end),
      "verification" => %{
        "independent_verification_available" =>
          scope.verification.independent_verification_available?,
        "primary_scorer_round_entry_id" => scope.verification.remaining_primary_scorer_entry_id,
        "designated_verifier_round_entry_id" =>
          scope.verification.remaining_designated_verifier_entry_id,
        "active_role_assignments" =>
          Enum.map(scope.verification.remaining_active_role_assignments, fn assignment ->
            %{
              "assignment_id" => assignment.id,
              "role" => to_string(assignment.role),
              "round_entry_id" => assignment.round_entry_id,
              "assignment_version" => assignment.assignment_version,
              "state" => "active"
            }
          end),
        "group_participants" =>
          Enum.map(scope.verification.participant_snapshot, fn participant ->
            %{
              "round_entry_id" => participant.round_entry_id,
              "registration_status" => to_string(participant.registration_status),
              "participation_status" => to_string(participant.participation_status)
            }
          end)
      },
      "group_attention" => %{
        "prior_state" => to_string(scope.gameplay.group.state),
        "state_changed" => attention_changed?,
        "blocker" =>
          if(scope.verification.independent_verification_available?,
            do: nil,
            else: "independent_verification_unavailable"
          ),
        "current_state" =>
          if(scope.verification.independent_verification_available?,
            do: to_string(scope.gameplay.group.state),
            else: "attention_required"
          )
      },
      "side_result_review_required_ids" => changed_side_result_ids,
      "side_result_blockers" =>
        Enum.map(scope.sides.sides, fn side ->
          %{
            "competition_side_id" => side.side_id,
            "competition_side_result_id" => side.result_id,
            "source_state" => side.state,
            "blockers" => Enum.map(side_blockers(side, scope.verification), &Atom.to_string/1)
          }
        end)
    }

    case Audit.record_staff_event(
           %{
             actor_staff_user_id: scope.actor_id,
             action: "accept_round_entry_withdrawal",
             target_type: "RoundEntryParticipationRuling",
             target_id: ruling.id,
             reason: input.reason,
             context: context,
             changes: %{"participation_status" => %{"from" => "active", "to" => "withdrawn"}}
           },
           authorize?: false
         ) do
      {:ok, _audit} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp guarded_write(operation, scope, callback) do
    if Process.get(@write_key) do
      {:error, :nested_round_entry_withdrawal_write}
    else
      gate = Process.get(@gate_key)

      proof = %{
        owner: __MODULE__,
        gate_token: gate.token,
        token: make_ref(),
        pid: self(),
        transaction_id: gate.transaction_id,
        operation: operation,
        scope: scope,
        used?: false
      }

      Process.put(@write_key, proof)
      context = %{owner: __MODULE__, token: proof.token}

      try do
        case callback.(context) do
          {:ok, record} ->
            if Process.get(@write_key).used? do
              {:ok, record}
            else
              {:error, :round_entry_withdrawal_write_not_consumed}
            end

          {:error, _reason} = error ->
            error
        end
      after
        Process.delete(@write_key)
      end
    end
  end

  defp valid_internal_write?(changeset, operation, gate, proof, context_proof) do
    is_map(gate) and is_map(proof) and is_map(context_proof) and
      gate_matches_operation?(gate, operation) and
      proof_matches_context?(gate, proof, context_proof, operation) and
      transaction_matches_proof?(gate, proof) and
      write_scope_matches?(changeset, operation, proof.scope, gate)
  rescue
    _ -> false
  end

  defp gate_matches_operation?(gate, operation) do
    ruling_state_matches? =
      if operation == :create_accepted_withdrawal_internal do
        not gate.ruling_inserted? and is_nil(gate.ruling_id)
      else
        gate.ruling_inserted? and is_binary(gate.ruling_id)
      end

    gate.owner == __MODULE__ and gate.pid == self() and
      ruling_state_matches? and
      is_reference(gate.token)
  end

  defp proof_matches_context?(gate, proof, context_proof, operation) do
    proof.owner == __MODULE__ and proof.pid == self() and proof.gate_token == gate.token and
      proof.token == context_proof.token and context_proof.owner == __MODULE__ and
      proof.operation == operation and not proof.used?
  end

  defp transaction_matches_proof?(gate, proof) do
    Repo.in_transaction?() and gate.transaction_id == proof.transaction_id and
      gate.transaction_id == transaction_id()
  end

  defp write_scope_matches?(changeset, :create_accepted_withdrawal_internal, scope, gate) do
    expected = %{
      event_id: gate.input.event_id,
      round_id: gate.input.round_id,
      round_entry_id: gate.input.round_entry_id,
      playing_group_id: gate.input.playing_group_id,
      authorized_by_event_staff_assignment_id: gate.authority.assignment_id,
      authorized_by_staff_user_id: gate.actor_id,
      authorized_by_role: gate.authority.role,
      checkpoint_hole_submission_id: gate.checkpoint.submission_id,
      checkpoint_round_hole_id: gate.checkpoint.checkpoint_round_hole_id,
      checkpoint_play_index: gate.checkpoint.checkpoint_play_index,
      effective_round_hole_id: gate.checkpoint.effective_round_hole_id,
      effective_play_index: gate.checkpoint.effective_play_index
    }

    accepted_attributes =
      Map.drop(expected, [:authorized_by_role, :checkpoint_play_index, :effective_play_index])

    scope == accepted_attributes and attributes_match?(changeset, accepted_attributes)
  end

  defp write_scope_matches?(changeset, :mark_participation_withdrawn_internal, scope, gate) do
    scope == %{round_entry_id: gate.input.round_entry_id} and
      changeset.resource == RoundEntry and changeset.data.id == gate.input.round_entry_id and
      changeset.data.event_id == gate.input.event_id and
      changeset.data.round_id == gate.input.round_id and
      changeset.data.playing_group_id == gate.input.playing_group_id and
      Ash.Changeset.get_data(changeset, :participation_status) == :active
  end

  defp write_scope_matches?(changeset, :mark_revoked_for_withdrawal_internal, scope, gate) do
    locked_assignment =
      Enum.find(gate.verification.revoked_assignments, &(&1.id == scope.assignment_id))

    case locked_assignment do
      nil -> false
      assignment -> locked_revocation_matches?(changeset, scope, gate, assignment)
    end
  end

  defp write_scope_matches?(changeset, :flag_group_attention_for_withdrawal_internal, scope, gate) do
    scope == %{playing_group_id: gate.input.playing_group_id} and
      changeset.resource == PlayingGroup and changeset.data.id == gate.input.playing_group_id and
      changeset.data.round_id == gate.input.round_id and
      Ash.Changeset.get_data(changeset, :state) == :playing and
      not gate.verification.independent_verification_available?
  end

  defp write_scope_matches?(changeset, :require_review_for_withdrawal_internal, scope, gate) do
    locked_side =
      Enum.find(gate.sides.sides, &(&1.result_id == scope.competition_side_result_id))

    case locked_side do
      nil -> false
      side -> locked_side_review_matches?(changeset, scope, gate, side)
    end
  end

  defp write_scope_matches?(_changeset, _operation, _scope, _gate), do: false

  defp locked_revocation_matches?(changeset, scope, gate, assignment) do
    accepted_ruling_matches?(gate) and scope == revocation_scope(assignment) and
      assignment_matches_withdrawal_target?(assignment, gate) and
      changeset_matches_locked_assignment?(changeset, assignment, gate)
  end

  defp revocation_scope(assignment) do
    %{
      assignment_id: assignment.id,
      round_id: assignment.round_id,
      playing_group_id: assignment.playing_group_id,
      round_entry_id: assignment.round_entry_id,
      role: assignment.role,
      assignment_version: assignment.assignment_version
    }
  end

  defp assignment_matches_withdrawal_target?(assignment, gate) do
    assignment.round_id == gate.input.round_id and
      assignment.playing_group_id == gate.input.playing_group_id and
      assignment.round_entry_id == gate.input.round_entry_id
  end

  defp changeset_matches_locked_assignment?(changeset, assignment, gate) do
    changeset.resource == GroupRoleAssignment and changeset.data.id == assignment.id and
      changeset.data.round_id == assignment.round_id and
      changeset.data.playing_group_id == assignment.playing_group_id and
      changeset.data.round_entry_id == gate.input.round_entry_id and
      changeset.data.role == String.to_existing_atom(assignment.role) and
      changeset.data.assignment_version == assignment.assignment_version and
      Ash.Changeset.get_data(changeset, :state) == :active
  end

  defp locked_side_review_matches?(changeset, scope, gate, side) do
    blocker_codes = side_blockers(side, gate.verification)

    accepted_ruling_matches?(gate) and scope == side_review_scope(side, blocker_codes) and
      blocker_codes != [] and side.state in ["provisional", :provisional] and
      side.round_id == gate.input.round_id and changeset_matches_locked_side?(changeset, side)
  end

  defp side_review_scope(side, blocker_codes) do
    %{
      competition_side_result_id: side.result_id,
      competition_side_id: side.side_id,
      blocker_codes: blocker_codes
    }
  end

  defp changeset_matches_locked_side?(changeset, side) do
    changeset.resource == CompetitionSideResult and changeset.data.id == side.result_id and
      changeset.data.competition_side_id == side.side_id and
      Ash.Changeset.get_data(changeset, :state) == :provisional
  end

  defp accepted_ruling_matches?(gate),
    do: gate.ruling_inserted? and is_binary(gate.ruling_id)

  defp attributes_match?(changeset, expected) do
    Enum.all?(expected, fn {field, value} ->
      Ash.Changeset.get_attribute(changeset, field) == value
    end)
  end

  defp write_attributes(:create_accepted_withdrawal_internal, _proof) do
    gate = Process.get(@gate_key)

    %{
      ruling_kind: "round_withdrawal",
      authorized_by_role: gate.authority.role,
      checkpoint_play_index: gate.checkpoint.checkpoint_play_index,
      effective_play_index: gate.checkpoint.effective_play_index,
      accepted_at: gate.input.attested_at,
      preplay_boundary_confirmed: true
    }
  end

  defp write_attributes(:mark_participation_withdrawn_internal, _proof),
    do: %{participation_status: :withdrawn}

  defp write_attributes(:mark_revoked_for_withdrawal_internal, _proof), do: %{state: :revoked}

  defp write_attributes(:flag_group_attention_for_withdrawal_internal, _proof),
    do: %{state: :attention_required}

  defp write_attributes(:require_review_for_withdrawal_internal, _proof),
    do: %{state: :review_required}

  defp canonical_ids(ids) do
    ids
    |> Enum.uniq()
    |> Enum.sort_by(&Ecto.UUID.dump!/1)
  end

  defp publish_notifications(accepted) do
    topic = "round:#{accepted.round_id}"

    safe_broadcast(
      topic,
      {:round_entry_withdrawn,
       %{
         round_id: accepted.round_id,
         playing_group_id: accepted.playing_group_id,
         round_entry_id: accepted.round_entry_id,
         ruling_id: accepted.ruling_id,
         effective_round_hole_id: accepted.effective_round_hole_id,
         effective_play_index: accepted.effective_play_index,
         changed_side_result_ids: accepted.changed_side_result_ids
       }}
    )

    if accepted.group_attention_changed? do
      safe_broadcast(
        topic,
        {:playing_group_attention_required,
         %{
           round_id: accepted.round_id,
           playing_group_id: accepted.playing_group_id,
           ruling_id: accepted.ruling_id,
           reason: :independent_verification_unavailable
         }}
      )
    end

    if accepted.changed_side_result_ids != [] do
      safe_broadcast(
        topic,
        {:competition_side_readiness_changed,
         %{
           round_id: accepted.round_id,
           playing_group_id: accepted.playing_group_id,
           ruling_id: accepted.ruling_id,
           competition_side_result_ids: accepted.changed_side_result_ids
         }}
      )
    end
  end

  defp safe_broadcast(topic, message) do
    Phoenix.PubSub.broadcast(GolfScoring.PubSub, topic, message)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp transaction_id do
    Repo.query!("SELECT pg_current_xact_id()::text").rows |> hd() |> hd()
  end
end

defmodule GolfScoring.Competition.Services.AcceptRoundEntryWithdrawal.WriteGuard do
  @moduledoc false

  use Ash.Resource.Change

  alias GolfScoring.Competition.Services.AcceptRoundEntryWithdrawal

  @impl true
  def change(changeset, opts, _context) do
    operation = Keyword.fetch!(opts, :operation)

    Ash.Changeset.before_action(changeset, &apply_guarded_write(&1, operation))
  end

  defp apply_guarded_write(changeset, operation) do
    case AcceptRoundEntryWithdrawal.consume_internal_write(changeset, operation) do
      {:ok, attributes} ->
        Enum.reduce(attributes, changeset, fn {field, value}, changeset ->
          Ash.Changeset.force_change_attribute(changeset, field, value)
        end)

      {:error, _reason} ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: "withdrawal writes require the active acceptance coordinator transaction"
        )
    end
  end
end

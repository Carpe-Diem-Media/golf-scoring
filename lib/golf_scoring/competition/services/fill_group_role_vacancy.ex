defmodule GolfScoring.Competition.Services.FillGroupRoleVacancy do
  @moduledoc false

  alias Ash.Changeset
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Audit
  alias GolfScoring.Competition.GroupRoleAssignment
  alias GolfScoring.Competition.GroupRoleAssignmentGuard
  alias GolfScoring.Competition.PlayingGroup
  alias GolfScoring.LockProtocol
  alias GolfScoring.Repo

  @roles [:primary_scorer, :designated_verifier]
  @authorized_roles ["event_admin", "competition_manager", "scoring_support"]
  @eligible_registration_states ["expected", "checked_in"]
  @eligible_participation_states ["not_started", "active", "completed"]
  @replacement_participation_state "active"
  @gate_key {__MODULE__, :vacancy_gate}
  @write_key {__MODULE__, :vacancy_write}
  @write_context_key :group_role_vacancy_write

  @type filled :: %{
          assignment: GroupRoleAssignment.t(),
          withdrawal_ruling_id: Ecto.UUID.t(),
          attention_cleared?: boolean(),
          remaining_attention_blockers: [atom()],
          verification_mappings: [map()]
        }

  @spec run(map(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), atom()) ::
          {:ok, filled()} | {:error, term()}
  def run(actor, event_id, round_id, playing_group_id, replacement_entry_id, role)
      when is_map(actor) and role in @roles do
    if Repo.in_transaction?() do
      {:error, :transaction_already_open}
    else
      with {:ok, actor_id} <- cast_uuid(Map.get(actor, :id)),
           {:ok, input} <-
             normalize_input(event_id, round_id, playing_group_id, replacement_entry_id, role) do
        run_standalone(actor_id, input)
      else
        _ -> {:error, :invalid_input}
      end
    end
  end

  def run(_actor, _event_id, _round_id, _playing_group_id, _replacement_entry_id, _role),
    do: {:error, :invalid_input}

  @doc false
  def consume_internal_write(changeset, operation) do
    gate = Process.get(@gate_key)
    proof = Process.get(@write_key)
    context_proof = Map.get(changeset.context, @write_context_key)

    if valid_internal_write?(changeset, operation, gate, proof, context_proof) do
      Process.put(@write_key, %{proof | used?: true})
      {:ok, write_attributes(operation, gate)}
    else
      {:error, :unauthorized_group_role_vacancy_write}
    end
  rescue
    _ -> {:error, :unauthorized_group_role_vacancy_write}
  end

  defp normalize_input(event_id, round_id, group_id, replacement_entry_id, role) do
    with {:ok, event_id} <- cast_uuid(event_id),
         {:ok, round_id} <- cast_uuid(round_id),
         {:ok, group_id} <- cast_uuid(group_id),
         {:ok, replacement_entry_id} <- cast_uuid(replacement_entry_id) do
      {:ok,
       %{
         event_id: event_id,
         round_id: round_id,
         playing_group_id: group_id,
         replacement_entry_id: replacement_entry_id,
         role: role
       }}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_input}
    end
  end

  defp run_standalone(actor_id, input) do
    Repo.transaction(fn ->
      case fill_locked(actor_id, input) do
        {:ok, filled} -> filled
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
    |> case do
      {:ok, filled} = result ->
        publish_notifications(filled)
        result

      error ->
        error
    end
  after
    Process.delete(@gate_key)
    Process.delete(@write_key)
  end

  defp fill_locked(actor_id, input) do
    with {:ok, authority_scope} <- EventAuthorityLock.lock_scope!(input.event_id, [actor_id]),
         {:ok, authority} <- authorize_locked_actor(authority_scope, actor_id),
         {:ok, gameplay} <- lock_gameplay(input.round_id, input.playing_group_id),
         :ok <- validate_gameplay(gameplay, input),
         {:ok, active_assignments} <- lock_active_assignments(input),
         :ok <- ensure_role_is_vacant(active_assignments, input.role),
         {:ok, entry_states} <- load_group_entry_states(input.playing_group_id),
         {:ok, replacement} <- lock_replacement_entry(input.replacement_entry_id),
         :ok <- validate_replacement(replacement, input),
         :ok <- ensure_replacement_has_no_active_role(active_assignments, replacement.id),
         {:ok, vacancy} <- current_vacancy(input, active_assignments),
         {:ok, provenance} <- vacancy_provenance(vacancy, input),
         assignment_version <-
           GroupRoleAssignmentGuard.next_assignment_version(
             Repo,
             input.playing_group_id,
             input.role
           ),
         :ok <- current_vacancy_revision(vacancy, assignment_version),
         gate <-
           build_gate(
             actor_id,
             authority,
             input,
             vacancy,
             provenance.ruling,
             replacement,
             assignment_version
           ),
         {:ok, assignment} <- persist_assignment(gate),
         assignments_after <- [assignment | active_assignments],
         {:ok, results} <- load_group_results(input, entry_states),
         verification <- verification_snapshot(assignments_after, entry_states, results),
         attention <-
           attention_decision(gameplay.group, verification, provenance.attention_history),
         :ok <- maybe_clear_attention(gameplay.group, gate, attention),
         :ok <-
           write_audit(
             gate,
             assignment,
             verification,
             attention
           ) do
      {:ok,
       %{
         assignment: assignment,
         event_id: input.event_id,
         round_id: input.round_id,
         playing_group_id: input.playing_group_id,
         withdrawal_ruling_id: provenance.ruling.id,
         revoked_assignment_id: vacancy.id,
         replacement_round_entry_id: replacement.id,
         attention_cleared?: attention.cleared?,
         group_state: attention.current_state,
         remaining_attention_blockers: attention.remaining_blockers,
         verification_mappings: verification.result_mappings
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  defp authorize_locked_actor(scope, actor_id) do
    staff = EventAuthorityLock.staff_user(scope, actor_id)

    assignment =
      Enum.find(scope.assignments, fn assignment ->
        assignment.staff_user_id == actor_id and assignment.status == "active" and
          assignment.role in @authorized_roles
      end)

    if match?(%{status: "active"}, staff) and assignment do
      {:ok, %{assignment_id: assignment.id, role: assignment.role}}
    else
      {:error, :forbidden}
    end
  end

  defp lock_gameplay(round_id, group_id) do
    case LockProtocol.acquire!(round: [round_id], playing_group: [group_id]) do
      {:ok, %{acquired: rows}} ->
        round = Enum.find(rows, &(&1.class == :round))
        group = Enum.find(rows, &(&1.class == :playing_group))

        case {round, group} do
          {%{row: round}, %{row: group}} -> {:ok, %{round: round, group: group}}
          {nil, _} -> {:error, :round_not_found}
          {_, nil} -> {:error, :playing_group_not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_gameplay(%{round: round, group: group}, input) do
    cond do
      round.event_id != input.event_id ->
        {:error, :event_mismatch}

      round.state not in ["scoring_open", :scoring_open] ->
        {:error, {:invalid_round_state, round.state}}

      group.round_id != input.round_id ->
        {:error, :playing_group_mismatch}

      group.state not in ["attention_required", :attention_required] ->
        {:error, {:invalid_playing_group_state, group.state}}

      group.scoring_revision < 1 ->
        {:error, :accepted_scoring_checkpoint_required}

      true ->
        :ok
    end
  end

  defp lock_active_assignments(input) do
    ids =
      Repo.query!(
        "SELECT id::text FROM group_role_assignments WHERE playing_group_id = $1::uuid AND state = 'active' ORDER BY id",
        [Ecto.UUID.dump!(input.playing_group_id)]
      ).rows
      |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end)

    with {:ok, %{acquired: rows}} <- LockProtocol.acquire!(group_role_assignment: ids),
         assignments <- Enum.map(rows, & &1.row),
         :ok <- active_assignments_match_scope(assignments, input) do
      {:ok, assignments}
    end
  end

  defp active_assignments_match_scope(assignments, input) do
    if Enum.all?(assignments, fn assignment ->
         assignment.round_id == input.round_id and
           assignment.playing_group_id == input.playing_group_id and
           assignment.state == "active"
       end) do
      :ok
    else
      {:error, :active_role_assignment_scope_changed}
    end
  end

  defp ensure_role_is_vacant(assignments, role) do
    if Enum.any?(assignments, &(&1.role == to_string(role) and &1.state == "active")) do
      {:error, :active_role_already_assigned}
    else
      :ok
    end
  end

  defp load_group_entry_states(group_id) do
    rows =
      Repo.query!(
        "SELECT id::text, registration_status, participation_status FROM round_entries WHERE playing_group_id = $1::uuid ORDER BY id",
        [Ecto.UUID.dump!(group_id)]
      ).rows

    {:ok,
     Map.new(rows, fn [id, registration_status, participation_status] ->
       {Ecto.UUID.cast!(id),
        %{registration_status: registration_status, participation_status: participation_status}}
     end)}
  end

  defp lock_replacement_entry(entry_id) do
    case Repo.query!(
           """
           SELECT id::text, event_id::text, round_id::text, playing_group_id::text,
                  registration_status, participation_status
           FROM round_entries
           WHERE id = $1::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(entry_id)]
         ).rows do
      [[id, event_id, round_id, group_id, registration_status, participation_status]] ->
        {:ok,
         %{
           id: Ecto.UUID.cast!(id),
           event_id: Ecto.UUID.cast!(event_id),
           round_id: Ecto.UUID.cast!(round_id),
           playing_group_id: cast_optional_uuid(group_id),
           registration_status: registration_status,
           participation_status: participation_status
         }}

      [] ->
        {:error, :round_entry_not_found}
    end
  end

  defp validate_replacement(replacement, input) do
    cond do
      replacement.event_id != input.event_id or replacement.round_id != input.round_id ->
        {:error, :round_entry_mismatch}

      replacement.playing_group_id != input.playing_group_id ->
        {:error, :round_entry_not_in_playing_group}

      replacement.registration_status not in @eligible_registration_states ->
        {:error, :ineligible_vacancy_replacement}

      replacement.participation_status != @replacement_participation_state ->
        {:error, :ineligible_vacancy_replacement}

      true ->
        :ok
    end
  end

  defp ensure_replacement_has_no_active_role(assignments, replacement_id) do
    if Enum.any?(assignments, &(&1.round_entry_id == replacement_id and &1.state == "active")) do
      {:error, :round_entry_already_holds_other_active_role}
    else
      :ok
    end
  end

  defp current_vacancy(input, active_assignments) do
    if Enum.any?(active_assignments, &(&1.role == to_string(input.role))) do
      {:error, :active_role_already_assigned}
    else
      latest_vacancy(input)
    end
  end

  defp latest_vacancy(input) do
    rows =
      Repo.query!(
        """
        SELECT id::text, round_id::text, playing_group_id::text, round_entry_id::text,
               role, state, assignment_version
        FROM group_role_assignments
        WHERE playing_group_id = $1::uuid AND role = $2
        ORDER BY assignment_version DESC
        LIMIT 1
        """,
        [Ecto.UUID.dump!(input.playing_group_id), to_string(input.role)]
      ).rows

    case rows do
      [[id, round_id, group_id, entry_id, role, state, version]] ->
        vacancy = %{
          id: Ecto.UUID.cast!(id),
          round_id: Ecto.UUID.cast!(round_id),
          playing_group_id: Ecto.UUID.cast!(group_id),
          round_entry_id: Ecto.UUID.cast!(entry_id),
          role: role,
          state: state,
          assignment_version: version
        }

        if current_vacancy_matches?(vacancy, input),
          do: {:ok, vacancy},
          else: {:error, :withdrawal_provenance_required}

      [] ->
        {:error, :withdrawal_provenance_required}
    end
  end

  defp current_vacancy_matches?(vacancy, input) do
    vacancy.round_id == input.round_id and
      vacancy.playing_group_id == input.playing_group_id and
      vacancy.role == to_string(input.role) and vacancy.state == "revoked"
  end

  defp vacancy_provenance(vacancy, input) do
    with {:ok, ruling} <- withdrawal_ruling(vacancy, input),
         {:ok, audit} <- withdrawal_audit(ruling),
         :ok <- audit_matches_vacancy?(audit, ruling, vacancy, input),
         {:ok, attention_history} <- load_attention_history(input) do
      {:ok, %{ruling: ruling, audit: audit, attention_history: attention_history}}
    end
  end

  defp withdrawal_ruling(vacancy, input) do
    rows =
      Repo.query!(
        """
        SELECT ruling.id::text, ruling.event_id::text, ruling.round_id::text,
               ruling.round_entry_id::text, ruling.playing_group_id::text,
               ruling.authorized_by_staff_user_id::text, ruling.ruling_kind,
               entry.event_id::text, entry.round_id::text, entry.playing_group_id::text,
               entry.participation_status
        FROM round_entry_participation_rulings AS ruling
        JOIN round_entries AS entry ON entry.id = ruling.round_entry_id
        WHERE ruling.round_entry_id = $1::uuid
        """,
        [Ecto.UUID.dump!(vacancy.round_entry_id)]
      ).rows

    case rows do
      [row] ->
        {ruling, entry_snapshot} = build_withdrawal_ruling(row)

        if valid_withdrawal_ruling?(ruling, entry_snapshot, vacancy, input),
          do: {:ok, ruling},
          else: {:error, :withdrawal_provenance_mismatch}

      [] ->
        {:error, :withdrawal_provenance_required}

      _ ->
        {:error, :ambiguous_withdrawal_provenance}
    end
  end

  defp build_withdrawal_ruling([
         id,
         event_id,
         round_id,
         entry_id,
         group_id,
         actor_id,
         kind,
         entry_event_id,
         entry_round_id,
         entry_group_id,
         entry_participation_status
       ]) do
    ruling = %{
      id: Ecto.UUID.cast!(id),
      event_id: Ecto.UUID.cast!(event_id),
      round_id: Ecto.UUID.cast!(round_id),
      round_entry_id: Ecto.UUID.cast!(entry_id),
      playing_group_id: Ecto.UUID.cast!(group_id),
      authorized_by_staff_user_id: Ecto.UUID.cast!(actor_id),
      ruling_kind: kind
    }

    entry = %{
      event_id: Ecto.UUID.cast!(entry_event_id),
      round_id: Ecto.UUID.cast!(entry_round_id),
      playing_group_id: cast_optional_uuid(entry_group_id),
      participation_status: entry_participation_status
    }

    {ruling, entry}
  end

  defp valid_withdrawal_ruling?(ruling, entry, vacancy, input) do
    ruling_scope_matches?(ruling, vacancy, input) and
      entry_scope_matches?(entry, input) and ruling.ruling_kind == "round_withdrawal" and
      entry.participation_status == "withdrawn"
  end

  defp ruling_scope_matches?(ruling, vacancy, input) do
    ruling.event_id == input.event_id and ruling.round_id == input.round_id and
      ruling.playing_group_id == input.playing_group_id and
      ruling.round_entry_id == vacancy.round_entry_id
  end

  defp entry_scope_matches?(entry, input) do
    entry.event_id == input.event_id and entry.round_id == input.round_id and
      entry.playing_group_id == input.playing_group_id
  end

  defp withdrawal_audit(ruling) do
    rows =
      Repo.query!(
        """
        SELECT id::text, actor_staff_user_id::text, target_type, target_id::text, action,
               context, occurred_at
        FROM audit_events
        WHERE target_type = 'RoundEntryParticipationRuling' AND target_id = $1::uuid
        ORDER BY id
        """,
        [Ecto.UUID.dump!(ruling.id)]
      ).rows

    case rows do
      [[id, actor_id, target_type, target_id, action, context, occurred_at]] ->
        audit = %{
          id: Ecto.UUID.cast!(id),
          actor_staff_user_id: cast_optional_uuid(actor_id),
          target_type: target_type,
          target_id: Ecto.UUID.cast!(target_id),
          action: action,
          context: context,
          occurred_at: occurred_at
        }

        if action == "accept_round_entry_withdrawal" and audit.target_id == ruling.id do
          {:ok, audit}
        else
          {:error, :withdrawal_provenance_mismatch}
        end

      [] ->
        {:error, :withdrawal_provenance_required}

      _ ->
        {:error, :ambiguous_withdrawal_provenance}
    end
  end

  defp audit_matches_vacancy?(audit, ruling, vacancy, input) do
    context = audit.context
    revoked = Map.get(context, "revoked_assignments")

    if a2_audit_matches_scope?(audit, ruling, vacancy, input) and
         matching_revoked_snapshot?(revoked, vacancy) do
      :ok
    else
      {:error, :withdrawal_provenance_mismatch}
    end
  end

  defp a2_audit_matches_scope?(audit, ruling, vacancy, input) do
    context = audit.context

    is_map(context) and audit.actor_staff_user_id == ruling.authorized_by_staff_user_id and
      context["event_id"] == input.event_id and context["round_id"] == input.round_id and
      context["playing_group_id"] == input.playing_group_id and
      context["round_entry_id"] == vacancy.round_entry_id and context["ruling_id"] == ruling.id
  end

  defp matching_revoked_snapshot?(snapshots, vacancy) when is_list(snapshots) do
    Enum.count(snapshots, &revoked_snapshot_matches?(&1, vacancy)) == 1
  end

  defp matching_revoked_snapshot?(_, _), do: false

  defp revoked_snapshot_matches?(snapshot, vacancy) when is_map(snapshot) do
    snapshot["assignment_id"] == vacancy.id and snapshot["role"] == vacancy.role and
      snapshot["prior_holder_round_entry_id"] == vacancy.round_entry_id and
      snapshot["assignment_version"] == vacancy.assignment_version and
      snapshot["state"] == "revoked"
  end

  defp revoked_snapshot_matches?(_, _), do: false

  defp current_vacancy_revision(vacancy, next_version) do
    if next_version == vacancy.assignment_version + 1 do
      :ok
    else
      {:error, :withdrawal_provenance_mismatch}
    end
  end

  defp build_gate(actor_id, authority, input, vacancy, ruling, replacement, assignment_version) do
    %{
      owner: __MODULE__,
      token: make_ref(),
      pid: self(),
      transaction_id: transaction_id(),
      actor_id: actor_id,
      authority: authority,
      input: input,
      vacancy: vacancy,
      ruling: ruling,
      replacement: replacement,
      assignment_version: assignment_version,
      assignment_created?: false
    }
  end

  defp persist_assignment(gate) do
    input = gate.input
    vacancy = gate.vacancy
    replacement = gate.replacement

    scope = %{
      event_id: input.event_id,
      round_id: input.round_id,
      playing_group_id: input.playing_group_id,
      replacement_entry_id: replacement.id,
      role: input.role,
      assignment_version: gate.assignment_version,
      actor_id: gate.actor_id,
      ruling_id: gate.ruling.id,
      revoked_assignment_id: vacancy.id
    }

    Process.put(@gate_key, Map.put(gate, :assignment_scope, scope))

    guarded_write(:create_for_vacancy_internal, scope, fn context ->
      GroupRoleAssignment
      |> Changeset.for_create(:create_for_vacancy_internal, %{
        round_id: input.round_id,
        playing_group_id: input.playing_group_id,
        round_entry_id: replacement.id,
        role: input.role,
        state: :active,
        assignment_version: gate.assignment_version
      })
      |> Changeset.set_context(%{@write_context_key => context})
      |> Ash.create(authorize?: false)
      |> case do
        {:ok, assignment} -> {:ok, assignment}
        {:error, error} -> {:error, error}
      end
    end)
    |> case do
      {:ok, assignment} ->
        current_gate = Process.get(@gate_key)

        Process.put(
          @gate_key,
          Map.merge(current_gate, %{assignment_created?: true, assignment: assignment})
        )

        {:ok, assignment}

      {:error, _reason} = error ->
        error
    end
  end

  defp load_group_results(input, entry_states) do
    ids = entry_states |> Map.keys() |> Enum.map(&Ecto.UUID.dump!/1)

    rows =
      Repo.query!(
        """
        SELECT hr.id::text, sc.round_entry_id::text, hr.revision
        FROM scorecards sc
        JOIN hole_results hr ON hr.scorecard_id = sc.id
        WHERE sc.round_id = $1::uuid AND sc.round_entry_id = ANY($2::uuid[])
        ORDER BY sc.round_entry_id, hr.round_hole_id
        """,
        [Ecto.UUID.dump!(input.round_id), ids]
      ).rows

    {:ok,
     Enum.map(rows, fn [id, subject_id, revision] ->
       %{
         id: Ecto.UUID.cast!(id),
         subject_round_entry_id: Ecto.UUID.cast!(subject_id),
         revision: revision
       }
     end)}
  end

  defp verification_snapshot(assignments, entry_states, results) do
    primary = role_assignment(assignments, "primary_scorer")
    verifier = role_assignment(assignments, "designated_verifier")
    current_revisions? = current_role_revisions?([primary, verifier])
    result_mappings = result_mappings(results, primary, verifier, entry_states)

    independent? =
      independent_verification?(
        primary,
        verifier,
        entry_states,
        result_mappings,
        current_revisions?
      )

    participant_snapshot =
      entry_states
      |> Enum.map(fn {entry_id, state} ->
        %{
          "round_entry_id" => entry_id,
          "registration_status" => to_string(state.registration_status),
          "participation_status" => to_string(state.participation_status)
        }
      end)
      |> Enum.sort_by(& &1["round_entry_id"])

    %{
      independent_verification_available?: independent?,
      current_role_revisions_verified?: current_revisions?,
      primary: primary,
      verifier: verifier,
      result_mappings: result_mappings,
      participant_snapshot: participant_snapshot
    }
  end

  defp current_role_revisions?(assignments) do
    Enum.all?(assignments, fn
      nil ->
        false

      assignment ->
        assignment.assignment_version ==
          GroupRoleAssignmentGuard.next_assignment_version(
            Repo,
            assignment.playing_group_id,
            role_atom(assignment.role)
          ) - 1
    end)
  end

  defp result_mappings(results, primary, verifier, entry_states) do
    Enum.map(results, fn result ->
      assignment = verifier_for_result(verifier, primary, result.subject_round_entry_id)
      result_mapping(result, assignment, entry_states)
    end)
  end

  defp verifier_for_result(verifier, primary, subject_entry_id) do
    if verifier && subject_entry_id == verifier.round_entry_id, do: primary, else: verifier
  end

  defp result_mapping(result, nil, _entry_states) do
    %{
      "hole_result_id" => result.id,
      "hole_result_revision" => result.revision,
      "subject_round_entry_id" => result.subject_round_entry_id,
      "verifier_available" => false
    }
  end

  defp result_mapping(result, assignment, entry_states) do
    available? =
      assignment.round_entry_id != result.subject_round_entry_id and
        eligible_role_holder?(assignment, entry_states)

    %{
      "hole_result_id" => result.id,
      "hole_result_revision" => result.revision,
      "subject_round_entry_id" => result.subject_round_entry_id,
      "verifier_available" => available?,
      "verifier_round_entry_id" => assignment.round_entry_id,
      "verifier_role" => to_string(assignment.role),
      "verifier_assignment_id" => assignment.id,
      "verifier_assignment_version" => assignment.assignment_version
    }
  end

  defp independent_verification?(primary, verifier, entry_states, mappings, current_revisions?) do
    distinct_holders? = primary && verifier && primary.round_entry_id != verifier.round_entry_id

    eligible_roles? =
      eligible_role_holder?(primary, entry_states) and
        eligible_role_holder?(verifier, entry_states)

    current_revisions? and distinct_holders? and eligible_roles? and
      Enum.all?(mappings, &(&1["verifier_available"] == true))
  end

  defp role_assignment(assignments, role) do
    case Enum.filter(
           assignments,
           &(to_string(&1.role) == role and to_string(&1.state) == "active")
         ) do
      [assignment] -> assignment
      _ -> nil
    end
  end

  defp eligible_role_holder?(nil, _entry_states), do: false

  defp eligible_role_holder?(assignment, entry_states) do
    case Map.get(entry_states, assignment.round_entry_id) do
      %{registration_status: registration, participation_status: participation} ->
        registration in @eligible_registration_states and
          participation in @eligible_participation_states

      _ ->
        false
    end
  end

  defp attention_decision(group, verification, attention_history) do
    if group.state in ["attention_required", :attention_required] do
      attention_required_decision(verification, attention_history)
    else
      %{cleared?: false, current_state: group.state, remaining_blockers: []}
    end
  end

  defp attention_required_decision(verification, attention_history) do
    blockers =
      []
      |> maybe_add_blocker(
        not verification.independent_verification_available?,
        :independent_verification_unavailable
      )
      |> maybe_add_blocker(not attention_history.clearable?, :attention_provenance_unresolved)

    %{
      cleared?: blockers == [],
      current_state: if(blockers == [], do: :playing, else: :attention_required),
      remaining_blockers: blockers
    }
  end

  defp maybe_add_blocker(blockers, true, blocker), do: blockers ++ [blocker]
  defp maybe_add_blocker(blockers, false, _blocker), do: blockers

  defp maybe_clear_attention(_group, _gate, %{cleared?: false}), do: :ok

  defp maybe_clear_attention(group, gate, %{cleared?: true}) do
    scope = %{
      playing_group_id: gate.input.playing_group_id,
      round_id: gate.input.round_id,
      actor_id: gate.actor_id,
      ruling_id: gate.ruling.id,
      revoked_assignment_id: gate.vacancy.id,
      replacement_entry_id: gate.replacement.id,
      role: gate.input.role,
      assignment_version: gate.assignment_version
    }

    current_gate = Process.get(@gate_key)

    Process.put(
      @gate_key,
      Map.merge(current_gate, %{recovery_scope: scope, recovery_clearable?: true})
    )

    case guarded_write(:clear_group_attention_for_vacancy_internal, scope, fn context ->
           PlayingGroup
           |> Ash.get!(group.id, authorize?: false)
           |> Changeset.for_update(:clear_group_attention_for_vacancy_internal, %{})
           |> Changeset.set_context(%{@write_context_key => context})
           |> Ash.update(authorize?: false)
         end) do
      {:ok, _group} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp write_audit(gate, assignment, verification, attention) do
    actor_id = gate.actor_id
    authority = gate.authority
    input = gate.input
    vacancy = gate.vacancy
    ruling = gate.ruling
    replacement = gate.replacement

    context = %{
      "event_id" => input.event_id,
      "round_id" => input.round_id,
      "playing_group_id" => input.playing_group_id,
      "actor_staff_user_id" => actor_id,
      "authorized_by_event_staff_assignment_id" => authority.assignment_id,
      "authorized_by_role" => authority.role,
      "withdrawal_ruling_id" => ruling.id,
      "withdrawn_round_entry_id" => vacancy.round_entry_id,
      "vacancy" => %{
        "role" => to_string(input.role),
        "revoked_assignment_id" => vacancy.id,
        "prior_holder_round_entry_id" => vacancy.round_entry_id,
        "revoked_assignment_version" => vacancy.assignment_version,
        "state" => "revoked"
      },
      "replacement" => %{
        "round_entry_id" => replacement.id,
        "assignment_id" => assignment.id,
        "assignment_version" => assignment.assignment_version,
        "state" => "active"
      },
      "verification" => %{
        "independent_verification_available" => verification.independent_verification_available?,
        "current_role_revisions_verified" => verification.current_role_revisions_verified?,
        "primary_scorer_round_entry_id" => role_entry_id(verification.primary),
        "designated_verifier_round_entry_id" => role_entry_id(verification.verifier),
        "role_assignments" =>
          Enum.reject([verification.primary, verification.verifier], &is_nil/1)
          |> Enum.map(&assignment_snapshot/1),
        "participant_snapshot" => verification.participant_snapshot,
        "result_mappings" => verification.result_mappings
      },
      "group_attention" => %{
        "prior_state" => "attention_required",
        "blocker_resolved" => verification.independent_verification_available?,
        "a3_blocker_resolved" => verification.independent_verification_available?,
        "attention_cleared" => attention.cleared?,
        "state_changed" => attention.cleared?,
        "current_state" => to_string(attention.current_state),
        "remaining_blockers" => Enum.map(attention.remaining_blockers, &Atom.to_string/1)
      }
    }

    case Audit.record_staff_event(
           %{
             actor_staff_user_id: actor_id,
             action: "fill_group_role_vacancy",
             target_type: "PlayingGroup",
             target_id: input.playing_group_id,
             context: context,
             changes: %{
               "role" => %{"from" => "vacant", "to" => "active"},
               "assignment_version" => assignment.assignment_version,
               "attention_state" => %{
                 "from" => "attention_required",
                 "to" => to_string(attention.current_state)
               }
             }
           },
           authorize?: false
         ) do
      {:ok, _audit} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp role_entry_id(nil), do: nil
  defp role_entry_id(assignment), do: assignment.round_entry_id

  defp role_atom(role) when is_atom(role), do: role
  defp role_atom(role) when is_binary(role), do: String.to_existing_atom(role)

  defp assignment_snapshot(assignment) do
    %{
      "assignment_id" => assignment.id,
      "role" => to_string(assignment.role),
      "round_id" => assignment.round_id,
      "playing_group_id" => assignment.playing_group_id,
      "round_entry_id" => assignment.round_entry_id,
      "assignment_version" => assignment.assignment_version,
      "state" => "active"
    }
  end

  defp load_attention_history(input) do
    entry_ids =
      Repo.query!(
        "SELECT id::text FROM round_entries WHERE playing_group_id = $1::uuid ORDER BY id",
        [Ecto.UUID.dump!(input.playing_group_id)]
      ).rows
      |> Enum.map(fn [id] -> Ecto.UUID.dump!(Ecto.UUID.cast!(id)) end)

    rulings =
      Repo.query!(
        """
        SELECT id::text, event_id::text, round_id::text, round_entry_id::text,
               playing_group_id::text, authorized_by_staff_user_id::text
        FROM round_entry_participation_rulings
        WHERE round_entry_id = ANY($1::uuid[])
        ORDER BY id
        """,
        [entry_ids]
      ).rows
      |> Enum.map(&ruling_row/1)
      |> Enum.filter(&(&1.playing_group_id == input.playing_group_id))

    audit_rows = withdrawal_audits_for(rulings)
    group_audits = group_audits(input.playing_group_id)
    history = build_attention_events(rulings, audit_rows, group_audits, input)

    {:ok, history}
  end

  defp ruling_row([id, event_id, round_id, entry_id, group_id, actor_id]) do
    %{
      id: Ecto.UUID.cast!(id),
      event_id: Ecto.UUID.cast!(event_id),
      round_id: Ecto.UUID.cast!(round_id),
      round_entry_id: Ecto.UUID.cast!(entry_id),
      playing_group_id: Ecto.UUID.cast!(group_id),
      authorized_by_staff_user_id: Ecto.UUID.cast!(actor_id)
    }
  end

  defp withdrawal_audits_for([]), do: []

  defp withdrawal_audits_for(rulings) do
    ids = Enum.map(rulings, &Ecto.UUID.dump!(&1.id))

    Repo.query!(
      """
      SELECT id::text, actor_staff_user_id::text, target_type, target_id::text, action,
             context, occurred_at
      FROM audit_events
      WHERE target_type = 'RoundEntryParticipationRuling' AND target_id = ANY($1::uuid[])
      ORDER BY occurred_at, id
      """,
      [ids]
    ).rows
    |> Enum.map(fn [id, actor_id, target_type, target_id, action, context, occurred_at] ->
      %{
        id: Ecto.UUID.cast!(id),
        actor_staff_user_id: cast_optional_uuid(actor_id),
        target_type: target_type,
        target_id: Ecto.UUID.cast!(target_id),
        action: action,
        context: context,
        occurred_at: occurred_at
      }
    end)
  end

  defp group_audits(group_id) do
    Repo.query!(
      "SELECT id::text, actor_staff_user_id::text, action, context, occurred_at FROM audit_events WHERE target_type = 'PlayingGroup' AND target_id = $1::uuid ORDER BY occurred_at, id",
      [Ecto.UUID.dump!(group_id)]
    ).rows
    |> Enum.map(fn [id, actor_id, action, context, occurred_at] ->
      %{
        id: id,
        actor_staff_user_id: cast_optional_uuid(actor_id),
        action: action,
        context: context,
        occurred_at: occurred_at
      }
    end)
  end

  defp build_attention_events(rulings, audits, group_audits, input) do
    grouped_audits = Enum.group_by(audits, & &1.target_id)

    {withdrawal_events, withdrawal_history_valid?} =
      build_withdrawal_events(rulings, grouped_audits, input)

    unknown_group_audit? =
      unknown_group_audit?(group_audits, input, rulings, grouped_audits)

    events = order_attention_events(withdrawal_events, group_audits)

    {clearable?, chain_valid?} = replay_attention_history(events)

    %{
      clearable?:
        clearable? and withdrawal_history_valid? and not unknown_group_audit? and chain_valid?
    }
  end

  defp build_withdrawal_events(rulings, grouped_audits, input) do
    Enum.map_reduce(rulings, true, fn ruling, valid? ->
      case Map.get(grouped_audits, ruling.id, []) do
        [audit] ->
          context = audit.context
          context_valid? = valid_withdrawal_history_audit?(audit, context, ruling, input)

          event = %{
            type: :withdrawal,
            context: context,
            occurred_at: audit.occurred_at,
            id: audit.id
          }

          {event, valid? and context_valid?}

        _ ->
          {nil, false}
      end
    end)
  end

  defp valid_withdrawal_history_audit?(audit, context, ruling, input) do
    audit.action == "accept_round_entry_withdrawal" and
      audit.actor_staff_user_id == ruling.authorized_by_staff_user_id and
      context_matches_ruling?(context, ruling, input) and
      revoked_snapshots_valid?(context["revoked_assignments"], ruling)
  end

  defp unknown_group_audit?(audits, input, rulings, grouped_audits) do
    Enum.any?(audits, fn audit ->
      case audit.action do
        action when action in ["handover_group_role", "revoke_group_role"] ->
          false

        "fill_group_role_vacancy" ->
          not fill_audit_context_valid?(audit, input, rulings, grouped_audits)

        _ ->
          true
      end
    end)
  end

  defp order_attention_events(withdrawal_events, group_audits) do
    fill_events =
      group_audits
      |> Enum.filter(&(&1.action == "fill_group_role_vacancy"))
      |> Enum.map(fn audit ->
        %{type: :fill, context: audit.context, occurred_at: audit.occurred_at, id: audit.id}
      end)

    (Enum.reject(withdrawal_events, &is_nil/1) ++ fill_events)
    |> Enum.sort_by(fn event ->
      {NaiveDateTime.to_iso8601(event.occurred_at), event.id}
    end)
  end

  defp context_matches_ruling?(context, ruling, input) when is_map(context) do
    context["event_id"] == ruling.event_id and context["round_id"] == ruling.round_id and
      context["playing_group_id"] == ruling.playing_group_id and
      context["round_entry_id"] == ruling.round_entry_id and context["ruling_id"] == ruling.id and
      ruling.event_id == input.event_id and ruling.round_id == input.round_id and
      ruling.playing_group_id == input.playing_group_id
  end

  defp context_matches_ruling?(_, _, _), do: false

  defp revoked_snapshots_valid?(snapshots, ruling) when is_list(snapshots) do
    Enum.all?(snapshots, fn snapshot ->
      with true <- is_map(snapshot),
           {:ok, assignment_id} <- Ecto.UUID.cast(snapshot["assignment_id"]),
           {:ok, entry_id} <- Ecto.UUID.cast(snapshot["prior_holder_round_entry_id"]),
           true <- snapshot["state"] == "revoked",
           true <- snapshot["role"] in Enum.map(@roles, &Atom.to_string/1),
           true <- entry_id == ruling.round_entry_id,
           true <- is_integer(snapshot["assignment_version"]),
           [[round_id, group_id, assignment_entry_id, role, state, version]] <-
             Repo.query!(
               "SELECT round_id::text, playing_group_id::text, round_entry_id::text, role, state, assignment_version FROM group_role_assignments WHERE id = $1::uuid",
               [Ecto.UUID.dump!(assignment_id)]
             ).rows do
        Ecto.UUID.cast!(round_id) == ruling.round_id and
          Ecto.UUID.cast!(group_id) == ruling.playing_group_id and
          Ecto.UUID.cast!(assignment_entry_id) == entry_id and role == snapshot["role"] and
          state == "revoked" and version == snapshot["assignment_version"]
      else
        _ -> false
      end
    end)
  end

  defp revoked_snapshots_valid?(_, _), do: false

  defp fill_audit_context_valid?(audit, input, rulings, grouped_withdrawals) do
    context = audit.context
    vacancy = context["vacancy"]
    replacement = context["replacement"]
    verification = context["verification"]
    attention = context["group_attention"]

    with true <- is_map(context),
         true <- audit.actor_staff_user_id != nil,
         true <- context["actor_staff_user_id"] == audit.actor_staff_user_id,
         true <- context["event_id"] == input.event_id,
         true <- context["round_id"] == input.round_id,
         true <- context["playing_group_id"] == input.playing_group_id,
         true <- is_map(vacancy) and is_map(replacement),
         true <- is_map(verification) and is_map(attention),
         {:ok, ruling_id} <- Ecto.UUID.cast(context["withdrawal_ruling_id"]),
         %{} = ruling <- Enum.find(rulings, &(&1.id == ruling_id)),
         true <- fill_vacancy_matches_withdrawal?(vacancy, ruling, grouped_withdrawals),
         true <- fill_replacement_assignment_valid?(replacement, vacancy, input),
         {:ok, verification_snapshot} <- validate_fill_verification_snapshot(verification),
         true <-
           fill_replacement_in_verification?(
             replacement,
             vacancy["role"],
             verification["role_assignments"]
           ),
         true <- valid_fill_attention_snapshot?(attention, verification_snapshot) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp fill_vacancy_matches_withdrawal?(vacancy, ruling, grouped_withdrawals) do
    with role when role in ["primary_scorer", "designated_verifier"] <- vacancy["role"],
         {:ok, assignment_id} <- Ecto.UUID.cast(vacancy["revoked_assignment_id"]),
         {:ok, entry_id} <- Ecto.UUID.cast(vacancy["prior_holder_round_entry_id"]),
         version when is_integer(version) and version > 0 <- vacancy["revoked_assignment_version"],
         true <- vacancy["state"] == "revoked",
         true <- entry_id == ruling.round_entry_id,
         true <- ruling.ruling_kind == "round_withdrawal",
         [withdrawal_audit] <- Map.get(grouped_withdrawals, ruling.id, []),
         true <- withdrawal_audit.action == "accept_round_entry_withdrawal",
         true <- withdrawal_audit.actor_staff_user_id == ruling.authorized_by_staff_user_id,
         true <-
           Enum.count(
             withdrawal_audit.context["revoked_assignments"],
             &revoked_snapshot_matches?(&1, %{
               id: assignment_id,
               role: role,
               round_id: ruling.round_id,
               playing_group_id: ruling.playing_group_id,
               round_entry_id: entry_id,
               assignment_version: version,
               state: "revoked"
             })
           ) == 1,
         true <-
           assignment_row_matches?(
             assignment_id,
             ruling.round_id,
             ruling.playing_group_id,
             entry_id,
             role,
             version,
             ["revoked"]
           ) do
      true
    else
      _ -> false
    end
  end

  defp fill_replacement_assignment_valid?(replacement, vacancy, input) do
    with {:ok, entry_id} <- Ecto.UUID.cast(replacement["round_entry_id"]),
         {:ok, assignment_id} <- Ecto.UUID.cast(replacement["assignment_id"]),
         version when is_integer(version) and version > 0 <- replacement["assignment_version"],
         true <- replacement["state"] == "active",
         true <- vacancy["role"] in ["primary_scorer", "designated_verifier"],
         true <-
           assignment_row_matches?(
             assignment_id,
             input.round_id,
             input.playing_group_id,
             entry_id,
             vacancy["role"],
             version,
             ["active", "handed_over", "revoked"]
           ) do
      true
    else
      _ -> false
    end
  end

  defp fill_replacement_in_verification?(replacement, role, role_assignments) do
    Enum.count(role_assignments, fn assignment ->
      assignment["assignment_id"] == replacement["assignment_id"] and
        assignment["round_entry_id"] == replacement["round_entry_id"] and
        assignment["assignment_version"] == replacement["assignment_version"] and
        assignment["role"] == role and assignment["state"] == "active"
    end) == 1
  end

  defp assignment_row_matches?(assignment_id, round_id, group_id, entry_id, role, version, states) do
    case Repo.query!(
           "SELECT round_id::text, playing_group_id::text, round_entry_id::text, role, state, assignment_version FROM group_role_assignments WHERE id = $1::uuid",
           [Ecto.UUID.dump!(assignment_id)]
         ).rows do
      [[round, group, entry, db_role, state, db_version]] ->
        Ecto.UUID.cast!(round) == round_id and Ecto.UUID.cast!(group) == group_id and
          Ecto.UUID.cast!(entry) == entry_id and db_role == role and state in states and
          db_version == version

      _ ->
        false
    end
  end

  defp validate_fill_verification_snapshot(verification) do
    roles = verification["role_assignments"]
    participants = verification["participant_snapshot"]
    mappings = verification["result_mappings"]
    current_revisions? = verification["current_role_revisions_verified"]

    with true <- is_boolean(current_revisions?),
         true <- is_list(roles) and is_list(participants) and is_list(mappings),
         {:ok, participant_states} <- fill_participant_states(participants),
         {:ok, role_map} <- fill_role_map(roles, participant_states),
         true <-
           verification["primary_scorer_round_entry_id"] ==
             fill_role_entry_id(role_map["primary_scorer"]),
         true <-
           verification["designated_verifier_round_entry_id"] ==
             fill_role_entry_id(role_map["designated_verifier"]),
         true <- Enum.all?(mappings, &valid_result_mapping?(&1, role_map, participant_states)),
         independent? <-
           current_revisions? and
             valid_fill_role_holder?(role_map["primary_scorer"], participant_states) and
             valid_fill_role_holder?(role_map["designated_verifier"], participant_states) and
             role_map["primary_scorer"]["round_entry_id"] !=
               role_map["designated_verifier"]["round_entry_id"] and
             Enum.all?(mappings, &(&1["verifier_available"] == true)),
         true <- verification["independent_verification_available"] == independent? do
      {:ok, %{independent?: independent?, mappings: mappings}}
    else
      _ -> {:error, :invalid_verification_snapshot}
    end
  end

  defp fill_participant_states(participants) do
    if Enum.all?(participants, fn participant ->
         is_map(participant) and valid_uuid?(participant["round_entry_id"]) and
           participant["registration_status"] in [
             "expected",
             "checked_in",
             "no_show",
             "withdrawn_before_start",
             "replaced_before_start"
           ] and
           participant["participation_status"] in [
             "not_started",
             "active",
             "completed",
             "withdrawn",
             "disqualified"
           ]
       end) do
      states = Map.new(participants, &{&1["round_entry_id"], &1})

      if map_size(states) == length(participants) do
        {:ok, states}
      else
        {:error, :duplicate_fill_participant}
      end
    else
      {:error, :invalid_fill_participant}
    end
  end

  defp fill_role_map(roles, participant_states) do
    with true <- Enum.all?(roles, &valid_fill_role_snapshot?(&1, participant_states)),
         true <- fill_role_snapshots_are_unique?(roles) do
      role_map = Map.new(roles, &{&1["role"], &1})

      if Enum.all?(roles, &valid_fill_role_assignment_row?(&1)) do
        {:ok, role_map}
      else
        {:error, :invalid_fill_role_assignment}
      end
    end
    |> case do
      {:ok, role_map} -> {:ok, role_map}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_fill_role_map}
    end
  end

  defp valid_fill_role_snapshot?(role, participant_states) when is_map(role) do
    role["state"] == "active" and role["role"] in ["primary_scorer", "designated_verifier"] and
      valid_uuid?(role["assignment_id"]) and valid_uuid?(role["round_entry_id"]) and
      is_integer(role["assignment_version"]) and role["assignment_version"] > 0 and
      Map.has_key?(participant_states, role["round_entry_id"])
  end

  defp valid_fill_role_snapshot?(_, _), do: false

  defp fill_role_snapshots_are_unique?(roles) do
    role_names = Enum.map(roles, & &1["role"])
    holder_ids = Enum.map(roles, & &1["round_entry_id"])

    length(role_names) == length(Enum.uniq(role_names)) and
      length(holder_ids) == length(Enum.uniq(holder_ids))
  end

  defp valid_fill_role_assignment_row?(role) do
    with {:ok, assignment_id} <- Ecto.UUID.cast(role["assignment_id"]),
         {:ok, round_id} <- Ecto.UUID.cast(role["round_id"]),
         {:ok, group_id} <- Ecto.UUID.cast(role["playing_group_id"]),
         {:ok, entry_id} <- Ecto.UUID.cast(role["round_entry_id"]) do
      assignment_row_matches?(
        assignment_id,
        round_id,
        group_id,
        entry_id,
        role["role"],
        role["assignment_version"],
        ["active", "handed_over", "revoked"]
      )
    else
      _ -> false
    end
  end

  defp valid_result_mapping?(mapping, role_map, participant_states) do
    case expected_result_verifier(mapping, role_map, participant_states) do
      {:ok, expected, available?} -> result_verifier_matches?(mapping, expected, available?)
      :error -> false
    end
  end

  defp expected_result_verifier(mapping, role_map, participant_states) do
    with true <- is_map(mapping),
         true <- valid_uuid?(mapping["hole_result_id"]),
         revision when is_integer(revision) and revision > 0 <- mapping["hole_result_revision"],
         subject when is_binary(subject) <- mapping["subject_round_entry_id"],
         true <- Map.has_key?(participant_states, subject) do
      verifier = role_map["designated_verifier"]
      primary = role_map["primary_scorer"]

      expected = if verifier && subject == verifier["round_entry_id"], do: primary, else: verifier

      available? =
        expected != nil and expected["round_entry_id"] != subject and
          valid_fill_role_holder?(expected, participant_states)

      {:ok, expected, available?}
    else
      _ -> :error
    end
  end

  defp result_verifier_matches?(mapping, nil, available?) do
    mapping["verifier_available"] == available? and
      is_nil(mapping["verifier_round_entry_id"]) and
      is_nil(mapping["verifier_assignment_id"])
  end

  defp result_verifier_matches?(mapping, expected, available?) do
    mapping["verifier_available"] == available? and
      mapping["verifier_round_entry_id"] == expected["round_entry_id"] and
      mapping["verifier_role"] == expected["role"] and
      mapping["verifier_assignment_id"] == expected["assignment_id"] and
      mapping["verifier_assignment_version"] == expected["assignment_version"]
  end

  defp valid_fill_role_holder?(nil, _participant_states), do: false

  defp valid_fill_role_holder?(role, participant_states) do
    case Map.get(participant_states, role["round_entry_id"]) do
      %{
        "registration_status" => registration,
        "participation_status" => participation
      } ->
        registration in @eligible_registration_states and
          participation in @eligible_participation_states

      _ ->
        false
    end
  end

  defp fill_role_entry_id(nil), do: nil
  defp fill_role_entry_id(role), do: role["round_entry_id"]

  defp valid_fill_attention_snapshot?(attention, verification) do
    blockers = attention["remaining_blockers"]
    clearable? = attention["attention_cleared"]

    is_boolean(clearable?) and is_list(blockers) and Enum.all?(blockers, &is_binary/1) and
      attention["prior_state"] == "attention_required" and
      attention["state_changed"] == clearable? and
      attention["blocker_resolved"] == verification.independent? and
      attention["a3_blocker_resolved"] == verification.independent? and
      attention_state_matches?(attention["current_state"], blockers, clearable?, verification)
  end

  defp attention_state_matches?("playing", [], true, %{independent?: true}), do: true

  defp attention_state_matches?("attention_required", blockers, false, verification)
       when is_list(blockers) and blockers != [] do
    verification.independent? or "independent_verification_unavailable" in blockers
  end

  defp attention_state_matches?(_, _, _, _), do: false

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp replay_attention_history(events) do
    Enum.reduce(events, {:ok, :unknown, false}, fn event, state ->
      replay_attention_event(event, state)
    end)
    |> case do
      {:ok, :attention_required, true} -> {true, true}
      {:ok, _state, _origin?} -> {false, true}
      {:error, _state, _origin?} -> {false, false}
    end
  end

  defp replay_attention_event(%{type: :withdrawal, context: context}, {:ok, state, origin?}) do
    attention = Map.get(context, "group_attention")
    verification = Map.get(context, "verification")
    revoked = Map.get(context, "revoked_assignments")

    if is_map(attention) and is_map(verification) and is_list(revoked) do
      replay_withdrawal_attention(attention, verification, revoked, state, origin?)
    else
      {:error, state, origin?}
    end
  end

  defp replay_attention_event(%{type: :fill, context: context}, {:ok, state, origin?}) do
    attention = Map.get(context, "group_attention")

    if is_map(attention) do
      replay_fill_attention(attention, state, origin?)
    else
      {:error, state, origin?}
    end
  end

  defp replay_attention_event(_event, state), do: {:error, elem(state, 1), elem(state, 2)}

  defp replay_withdrawal_attention(attention, verification, revoked, state, origin?) do
    cond do
      withdrawal_left_group_playing?(attention, state) ->
        {:ok, :playing, false}

      withdrawal_created_attention?(attention, verification, revoked) ->
        {:ok, :attention_required, true}

      withdrawal_preserved_attention?(attention, state, origin?) ->
        {:ok, :attention_required, true}

      true ->
        {:error, state, origin?}
    end
  end

  defp withdrawal_left_group_playing?(attention, state) do
    attention["prior_state"] == "playing" and attention["state_changed"] == false and
      attention["current_state"] == "playing" and is_nil(attention["blocker"]) and
      state in [:unknown, :playing]
  end

  defp withdrawal_created_attention?(attention, verification, revoked) do
    attention["prior_state"] == "playing" and attention["state_changed"] == true and
      attention["current_state"] == "attention_required" and
      attention["blocker"] == "independent_verification_unavailable" and
      verification["independent_verification_available"] == false and revoked != []
  end

  defp withdrawal_preserved_attention?(attention, state, origin?) do
    attention["prior_state"] == "attention_required" and
      attention["state_changed"] == false and
      attention["current_state"] == "attention_required" and
      attention["blocker"] == "independent_verification_unavailable" and
      state == :attention_required and origin?
  end

  defp replay_fill_attention(attention, state, origin?) do
    cond do
      fill_preserved_attention?(attention, state, origin?) -> {:ok, :attention_required, true}
      fill_cleared_attention?(attention, state, origin?) -> {:ok, :playing, false}
      true -> {:error, state, origin?}
    end
  end

  defp fill_preserved_attention?(attention, state, origin?) do
    attention["prior_state"] == "attention_required" and
      attention["current_state"] == "attention_required" and
      attention["attention_cleared"] == false and state == :attention_required and origin? and
      "attention_provenance_unresolved" not in List.wrap(attention["remaining_blockers"])
  end

  defp fill_cleared_attention?(attention, state, origin?) do
    attention["prior_state"] == "attention_required" and
      attention["current_state"] == "playing" and attention["attention_cleared"] == true and
      state == :attention_required and origin?
  end

  defp guarded_write(operation, scope, callback) do
    if Process.get(@write_key) do
      {:error, :nested_group_role_vacancy_write}
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
              {:error, :group_role_vacancy_write_not_consumed}
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
      Repo.in_transaction?() and gate.transaction_id == transaction_id() and
      proof.transaction_id == gate.transaction_id and
      write_scope_matches?(changeset, operation, proof.scope, gate)
  rescue
    _ -> false
  end

  defp gate_matches_operation?(gate, :create_for_vacancy_internal) do
    gate.owner == __MODULE__ and gate.pid == self() and is_reference(gate.token) and
      not gate.assignment_created? and is_map(gate.assignment_scope)
  end

  defp gate_matches_operation?(gate, :clear_group_attention_for_vacancy_internal) do
    gate.owner == __MODULE__ and gate.pid == self() and is_reference(gate.token) and
      gate.assignment_created? and gate.recovery_clearable? == true and
      is_map(gate.recovery_scope)
  end

  defp gate_matches_operation?(_, _), do: false

  defp proof_matches_context?(gate, proof, context_proof, operation) do
    proof.owner == __MODULE__ and proof.pid == self() and proof.gate_token == gate.token and
      proof.token == context_proof.token and context_proof.owner == __MODULE__ and
      proof.operation == operation and not proof.used?
  end

  defp write_scope_matches?(changeset, :create_for_vacancy_internal, scope, gate) do
    expected = gate.assignment_scope

    scope == expected and changeset.resource == GroupRoleAssignment and
      Ash.Changeset.get_attribute(changeset, :round_id) == expected.round_id and
      Ash.Changeset.get_attribute(changeset, :playing_group_id) == expected.playing_group_id and
      Ash.Changeset.get_attribute(changeset, :round_entry_id) == expected.replacement_entry_id and
      Ash.Changeset.get_attribute(changeset, :role) == expected.role and
      Ash.Changeset.get_attribute(changeset, :state) == :active and
      Ash.Changeset.get_attribute(changeset, :assignment_version) == expected.assignment_version
  end

  defp write_scope_matches?(changeset, :clear_group_attention_for_vacancy_internal, scope, gate) do
    scope == gate.recovery_scope and changeset.resource == PlayingGroup and
      changeset.data.id == gate.input.playing_group_id and
      changeset.data.round_id == gate.input.round_id and
      Ash.Changeset.get_data(changeset, :state) in [:attention_required, "attention_required"]
  end

  defp write_scope_matches?(_changeset, _operation, _scope, _gate), do: false

  defp write_attributes(:create_for_vacancy_internal, gate) do
    scope = gate.assignment_scope

    %{
      round_id: scope.round_id,
      playing_group_id: scope.playing_group_id,
      round_entry_id: scope.replacement_entry_id,
      role: scope.role,
      state: :active,
      assignment_version: scope.assignment_version
    }
  end

  defp write_attributes(:clear_group_attention_for_vacancy_internal, _gate),
    do: %{state: :playing}

  defp publish_notifications(filled) do
    topic = "round:#{filled.round_id}"

    safe_broadcast(
      topic,
      {:group_role_vacancy_filled,
       %{
         event_id: filled.event_id,
         round_id: filled.round_id,
         playing_group_id: filled.playing_group_id,
         role: filled.assignment.role,
         withdrawal_ruling_id: filled.withdrawal_ruling_id,
         revoked_assignment_id: filled.revoked_assignment_id,
         replacement_round_entry_id: filled.replacement_round_entry_id,
         assignment_id: filled.assignment.id,
         assignment_version: filled.assignment.assignment_version,
         attention_cleared?: filled.attention_cleared?,
         remaining_attention_blockers: filled.remaining_attention_blockers
       }}
    )

    if filled.attention_cleared? do
      safe_broadcast(
        topic,
        {:playing_group_attention_cleared,
         %{
           round_id: filled.round_id,
           playing_group_id: filled.playing_group_id,
           withdrawal_ruling_id: filled.withdrawal_ruling_id,
           role_assignment_id: filled.assignment.id,
           role_assignment_version: filled.assignment.assignment_version
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

  defp cast_optional_uuid(nil), do: nil
  defp cast_optional_uuid(value), do: Ecto.UUID.cast!(value)

  defp normalize_transaction_result({:ok, result}), do: {:ok, result}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
  defp normalize_transaction_result({:error, :rollback, reason}), do: {:error, reason}

  defp transaction_id do
    Repo.query!("SELECT pg_current_xact_id()::text").rows |> hd() |> hd()
  end
end

defmodule GolfScoring.Competition.Services.FillGroupRoleVacancy.WriteGuard do
  @moduledoc false

  use Ash.Resource.Change

  alias GolfScoring.Competition.Services.FillGroupRoleVacancy

  @impl true
  def change(changeset, opts, _context) do
    operation = Keyword.fetch!(opts, :operation)

    Ash.Changeset.before_action(changeset, &apply_vacancy_write(&1, operation))
  end

  defp apply_vacancy_write(changeset, operation) do
    case FillGroupRoleVacancy.consume_internal_write(changeset, operation) do
      {:ok, attributes} ->
        force_vacancy_attributes(changeset, attributes)

      {:error, _reason} ->
        Ash.Changeset.add_error(changeset,
          field: :state,
          message: "vacancy writes require the active FillGroupRoleVacancy transaction"
        )
    end
  end

  defp force_vacancy_attributes(changeset, attributes) do
    Enum.reduce(attributes, changeset, fn {field, value}, changeset ->
      Ash.Changeset.force_change_attribute(changeset, field, value)
    end)
  end
end

defmodule GolfScoring.Competition.Services.AcceptCompetitionSideRetirement do
  @moduledoc """
  Accepts one authoritative, audited CompetitionSide retirement ruling inside one transaction.

  The coordinator validates server checkpoint and prospective boundary evidence, persists
  immutable retirement proof, preserves or establishes `review_required`, rechecks affected
  Mystery rules, and records mandatory audit. Every effect commits or rolls back together.
  """

  alias Ash.Changeset
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Audit
  alias GolfScoring.Competition.CompetitionSideResult
  alias GolfScoring.Competition.CompetitionSideRetirement
  alias GolfScoring.Competition.CompetitionSideRetirementWriteGuard
  alias GolfScoring.Competition.Services.MysteryRevealCoordinator
  alias GolfScoring.LockProtocol
  alias GolfScoring.Repo

  @manager_roles [:event_admin, :competition_manager]
  @scheduled_holes 18
  @gate_key {__MODULE__, :retirement_gate}
  @write_key {__MODULE__, :retirement_write}
  @mystery_gate_key {__MODULE__, :mystery_recheck}

  @type result :: %{
          retirement_id: Ecto.UUID.t(),
          side_result_id: Ecto.UUID.t(),
          mystery_reveal_created?: boolean(),
          idempotent_retry?: boolean()
        }

  @spec run(StaffUser.t(), term(), term(), term(), term(), term(), map()) ::
          {:ok, result()} | {:error, term()}
  def run(
        actor,
        event_id,
        round_id,
        round_competition_id,
        side_id,
        playing_group_id,
        attrs
      )
      when is_map(attrs) do
    with %StaffUser{id: actor_id} <- actor,
         {:ok, actor_id} <- Ecto.UUID.cast(actor_id),
         {:ok, event_id} <- Ecto.UUID.cast(event_id),
         {:ok, round_id} <- Ecto.UUID.cast(round_id),
         {:ok, round_competition_id} <- Ecto.UUID.cast(round_competition_id),
         {:ok, side_id} <- Ecto.UUID.cast(side_id),
         {:ok, playing_group_id} <- Ecto.UUID.cast(playing_group_id),
         {:ok, reason} <- normalize_reason(Map.get(attrs, :reason)),
         {:ok, command_id} <- cast_command_id(Map.get(attrs, :acceptance_command_id)),
         {:ok, submission_id} <- Ecto.UUID.cast(Map.get(attrs, :checkpoint_hole_submission_id)),
         {:ok, effective_hole_id} <- Ecto.UUID.cast(Map.get(attrs, :effective_from_round_hole_id)),
         :ok <- require_preplay_attestation(Map.get(attrs, :confirm_effective_hole_unplayed?)),
         {:ok, command_meaning_fingerprint} <-
           derive_command_meaning_fingerprint(%{
             event_id: event_id,
             round_id: round_id,
             round_competition_id: round_competition_id,
             competition_side_id: side_id,
             playing_group_id: playing_group_id,
             reason: reason,
             acceptance_command_id: command_id,
             checkpoint_hole_submission_id: submission_id,
             effective_from_round_hole_id: effective_hole_id
           }),
         :ok <- require_commit_boundary() do
      run_transaction(
        actor_id,
        event_id,
        round_id,
        round_competition_id,
        side_id,
        playing_group_id,
        %{
          reason: reason,
          acceptance_command_id: command_id,
          command_meaning_fingerprint: command_meaning_fingerprint,
          checkpoint_hole_submission_id: submission_id,
          effective_from_round_hole_id: effective_hole_id
        }
      )
    else
      {:error, _reason} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  def run(
        _actor,
        _event_id,
        _round_id,
        _round_competition_id,
        _side_id,
        _playing_group_id,
        _attrs
      ),
      do: {:error, :invalid_input}

  @doc false
  def verified_retirement_review?(context, result_id, side_id, evidence) do
    gate = Process.get(@gate_key)
    proof = evidence || Map.get(context || %{}, :competition_side_result_retirement)

    Repo.in_transaction?() and retirement_gate_valid?(gate, proof, result_id, side_id)
  end

  defp retirement_gate_valid?(gate, proof, result_id, side_id) do
    is_map(gate) and is_map(proof) and is_reference(gate.token) and gate == proof and
      gate.operation == :accept_retirement and gate.result_id == result_id and
      gate.side_id == side_id
  end

  @doc false
  def consume_retirement_write(changeset, token) do
    proof = Process.get(@write_key)

    if CompetitionSideRetirementWriteGuard.matches?(changeset, proof) and
         proof.token == token and Repo.in_transaction?() and
         proof.transaction_id == retirement_transaction_id() do
      Process.put(@write_key, %{proof | used?: true})
      :ok
    else
      {:error, :unauthorized_retirement_write}
    end
  end

  defp normalize_reason(reason) when is_binary(reason) do
    trimmed = String.trim(reason)
    if trimmed == "", do: {:error, :retirement_reason_required}, else: {:ok, trimmed}
  end

  defp normalize_reason(_), do: {:error, :retirement_reason_required}

  defp cast_command_id(id), do: Ecto.UUID.cast(id)

  defp derive_command_meaning_fingerprint(scope) do
    canonical =
      {scope.event_id, scope.round_id, scope.round_competition_id, scope.competition_side_id,
       scope.playing_group_id, scope.reason, scope.acceptance_command_id,
       scope.checkpoint_hole_submission_id, scope.effective_from_round_hole_id, true}

    {:ok, :crypto.hash(:sha256, :erlang.term_to_binary(canonical))}
  end

  defp require_preplay_attestation(true), do: :ok
  defp require_preplay_attestation(_), do: {:error, :preplay_boundary_attestation_required}

  defp require_commit_boundary do
    if Repo.in_transaction?(), do: {:error, :transaction_already_open}, else: :ok
  end

  defp run_transaction(
         actor_id,
         event_id,
         round_id,
         round_competition_id,
         side_id,
         group_id,
         attrs
       ) do
    result =
      Repo.transaction(fn ->
        case accept_locked(
               actor_id,
               event_id,
               round_id,
               round_competition_id,
               side_id,
               group_id,
               attrs
             ) do
          {:ok, outcome} -> outcome
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, %{retirement_id: retirement_id, mystery_reveal_created?: true} = outcome} ->
        broadcast_mystery_reveal_changed(round_id)
        {:ok, Map.put(outcome, :retirement_id, retirement_id)}

      {:ok, outcome} ->
        {:ok, outcome}

      {:error, reason} ->
        {:error, reason}

      {:error, :rollback, reason} ->
        {:error, reason}
    end
  end

  defp accept_locked(actor_id, event_id, round_id, round_competition_id, side_id, group_id, attrs) do
    attrs = Map.put(attrs, :competition_side_id, side_id)

    with {:ok, _scope} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
         :ok <- authorize(actor_id, event_id) do
      case resolve_idempotent(attrs) do
        {:ok, existing} ->
          {:ok, existing}

        {:error, _} = error ->
          error

        :continue ->
          accept_locked_transaction(
            actor_id,
            event_id,
            round_id,
            round_competition_id,
            side_id,
            group_id,
            attrs
          )
      end
    end
  end

  defp accept_locked_transaction(
         actor_id,
         event_id,
         round_id,
         round_competition_id,
         side_id,
         group_id,
         attrs
       ) do
    with {:ok, locked} <- lock_gameplay_scope(round_id, group_id, side_id),
         :ok <-
           validate_scope(locked, event_id, round_id, round_competition_id, group_id, side_id),
         {:ok, route} <- load_route(locked.group, round_id),
         {:ok, checkpoint_row} <-
           load_checkpoint_submission(
             attrs.checkpoint_hole_submission_id,
             round_id,
             group_id,
             locked.group
           ),
         {:ok, checkpoint} <- validate_checkpoint_matches_route(checkpoint_row, route),
         {:ok, effective_index} <- effective_index(route, attrs.effective_from_round_hole_id),
         :ok <- validate_checkpoint_not_after_boundary(checkpoint.index, effective_index),
         :ok <- validate_authoritative_checkpoint_position(checkpoint.index, locked.group),
         :ok <- validate_group_progress(locked.group, effective_index),
         :ok <-
           validate_retirement_boundary_progression(
             checkpoint.index,
             effective_index,
             locked.group
           ),
         :ok <- reject_effective_hole_already_played(round_id, group_id, route, effective_index),
         {:ok, side_result} <- ensure_result(side_id),
         {:ok, locked_result} <- lock_side_result(side_result.id, side_id),
         :ok <- require_supported_state(locked_result),
         :ok <- reject_conflicting_side_retirement(side_id, attrs),
         {:ok, retirement, review_changed?} <-
           persist_acceptance(%{
             locked_result: locked_result,
             actor_id: actor_id,
             event_id: event_id,
             round_id: round_id,
             round_competition_id: round_competition_id,
             side_id: side_id,
             group_id: group_id,
             checkpoint: checkpoint,
             effective_index: effective_index,
             attrs: attrs
           }),
         :ok <-
           write_audit(%{
             actor_id: actor_id,
             event_id: event_id,
             round_id: round_id,
             round_competition_id: round_competition_id,
             side_id: side_id,
             playing_group_id: group_id,
             retirement_id: retirement.id,
             result_id: locked_result.id,
             reason: attrs.reason,
             checkpoint_submission_id: attrs.checkpoint_hole_submission_id,
             effective_hole_id: attrs.effective_from_round_hole_id,
             effective_index: effective_index
           }),
         {:ok, reveal_result} <-
           recheck_affected_rules(round_id, round_competition_id, route, effective_index, %{
             actor_id: actor_id,
             event_id: event_id,
             group_id: group_id,
             side_id: side_id,
             result_id: locked_result.id,
             retirement_id: retirement.id,
             review_changed?: review_changed?
           }) do
      {:ok,
       %{
         retirement_id: retirement.id,
         side_result_id: locked_result.id,
         mystery_reveal_created?: reveal_result.created?,
         idempotent_retry?: false
       }}
    end
  end

  defp resolve_idempotent(attrs) do
    case Repo.query!(
           """
           SELECT id::text, competition_side_result_id::text
           FROM competition_side_retirements
           WHERE acceptance_command_id = $1::uuid
             AND competition_side_id = $2::uuid
             AND command_meaning_fingerprint = $3::bytea
           """,
           [
             Ecto.UUID.dump!(attrs.acceptance_command_id),
             Ecto.UUID.dump!(attrs.competition_side_id),
             attrs.command_meaning_fingerprint
           ]
         ).rows do
      [[id, result_id]] ->
        {:ok,
         %{
           retirement_id: Ecto.UUID.cast!(id),
           side_result_id: Ecto.UUID.cast!(result_id),
           mystery_reveal_created?: false,
           idempotent_retry?: true
         }}

      [] ->
        cond do
          Repo.query!(
            "SELECT 1 FROM competition_side_retirements WHERE acceptance_command_id = $1::uuid",
            [Ecto.UUID.dump!(attrs.acceptance_command_id)]
          ).rows != [] ->
            {:error, :command_meaning_conflict}

          Repo.query!(
            "SELECT 1 FROM competition_side_retirements WHERE competition_side_id = $1::uuid",
            [Ecto.UUID.dump!(attrs.competition_side_id)]
          ).rows != [] ->
            {:error, :competition_side_already_retired}

          true ->
            :continue
        end
    end
  end

  defp reject_conflicting_side_retirement(side_id, attrs) do
    case Repo.query!(
           "SELECT acceptance_command_id::text FROM competition_side_retirements WHERE competition_side_id = $1::uuid",
           [Ecto.UUID.dump!(side_id)]
         ).rows do
      [] ->
        :ok

      [[existing_command]] ->
        if Ecto.UUID.cast!(existing_command) == attrs.acceptance_command_id,
          do: :ok,
          else: {:error, :competition_side_already_retired}
    end
  end

  defp authorize(actor_id, event_id) do
    if ActiveEventRole.authorized?(actor_id, event_id, @manager_roles),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp lock_gameplay_scope(round_id, playing_group_id, side_id) do
    case LockProtocol.acquire!(
           round: [round_id],
           playing_group: [playing_group_id],
           competition_side: [side_id]
         ) do
      {:ok, %{acquired: acquired}} ->
        {:ok,
         %{
           round: Enum.find(acquired, &(&1.class == :round)).row,
           group: Enum.find(acquired, &(&1.class == :playing_group)).row,
           side: Enum.find(acquired, &(&1.class == :competition_side)).row
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_scope(locked, event_id, round_id, round_competition_id, playing_group_id, side_id) do
    cond do
      locked.round.event_id != event_id ->
        {:error, :event_mismatch}

      locked.round.state not in ["scoring_open", :scoring_open] ->
        {:error, {:invalid_round_state, locked.round.state}}

      locked.group.round_id != round_id ->
        {:error, :playing_group_mismatch}

      locked.side.round_id != round_id or locked.side.id != side_id ->
        {:error, :competition_side_mismatch}

      locked.side.round_competition_id != round_competition_id ->
        {:error, :competition_mismatch}

      locked.group.id != playing_group_id ->
        {:error, :playing_group_mismatch}

      true ->
        validate_competition_and_membership(
          event_id,
          round_id,
          round_competition_id,
          side_id,
          playing_group_id
        )
    end
  end

  defp validate_competition_and_membership(
         event_id,
         round_id,
         round_competition_id,
         side_id,
         group_id
       ) do
    case Repo.query!(
           "SELECT event_id::text, round_id::text FROM round_competitions WHERE id = $1::uuid",
           [Ecto.UUID.dump!(round_competition_id)]
         ).rows do
      [[competition_event_id, competition_round_id]] ->
        if Ecto.UUID.cast!(competition_event_id) == event_id and
             Ecto.UUID.cast!(competition_round_id) == round_id do
          validate_side_memberships(round_id, round_competition_id, side_id, group_id)
        else
          {:error, :competition_mismatch}
        end

      [] ->
        {:error, :competition_not_found}
    end
  end

  defp validate_side_memberships(round_id, round_competition_id, side_id, playing_group_id) do
    rows =
      Repo.query!(
        """
        SELECT csm.round_id::text, csm.round_competition_id::text,
               re.round_id::text, re.playing_group_id::text
        FROM competition_side_memberships csm
        JOIN round_entries re ON re.id = csm.round_entry_id
        WHERE csm.competition_side_id = $1::uuid
        ORDER BY csm.round_entry_id
        """,
        [Ecto.UUID.dump!(side_id)]
      ).rows

    cond do
      rows == [] ->
        {:error, :competition_side_has_no_members}

      Enum.any?(rows, fn [m_round, m_competition, entry_round, group_id] ->
        Ecto.UUID.cast!(m_round) != round_id or
          Ecto.UUID.cast!(m_competition) != round_competition_id or
          Ecto.UUID.cast!(entry_round) != round_id or
            Ecto.UUID.cast!(group_id) != playing_group_id
      end) ->
        {:error, :competition_side_group_mismatch}

      true ->
        :ok
    end
  end

  defp load_route(%{starting_round_hole_id: start_hole_id}, round_id) do
    holes =
      Repo.query!(
        "SELECT id::text, play_order::int FROM round_holes WHERE round_id = $1::uuid ORDER BY play_order",
        [Ecto.UUID.dump!(round_id)]
      ).rows
      |> Enum.map(fn [id, play_order] -> %{id: Ecto.UUID.cast!(id), play_order: play_order} end)

    cond do
      length(holes) != @scheduled_holes or
          Enum.map(holes, & &1.play_order) != Enum.to_list(1..@scheduled_holes) ->
        {:error, :invalid_round_route}

      is_nil(start_hole_id) ->
        {:error, :starting_hole_not_assigned}

      true ->
        case Enum.find_index(holes, &(&1.id == start_hole_id)) do
          nil -> {:error, :starting_hole_not_in_route}
          start_index -> {:ok, rotate_route(holes, start_index)}
        end
    end
  end

  defp load_checkpoint_submission(submission_id, round_id, group_id, group) do
    case Repo.query!(
           """
           SELECT hs.round_id::text, hs.playing_group_id::text, hs.round_hole_id::text,
                  hs.accepted_at, hs.expected_group_score_revision
           FROM hole_submissions hs
           WHERE hs.id = $1::uuid
           """,
           [Ecto.UUID.dump!(submission_id)]
         ).rows do
      [[r_id, g_id, hole_id, accepted_at, expected_revision]] ->
        cond do
          is_nil(accepted_at) ->
            {:error, :checkpoint_submission_not_accepted}

          Ecto.UUID.cast!(r_id) != round_id or Ecto.UUID.cast!(g_id) != group_id ->
            {:error, :checkpoint_submission_scope_mismatch}

          expected_revision != group.scoring_revision - 1 ->
            {:error, :stale_checkpoint_receipt}

          true ->
            {:ok,
             %{
               round_hole_id: Ecto.UUID.cast!(hole_id),
               expected_group_score_revision: expected_revision
             }}
        end

      [] ->
        {:error, :checkpoint_submission_not_found}
    end
  end

  defp validate_authoritative_checkpoint_position(checkpoint_index, %{scoring_revision: revision}) do
    if revision > 0 and checkpoint_index == revision - 1,
      do: :ok,
      else: {:error, :stale_checkpoint_receipt}
  end

  defp validate_retirement_boundary_progression(
         checkpoint_index,
         effective_index,
         %{scoring_revision: revision}
       ) do
    if effective_index == revision and effective_index == checkpoint_index + 1,
      do: :ok,
      else: {:error, :retirement_boundary_gap_unproven}
  end

  defp validate_checkpoint_matches_route(%{round_hole_id: hole_id}, route) do
    case Enum.find_index(route, &(&1.id == hole_id)) do
      nil -> {:error, :checkpoint_hole_not_in_round_route}
      index -> {:ok, %{round_hole_id: hole_id, index: index}}
    end
  end

  defp validate_checkpoint_not_after_boundary(checkpoint_index, effective_index) do
    if checkpoint_index <= effective_index,
      do: :ok,
      else: {:error, :checkpoint_after_effective_boundary}
  end

  defp effective_index(route, effective_hole_id) do
    case Enum.find_index(route, &(&1.id == effective_hole_id)) do
      nil -> {:error, :effective_hole_not_in_round_route}
      index -> {:ok, index}
    end
  end

  defp rotate_route(route, start_index) do
    {head, tail} = Enum.split(route, start_index)
    tail ++ head
  end

  defp validate_group_progress(%{state: state, scoring_revision: revision}, effective_index) do
    cond do
      state in ["attention_required", :attention_required] ->
        {:error, :physical_play_status_uncertain}

      state in ["finished_playing", :finished_playing] and revision > effective_index ->
        {:error, :effective_boundary_already_passed}

      state not in [
        "not_started",
        :not_started,
        "playing",
        :playing,
        "finished_playing",
        :finished_playing
      ] ->
        {:error, {:invalid_group_state, state}}

      revision > effective_index ->
        {:error, :effective_boundary_already_passed}

      true ->
        :ok
    end
  end

  defp reject_effective_hole_already_played(round_id, playing_group_id, route, effective_index) do
    hole_id = Enum.at(route, effective_index).id |> Ecto.UUID.dump!()

    submission_count =
      Repo.query!(
        """
        SELECT count(*)::int FROM hole_submissions
        WHERE round_id = $1::uuid AND playing_group_id = $2::uuid AND round_hole_id = $3::uuid
        """,
        [Ecto.UUID.dump!(round_id), Ecto.UUID.dump!(playing_group_id), hole_id]
      ).rows
      |> hd()
      |> hd()

    result_count =
      Repo.query!(
        """
        SELECT count(*)::int
        FROM hole_results hr
        JOIN scorecards sc ON sc.id = hr.scorecard_id
        JOIN round_entries re ON re.id = sc.round_entry_id
        WHERE re.playing_group_id = $1::uuid AND hr.round_id = $2::uuid AND hr.round_hole_id = $3::uuid
        """,
        [Ecto.UUID.dump!(playing_group_id), Ecto.UUID.dump!(round_id), hole_id]
      ).rows
      |> hd()
      |> hd()

    if submission_count == 0 and result_count == 0,
      do: :ok,
      else: {:error, :effective_boundary_already_played}
  end

  defp ensure_result(side_id) do
    case Repo.query!(
           "SELECT id::text, state FROM competition_side_results WHERE competition_side_id = $1::uuid",
           [Ecto.UUID.dump!(side_id)]
         ).rows do
      [[id, state]] -> {:ok, %{id: Ecto.UUID.cast!(id), state: state}}
      [] -> create_provisional(side_id)
    end
  end

  defp create_provisional(side_id) do
    CompetitionSideResult
    |> Changeset.for_create(:create_provisional_internal, %{competition_side_id: side_id})
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, result} -> {:ok, %{id: result.id, state: "provisional"}}
      {:error, error} -> {:error, error}
    end
  end

  defp lock_side_result(result_id, side_id) do
    case LockProtocol.acquire!(competition_side_result: [result_id]) do
      {:ok, %{acquired: [%{row: %{competition_side_id: ^side_id} = row}]}} -> {:ok, row}
      {:ok, _} -> {:error, :competition_side_result_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_supported_state(%{state: state})
       when state in ["provisional", :provisional, "review_required", :review_required],
       do: :ok

  defp require_supported_state(%{state: "finalized"}),
    do: {:error, :competition_side_result_terminal}

  defp require_supported_state(%{state: "excluded"}),
    do: {:error, :competition_side_result_terminal}

  defp require_supported_state(_), do: {:error, :unsupported_side_result_state}

  defp persist_acceptance(%{locked_result: locked_result, side_id: side_id} = scope) do
    token = make_ref()

    review_gate = %{
      operation: :accept_retirement,
      result_id: locked_result.id,
      side_id: side_id,
      token: token,
      actor_id: scope.actor_id
    }

    previous_gate = Process.put(@gate_key, review_gate)

    try do
      review_changed? = locked_result.state in ["provisional", :provisional]

      with {:ok, _result} <- apply_review_transition(locked_result, review_gate, review_changed?),
           {:ok, retirement} <- insert_retirement_evidence(Map.put(scope, :gate_token, token)) do
        {:ok, retirement, review_changed?}
      end
    after
      if previous_gate, do: Process.put(@gate_key, previous_gate), else: Process.delete(@gate_key)
    end
  end

  defp apply_review_transition(locked_result, review_gate, review_changed?) do
    CompetitionSideResult
    |> Ash.get!(locked_result.id, authorize?: false)
    |> Changeset.for_update(:accept_retirement_internal, %{})
    |> Changeset.set_context(%{competition_side_result_retirement: review_gate})
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, result} -> {:ok, if(review_changed?, do: result, else: locked_result)}
      {:error, error} -> {:error, error}
    end
  end

  defp insert_retirement_evidence(%{
         locked_result: locked_result,
         actor_id: actor_id,
         event_id: event_id,
         round_id: round_id,
         round_competition_id: round_competition_id,
         side_id: side_id,
         group_id: group_id,
         checkpoint: checkpoint,
         effective_index: effective_index,
         attrs: attrs,
         gate_token: gate_token
       }) do
    scope = %{
      event_id: event_id,
      round_id: round_id,
      round_competition_id: round_competition_id,
      competition_side_id: side_id,
      competition_side_result_id: locked_result.id,
      playing_group_id: group_id,
      authorized_by_staff_user_id: actor_id,
      reason: attrs.reason,
      acceptance_command_id: attrs.acceptance_command_id,
      command_meaning_fingerprint: attrs.command_meaning_fingerprint,
      checkpoint_hole_submission_id: attrs.checkpoint_hole_submission_id,
      checkpoint_round_hole_id: checkpoint.round_hole_id,
      checkpoint_play_index: checkpoint.index,
      effective_round_hole_id: attrs.effective_from_round_hole_id,
      effective_play_index: effective_index,
      preplay_boundary_confirmed: true
    }

    write_proof = %{
      scope: scope,
      pid: self(),
      token: gate_token,
      transaction_id: retirement_transaction_id(),
      used?: false
    }

    if Process.get(@write_key), do: Repo.rollback(:nested_retirement_write)
    Process.put(@write_key, write_proof)

    try do
      CompetitionSideRetirement
      |> Changeset.for_create(:create_accepted_internal, scope)
      |> Changeset.set_context(%{
        competition_side_retirement_write: %{owner: __MODULE__, token: gate_token}
      })
      |> Ash.create(authorize?: false)
    after
      Process.delete(@write_key)
    end
  end

  defp write_audit(attrs) do
    case Audit.record_staff_event(
           %{
             actor_staff_user_id: attrs.actor_id,
             action: "accept_competition_side_retirement",
             target_type: "CompetitionSideRetirement",
             target_id: attrs.retirement_id,
             reason: attrs.reason,
             context: Map.drop(attrs, [:actor_id, :retirement_id, :reason])
           },
           authorize?: false
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp recheck_affected_rules(round_id, round_competition_id, route, effective_index, evidence) do
    route_position = Map.new(Enum.with_index(route), fn {hole, index} -> {hole.id, index} end)

    hole_ids =
      Repo.query!(
        """
        SELECT mhr.round_hole_id::text
        FROM mystery_hole_rules mhr
        JOIN scoring_tracks st ON st.id = mhr.scoring_track_id
        WHERE mhr.round_id = $1::uuid AND st.round_competition_id = $2::uuid
        ORDER BY mhr.id
        """,
        [Ecto.UUID.dump!(round_id), Ecto.UUID.dump!(round_competition_id)]
      ).rows
      |> Enum.map(fn [hole_id] -> Ecto.UUID.cast!(hole_id) end)

    if Enum.all?(hole_ids, &Map.has_key?(route_position, &1)) do
      affected_hole_ids =
        hole_ids
        |> Enum.filter(&(Map.fetch!(route_position, &1) >= effective_index))
        |> Enum.uniq()

      holes = Enum.sort_by(affected_hole_ids, &Ecto.UUID.dump!/1)

      proof =
        Map.merge(evidence, %{
          owner: __MODULE__,
          operation: :accept_retirement,
          token: make_ref(),
          pid: self(),
          transaction_id: mystery_transaction_id(),
          round_id: round_id,
          competition_id: round_competition_id,
          holes: holes,
          effective_index: effective_index,
          used?: false
        })

      if Process.get(@mystery_gate_key), do: Repo.rollback(:nested_mystery_recheck)
      Process.put(@mystery_gate_key, proof)

      try do
        MysteryRevealCoordinator.recheck_many(round_id, round_competition_id, holes, proof)
      after
        Process.delete(@mystery_gate_key)
      end
    else
      {:error, :mystery_rule_hole_not_in_round_route}
    end
  end

  @doc false
  def consume_mystery_recheck(proof, scope) do
    gate = Process.get(@mystery_gate_key)

    if is_map(gate) and gate == proof and not gate.used? and gate.pid == self() and
         scope == Map.take(gate, [:round_id, :competition_id, :holes]) and
         Repo.in_transaction?() and gate.transaction_id == mystery_transaction_id() and
         persisted_mystery_retirement?(gate) do
      Process.put(@mystery_gate_key, %{gate | used?: true})
      :ok
    else
      {:error, :unauthorized_mystery_recheck}
    end
  end

  defp persisted_mystery_retirement?(gate) do
    Repo.query!(
      """
      SELECT 1 FROM competition_side_retirements csr
      JOIN competition_sides cs ON cs.id = csr.competition_side_id
      JOIN rounds r ON r.id = cs.round_id
      WHERE csr.id = $1::uuid AND cs.id = $2::uuid AND r.id = $3::uuid
        AND r.event_id = $4::uuid AND cs.round_competition_id = $5::uuid
        AND csr.playing_group_id = $6::uuid AND csr.effective_play_index = $7
        AND EXISTS (
          SELECT 1 FROM audit_events a WHERE a.target_id = csr.id
          AND a.action = 'accept_competition_side_retirement'
          AND a.actor_staff_user_id = $8::uuid
        )
      """,
      [
        Ecto.UUID.dump!(gate.retirement_id),
        Ecto.UUID.dump!(gate.side_id),
        Ecto.UUID.dump!(gate.round_id),
        Ecto.UUID.dump!(gate.event_id),
        Ecto.UUID.dump!(gate.competition_id),
        Ecto.UUID.dump!(gate.group_id),
        gate.effective_index,
        Ecto.UUID.dump!(gate.actor_id)
      ]
    ).rows == [[1]]
  end

  defp retirement_transaction_id,
    do: Repo.query!("SELECT pg_current_xact_id()::text").rows |> hd() |> hd()

  defp mystery_transaction_id, do: retirement_transaction_id()

  defp broadcast_mystery_reveal_changed(round_id) do
    Phoenix.PubSub.broadcast(
      GolfScoring.PubSub,
      "round:#{round_id}",
      {:mystery_reveal_changed, %{round_id: round_id}}
    )
  end
end

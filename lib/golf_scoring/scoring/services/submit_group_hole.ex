defmodule GolfScoring.Scoring.Services.SubmitGroupHole do
  @moduledoc false

  require Ash.Query

  alias Ash.Changeset
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Accounts.PlayerAccessGrant
  alias GolfScoring.Accounts.PlayerAccessGrantGuard
  alias GolfScoring.Audit
  alias GolfScoring.Competition.PlayingGroup
  alias GolfScoring.Competition.RoundEntry
  alias GolfScoring.LockProtocol
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Calculators.StrokeAllocation
  alias GolfScoring.Scoring.HoleResult
  alias GolfScoring.Scoring.HoleSubmission
  alias GolfScoring.Scoring.Policies.PickupEligibility
  alias GolfScoring.Scoring.Scorecard

  @staff_roles [:event_admin, :competition_manager, :scoring_support]
  @required_registration ~w(expected checked_in)
  @required_participation ~w(not_started active)
  @scheduled_holes 18
  @progression_batch_key {__MODULE__, :progression_batch}

  @type command :: map()

  @doc false
  def verified_progression?(context, playing_group_id, operation, record_id \\ nil) do
    batch = Process.get(@progression_batch_key)

    progression = Map.get(context || %{}, :submit_group_hole_progression)

    Repo.in_transaction?() and is_reference(batch) and
      match?(
        %{
          playing_group_id: ^playing_group_id,
          operation: ^operation,
          batch: ^batch
        },
        progression
      ) and (is_nil(record_id) or progression[:record_id] == record_id)
  end

  @doc false
  def scorecard_lifecycle_evidence?(:mark_in_progress, scorecard_id),
    do: hole_result_count_for_scorecard(scorecard_id) >= 1

  def scorecard_lifecycle_evidence?(:mark_complete, scorecard_id),
    do: hole_result_count_for_scorecard(scorecard_id) == @scheduled_holes

  def scorecard_lifecycle_evidence?(_, _), do: false

  @doc false
  def round_entry_lifecycle_evidence?(:mark_participation_active, entry_id) do
    case scorecard_id_for_entry(entry_id) do
      scorecard_id when not is_nil(scorecard_id) ->
        hole_result_count_for_scorecard(scorecard_id) >= 1

      _ ->
        false
    end
  end

  def round_entry_lifecycle_evidence?(:mark_participation_completed, entry_id) do
    case scorecard_id_for_entry(entry_id) do
      scorecard_id when not is_nil(scorecard_id) ->
        hole_result_count_for_scorecard(scorecard_id) == @scheduled_holes

      _ ->
        false
    end
  end

  def round_entry_lifecycle_evidence?(_, _), do: false

  @doc false
  def playing_group_lifecycle_evidence?(:mark_group_playing, playing_group_id) do
    required_count = required_participant_count(playing_group_id)
    accounted_count = required_entries_with_hole_results_count(playing_group_id)
    required_count > 0 and accounted_count == required_count
  end

  def playing_group_lifecycle_evidence?(:mark_group_finished, playing_group_id) do
    case Repo.get(PlayingGroup, playing_group_id) do
      %{scoring_revision: 18} ->
        outstanding_incomplete_participants?(playing_group_id) == false

      _ ->
        false
    end
  end

  def playing_group_lifecycle_evidence?(_, _), do: false

  defp hole_result_count_for_scorecard(scorecard_id) do
    Repo.query!(
      "SELECT count(*)::int FROM hole_results WHERE scorecard_id = $1::uuid",
      [Ecto.UUID.dump!(scorecard_id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp scorecard_id_for_entry(entry_id) do
    case Repo.query!(
           "SELECT id::text FROM scorecards WHERE round_entry_id = $1::uuid LIMIT 1",
           [Ecto.UUID.dump!(entry_id)]
         ).rows do
      [[id]] -> Ecto.UUID.cast!(id)
      [] -> nil
    end
  end

  defp required_participant_count(playing_group_id) do
    Repo.query!(
      """
      SELECT count(*)::int FROM round_entries
      WHERE playing_group_id = $1::uuid
        AND registration_status = ANY($2::text[])
        AND participation_status = ANY($3::text[])
      """,
      [
        Ecto.UUID.dump!(playing_group_id),
        @required_registration,
        @required_participation
      ]
    ).rows
    |> hd()
    |> hd()
  end

  defp required_entries_with_hole_results_count(playing_group_id) do
    Repo.query!(
      """
      SELECT count(DISTINCT re.id)::int
      FROM round_entries re
      INNER JOIN scorecards sc ON sc.round_entry_id = re.id
      INNER JOIN hole_results hr ON hr.scorecard_id = sc.id
      WHERE re.playing_group_id = $1::uuid
        AND re.registration_status = ANY($2::text[])
        AND re.participation_status = ANY($3::text[])
      """,
      [
        Ecto.UUID.dump!(playing_group_id),
        @required_registration,
        @required_participation
      ]
    ).rows
    |> hd()
    |> hd()
  end

  defp outstanding_incomplete_participants?(playing_group_id) do
    Repo.query!(
      """
      SELECT exists(
        SELECT 1 FROM round_entries
        WHERE playing_group_id = $1::uuid
          AND registration_status = ANY($2::text[])
          AND participation_status = ANY($3::text[])
      )
      """,
      [
        Ecto.UUID.dump!(playing_group_id),
        @required_registration,
        @required_participation
      ]
    ).rows
    |> hd()
    |> hd()
  end

  @spec run(term(), Ecto.UUID.t(), Ecto.UUID.t(), command()) ::
          {:ok, HoleSubmission.t()} | {:error, term()}
  def run(actor, event_id, round_id, command) when is_map(command) do
    with {:ok, cmd} <- normalize_command(command) do
      run_transaction(actor, event_id, round_id, cmd)
    end
  end

  def run(_actor, _event_id, _round_id, _command), do: {:error, :invalid_input}

  defp run_transaction(actor, event_id, round_id, cmd) do
    result =
      Repo.transaction(fn ->
        case execute(actor, event_id, round_id, cmd) do
          {:ok, outcome} -> outcome
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, %{receipt: receipt, idempotent_retry?: true}} ->
        {:ok, receipt}

      {:ok, %{receipt: receipt, idempotent_retry?: false, broadcast: payload}} ->
        broadcast!(payload)
        {:ok, receipt}

      {:error, reason} ->
        {:error, reason}

      {:error, :rollback, reason} ->
        {:error, reason}
    end
  end

  defp execute(actor, event_id, round_id, cmd) do
    with {:ok, actor_ctx} <- resolve_actor(actor, event_id),
         :ok <- validate_command_shape(actor_ctx, cmd),
         {:ok, locked} <- lock_gameplay_scope(round_id, cmd.playing_group_id),
         {:ok, actor_ctx} <- finalize_actor_context(actor_ctx, cmd, locked),
         :ok <- validate_round(locked.round, event_id) do
      continue_after_idempotency_check(actor_ctx, cmd, locked, event_id, round_id)
    end
  end

  defp continue_after_idempotency_check(actor_ctx, cmd, locked, event_id, round_id) do
    case resolve_idempotency(cmd, actor_ctx, round_id) do
      {:ok, %HoleSubmission{} = existing} ->
        {:ok, %{receipt: existing, idempotent_retry?: true, broadcast: nil}}

      {:ok, :continue} ->
        with :ok <- validate_group_for_new_submission(locked.group, round_id),
             {:ok, expected_hole_id} <- derive_expected_hole(locked.group, locked.route_holes) do
          accept_new_hole(actor_ctx, cmd, locked, expected_hole_id, event_id, round_id)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_command_shape(%{kind: :staff}, %{role_assignment_version: nil}), do: :ok

  defp validate_command_shape(%{kind: :staff}, %{role_assignment_version: _}),
    do: {:error, :staff_role_version_forbidden}

  defp validate_command_shape(%{kind: :player}, %{role_assignment_version: version})
       when is_integer(version) and version > 0,
       do: :ok

  defp validate_command_shape(%{kind: :player}, _),
    do: {:error, :role_assignment_version_required}

  defp accept_new_hole(actor_ctx, cmd, locked, expected_hole_id, event_id, round_id) do
    with :ok <- require_revision_match(cmd, locked.group),
         :ok <- require_hole_match(cmd, expected_hole_id),
         {:ok, entries} <- lock_required_entries(locked.group.id),
         :ok <- validate_results_set(entries, cmd.results),
         :ok <- validate_outcomes(entries, cmd, expected_hole_id, locked.round.id),
         {:ok, scorecards} <- ensure_and_lock_scorecards(entries, locked.round.id),
         :ok <- confirm_no_conflicting_hole_results(scorecards, expected_hole_id),
         {:ok, receipt} <-
           persist_acceptance(
             actor_ctx,
             cmd,
             locked,
             entries,
             scorecards,
             expected_hole_id,
             event_id
           ) do
      broadcast_payload = %{
        round_id: round_id,
        playing_group_id: cmd.playing_group_id,
        round_hole_id: expected_hole_id,
        hole_submission_id: receipt.id,
        scoring_revision: locked.group.scoring_revision + 1
      }

      {:ok, %{receipt: receipt, idempotent_retry?: false, broadcast: broadcast_payload}}
    end
  end

  defp resolve_idempotency(cmd, actor_ctx, round_id) do
    fingerprint = payload_fingerprint(cmd, actor_ctx)

    case HoleSubmission
         |> Ash.Query.filter(client_submission_id == ^cmd.client_submission_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        {:ok, :continue}

      {:ok, existing} ->
        verify_idempotent_receipt(existing, cmd, actor_ctx, round_id, fingerprint)

      {:error, error} ->
        {:error, error}
    end
  end

  defp verify_idempotent_receipt(existing, cmd, actor_ctx, round_id, fingerprint) do
    cond do
      existing.round_id != round_id ->
        {:error, :idempotency_scope_mismatch}

      existing.playing_group_id != cmd.playing_group_id ->
        {:error, :idempotency_scope_mismatch}

      existing.round_hole_id != cmd.round_hole_id ->
        {:error, :idempotency_scope_mismatch}

      not actor_matches?(existing, actor_ctx) ->
        {:error, :idempotency_actor_mismatch}

      existing.payload_fingerprint != fingerprint ->
        {:error, :idempotency_payload_conflict}

      true ->
        {:ok, existing}
    end
  end

  defp actor_matches?(%{submitted_by_staff_user_id: staff_id}, %{kind: :staff, staff_id: staff_id})
       when not is_nil(staff_id),
       do: true

  defp actor_matches?(
         %{submitted_by_round_entry_id: entry_id, role_assignment_version: version},
         %{kind: :player, round_entry_id: entry_id, role_assignment_version: version}
       )
       when not is_nil(entry_id),
       do: true

  defp actor_matches?(_, _), do: false

  defp persist_acceptance(actor_ctx, cmd, locked, entries, scorecards, round_hole_id, event_id) do
    round_id = locked.round.id
    group = locked.group
    first_hole? = group.scoring_revision == 0
    final_hole? = group.scoring_revision == @scheduled_holes - 1
    fingerprint = payload_fingerprint(cmd, actor_ctx)
    group_id = group.id

    with_progression_batch(fn ->
      with :ok <- write_hole_results(entries, scorecards, round_id, round_hole_id, cmd.results),
           :ok <- advance_scorecards(scorecards, final_hole?, group_id),
           :ok <- advance_entries(entries, first_hole?, final_hole?, group_id),
           :ok <- advance_group(group, first_hole?, final_hole?),
           {:ok, receipt} <-
             create_receipt(
               actor_ctx,
               cmd,
               round_id,
               round_hole_id,
               group.scoring_revision,
               fingerprint
             ),
           :ok <-
             write_audit(actor_ctx, receipt, event_id, group.scoring_revision, length(entries)) do
        {:ok, receipt}
      end
    end)
  end

  defp with_progression_batch(fun) do
    batch = make_ref()
    previous = Process.put(@progression_batch_key, batch)

    try do
      fun.()
    after
      if previous,
        do: Process.put(@progression_batch_key, previous),
        else: Process.delete(@progression_batch_key)
    end
  end

  defp progression_context(playing_group_id, operation, record_id) do
    batch = Process.get(@progression_batch_key)

    %{
      submit_group_hole_progression: %{
        playing_group_id: playing_group_id,
        operation: operation,
        record_id: record_id,
        batch: batch
      }
    }
  end

  defp write_hole_results(entries, scorecards, round_id, round_hole_id, results) do
    result_by_entry = Map.new(results, &{&1.round_entry_id, &1})
    scorecard_by_entry = Map.new(scorecards, &{&1.round_entry_id, &1})

    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      result = Map.fetch!(result_by_entry, entry.id)
      scorecard = Map.fetch!(scorecard_by_entry, entry.id)

      attrs = %{
        round_id: round_id,
        scorecard_id: scorecard.id,
        round_hole_id: round_hole_id,
        outcome: result.outcome,
        gross_strokes: result.gross_strokes
      }

      case HoleResult
           |> Changeset.for_create(:record_internal, attrs)
           |> Ash.create(authorize?: false) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp advance_scorecards(scorecards, final_hole?, playing_group_id) do
    Enum.reduce_while(scorecards, :ok, fn card, :ok ->
      with :ok <- maybe_mark_scorecard_in_progress(card, playing_group_id),
           :ok <- maybe_mark_scorecard_complete(card, final_hole?, playing_group_id) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_mark_scorecard_in_progress(%{id: id, state: state}, playing_group_id)
       when state in ["not_started", :not_started] do
    update_scorecard!(id, :mark_in_progress_internal, playing_group_id, :mark_in_progress)
  end

  defp maybe_mark_scorecard_in_progress(_, _), do: :ok

  defp maybe_mark_scorecard_complete(%{id: id, state: state}, true, playing_group_id)
       when state in ["in_progress", :in_progress] do
    update_scorecard!(id, :mark_complete_internal, playing_group_id, :mark_complete)
  end

  defp maybe_mark_scorecard_complete(_, _, _), do: :ok

  defp update_scorecard!(id, action, playing_group_id, operation) do
    ctx = progression_context(playing_group_id, operation, id)

    Scorecard
    |> Ash.get!(id, authorize?: false)
    |> Changeset.for_update(action, %{})
    |> Ash.Changeset.set_context(ctx)
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp advance_entries(entries, first_hole?, final_hole?, playing_group_id) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case advance_entry_participation(entry.id, first_hole?, final_hole?, playing_group_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp advance_entry_participation(entry_id, first_hole?, final_hole?, playing_group_id) do
    with :ok <-
           if(first_hole?,
             do: mark_entry_active(entry_id, playing_group_id),
             else: :ok
           ) do
      if final_hole?, do: mark_entry_completed(entry_id, playing_group_id), else: :ok
    end
  end

  defp mark_entry_active(entry_id, playing_group_id) do
    ctx = progression_context(playing_group_id, :mark_participation_active, entry_id)

    RoundEntry
    |> Ash.get!(entry_id, authorize?: false)
    |> Changeset.for_update(:mark_participation_active_internal, %{})
    |> Ash.Changeset.set_context(ctx)
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp mark_entry_completed(entry_id, playing_group_id) do
    ctx = progression_context(playing_group_id, :mark_participation_completed, entry_id)

    RoundEntry
    |> Ash.get!(entry_id, authorize?: false)
    |> Changeset.for_update(:mark_participation_completed_internal, %{})
    |> Ash.Changeset.set_context(ctx)
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp advance_group(%{id: group_id}, first_hole?, final_hole?) do
    group = Ash.get!(PlayingGroup, group_id, authorize?: false)

    with :ok <- if(first_hole?, do: mark_group_playing(group), else: :ok),
         :ok <- increment_revision(group) do
      if final_hole?, do: mark_group_finished(group_id), else: :ok
    end
  end

  defp mark_group_playing(group) do
    ctx = progression_context(group.id, :mark_group_playing, group.id)

    group
    |> Changeset.for_update(:mark_group_playing, %{})
    |> Ash.Changeset.set_context(ctx)
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp increment_revision(group) do
    ctx = progression_context(group.id, :increment_scoring_revision, group.id)

    group
    |> Changeset.for_update(:increment_scoring_revision_internal, %{})
    |> Ash.Changeset.set_context(ctx)
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp mark_group_finished(group_id) do
    ctx = progression_context(group_id, :mark_group_finished, group_id)

    PlayingGroup
    |> Ash.get!(group_id, authorize?: false)
    |> Changeset.for_update(:mark_group_finished, %{})
    |> Ash.Changeset.set_context(ctx)
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp create_receipt(actor_ctx, cmd, round_id, round_hole_id, scoring_revision, fingerprint) do
    base = %{
      client_submission_id: cmd.client_submission_id,
      round_id: round_id,
      playing_group_id: cmd.playing_group_id,
      round_hole_id: round_hole_id,
      expected_group_score_revision: scoring_revision,
      payload_fingerprint: fingerprint,
      submitted_payload: semantic_payload_map(cmd, actor_ctx),
      captured_at: cmd.captured_at
    }

    attrs =
      case actor_ctx do
        %{kind: :staff, staff_id: staff_id} ->
          Map.merge(base, %{
            submitted_by_staff_user_id: staff_id,
            submitted_by_round_entry_id: nil,
            group_role_assignment_id: nil,
            role_assignment_version: nil
          })

        %{
          kind: :player,
          round_entry_id: entry_id,
          assignment_id: assignment_id,
          role_assignment_version: version
        } ->
          Map.merge(base, %{
            submitted_by_staff_user_id: nil,
            submitted_by_round_entry_id: entry_id,
            group_role_assignment_id: assignment_id,
            role_assignment_version: version
          })
      end

    HoleSubmission
    |> Changeset.for_create(:create_accepted_internal, attrs)
    |> Ash.create(authorize?: false)
  end

  defp write_audit(actor_ctx, receipt, event_id, old_revision, result_count) do
    context = %{
      event_id: event_id,
      round_id: receipt.round_id,
      playing_group_id: receipt.playing_group_id,
      round_hole_id: receipt.round_hole_id,
      old_scoring_revision: old_revision,
      new_scoring_revision: old_revision + 1,
      result_count: result_count,
      actor_type: actor_ctx.kind
    }

    case actor_ctx do
      %{kind: :staff, staff_id: staff_id} ->
        Audit.record_staff_event(
          %{
            actor_staff_user_id: staff_id,
            action: "submit_group_hole",
            target_type: "HoleSubmission",
            target_id: receipt.id,
            context: context
          },
          authorize?: false
        )

      %{kind: :player, round_entry_id: entry_id, role_assignment_version: version} ->
        Audit.record_system_event(
          %{
            action: "submit_group_hole",
            target_type: "HoleSubmission",
            target_id: receipt.id,
            context:
              Map.merge(context, %{
                submitted_by_round_entry_id: entry_id,
                role_assignment_version: version
              })
          },
          authorize?: false
        )
    end
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp broadcast!(payload) do
    Phoenix.PubSub.broadcast(
      GolfScoring.PubSub,
      "round:#{payload.round_id}",
      {:group_hole_submitted, payload}
    )
  end

  defp resolve_actor(%PlayerAccessGrant{} = grant, event_id) do
    with :ok <- PlayerAccessGrantGuard.apply_lazy_expiry_for_grant_id(Repo, grant.id),
         {:ok, locked_grant} <- lock_grant(grant.id),
         :ok <- grant_event_matches(locked_grant, event_id),
         :ok <- grant_usable(locked_grant) do
      {:ok, %{kind: :player, grant: locked_grant}}
    end
  end

  defp resolve_actor(%{id: staff_id}, event_id) when is_binary(staff_id) do
    with {:ok, _scope} <- EventAuthorityLock.lock_scope!(event_id, [staff_id]),
         :ok <- authorize_staff(staff_id, event_id) do
      {:ok, %{kind: :staff, staff_id: staff_id}}
    end
  end

  defp resolve_actor(_, _), do: {:error, :invalid_actor}

  defp finalize_actor_context(%{kind: :staff} = ctx, _cmd, locked) do
    case lock_assignments(locked.group.id) do
      {:ok, _} -> {:ok, ctx}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finalize_actor_context(%{kind: :player, grant: grant} = ctx, cmd, locked) do
    with {:ok, assignment_rows} <- lock_assignments(locked.group.id),
         {:ok, primary} <- active_primary_scorer(assignment_rows),
         :ok <- role_version_matches(cmd, primary),
         {:ok, entry} <-
           player_entry_for_grant(grant, locked.round.id, cmd.playing_group_id) do
      if primary.round_entry_id == entry.id do
        {:ok,
         Map.merge(ctx, %{
           round_entry_id: entry.id,
           assignment_id: primary.id,
           role_assignment_version: primary.assignment_version
         })}
      else
        {:error, :not_primary_scorer}
      end
    end
  end

  defp finalize_actor_context(_, _, _), do: {:error, :invalid_actor}

  defp lock_assignments(playing_group_id) do
    ids =
      Repo.query!(
        "SELECT id::text FROM group_role_assignments WHERE playing_group_id = $1::uuid AND state = 'active' ORDER BY id",
        [Ecto.UUID.dump!(playing_group_id)]
      ).rows
      |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end)

    case LockProtocol.acquire!(group_role_assignment: ids) do
      {:ok, %{acquired: acquired}} -> {:ok, Enum.map(acquired, & &1.row)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_grant(grant_id) do
    case Repo.query!(
           """
           SELECT id::text, event_id::text, player_id::text, state, expires_at
           FROM player_access_grants
           WHERE id = $1::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(grant_id)]
         ).rows do
      [[id, event_id, player_id, state, expires_at]] ->
        grant = %{
          id: Ecto.UUID.cast!(id),
          event_id: Ecto.UUID.cast!(event_id),
          player_id: Ecto.UUID.cast!(player_id),
          state: String.to_existing_atom(state),
          expires_at: expires_at
        }

        if PlayerAccessGrantGuard.grant_expired?(grant, DateTime.utc_now()) do
          {:error, :invalid_player_session}
        else
          {:ok, grant}
        end

      [] ->
        {:error, :invalid_player_session}
    end
  end

  defp grant_event_matches(%{event_id: grant_event}, event_id) do
    if grant_event == event_id, do: :ok, else: {:error, :invalid_player_session}
  end

  defp grant_usable(%{state: :active}), do: :ok
  defp grant_usable(_), do: {:error, :invalid_player_session}

  defp player_entry_for_grant(%{player_id: player_id}, round_id, playing_group_id) do
    case Repo.query!(
           """
           SELECT id::text FROM round_entries
           WHERE round_id = $1::uuid AND player_id = $2::uuid AND playing_group_id = $3::uuid
           """,
           [
             Ecto.UUID.dump!(round_id),
             Ecto.UUID.dump!(player_id),
             Ecto.UUID.dump!(playing_group_id)
           ]
         ).rows do
      [[id]] -> {:ok, %{id: Ecto.UUID.cast!(id)}}
      [] -> {:error, :player_not_in_group}
    end
  end

  defp authorize_staff(staff_id, event_id) do
    if ActiveEventRole.authorized?(staff_id, event_id, @staff_roles),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp active_primary_scorer(rows) do
    case Enum.find(rows, &(&1.role == "primary_scorer" and &1.state == "active")) do
      nil -> {:error, :no_active_primary_scorer}
      row -> {:ok, row}
    end
  end

  defp role_version_matches(%{role_assignment_version: nil}, _),
    do: {:error, :role_assignment_version_required}

  defp role_version_matches(%{role_assignment_version: version}, %{assignment_version: locked})
       when version == locked,
       do: :ok

  defp role_version_matches(_, _), do: {:error, :stale_role_assignment}

  defp lock_gameplay_scope(round_id, playing_group_id) do
    case LockProtocol.acquire!(round: [round_id], playing_group: [playing_group_id]) do
      {:ok, %{acquired: acquired}} ->
        round = Enum.find(acquired, &(&1.class == :round)).row
        group = Enum.find(acquired, &(&1.class == :playing_group)).row
        route = load_route_holes(round_id)
        {:ok, %{round: normalize_round(round), group: normalize_group(group), route_holes: route}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_round(row) do
    %{
      id: row.id,
      event_id: row.event_id,
      state: row.state
    }
  end

  defp normalize_group(row) do
    %{
      id: row.id,
      round_id: row.round_id,
      state: to_existing_atom(row.state),
      scoring_revision: row.scoring_revision,
      starting_round_hole_id: row.starting_round_hole_id
    }
  end

  defp load_route_holes(round_id) do
    Repo.query!(
      "SELECT id::text, play_order::int FROM round_holes WHERE round_id = $1::uuid ORDER BY play_order",
      [Ecto.UUID.dump!(round_id)]
    ).rows
    |> Enum.map(fn [id, play_order] -> %{id: Ecto.UUID.cast!(id), play_order: play_order} end)
  end

  defp validate_round(%{event_id: round_event, state: state}, event_id) do
    cond do
      round_event != event_id ->
        {:error, :event_mismatch}

      state != "scoring_open" and state != :scoring_open ->
        {:error, {:invalid_round_state, state}}

      true ->
        :ok
    end
  end

  defp validate_group_for_new_submission(%{round_id: group_round, state: state}, round_id) do
    cond do
      group_round != round_id ->
        {:error, :playing_group_mismatch}

      state in [:attention_required, :finished_playing, "attention_required", "finished_playing"] ->
        {:error, {:invalid_group_state, state}}

      state in [:not_started, :playing, "not_started", "playing"] ->
        :ok

      true ->
        {:error, {:invalid_group_state, state}}
    end
  end

  defp derive_expected_hole(group, route_holes) do
    with {:ok, start_id} <- require_start_hole(group.starting_round_hole_id),
         true <- length(route_holes) == @scheduled_holes,
         {:ok, hole_id} <- expected_hole_id(route_holes, start_id, group.scoring_revision) do
      {:ok, hole_id}
    else
      false -> {:error, :invalid_round_route}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_start_hole(nil), do: {:error, :starting_hole_not_assigned}
  defp require_start_hole(id), do: {:ok, id}

  defp expected_hole_id(_route_holes, _start_id, scoring_revision)
       when scoring_revision >= @scheduled_holes do
    {:error, :group_scoring_complete}
  end

  defp expected_hole_id(route_holes, start_id, scoring_revision) do
    start_index = Enum.find_index(route_holes, &(&1.id == start_id))

    if is_nil(start_index) do
      {:error, :starting_hole_not_in_route}
    else
      rotated = rotate_route(route_holes, start_index)
      hole = Enum.at(rotated, scoring_revision)
      {:ok, hole.id}
    end
  end

  defp rotate_route(route_holes, start_index) do
    {head, tail} = Enum.split(route_holes, start_index)
    tail ++ head
  end

  defp require_revision_match(%{expected_group_score_revision: expected}, %{
         scoring_revision: actual
       })
       when expected == actual,
       do: :ok

  defp require_revision_match(_, _), do: {:error, :stale_scoring_revision}

  defp require_hole_match(%{round_hole_id: claimed}, expected) when claimed == expected, do: :ok
  defp require_hole_match(_, _), do: {:error, :wrong_round_hole}

  defp lock_required_entries(playing_group_id) do
    rows =
      Repo.query!(
        """
        SELECT id::text, event_id::text, round_id::text, player_id::text,
               registration_status, participation_status, playing_group_id::text,
               round_tee_profile_snapshot_id::text
        FROM round_entries
        WHERE playing_group_id = $1::uuid
          AND registration_status = ANY($2::text[])
          AND participation_status = ANY($3::text[])
        ORDER BY id
        FOR UPDATE
        """,
        [
          Ecto.UUID.dump!(playing_group_id),
          @required_registration,
          @required_participation
        ]
      ).rows

    entries =
      Enum.map(rows, fn [
                          id,
                          event_id,
                          round_id,
                          player_id,
                          registration_status,
                          participation_status,
                          group_id,
                          tee_snapshot_id
                        ] ->
        %{
          id: Ecto.UUID.cast!(id),
          event_id: Ecto.UUID.cast!(event_id),
          round_id: Ecto.UUID.cast!(round_id),
          player_id: Ecto.UUID.cast!(player_id),
          registration_status: String.to_existing_atom(registration_status),
          participation_status: String.to_existing_atom(participation_status),
          playing_group_id: Ecto.UUID.cast!(group_id),
          round_tee_profile_snapshot_id: cast_optional_uuid(tee_snapshot_id)
        }
      end)

    if entries == [] do
      {:error, :no_required_participants}
    else
      {:ok, entries}
    end
  end

  defp cast_optional_uuid(nil), do: nil

  defp cast_optional_uuid(value) do
    {:ok, uuid} = Ecto.UUID.cast(value)
    uuid
  end

  defp validate_results_set(entries, results) when is_list(results) do
    entry_ids = Enum.map(entries, & &1.id) |> MapSet.new()
    result_ids = Enum.map(results, & &1.round_entry_id)

    cond do
      duplicate?(result_ids) ->
        {:error, :duplicate_result_entry}

      length(results) != length(entries) ->
        {:error, :results_count_mismatch}

      MapSet.new(result_ids) != entry_ids ->
        {:error, :results_participant_mismatch}

      Enum.any?(results, &invalid_result_shape?/1) ->
        {:error, :invalid_result}

      true ->
        :ok
    end
  end

  defp validate_results_set(_, _), do: {:error, :invalid_results}

  defp duplicate?(ids), do: length(ids) != length(Enum.uniq(ids))

  defp invalid_result_shape?(%{round_entry_id: id, outcome: outcome})
       when not is_nil(id) and outcome in [:holed_out, :picked_up, "holed_out", "picked_up"],
       do: false

  defp invalid_result_shape?(_), do: true

  defp validate_outcomes(entries, cmd, round_hole_id, round_id) do
    case load_primary_competition(round_id) do
      {:ok, competition} ->
        validate_all_outcomes(entries, cmd, round_hole_id, competition)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_all_outcomes(entries, cmd, round_hole_id, competition) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      result = Enum.find(cmd.results, &(&1.round_entry_id == entry.id))

      case validate_one_outcome(entry, result, round_hole_id, competition) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp load_primary_competition(round_id) do
    rows =
      Repo.query!(
        """
        SELECT id::text, pickup_policy_identifier
        FROM round_competitions
        WHERE round_id = $1::uuid AND is_primary = true
        """,
        [Ecto.UUID.dump!(round_id)]
      ).rows

    case rows do
      [[id, policy]] -> {:ok, %{id: Ecto.UUID.cast!(id), pickup_policy_identifier: policy}}
      [] -> {:error, :primary_round_competition_missing}
      _ -> {:error, :ambiguous_primary_round_competition}
    end
  end

  defp validate_one_outcome(entry, result, round_hole_id, competition) do
    outcome = normalize_outcome(result.outcome)

    case outcome do
      :holed_out ->
        if is_integer(result.gross_strokes) and result.gross_strokes >= 1 do
          :ok
        else
          {:error, :invalid_gross_strokes}
        end

      :picked_up ->
        if is_nil(result.gross_strokes) do
          validate_pickup(entry, result, round_hole_id, competition)
        else
          {:error, :picked_up_with_gross}
        end
    end
  end

  defp normalize_outcome(atom) when is_atom(atom), do: atom
  defp normalize_outcome("holed_out"), do: :holed_out
  defp normalize_outcome("picked_up"), do: :picked_up

  defp validate_pickup(entry, result, round_hole_id, competition) do
    with {:ok, playing_handicap} <- load_playing_handicap(entry.id, competition.id),
         {:ok, hole_facts} <- load_tee_hole_facts(entry.round_tee_profile_snapshot_id),
         {:ok, %{strokes_by_round_hole_id: strokes}} <-
           StrokeAllocation.allocate(playing_handicap, hole_facts),
         allocated when is_integer(allocated) <- Map.get(strokes, round_hole_id),
         par when is_integer(par) <- par_for_hole(hole_facts, round_hole_id),
         strokes_taken when is_integer(strokes_taken) <- Map.get(result, :strokes_taken) do
      PickupEligibility.decide(%{
        pickup_policy_identifier: competition.pickup_policy_identifier,
        par: par,
        allocated_strokes: allocated,
        strokes_taken: strokes_taken
      })
      |> case do
        {:ok, %{eligible?: true}} -> :ok
        {:ok, %{eligible?: false}} -> {:error, :pickup_not_eligible}
        {:error, :unsupported_pickup_policy} -> {:error, :unsupported_pickup_policy}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :strokes_taken_required}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :pickup_validation_failed}
    end
  end

  defp par_for_hole(hole_facts, round_hole_id) do
    case Enum.find(hole_facts, &(&1.round_hole_id == round_hole_id)) do
      %{par: par} -> par
      _ -> nil
    end
  end

  defp load_playing_handicap(entry_id, competition_id) do
    case Repo.query!(
           """
           SELECT playing_handicap::int FROM competition_handicaps
           WHERE round_entry_id = $1::uuid AND round_competition_id = $2::uuid
           """,
           [Ecto.UUID.dump!(entry_id), Ecto.UUID.dump!(competition_id)]
         ).rows do
      [[hi]] -> {:ok, hi}
      [] -> {:error, :competition_handicap_missing}
    end
  end

  defp load_tee_hole_facts(nil), do: {:error, :tee_not_assigned}

  defp load_tee_hole_facts(snapshot_id) do
    holes =
      Repo.query!(
        """
        SELECT round_hole_id::text, par::int, stroke_index::int, plus_stroke_order::int
        FROM round_tee_hole_snapshots
        WHERE round_tee_profile_snapshot_id = $1::uuid
        ORDER BY round_hole_id
        """,
        [Ecto.UUID.dump!(snapshot_id)]
      ).rows
      |> Enum.map(fn [round_hole_id, par, stroke_index, plus_stroke_order] ->
        %{
          round_hole_id: Ecto.UUID.cast!(round_hole_id),
          par: par,
          stroke_index: stroke_index,
          plus_stroke_order: plus_stroke_order
        }
      end)

    if length(holes) == 18 do
      {:ok, holes}
    else
      {:error, :invalid_hole_set}
    end
  end

  defp confirm_no_conflicting_hole_results(scorecards, round_hole_id) do
    scorecard_ids = Enum.map(scorecards, & &1.id)

    count =
      Repo.query!(
        """
        SELECT count(*)::int
        FROM hole_results
        WHERE round_hole_id = $1::uuid AND scorecard_id = ANY($2::uuid[])
        """,
        [Ecto.UUID.dump!(round_hole_id), Enum.map(scorecard_ids, &Ecto.UUID.dump!/1)]
      ).rows
      |> hd()
      |> hd()

    if count == 0, do: :ok, else: {:error, :hole_result_conflict}
  end

  defp ensure_and_lock_scorecards(entries, round_id) do
    cards =
      Enum.map(entries, fn entry ->
        case Repo.query!(
               "SELECT id::text FROM scorecards WHERE round_entry_id = $1::uuid",
               [Ecto.UUID.dump!(entry.id)]
             ).rows do
          [[id]] ->
            %{id: Ecto.UUID.cast!(id), round_entry_id: entry.id}

          [] ->
            create_scorecard!(round_id, entry.id)
        end
      end)

    ids = Enum.map(cards, & &1.id)

    case LockProtocol.acquire!(score_row: ids) do
      {:ok, %{acquired: acquired}} ->
        locked =
          Enum.map(acquired, fn %{row: row} ->
            %{
              id: row.id,
              round_entry_id: row.round_entry_id,
              state: row.state
            }
          end)

        {:ok, locked}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_scorecard!(round_id, round_entry_id) do
    Scorecard
    |> Changeset.for_create(:create_internal, %{
      round_id: round_id,
      round_entry_id: round_entry_id
    })
    |> Ash.create!(authorize?: false)
    |> then(&%{id: &1.id, round_entry_id: &1.round_entry_id})
  end

  defp payload_fingerprint(cmd, actor_ctx) do
    cmd
    |> canonical_fingerprint_term(actor_ctx)
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp canonical_fingerprint_term(cmd, actor_ctx) do
    {
      cmd.playing_group_id,
      cmd.round_hole_id,
      cmd.expected_group_score_revision,
      canonical_role_assignment_version(cmd, actor_ctx),
      DateTime.to_unix(cmd.captured_at, :microsecond),
      canonical_actor_term(actor_ctx),
      canonical_sorted_results(cmd.results)
    }
  end

  defp canonical_role_assignment_version(%{role_assignment_version: version}, %{kind: :player})
       when is_integer(version),
       do: version

  defp canonical_role_assignment_version(_, %{kind: :staff}), do: nil

  defp canonical_actor_term(%{kind: :staff, staff_id: id}), do: {:staff, id}

  defp canonical_actor_term(%{
         kind: :player,
         round_entry_id: entry_id,
         role_assignment_version: version
       }),
       do: {:player, entry_id, version}

  defp canonical_sorted_results(results) do
    results
    |> Enum.map(fn result ->
      {
        result.round_entry_id,
        normalize_outcome(result.outcome),
        result.gross_strokes,
        Map.get(result, :strokes_taken)
      }
    end)
    |> Enum.sort_by(fn {entry_id, _, _, _} -> entry_id end)
  end

  defp semantic_payload_map(cmd, actor_ctx) do
    %{
      playing_group_id: cmd.playing_group_id,
      round_hole_id: cmd.round_hole_id,
      expected_group_score_revision: cmd.expected_group_score_revision,
      role_assignment_version: Map.get(cmd, :role_assignment_version),
      captured_at: DateTime.to_iso8601(cmd.captured_at),
      actor: semantic_actor(actor_ctx),
      results: semantic_results(cmd.results)
    }
  end

  defp semantic_actor(%{kind: :staff, staff_id: id}), do: %{type: "staff", staff_user_id: id}

  defp semantic_actor(%{
         kind: :player,
         round_entry_id: entry_id,
         role_assignment_version: version
       }) do
    %{type: "player", round_entry_id: entry_id, role_assignment_version: version}
  end

  defp semantic_results(results) do
    results
    |> Enum.map(fn result ->
      %{
        round_entry_id: result.round_entry_id,
        outcome: to_string(normalize_outcome(result.outcome)),
        gross_strokes: result.gross_strokes,
        strokes_taken: Map.get(result, :strokes_taken)
      }
    end)
    |> Enum.sort_by(& &1.round_entry_id)
  end

  defp normalize_command(command) do
    with {:ok, client_submission_id} <-
           fetch_uuid(command, "client_submission_id", :client_submission_id),
         {:ok, playing_group_id} <- fetch_uuid(command, "playing_group_id", :playing_group_id),
         {:ok, round_hole_id} <- fetch_uuid(command, "round_hole_id", :round_hole_id),
         {:ok, expected_group_score_revision} <-
           fetch_int(command, "expected_group_score_revision", :expected_group_score_revision),
         {:ok, captured_at} <- fetch_datetime(command, "captured_at", :captured_at),
         {:ok, results} <-
           normalize_results(Map.get(command, "results") || Map.get(command, :results)) do
      role_assignment_version =
        Map.get(command, "role_assignment_version") || Map.get(command, :role_assignment_version)

      {:ok,
       %{
         client_submission_id: client_submission_id,
         playing_group_id: playing_group_id,
         round_hole_id: round_hole_id,
         expected_group_score_revision: expected_group_score_revision,
         role_assignment_version: role_assignment_version,
         captured_at: captured_at,
         results: results
       }}
    end
  end

  defp normalize_results(results) when is_list(results) do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, acc} ->
      case normalize_result(result) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_results(_), do: {:error, :invalid_results}

  defp normalize_result(result) when is_map(result) do
    with {:ok, round_entry_id} <- fetch_uuid(result, "round_entry_id", :round_entry_id) do
      outcome = Map.get(result, "outcome") || Map.get(result, :outcome)
      gross = Map.get(result, "gross_strokes") || Map.get(result, :gross_strokes)
      strokes_taken = Map.get(result, "strokes_taken") || Map.get(result, :strokes_taken)

      {:ok,
       %{
         round_entry_id: round_entry_id,
         outcome: outcome,
         gross_strokes: gross,
         strokes_taken: strokes_taken
       }}
    end
  end

  defp normalize_result(_), do: {:error, :invalid_result}

  defp fetch_uuid(map, string_key, atom_key) do
    value = Map.get(map, string_key) || Map.get(map, atom_key)

    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_input}
    end
  end

  defp fetch_int(map, string_key, atom_key) do
    case Map.get(map, string_key) || Map.get(map, atom_key) do
      int when is_integer(int) -> {:ok, int}
      _ -> {:error, :invalid_input}
    end
  end

  defp fetch_datetime(map, string_key, atom_key) do
    case Map.get(map, string_key) || Map.get(map, atom_key) do
      %DateTime{} = dt -> {:ok, dt}
      _ -> {:error, :invalid_input}
    end
  end

  defp to_existing_atom(value) when is_atom(value), do: value

  defp to_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end
end

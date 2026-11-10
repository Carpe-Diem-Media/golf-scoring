defmodule GolfScoring.Competition.Services.ExcludeCompetitionSideBeforeHole do
  @moduledoc """
  Records an authorized, audited CompetitionSide exclusion at a positively attested pre-play hole.

  The transition writes only `provisional → excluded` on the existing CompetitionSideResult.
  It keeps the original side membership, rejects checkpoints already passed by accepted play,
  and rechecks affected Mystery rules in the same transaction. The public service result contains
  only the result ID and whether this transaction created a reveal. The Mystery rule remains
  private.
  """

  alias Ash.Changeset
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Audit
  alias GolfScoring.Competition.CompetitionSideResult
  alias GolfScoring.Competition.Services.MysteryRevealCoordinator
  alias GolfScoring.LockProtocol
  alias GolfScoring.Repo

  @manager_roles [:event_admin, :competition_manager]
  @scheduled_holes 18
  @gate_key {__MODULE__, :exclusion_gate}
  @mystery_gate_key {__MODULE__, :mystery_recheck}

  @type result :: %{side_result_id: Ecto.UUID.t(), mystery_reveal_created?: boolean()}

  @spec run(map(), term(), term(), term(), term(), term(), term(), map()) ::
          {:ok, result()} | {:error, term()}
  def run(
        actor,
        event_id,
        round_id,
        round_competition_id,
        side_id,
        playing_group_id,
        effective_from_round_hole_id,
        attrs
      )
      when is_map(actor) and is_map(attrs) do
    with {:ok, actor_id} <- Ecto.UUID.cast(Map.get(actor, :id)),
         {:ok, event_id} <- Ecto.UUID.cast(event_id),
         {:ok, round_id} <- Ecto.UUID.cast(round_id),
         {:ok, round_competition_id} <- Ecto.UUID.cast(round_competition_id),
         {:ok, side_id} <- Ecto.UUID.cast(side_id),
         {:ok, playing_group_id} <- Ecto.UUID.cast(playing_group_id),
         {:ok, effective_hole_id} <- Ecto.UUID.cast(effective_from_round_hole_id),
         {:ok, reason} <- normalize_reason(Map.get(attrs, :reason)),
         :ok <- require_preplay_attestation(Map.get(attrs, :confirm_hole_unplayed?)),
         :ok <- require_commit_boundary() do
      run_transaction(
        actor_id,
        event_id,
        round_id,
        round_competition_id,
        side_id,
        playing_group_id,
        effective_hole_id,
        reason
      )
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_input}
    end
  end

  def run(
        _actor,
        _event_id,
        _round_id,
        _round_competition_id,
        _side_id,
        _playing_group_id,
        _effective_from_round_hole_id,
        _attrs
      ),
      do: {:error, :invalid_input}

  @doc false
  def verified_exclusion?(context, result_id, side_id) do
    gate = Process.get(@gate_key)
    proof = Map.get(context || %{}, :competition_side_result_exclusion)

    Repo.in_transaction?() and is_map(gate) and is_map(proof) and
      is_reference(gate.token) and gate == proof and gate.operation == :exclude_before_hole and
      gate.result_id == result_id and gate.side_id == side_id
  end

  defp normalize_reason(reason) when is_binary(reason) do
    trimmed = String.trim(reason)
    if trimmed == "", do: {:error, :exclusion_reason_required}, else: {:ok, trimmed}
  end

  defp normalize_reason(_), do: {:error, :exclusion_reason_required}

  defp require_preplay_attestation(true), do: :ok
  defp require_preplay_attestation(_), do: {:error, :preplay_attestation_required}

  defp require_commit_boundary do
    if Repo.in_transaction?(),
      do: {:error, :transaction_already_open},
      else: :ok
  end

  defp run_transaction(
         actor_id,
         event_id,
         round_id,
         round_competition_id,
         side_id,
         playing_group_id,
         effective_hole_id,
         reason
       ) do
    result =
      Repo.transaction(fn ->
        case exclude_locked(
               actor_id,
               event_id,
               round_id,
               round_competition_id,
               side_id,
               playing_group_id,
               effective_hole_id,
               reason
             ) do
          {:ok, outcome} -> outcome
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, %{side_result_id: result_id, mystery_reveal_created?: true} = outcome} ->
        broadcast_mystery_reveal_changed(round_id)
        {:ok, Map.put(outcome, :side_result_id, result_id)}

      {:ok, outcome} ->
        {:ok, outcome}

      {:error, reason} ->
        {:error, reason}

      {:error, :rollback, reason} ->
        {:error, reason}
    end
  end

  defp exclude_locked(
         actor_id,
         event_id,
         round_id,
         round_competition_id,
         side_id,
         playing_group_id,
         effective_hole_id,
         reason
       ) do
    with {:ok, _scope} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
         :ok <- authorize(actor_id, event_id),
         {:ok, locked} <- lock_gameplay_scope(round_id, playing_group_id, side_id),
         :ok <- validate_scope(locked, event_id, round_id, round_competition_id, playing_group_id),
         {:ok, route} <- load_route(locked.group, round_id),
         {:ok, effective_index} <- effective_index(route, effective_hole_id),
         :ok <- validate_group_progress(locked.group, effective_index),
         :ok <-
           reject_accepted_play_after_checkpoint(
             round_id,
             playing_group_id,
             route,
             effective_index
           ),
         {:ok, side_result} <- ensure_provisional_result(side_id),
         {:ok, locked_result} <- lock_side_result(side_result.id, side_id),
         :ok <- require_provisional(locked_result),
         {:ok, excluded} <-
           persist_exclusion(
             locked_result,
             actor_id,
             side_id,
             playing_group_id,
             effective_hole_id,
             effective_index,
             reason
           ),
         :ok <-
           write_audit(%{
             actor_id: actor_id,
             event_id: event_id,
             round_id: round_id,
             round_competition_id: round_competition_id,
             side_id: side_id,
             playing_group_id: playing_group_id,
             effective_hole_id: effective_hole_id,
             effective_index: effective_index,
             reason: reason,
             result_id: excluded.id
           }),
         {:ok, reveal_result} <-
           recheck_affected_rules(round_id, round_competition_id, route, effective_index, %{
             actor_id: actor_id,
             event_id: event_id,
             group_id: playing_group_id,
             side_id: side_id,
             result_id: locked_result.id
           }) do
      {:ok,
       %{
         side_result_id: excluded.id,
         mystery_reveal_created?: reveal_result.created?
       }}
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

  defp validate_scope(locked, event_id, round_id, round_competition_id, playing_group_id) do
    cond do
      locked.round.event_id != event_id ->
        {:error, :event_mismatch}

      locked.round.state not in ["scoring_open", :scoring_open] ->
        {:error, {:invalid_round_state, locked.round.state}}

      locked.group.round_id != round_id ->
        {:error, :playing_group_mismatch}

      locked.side.round_id != round_id ->
        {:error, :competition_side_mismatch}

      locked.side.round_competition_id != round_competition_id ->
        {:error, :competition_mismatch}

      true ->
        validate_competition_and_membership(
          event_id,
          round_id,
          round_competition_id,
          locked.side.id,
          playing_group_id
        )
    end
  end

  defp validate_competition_and_membership(
         event_id,
         round_id,
         round_competition_id,
         side_id,
         playing_group_id
       ) do
    case Repo.query!(
           "SELECT event_id::text, round_id::text FROM round_competitions WHERE id = $1::uuid",
           [Ecto.UUID.dump!(round_competition_id)]
         ).rows do
      [[competition_event_id, competition_round_id]] ->
        if Ecto.UUID.cast!(competition_event_id) == event_id and
             Ecto.UUID.cast!(competition_round_id) == round_id do
          validate_side_memberships(round_id, round_competition_id, side_id, playing_group_id)
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

      Enum.any?(rows, fn [membership_round, membership_competition, entry_round, group_id] ->
        Ecto.UUID.cast!(membership_round) != round_id or
          Ecto.UUID.cast!(membership_competition) != round_competition_id or
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

    expected_orders = Enum.to_list(1..@scheduled_holes)
    actual_orders = Enum.map(holes, & &1.play_order)

    cond do
      length(holes) != @scheduled_holes or actual_orders != expected_orders ->
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

      state in ["finished_playing", :finished_playing] ->
        {:error, :preplay_checkpoint_already_passed}

      state not in ["not_started", :not_started, "playing", :playing] ->
        {:error, {:invalid_group_state, state}}

      revision > effective_index ->
        {:error, :preplay_checkpoint_already_passed}

      true ->
        :ok
    end
  end

  defp reject_accepted_play_after_checkpoint(round_id, playing_group_id, route, effective_index) do
    future_hole_ids =
      route
      |> Enum.drop(effective_index)
      |> Enum.map(&Ecto.UUID.dump!(&1.id))

    submission_count =
      Repo.query!(
        """
        SELECT count(*)::int
        FROM hole_submissions
        WHERE round_id = $1::uuid
          AND playing_group_id = $2::uuid
          AND round_hole_id = ANY($3::uuid[])
        """,
        [Ecto.UUID.dump!(round_id), Ecto.UUID.dump!(playing_group_id), future_hole_ids]
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
        WHERE re.playing_group_id = $1::uuid
          AND hr.round_id = $2::uuid
          AND hr.round_hole_id = ANY($3::uuid[])
        """,
        [Ecto.UUID.dump!(playing_group_id), Ecto.UUID.dump!(round_id), future_hole_ids]
      ).rows
      |> hd()
      |> hd()

    if submission_count == 0 and result_count == 0,
      do: :ok,
      else: {:error, :preplay_checkpoint_already_passed}
  end

  defp ensure_provisional_result(side_id) do
    case Repo.query!(
           "SELECT id::text FROM competition_side_results WHERE competition_side_id = $1::uuid",
           [Ecto.UUID.dump!(side_id)]
         ).rows do
      [[id]] ->
        {:ok, %{id: Ecto.UUID.cast!(id)}}

      [] ->
        CompetitionSideResult
        |> Changeset.for_create(:create_provisional_internal, %{competition_side_id: side_id})
        |> Ash.create(authorize?: false)
        |> case do
          {:ok, result} -> {:ok, %{id: result.id}}
          {:error, error} -> {:error, error}
        end
    end
  end

  defp lock_side_result(result_id, side_id) do
    case LockProtocol.acquire!(competition_side_result: [result_id]) do
      {:ok, %{acquired: [%{row: %{competition_side_id: ^side_id} = row}]}} ->
        {:ok, row}

      {:ok, _} ->
        {:error, :competition_side_result_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_provisional(%{state: state}) when state in ["provisional", :provisional], do: :ok
  defp require_provisional(%{state: "excluded"}), do: {:error, :competition_side_already_excluded}
  defp require_provisional(_), do: {:error, :competition_side_result_terminal}

  defp persist_exclusion(
         locked_result,
         actor_id,
         side_id,
         playing_group_id,
         effective_hole_id,
         effective_index,
         reason
       ) do
    [[excluded_at]] = Repo.query!("SELECT clock_timestamp()").rows
    token = make_ref()

    proof = %{
      operation: :exclude_before_hole,
      result_id: locked_result.id,
      side_id: side_id,
      token: token,
      actor_id: actor_id,
      reason: reason,
      excluded_at: excluded_at,
      playing_group_id: playing_group_id,
      effective_round_hole_id: effective_hole_id,
      effective_play_index: effective_index,
      preplay_confirmed?: true
    }

    previous = Process.put(@gate_key, proof)

    try do
      CompetitionSideResult
      |> Ash.get!(locked_result.id, authorize?: false)
      |> Changeset.for_update(:exclude_before_hole_internal, %{})
      |> Changeset.set_context(%{competition_side_result_exclusion: proof})
      |> Ash.update(authorize?: false)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, error} -> {:error, error}
      end
    after
      if previous,
        do: Process.put(@gate_key, previous),
        else: Process.delete(@gate_key)
    end
  end

  defp write_audit(%{
         actor_id: actor_id,
         event_id: event_id,
         round_id: round_id,
         round_competition_id: round_competition_id,
         side_id: side_id,
         playing_group_id: playing_group_id,
         effective_hole_id: effective_hole_id,
         effective_index: effective_index,
         reason: reason,
         result_id: result_id
       }) do
    attrs = %{
      actor_staff_user_id: actor_id,
      action: "exclude_competition_side_before_hole",
      target_type: "CompetitionSideResult",
      target_id: result_id,
      reason: reason,
      context: %{
        event_id: event_id,
        round_id: round_id,
        round_competition_id: round_competition_id,
        competition_side_id: side_id,
        playing_group_id: playing_group_id,
        effective_round_hole_id: effective_hole_id,
        effective_play_index: effective_index,
        confirm_hole_unplayed: true
      }
    }

    case Audit.record_staff_event(attrs, authorize?: false) do
      {:ok, _audit} -> :ok
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
        WHERE mhr.round_id = $1::uuid
          AND st.round_competition_id = $2::uuid
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
          operation: :exclude_before_hole,
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
         persisted_mystery_exclusion?(gate) do
      Process.put(@mystery_gate_key, %{gate | used?: true})
      :ok
    else
      {:error, :unauthorized_mystery_recheck}
    end
  end

  defp persisted_mystery_exclusion?(gate) do
    Repo.query!(
      """
      SELECT 1 FROM competition_side_results csr
      JOIN competition_sides cs ON cs.id = csr.competition_side_id
      JOIN rounds r ON r.id = cs.round_id
      WHERE csr.id = $1::uuid AND cs.id = $2::uuid AND r.id = $3::uuid
        AND r.event_id = $4::uuid AND cs.round_competition_id = $5::uuid
        AND csr.state = 'excluded' AND csr.excluded_playing_group_id = $6::uuid
        AND csr.excluded_effective_play_index = $7 AND csr.excluded_preplay_confirmed
        AND EXISTS (SELECT 1 FROM audit_events a WHERE a.target_id = csr.id
                    AND a.action = 'exclude_competition_side_before_hole'
                    AND a.actor_staff_user_id = $8::uuid)
      """,
      [
        Ecto.UUID.dump!(gate.result_id),
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

  defp mystery_transaction_id,
    do: Repo.query!("SELECT pg_current_xact_id()::text").rows |> hd() |> hd()

  defp broadcast_mystery_reveal_changed(round_id) do
    Phoenix.PubSub.broadcast(
      GolfScoring.PubSub,
      "round:#{round_id}",
      {:mystery_reveal_changed, %{round_id: round_id}}
    )
  end
end

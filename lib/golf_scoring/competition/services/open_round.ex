defmodule GolfScoring.Competition.Services.OpenRound do
  @moduledoc false

  require Ash.Query
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock

  alias GolfScoring.Competition.{
    CompetitionSide,
    CompetitionSideMembership,
    GroupRoleAssignment,
    MysteryHoleRule,
    Player,
    PlayingGroup,
    Round,
    RoundCompetition,
    RoundEntry,
    RoundHole,
    RoundTeeHoleSnapshot,
    RoundTeeProfileSnapshot,
    ScoringTrack
  }

  alias GolfScoring.Competition.Policies.RoundOpening
  alias GolfScoring.Competition.Services.LockScoringTracksForRound
  alias GolfScoring.{LockProtocol, Repo}
  alias GolfScoring.Scoring.{CompetitionHandicap, HandicapSnapshot}

  def mark_ready(actor, event_id, round_id),
    do: execute(actor, event_id, round_id, :mark_round_ready)

  def run(actor, event_id, round_id), do: execute(actor, event_id, round_id, :open_scoring)

  defp execute(%{id: actor_id}, event_id, round_id, operation) do
    with {:ok, actor_id} <- Ecto.UUID.cast(actor_id),
         {:ok, event_id} <- Ecto.UUID.cast(event_id),
         {:ok, round_id} <- Ecto.UUID.cast(round_id) do
      Repo.transaction(fn -> execute_locked(actor_id, event_id, round_id, operation) end)
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp execute(_, _, _, _), do: {:error, :invalid_input}

  defp execute_locked(actor_id, event_id, round_id, operation) do
    with {:ok, _} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
         :ok <- authorize(actor_id, event_id),
         {:ok, %{acquired: [%{row: round}]}} <- LockProtocol.acquire!(round: [round_id]),
         :ok <- check_round(round, event_id, operation),
         :ok <- lock_children(round_id),
         facts <- load_facts(round_id, event_id),
         %{blockers: blockers, warnings: warnings} <- RoundOpening.evaluate(facts),
         :ok <- require_clear(blockers, warnings),
         :ok <- freeze_if_open(operation, round_id, event_id) do
      transition(actor_id, round_id, operation, warnings)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc false
  def verified_gate?(context, round_id, operation) do
    Repo.in_transaction?() and
      Map.get(context, :round_opening_gate) == Process.get({__MODULE__, :gate}) and
      match?(
        %{round_id: ^round_id, operation: ^operation, token: token} when is_reference(token),
        Map.get(context, :round_opening_gate)
      )
  end

  defp transition(actor_id, round_id, operation, warnings) do
    proof = %{round_id: round_id, operation: operation, token: make_ref()}
    previous = Process.put({__MODULE__, :gate}, proof)

    try do
      actor = Repo.get!(GolfScoring.Accounts.StaffUser, actor_id)

      changeset =
        Repo.get!(Round, round_id)
        |> Ash.Changeset.for_update(operation, %{}, actor: actor)
        |> Ash.Changeset.set_context(%{round_opening_gate: proof})

      case Ash.update(changeset) do
        {:ok, round} -> %{round: round, warnings: warnings}
        {:error, error} -> Repo.rollback(error)
      end
    after
      if previous,
        do: Process.put({__MODULE__, :gate}, previous),
        else: Process.delete({__MODULE__, :gate})
    end
  end

  defp authorize(actor_id, event_id) do
    if ActiveEventRole.authorized?(actor_id, event_id, [:event_admin, :competition_manager]),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp check_round(%{event_id: event_id, state: state}, event_id, operation) do
    required = if operation == :mark_round_ready, do: "draft", else: "ready"
    if state == required, do: :ok, else: {:error, {:invalid_round_state, state}}
  end

  defp check_round(_, _, _), do: {:error, :event_mismatch}

  defp freeze_if_open(:mark_round_ready, _round_id, _event_id), do: :ok

  defp freeze_if_open(:open_scoring, round_id, event_id) do
    with :ok <- LockScoringTracksForRound.run(round_id),
         facts <- load_facts(round_id, event_id),
         %{blockers: blockers, warnings: warnings} <- RoundOpening.evaluate(facts),
         :ok <- require_clear(blockers, warnings),
         true <-
           length(facts.tracks) == 2 and
             Enum.all?(facts.tracks, &(&1.configuration_state == :locked)) do
      :ok
    else
      false -> {:error, :track_freeze_failed}
      {:error, _} = error -> error
    end
  end

  defp require_clear([], _warnings), do: :ok

  defp require_clear(blockers, warnings),
    do: {:error, {:round_opening_blocked, blockers, warnings}}

  defp lock_children(round_id) do
    requests = [
      playing_group: ids(PlayingGroup, round_id),
      group_role_assignment: ids(GroupRoleAssignment, round_id),
      competition_side: ids(CompetitionSide, round_id),
      mystery_hole_rule: ids(MysteryHoleRule, round_id)
    ]

    case LockProtocol.acquire!(requests) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ids(resource, round_id), do: Enum.map(load_round(resource, round_id), & &1.id)

  defp load_round(resource, round_id) do
    resource |> Ash.Query.filter(round_id == ^round_id) |> Ash.read!(authorize?: false)
  end

  defp load_facts(round_id, event_id) do
    entries = load_round(RoundEntry, round_id)
    player_ids = Enum.map(entries, & &1.player_id)
    players = Player |> Ash.Query.filter(id in ^player_ids) |> Ash.read!(authorize?: false)

    %{
      round: Repo.get!(Round, round_id),
      event_id: event_id,
      holes: load_round(RoundHole, round_id),
      entries: entries,
      players: players,
      groups: load_round(PlayingGroup, round_id),
      roles: load_round(GroupRoleAssignment, round_id),
      competitions: load_round(RoundCompetition, round_id),
      sides: load_round(CompetitionSide, round_id),
      memberships: load_round(CompetitionSideMembership, round_id),
      tracks: load_round(ScoringTrack, round_id),
      rules: load_round(MysteryHoleRule, round_id),
      tees: load_round(RoundTeeProfileSnapshot, round_id),
      tee_holes: load_round(RoundTeeHoleSnapshot, round_id),
      handicaps: load_round(HandicapSnapshot, round_id),
      competition_handicaps: load_round(CompetitionHandicap, round_id)
    }
  end
end

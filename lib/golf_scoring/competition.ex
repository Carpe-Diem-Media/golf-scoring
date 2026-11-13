defmodule GolfScoring.Competition do
  @moduledoc "Competition and Event lifecycle domain."

  use Ash.Domain

  alias GolfScoring.Competition.Services.AcceptCompetitionSideRetirement
  alias GolfScoring.Competition.Services.AcceptRoundEntryWithdrawal
  alias GolfScoring.Competition.Services.AssignGroupRole
  alias GolfScoring.Competition.Services.AssignRoundTee
  alias GolfScoring.Competition.Services.ConfigureMysteryHoleRule
  alias GolfScoring.Competition.Services.ConfigureRoundCompetition
  alias GolfScoring.Competition.Services.ConfigureScoringTrack
  alias GolfScoring.Competition.Services.CreateCompetitionSide
  alias GolfScoring.Competition.Services.HandoverGroupRole
  alias GolfScoring.Competition.Services.OpenRound
  alias GolfScoring.Competition.Services.RevokeGroupRole
  alias GolfScoring.Competition.Services.SetSideMembership

  resources do
    resource GolfScoring.Competition.Event do
      define :cancel_event, action: :cancel_event
      define :archive_event, action: :archive_event
    end

    resource GolfScoring.Competition.Round do
      define :create_round, action: :create_round, args: [:event_id, :course_id]
      define :get_round_by_id, action: :read, get_by: [:id]
      define :close_scoring, action: :close_scoring
      define :finalize_round, action: :finalize_round
      define :reopen_round, action: :reopen_round, args: [:reason]
      define :cancel_round, action: :cancel_round
    end

    resource GolfScoring.Competition.RoundHole

    resource GolfScoring.Competition.RoundTeeProfileSnapshot
    resource GolfScoring.Competition.RoundTeeHoleSnapshot

    resource GolfScoring.Competition.Player

    resource GolfScoring.Competition.CompetitionCategory
    resource GolfScoring.Competition.RoundEntryCategoryMembership

    resource GolfScoring.Competition.RoundEntry do
      define :add_round_entry, action: :add_round_entry, args: [:event_id, :round_id, :player_id]
      define :check_in_round_entry, action: :check_in_round_entry
      define :mark_no_show, action: :mark_no_show
      define :withdraw_before_start, action: :withdraw_before_start
      define :get_round_entry_by_id, action: :read, get_by: [:id]
    end

    resource GolfScoring.Competition.PlayingGroup do
      define :create_playing_group, action: :create_playing_group, args: [:event_id, :round_id]
      define :get_playing_group_by_id, action: :read, get_by: [:id]
    end

    resource GolfScoring.Competition.RoundCompetition do
      define :get_round_competition_by_id, action: :read, get_by: [:id]
    end

    resource GolfScoring.Competition.CompetitionSide do
      define :get_competition_side_by_id, action: :read, get_by: [:id]
    end

    resource GolfScoring.Competition.CompetitionSideMembership
    resource GolfScoring.Competition.CompetitionSideResult
    resource GolfScoring.Competition.CompetitionSideRetirement
    resource GolfScoring.Competition.RoundEntryParticipationRuling
    resource GolfScoring.Competition.GroupRoleAssignment

    resource GolfScoring.Competition.ScoringTrack do
      define :get_scoring_track_by_id, action: :read, get_by: [:id]
    end

    resource GolfScoring.Competition.MysteryHoleRule
    resource GolfScoring.Competition.MysteryReveal
  end

  def mark_round_ready(actor, event_id, round_id),
    do: OpenRound.mark_ready(actor, event_id, round_id)

  def open_round(actor, event_id, round_id),
    do: OpenRound.run(actor, event_id, round_id)

  def configure_round_competition(actor, event_id, round_id, attrs) do
    ConfigureRoundCompetition.run(actor, event_id, round_id, attrs)
  end

  def create_competition_side(actor, event_id, round_id, round_competition_id, formation) do
    CreateCompetitionSide.run(actor, event_id, round_id, round_competition_id, formation)
  end

  def set_side_membership(
        actor,
        event_id,
        round_id,
        round_competition_id,
        competition_side_id,
        round_entry_ids
      ) do
    SetSideMembership.run(
      actor,
      event_id,
      round_id,
      round_competition_id,
      competition_side_id,
      round_entry_ids
    )
  end

  def assign_primary_scorer(actor, event_id, round_id, playing_group_id, round_entry_id) do
    AssignGroupRole.run(
      actor,
      event_id,
      round_id,
      playing_group_id,
      round_entry_id,
      :primary_scorer
    )
  end

  def assign_designated_verifier(actor, event_id, round_id, playing_group_id, round_entry_id) do
    AssignGroupRole.run(
      actor,
      event_id,
      round_id,
      playing_group_id,
      round_entry_id,
      :designated_verifier
    )
  end

  def handover_primary_scorer(actor, event_id, round_id, playing_group_id, replacement_entry_id) do
    HandoverGroupRole.run(
      actor,
      event_id,
      round_id,
      playing_group_id,
      replacement_entry_id,
      :primary_scorer
    )
  end

  def handover_designated_verifier(
        actor,
        event_id,
        round_id,
        playing_group_id,
        replacement_entry_id
      ) do
    HandoverGroupRole.run(
      actor,
      event_id,
      round_id,
      playing_group_id,
      replacement_entry_id,
      :designated_verifier
    )
  end

  def revoke_primary_scorer(actor, event_id, round_id, playing_group_id, reason) do
    RevokeGroupRole.run(actor, event_id, round_id, playing_group_id, :primary_scorer, reason)
  end

  def revoke_designated_verifier(actor, event_id, round_id, playing_group_id, reason) do
    RevokeGroupRole.run(actor, event_id, round_id, playing_group_id, :designated_verifier, reason)
  end

  def assign_round_tee(actor, event_id, round_id, round_entry_id, round_tee_profile_snapshot_id) do
    AssignRoundTee.run(
      actor,
      event_id,
      round_id,
      round_entry_id,
      round_tee_profile_snapshot_id
    )
  end

  def configure_scoring_track(actor, event_id, round_id, round_competition_id, attrs) do
    ConfigureScoringTrack.run(actor, event_id, round_id, round_competition_id, attrs)
  end

  def configure_mystery_hole_rule(
        actor,
        event_id,
        round_id,
        scoring_track_id,
        round_hole_id,
        rule
      ) do
    ConfigureMysteryHoleRule.run(
      actor,
      event_id,
      round_id,
      scoring_track_id,
      round_hole_id,
      rule
    )
  end

  def remove_mystery_hole_rule(actor, event_id, round_id, scoring_track_id, round_hole_id) do
    ConfigureMysteryHoleRule.remove(
      actor,
      event_id,
      round_id,
      scoring_track_id,
      round_hole_id
    )
  end

  def accept_competition_side_retirement(
        actor,
        event_id,
        round_id,
        round_competition_id,
        competition_side_id,
        playing_group_id,
        attrs
      ) do
    AcceptCompetitionSideRetirement.run(
      actor,
      event_id,
      round_id,
      round_competition_id,
      competition_side_id,
      playing_group_id,
      attrs
    )
  end

  def accept_round_entry_withdrawal(
        actor,
        event_id,
        round_id,
        playing_group_id,
        round_entry_id,
        attrs
      ) do
    AcceptRoundEntryWithdrawal.run(
      actor,
      event_id,
      round_id,
      playing_group_id,
      round_entry_id,
      attrs
    )
  end
end

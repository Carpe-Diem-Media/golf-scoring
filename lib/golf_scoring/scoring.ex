defmodule GolfScoring.Scoring do
  @moduledoc "Handicap snapshots, competition handicaps, and authoritative score records."

  use Ash.Domain

  alias GolfScoring.Scoring.Services.ApplyNoHiPolicy
  alias GolfScoring.Scoring.Services.BuildCompetitionHandicap
  alias GolfScoring.Scoring.Services.BuildHandicapSnapshot
  alias GolfScoring.Scoring.Services.ConfirmHandicapInput
  alias GolfScoring.Scoring.Services.ConfirmHandicapInputForPlayerGrant
  alias GolfScoring.Scoring.Services.OverrideHandicapBasis

  resources do
    resource GolfScoring.Scoring.HandicapSnapshot
    resource GolfScoring.Scoring.CompetitionHandicap
    resource GolfScoring.Scoring.Scorecard
    resource GolfScoring.Scoring.HoleResult
    resource GolfScoring.Scoring.HoleSubmission
  end

  def confirm_handicap_input(actor, event_id, round_id, round_entry_id, attrs) do
    ConfirmHandicapInput.run(actor, event_id, round_id, round_entry_id, attrs)
  end

  def confirm_handicap_input(actor, event_id, round_id, round_entry_id, attrs, opts)
      when is_list(opts) do
    ConfirmHandicapInput.run(actor, event_id, round_id, round_entry_id, attrs, opts)
  end

  def confirm_handicap_input_for_player_grant(grant_id, round_id, round_entry_id, attrs) do
    ConfirmHandicapInputForPlayerGrant.run(grant_id, round_id, round_entry_id, attrs)
  end

  def apply_no_hi_policy(actor, event_id, round_id, round_entry_id, attrs) do
    ApplyNoHiPolicy.run(actor, event_id, round_id, round_entry_id, attrs)
  end

  def override_handicap_basis(actor, event_id, round_id, round_entry_id, attrs) do
    OverrideHandicapBasis.run(actor, event_id, round_id, round_entry_id, attrs)
  end

  def build_handicap_snapshot(round_entry_id, attrs) do
    BuildHandicapSnapshot.run(round_entry_id, attrs)
  end

  def build_competition_handicap(round_entry_id, round_competition_id, attrs) do
    BuildCompetitionHandicap.run(round_entry_id, round_competition_id, attrs)
  end

  def submit_group_hole(actor, event_id, round_id, command) do
    GolfScoring.Scoring.Services.SubmitGroupHole.run(actor, event_id, round_id, command)
  end
end

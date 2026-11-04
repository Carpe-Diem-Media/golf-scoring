defmodule GolfScoring.Scoring do
  @moduledoc """
  Public application interface for scoring operations and scorecard reads.

  Score submissions remain owned by `SubmitGroupHole`; scorecard reads and
  preview projections are provided here so web modules do not own scoring
  queries, authorization, or golf calculations.
  """

  use Ash.Domain

  alias GolfScoring.Scoring.Services.ApplyNoHiPolicy
  alias GolfScoring.Scoring.Services.BuildCompetitionHandicap
  alias GolfScoring.Scoring.Services.BuildHandicapSnapshot
  alias GolfScoring.Scoring.Services.ConfirmHandicapInput
  alias GolfScoring.Scoring.Services.ConfirmHandicapInputForPlayerGrant
  alias GolfScoring.Scoring.Services.LoadGroupScorecard
  alias GolfScoring.Scoring.Services.OverrideHandicapBasis
  alias GolfScoring.Scoring.Services.SubmitGroupHole

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
    SubmitGroupHole.run(actor, event_id, round_id, command)
  end

  @doc """
  Loads the scorecard for a player grant and route identifiers.

  The current grant and primary-scorer assignment are revalidated for every
  read. The round must be open for scoring. The result contains the authorized
  roster, frozen hole and handicap facts, and the physical route.
  """
  @spec load_group_scorecard(term(), term(), term(), term()) ::
          {:ok, LoadGroupScorecard.scorecard()} | {:error, term()}
  def load_group_scorecard(grant, event_id, round_id, group_id) do
    LoadGroupScorecard.run(grant, event_id, round_id, group_id)
  end

  @doc """
  Finds and loads the current grant holder's assigned scorecard.

  Returns an error when the grant has no single active primary-scorer group in
  an open round.
  """
  @spec load_assigned_group_scorecard(term()) ::
          {:ok, LoadGroupScorecard.scorecard()} | {:error, term()}
  def load_assigned_group_scorecard(grant) do
    LoadGroupScorecard.run_for_assigned_group(grant)
  end

  @doc "Calculates presentation previews from a scorecard and current form values."
  @spec preview_group_scorecard(LoadGroupScorecard.scorecard(), map()) :: [map()]
  def preview_group_scorecard(scorecard, result_values) do
    LoadGroupScorecard.preview(scorecard, result_values)
  end
end

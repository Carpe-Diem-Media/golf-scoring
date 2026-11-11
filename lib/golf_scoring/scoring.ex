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
  alias GolfScoring.Scoring.Services.CorrectHoleResult
  alias GolfScoring.Scoring.Services.DecideScoreQuery
  alias GolfScoring.Scoring.Services.EscalateScoreQuery
  alias GolfScoring.Scoring.Services.LoadGroupScorecard
  alias GolfScoring.Scoring.Services.LoadPlayerVerificationContext
  alias GolfScoring.Scoring.Services.LoadStaffScoreQueryReview
  alias GolfScoring.Scoring.Services.OpenScoreQuery
  alias GolfScoring.Scoring.Services.OverrideHandicapBasis
  alias GolfScoring.Scoring.Services.ResolveScoreQueryWithCorrection
  alias GolfScoring.Scoring.Services.SubmitGroupHole
  alias GolfScoring.Scoring.Services.VerifyHoleResult

  resources do
    resource GolfScoring.Scoring.HandicapSnapshot
    resource GolfScoring.Scoring.CompetitionHandicap
    resource GolfScoring.Scoring.Scorecard
    resource GolfScoring.Scoring.HoleResult
    resource GolfScoring.Scoring.ScoreVerification
    resource GolfScoring.Scoring.ScoreQuery
    resource GolfScoring.Scoring.ScoreRevision
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

  @doc """
  Escalates an open current-revision dispute as trusted same-event staff.

  Requires score_query_id, expected_revision and an escalation reason. Allows
  Event Admin, Competition Manager and Scoring Support. The service owns its
  outer transaction; duplicate escalation is a conflict. Audit is atomic and
  notification status is separate from committed success. Admin-attention UI
  and player escalation remain separate release gates.
  """
  def escalate_score_query(actor, event_id, round_id, command) do
    EscalateScoreQuery.run(actor, event_id, round_id, command)
  end

  @doc """
  Terminates an open or escalated dispute as trusted same-event staff.

  Requires `score_query_id`, `expected_revision`, `reason`, and `decision`
  (`:resolve_no_change` or `:dismiss`). Allows Event Admin and Competition Manager only.
  Correction-based resolution is unsupported. The service owns its outer transaction.
  """
  def decide_score_query(actor, event_id, round_id, command) do
    DecideScoreQuery.run(actor, event_id, round_id, command)
  end

  def resolve_score_query_no_change(actor, event_id, round_id, command) when is_map(command) do
    DecideScoreQuery.run(
      actor,
      event_id,
      round_id,
      Map.put(command, :decision, :resolve_no_change)
    )
  end

  def resolve_score_query_no_change(_actor, _event_id, _round_id, _command),
    do: {:error, :invalid_input}

  def dismiss_score_query(actor, event_id, round_id, command) when is_map(command) do
    DecideScoreQuery.run(actor, event_id, round_id, Map.put(command, :decision, :dismiss))
  end

  def dismiss_score_query(_actor, _event_id, _round_id, _command), do: {:error, :invalid_input}

  @doc """
  Resolves an open or escalated dispute by correcting the associated HoleResult.

  Requires `score_query_id`, `expected_revision`, `new_gross_strokes`, and `reason`.
  Holed-out gross correction only. The workflow owns the outer transaction.
  """
  def resolve_score_query_with_correction(actor, event_id, round_id, command),
    do: ResolveScoreQueryWithCorrection.run(actor, event_id, round_id, command)

  @doc """
  Opens a current-revision dispute as trusted same-event staff.

  Requires hole_result_id, expected_revision and a nonblank reason. The service
  owns its transaction and reviews the Scorecard and all affected provisional
  sides atomically with the query and audit. Notification status is separate
  from committed success. Player initiation and query resolution are unavailable.
  """
  def query_hole_result(actor, event_id, round_id, command) do
    OpenScoreQuery.run(actor, event_id, round_id, command)
  end

  @doc """
  Corrects a recorded holed-out gross score as trusted same-event staff.

  Requires expected_revision, new_gross_strokes and reason. Owns its transaction;
  nested use is rejected. Success includes the committed evidence and a separate
  notification delivery status. Unsupported review/dispute workflows fail closed.
  """
  def correct_hole_result(actor, event_id, round_id, command) do
    CorrectHoleResult.run(actor, event_id, round_id, command)
  end

  def submit_group_hole(actor, event_id, round_id, command) do
    SubmitGroupHole.run(actor, event_id, round_id, command)
  end

  @doc """
  Certifies the current result revision using a player grant and current role assignment.

  The command identifies the playing group, HoleResult, expected result revision,
  assignment ID and assignment version. Identical retries return the same evidence;
  a stale revision, ineligible actor or conflicting certification returns an error.
  """
  def verify_hole_result(actor, event_id, round_id, command) do
    VerifyHoleResult.run(actor, event_id, round_id, command)
  end

  @doc """
  Loads a current group verification projection for a trusted player grant.

  Eligibility is advisory; verification rechecks authority and revision under lock.
  Expired grants are rejected without applying the session helper's lazy expiry.
  """
  def load_player_verification_context(grant, event_id, round_id, group_id) do
    LoadPlayerVerificationContext.run(grant, event_id, round_id, group_id)
  end

  @doc """
  Loads a bounded, round-scoped query review page for a trusted staff session.

  Options are `:limit` (1..50, default 50) and `:cursor`, which must be the
  `next_cursor` returned by a previous page. The result contains `:items` and
  `:next_cursor`; nil means there are no more results.

  Authority is rechecked on each read. Returned state is a snapshot and does
  not authorize any subsequent decision or correction.
  """
  def load_staff_score_query_review(staff, event_id, round_id, opts) do
    LoadStaffScoreQueryReview.run(staff, event_id, round_id, opts)
  end

  @doc """
  Records an authorized staff exception for the current result revision.

  The command identifies the playing group, HoleResult, expected revision and a
  nonblank reason. The transaction records the staff identity and audit event.
  """
  def override_hole_verification(actor, event_id, round_id, command) do
    VerifyHoleResult.override(actor, event_id, round_id, command)
  end

  @doc """
  Resolves an existing accepted player command by its idempotency key.

  The current grant, primary-scorer assignment, round, and command payload are
  checked again. This function only reads an existing receipt and never accepts
  a new score.
  """
  @spec resolve_accepted_group_hole_receipt(term(), term(), term(), map()) ::
          {:ok, GolfScoring.Scoring.HoleSubmission.t()} | {:error, term()}
  def resolve_accepted_group_hole_receipt(actor, event_id, round_id, command) do
    SubmitGroupHole.resolve_accepted_receipt(actor, event_id, round_id, command)
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

defmodule GolfScoring.Scoring.ScoreQuery do
  @moduledoc """
  A dispute against one revision of a hole result.

  Open and escalated queries are unresolved; resolved and dismissed queries are
  terminal. Staff creation is restricted to OpenScoreQuery and its atomic review
  transaction.   Staff escalation is restricted to EscalateScoreQuery with atomic audit.
  Terminal no-change resolution and staff dismissal are restricted to DecideScoreQuery
  with atomic audit.
  """

  use Ash.Resource, domain: GolfScoring.Scoring, data_layer: AshPostgres.DataLayer

  postgres do
    table "score_queries"
    repo GolfScoring.Repo

    references do
      reference :hole_result, on_delete: :restrict, match_with: [scorecard_id: :scorecard_id]
      reference :scorecard, on_delete: :restrict, match_with: [round_id: :round_id]
      reference :round, on_delete: :restrict
      reference :requested_by_round_entry, on_delete: :restrict, match_with: [round_id: :round_id]
      reference :requested_by_staff_user, on_delete: :restrict
      reference :resolved_by_staff_user, on_delete: :restrict
      reference :resolved_by_round_entry, on_delete: :restrict, match_with: [round_id: :round_id]
    end

    custom_indexes do
      index [:round_id, {:desc, :inserted_at}, {:desc, :id}],
        name: "score_queries_round_queue_index"

      index [:hole_result_id],
        unique: true,
        where: "status IN ('open', 'escalated')",
        name: "score_queries_one_unresolved_index"
    end

    check_constraints do
      check_constraint :hole_result_revision, "score_queries_revision_positive",
        check: "hole_result_revision > 0",
        message: "must be positive"

      check_constraint :reason, "score_queries_reason_present",
        check: "length(btrim(reason)) > 0",
        message: "must be present"

      check_constraint :requested_by_round_entry_id, "score_queries_requester_shape",
        check:
          "(requested_by_round_entry_id IS NOT NULL) <> (requested_by_staff_user_id IS NOT NULL)",
        message: "requires exactly one requester"

      check_constraint :status, "score_queries_resolution_shape",
        check: """
        (status IN ('open', 'escalated') AND resolved_by_staff_user_id IS NULL AND resolved_by_round_entry_id IS NULL AND resolution_reason IS NULL AND resolved_at IS NULL)
        OR (status = 'resolved' AND (resolved_by_staff_user_id IS NOT NULL) <> (resolved_by_round_entry_id IS NOT NULL) AND resolution_reason IS NOT NULL AND length(btrim(resolution_reason)) > 0 AND resolved_at IS NOT NULL)
        OR (status = 'dismissed' AND resolved_by_staff_user_id IS NOT NULL AND resolved_by_round_entry_id IS NULL AND resolution_reason IS NOT NULL AND length(btrim(resolution_reason)) > 0 AND resolved_at IS NOT NULL)
        """,
        message: "must match its resolution evidence"
    end
  end

  actions do
    create :open_internal do
      public? false

      accept [
        :hole_result_id,
        :scorecard_id,
        :round_id,
        :hole_result_revision,
        :requested_by_staff_user_id,
        :reason
      ]

      change GolfScoring.Scoring.ScoreQueryOpenGuard
    end

    update :escalate_internal do
      public? false
      accept []
      require_atomic? false
      atomic_upgrade? false
      change GolfScoring.Scoring.ScoreQueryEscalationGuard
    end

    update :resolve_no_change_internal do
      public? false
      accept []
      require_atomic? false
      atomic_upgrade? false
      change GolfScoring.Scoring.ScoreQueryDecisionGuard
    end

    update :dismiss_internal do
      public? false
      accept []
      require_atomic? false
      atomic_upgrade? false
      change GolfScoring.Scoring.ScoreQueryDecisionGuard
    end

    update :resolve_with_correction_internal do
      public? false
      accept []
      require_atomic? false
      atomic_upgrade? false
      change GolfScoring.Scoring.ScoreQueryDecisionGuard
    end

    read :read do
      primary? true
      public? false
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :hole_result_revision, :integer,
      allow_nil?: false,
      public?: false,
      constraints: [min: 1]

    attribute :status, :atom,
      allow_nil?: false,
      public?: false,
      default: :open,
      constraints: [one_of: [:open, :escalated, :resolved, :dismissed]]

    attribute :reason, :string, allow_nil?: false, public?: false
    attribute :resolution_reason, :string, public?: false
    attribute :resolved_at, :utc_datetime_usec, public?: false
    timestamps()
  end

  relationships do
    belongs_to :hole_result, GolfScoring.Scoring.HoleResult, allow_nil?: false, public?: false
    belongs_to :scorecard, GolfScoring.Scoring.Scorecard, allow_nil?: false, public?: false
    belongs_to :round, GolfScoring.Competition.Round, allow_nil?: false, public?: false
    belongs_to :requested_by_round_entry, GolfScoring.Competition.RoundEntry, public?: false
    belongs_to :requested_by_staff_user, GolfScoring.Accounts.StaffUser, public?: false
    belongs_to :resolved_by_staff_user, GolfScoring.Accounts.StaffUser, public?: false
    belongs_to :resolved_by_round_entry, GolfScoring.Competition.RoundEntry, public?: false
  end
end

defmodule GolfScoring.Scoring.ScoreRevision do
  @moduledoc """
  Append-only evidence of a change to a hole result.

  Creation is restricted to the atomic staff correction coordinator under the
  scorecard lock. No update or destroy actions are exposed.
  """

  use Ash.Resource, domain: GolfScoring.Scoring, data_layer: AshPostgres.DataLayer

  postgres do
    table "score_revisions"
    repo GolfScoring.Repo

    references do
      reference :hole_result, on_delete: :restrict, match_with: [scorecard_id: :scorecard_id]
      reference :scorecard, on_delete: :restrict, match_with: [round_id: :round_id]
      reference :round, on_delete: :restrict
      reference :actor_round_entry, on_delete: :restrict, match_with: [round_id: :round_id]
      reference :actor_staff_user, on_delete: :restrict

      reference :source_query,
        on_delete: :restrict,
        match_with: [hole_result_id: :hole_result_id, original_revision: :hole_result_revision]
    end

    identity_index_names unique_resulting_revision:
                           "score_revisions_unique_resulting_revision_index"

    check_constraints do
      check_constraint :original_revision, "score_revisions_consecutive_revisions",
        check: "original_revision > 0 AND resulting_revision = original_revision + 1",
        message: "must be consecutive positive revisions"

      check_constraint :original_outcome, "score_revisions_original_outcome_shape",
        check:
          "(original_outcome = 'holed_out' AND original_gross_strokes IS NOT NULL AND original_gross_strokes >= 1) OR (original_outcome = 'picked_up' AND original_gross_strokes IS NULL)",
        message: "must match original gross strokes"

      check_constraint :new_outcome, "score_revisions_new_outcome_shape",
        check:
          "(new_outcome = 'holed_out' AND new_gross_strokes IS NOT NULL AND new_gross_strokes >= 1) OR (new_outcome = 'picked_up' AND new_gross_strokes IS NULL)",
        message: "must match new gross strokes"

      check_constraint :actor_round_entry_id, "score_revisions_actor_shape",
        check: "(actor_round_entry_id IS NOT NULL) <> (actor_staff_user_id IS NOT NULL)",
        message: "requires exactly one actor"

      check_constraint :reason, "score_revisions_reason_present",
        check: "length(btrim(reason)) > 0",
        message: "must be present"
    end
  end

  actions do
    create :record_correction_internal do
      public? false

      accept [
        :hole_result_id,
        :scorecard_id,
        :round_id,
        :actor_staff_user_id,
        :original_revision,
        :resulting_revision,
        :original_outcome,
        :original_gross_strokes,
        :new_outcome,
        :new_gross_strokes,
        :reason
      ]

      change {GolfScoring.Scoring.CorrectionWriteGuard, operation: :evidence}
    end

    read :read do
      primary? true
      public? false
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :original_revision, :integer,
      allow_nil?: false,
      public?: false,
      constraints: [min: 1]

    attribute :resulting_revision, :integer,
      allow_nil?: false,
      public?: false,
      constraints: [min: 2]

    attribute :original_outcome, :atom,
      allow_nil?: false,
      public?: false,
      constraints: [one_of: [:holed_out, :picked_up]]

    attribute :original_gross_strokes, :integer, public?: false

    attribute :new_outcome, :atom,
      allow_nil?: false,
      public?: false,
      constraints: [one_of: [:holed_out, :picked_up]]

    attribute :new_gross_strokes, :integer, public?: false
    attribute :reason, :string, allow_nil?: false, public?: false
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :hole_result, GolfScoring.Scoring.HoleResult, allow_nil?: false, public?: false
    belongs_to :scorecard, GolfScoring.Scoring.Scorecard, allow_nil?: false, public?: false
    belongs_to :round, GolfScoring.Competition.Round, allow_nil?: false, public?: false
    belongs_to :actor_round_entry, GolfScoring.Competition.RoundEntry, public?: false
    belongs_to :actor_staff_user, GolfScoring.Accounts.StaffUser, public?: false
    belongs_to :source_query, GolfScoring.Scoring.ScoreQuery, public?: false
  end

  identities do
    identity :unique_resulting_revision, [:hole_result_id, :resulting_revision]
  end
end

defmodule GolfScoring.Scoring.HoleResult do
  @moduledoc "Current authoritative raw golf outcome for one Scorecard and RoundHole."

  use Ash.Resource,
    domain: GolfScoring.Scoring,
    data_layer: AshPostgres.DataLayer

  @outcomes [:holed_out, :picked_up]

  postgres do
    table "hole_results"
    repo GolfScoring.Repo

    references do
      reference :round, on_delete: :restrict

      reference :scorecard,
        on_delete: :restrict,
        match_with: [round_id: :round_id]

      reference :round_hole,
        on_delete: :restrict,
        match_with: [round_id: :round_id]
    end

    custom_indexes do
      index [:round_id, :round_hole_id]
      index [:scorecard_id]
      index [:round_hole_id]
      index [:round_id]
    end

    identity_index_names unique_scorecard_hole: "hole_results_unique_scorecard_hole_index"

    check_constraints do
      check_constraint :outcome, "hole_results_outcome_must_be_valid",
        check: "outcome IN ('holed_out', 'picked_up')",
        message: "must be holed_out or picked_up"

      check_constraint :outcome, "hole_results_outcome_gross_shape",
        check: """
        (outcome = 'holed_out' AND gross_strokes IS NOT NULL AND gross_strokes >= 1)
        OR (outcome = 'picked_up' AND gross_strokes IS NULL)
        """,
        message: "gross strokes must match outcome"

      check_constraint :revision, "hole_results_revision_must_be_positive",
        check: "revision > 0",
        message: "revision must be positive"
    end
  end

  actions do
    read :read do
      public? false
      primary? true
    end

    update :correct_gross_internal do
      public? false
      require_atomic? false
      atomic_upgrade? false
      accept [:gross_strokes]
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      change optimistic_lock(:revision)
      change {GolfScoring.Scoring.CorrectionWriteGuard, operation: :update}
    end

    create :record_internal do
      public? false

      accept [
        :round_id,
        :scorecard_id,
        :round_hole_id,
        :outcome,
        :gross_strokes
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :outcome, :atom do
      allow_nil? false
      public? false
      constraints one_of: @outcomes
    end

    attribute :gross_strokes, :integer do
      allow_nil? true
      public? false
    end

    attribute :revision, :integer do
      allow_nil? false
      public? false
      writable? false
      default 1
      constraints min: 1
    end

    timestamps()
  end

  relationships do
    belongs_to :round, GolfScoring.Competition.Round do
      allow_nil? false
      public? false
    end

    belongs_to :scorecard, GolfScoring.Scoring.Scorecard do
      allow_nil? false
      public? false
    end

    belongs_to :round_hole, GolfScoring.Competition.RoundHole do
      allow_nil? false
      public? false
    end
  end

  identities do
    identity :unique_scorecard_hole, [:scorecard_id, :round_hole_id]
  end

  def outcomes, do: @outcomes
end

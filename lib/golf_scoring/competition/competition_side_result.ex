defmodule GolfScoring.Competition.CompetitionSideResult do
  @moduledoc "Official competitive readiness state and audited pre-play exclusion evidence for one CompetitionSide."

  use Ash.Resource,
    domain: GolfScoring.Competition,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "competition_side_results"
    repo GolfScoring.Repo

    references do
      reference :competition_side, on_delete: :restrict
      reference :excluded_by_staff_user, on_delete: :restrict
      reference :excluded_playing_group, on_delete: :restrict
      reference :excluded_effective_round_hole, on_delete: :restrict
    end

    custom_indexes do
      index [:competition_side_id]
    end

    check_constraints do
      check_constraint :state, "competition_side_results_state_must_be_valid",
        check:
          "state IN ('provisional', 'review_required', 'ready_to_finalize', 'finalized', 'excluded')",
        message: "must be a valid CompetitionSideResult lifecycle state"

      check_constraint :excluded_preplay_confirmed,
                       "competition_side_results_exclusion_provenance_consistent",
                       check: """
                       (
                         state = 'excluded'
                         AND excluded_by_staff_user_id IS NOT NULL
                         AND exclusion_reason IS NOT NULL
                         AND exclusion_reason = btrim(
                           exclusion_reason,
                           chr(9) || chr(10) || chr(11) || chr(12) || chr(13) || chr(32) ||
                             chr(133) || chr(160) || chr(5760) || chr(8192) || chr(8193) ||
                             chr(8194) || chr(8195) || chr(8196) || chr(8197) || chr(8198) ||
                             chr(8199) || chr(8200) || chr(8201) || chr(8202) || chr(8232) ||
                             chr(8233) || chr(8239) || chr(8287) || chr(12288)
                         )
                         AND char_length(btrim(
                           exclusion_reason,
                           chr(9) || chr(10) || chr(11) || chr(12) || chr(13) || chr(32) ||
                             chr(133) || chr(160) || chr(5760) || chr(8192) || chr(8193) ||
                             chr(8194) || chr(8195) || chr(8196) || chr(8197) || chr(8198) ||
                             chr(8199) || chr(8200) || chr(8201) || chr(8202) || chr(8232) ||
                             chr(8233) || chr(8239) || chr(8287) || chr(12288)
                         )) > 0
                         AND excluded_at IS NOT NULL
                         AND excluded_playing_group_id IS NOT NULL
                         AND excluded_effective_round_hole_id IS NOT NULL
                         AND excluded_effective_play_index BETWEEN 0 AND 17
                         AND excluded_preplay_confirmed IS TRUE
                       )
                       OR (
                         state <> 'excluded'
                         AND excluded_by_staff_user_id IS NULL
                         AND exclusion_reason IS NULL
                         AND excluded_at IS NULL
                         AND excluded_playing_group_id IS NULL
                         AND excluded_effective_round_hole_id IS NULL
                         AND excluded_effective_play_index IS NULL
                         AND excluded_preplay_confirmed IS NULL
                       )
                       """,
                       message: "exclusion state requires complete pre-play provenance"
    end

    identity_index_names unique_result_per_side: "competition_side_results_unique_side_index"
  end

  actions do
    read :read do
      public? false
      primary? true
    end

    create :create_provisional_internal do
      public? false
      accept [:competition_side_id]
      change set_attribute(:state, :provisional)
    end

    update :mark_review_required do
      public? false
      accept []
      require_atomic? false
      atomic_upgrade? false

      change {GolfScoring.Competition.CompetitionSideResultLifecycleGuard,
              operation: :mark_review_required}
    end

    update :mark_ready_to_finalize do
      public? false
      accept []
      require_atomic? false
      atomic_upgrade? false

      change {GolfScoring.Competition.CompetitionSideResultLifecycleGuard,
              operation: :mark_ready_to_finalize}
    end

    update :finalize do
      public? false
      accept []
      require_atomic? false
      atomic_upgrade? false
      change {GolfScoring.Competition.CompetitionSideResultLifecycleGuard, operation: :finalize}
    end

    update :reopen do
      public? false
      accept []
      require_atomic? false
      atomic_upgrade? false
      change {GolfScoring.Competition.CompetitionSideResultLifecycleGuard, operation: :reopen}
    end

    update :exclude do
      public? false
      accept []
      require_atomic? false
      atomic_upgrade? false
      change {GolfScoring.Competition.CompetitionSideResultLifecycleGuard, operation: :exclude}
    end

    update :exclude_before_hole_internal do
      public? false
      accept []
      require_atomic? false
      atomic_upgrade? false

      change {GolfScoring.Competition.CompetitionSideResultLifecycleGuard,
              operation: :exclude_before_hole_internal}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :state, :atom do
      allow_nil? false
      default :provisional
      public? false
      writable? false

      constraints one_of: [
                    :provisional,
                    :review_required,
                    :ready_to_finalize,
                    :finalized,
                    :excluded
                  ]
    end

    attribute :exclusion_reason, :string do
      allow_nil? true
      public? false
      writable? false
    end

    attribute :excluded_at, :utc_datetime_usec do
      allow_nil? true
      public? false
      writable? false
    end

    attribute :excluded_effective_play_index, :integer do
      allow_nil? true
      public? false
      writable? false
      constraints min: 0, max: 17
    end

    attribute :excluded_preplay_confirmed, :boolean do
      allow_nil? true
      public? false
      writable? false
    end

    timestamps()
  end

  relationships do
    belongs_to :competition_side, GolfScoring.Competition.CompetitionSide do
      allow_nil? false
      public? false
    end

    belongs_to :excluded_by_staff_user, GolfScoring.Accounts.StaffUser do
      allow_nil? true
      public? false
      attribute_public? false
    end

    belongs_to :excluded_playing_group, GolfScoring.Competition.PlayingGroup do
      allow_nil? true
      public? false
      attribute_public? false
    end

    belongs_to :excluded_effective_round_hole, GolfScoring.Competition.RoundHole do
      allow_nil? true
      public? false
      attribute_public? false
    end
  end

  identities do
    identity :unique_result_per_side, [:competition_side_id]
  end
end

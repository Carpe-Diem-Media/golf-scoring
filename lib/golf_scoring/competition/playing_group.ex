defmodule GolfScoring.Competition.PlayingGroup do
  @moduledoc "Physical group of golfers playing together in one Round."

  use Ash.Resource,
    domain: GolfScoring.Competition,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "playing_groups"
    repo GolfScoring.Repo

    references do
      reference :round, on_delete: :restrict

      reference :starting_round_hole,
        on_delete: :restrict,
        match_with: [round_id: :round_id]
    end

    custom_indexes do
      index [:round_id]
    end

    check_constraints do
      check_constraint :state, "playing_groups_state_must_be_valid",
        check: "state IN ('not_started', 'playing', 'attention_required', 'finished_playing')",
        message: "must be a valid PlayingGroup lifecycle state"

      check_constraint :starting_position, "playing_groups_starting_position_must_be_positive",
        check: "starting_position IS NULL OR starting_position > 0",
        message: "must be a positive starting position"

      check_constraint :starting_round_hole_id,
                       "playing_groups_start_assignment_must_be_complete",
                       check:
                         "(starting_round_hole_id IS NULL AND starting_position IS NULL) OR (starting_round_hole_id IS NOT NULL AND starting_position IS NOT NULL)",
                       message: "starting hole and position must both be set or both be unset"

      check_constraint :scoring_revision, "playing_groups_scoring_revision_non_negative",
        check: "scoring_revision >= 0",
        message: "scoring revision must be non-negative"
    end

    identity_index_names unique_start_slot_per_round: "playing_groups_unique_start_slot_index"
  end

  actions do
    read :read do
      public? false
      primary? true
    end

    create :create_playing_group do
      public? false
      accept [:round_id]
      transaction? true

      argument :event_id, :uuid do
        allow_nil? false
      end

      change GolfScoring.Competition.Changes.CreatePlayingGroup
    end

    update :assign_start_internal do
      public? false
      accept [:starting_round_hole_id, :starting_position]
      require_atomic? false
    end

    update :mark_group_playing do
      public? false
      accept []
      transaction? true
      require_atomic? false
      atomic_upgrade? false
      change {GolfScoring.Competition.PlayingGroupLifecycleGuard, operation: :mark_group_playing}
    end

    update :mark_group_finished do
      public? false
      accept []
      transaction? true
      require_atomic? false
      atomic_upgrade? false
      change {GolfScoring.Competition.PlayingGroupLifecycleGuard, operation: :mark_group_finished}
    end

    update :flag_group_attention do
      public? false
      accept []
      transaction? true
      require_atomic? false
      atomic_upgrade? false

      change {GolfScoring.Competition.PlayingGroupLifecycleGuard,
              operation: :flag_group_attention}
    end

    update :flag_group_attention_for_withdrawal_internal do
      public? false
      accept []
      transaction? false
      require_atomic? false
      atomic_upgrade? false

      change {GolfScoring.Competition.PlayingGroupLifecycleGuard,
              operation: :flag_group_attention_for_withdrawal_internal}
    end

    update :clear_group_attention do
      public? false
      accept []
      transaction? true
      require_atomic? false
      atomic_upgrade? false

      change {GolfScoring.Competition.PlayingGroupLifecycleGuard,
              operation: :clear_group_attention}
    end

    update :clear_group_attention_for_vacancy_internal do
      public? false
      accept []
      transaction? false
      require_atomic? false
      atomic_upgrade? false

      change {GolfScoring.Competition.PlayingGroupLifecycleGuard,
              operation: :clear_group_attention_for_vacancy_internal}
    end

    update :increment_scoring_revision_internal do
      public? false
      accept []
      require_atomic? false
      atomic_upgrade? false
      change GolfScoring.Competition.Changes.IncrementPlayingGroupScoringRevision
    end
  end

  policies do
    policy action(:create_playing_group) do
      access_type :strict

      authorize_if {GolfScoring.Accounts.Checks.ActiveEventRole,
                    roles: [:event_admin, :competition_manager]}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :state, :atom do
      allow_nil? false
      default :not_started
      public? false
      writable? false

      constraints one_of: [:not_started, :playing, :attention_required, :finished_playing]
    end

    attribute :starting_position, :integer do
      allow_nil? true
      public? false
      constraints min: 1
    end

    attribute :scoring_revision, :integer do
      allow_nil? false
      public? false
      writable? false
      default 0
      constraints min: 0
    end

    timestamps()
  end

  relationships do
    belongs_to :round, GolfScoring.Competition.Round do
      allow_nil? false
      public? false
    end

    belongs_to :starting_round_hole, GolfScoring.Competition.RoundHole do
      allow_nil? true
      public? false
      attribute_public? false
    end

    has_many :round_entries, GolfScoring.Competition.RoundEntry
  end

  identities do
    identity :unique_id_per_round, [:id, :round_id]

    identity :unique_start_slot_per_round, [
      :round_id,
      :starting_round_hole_id,
      :starting_position
    ]
  end
end

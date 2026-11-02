defmodule GolfScoring.Competition.Round do
  @moduledoc "A competition Round. Opening transitions require the RoundOpening coordinator."

  use Ash.Resource,
    domain: GolfScoring.Competition,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "rounds"
    repo GolfScoring.Repo

    references do
      reference :event, on_delete: :restrict
      reference :course, on_delete: :restrict
    end

    check_constraints do
      check_constraint :state, "rounds_state_must_be_valid",
        check:
          "state IN ('draft', 'ready', 'scoring_open', 'scoring_closed', 'finalized', 'cancelled')",
        message: "must be a valid Round lifecycle state"
    end
  end

  actions do
    read :read do
      public? false
      primary? true
    end

    create :create_round do
      public? false
      accept [:event_id, :course_id]
      transaction? true
      change GolfScoring.Competition.Changes.CreateRound
    end

    update :mark_round_ready do
      public? false
      accept []
      transaction? true
      require_atomic? false
      atomic_upgrade? false
      change {GolfScoring.Competition.RoundLifecycleGuard, operation: :mark_round_ready}
    end

    update :open_scoring do
      public? false
      accept []
      transaction? true
      require_atomic? false
      atomic_upgrade? false
      change {GolfScoring.Competition.RoundLifecycleGuard, operation: :open_scoring}
    end

    update :close_scoring do
      public? false
      accept []
      transaction? true
      require_atomic? false
      atomic_upgrade? false
      change {GolfScoring.Competition.RoundLifecycleGuard, operation: :close_scoring}
    end

    update :finalize_round do
      public? false
      accept []
      transaction? true
      require_atomic? false
      atomic_upgrade? false
      change {GolfScoring.Competition.RoundLifecycleGuard, operation: :finalize_round}
    end

    update :reopen_round do
      public? false
      accept []

      argument :reason, :string do
        allow_nil? false
        sensitive? false
      end

      validate present(:reason)
      validate string_length(:reason, min: 1)

      transaction? true
      require_atomic? false
      atomic_upgrade? false
      change {GolfScoring.Competition.RoundLifecycleGuard, operation: :reopen_round}
    end

    update :cancel_round do
      public? false
      accept []
      transaction? true
      require_atomic? false
      atomic_upgrade? false
      change {GolfScoring.Competition.RoundLifecycleGuard, operation: :cancel_round}
    end
  end

  policies do
    policy action(:create_round) do
      access_type :strict
      authorize_if {GolfScoring.Accounts.Checks.ActiveEventRole, role: :event_admin}
    end

    for action <- [:mark_round_ready, :open_scoring, :close_scoring, :finalize_round] do
      policy action(action) do
        access_type :strict

        authorize_if {GolfScoring.Accounts.Checks.ActiveEventRole,
                      roles: [:event_admin, :competition_manager]}
      end
    end

    for action <- [:reopen_round, :cancel_round] do
      policy action(action) do
        access_type :strict
        authorize_if {GolfScoring.Accounts.Checks.ActiveEventRole, role: :event_admin}
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :state, :atom do
      allow_nil? false
      default :draft
      public? false
      writable? false

      constraints one_of: [
                    :draft,
                    :ready,
                    :scoring_open,
                    :scoring_closed,
                    :finalized,
                    :cancelled
                  ]
    end

    timestamps()
  end

  relationships do
    belongs_to :event, GolfScoring.Competition.Event do
      allow_nil? false
      public? false
    end

    belongs_to :course, GolfScoring.GolfCatalog.Course do
      allow_nil? false
      public? false
    end

    has_many :round_holes, GolfScoring.Competition.RoundHole do
      sort play_order: :asc
    end

    has_many :round_tee_profile_snapshots, GolfScoring.Competition.RoundTeeProfileSnapshot
    has_many :round_entries, GolfScoring.Competition.RoundEntry
    has_many :playing_groups, GolfScoring.Competition.PlayingGroup
  end

  identities do
    identity :unique_id_per_course, [:id, :course_id]
    identity :unique_id_per_event, [:id, :event_id]
  end
end

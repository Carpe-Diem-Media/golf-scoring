defmodule GolfScoring.Competition.RoundEntry do
  @moduledoc "One Player participating in one Round."

  use Ash.Resource,
    domain: GolfScoring.Competition,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "round_entries"
    repo GolfScoring.Repo

    references do
      reference :event, on_delete: :restrict
      reference :round, on_delete: :restrict, match_with: [event_id: :event_id]
      reference :player, on_delete: :restrict
      reference :checked_in_by_staff_user, on_delete: :restrict

      reference :playing_group,
        on_delete: :restrict,
        match_with: [round_id: :round_id],
        name: "round_entries_playing_group_same_round_fkey"

      reference :round_tee_profile_snapshot,
        on_delete: :restrict,
        match_with: [round_id: :round_id],
        name: "round_entries_round_tee_snapshot_same_round_fkey"
    end

    custom_indexes do
      index [:round_id, :registration_status]
      index [:round_id, :participation_status]
      index [:event_id]
      index [:round_id, :playing_group_id], name: "round_entries_round_id_playing_group_id_index"
      index [:round_tee_profile_snapshot_id]
    end

    identity_index_names unique_entry_scope: "round_entries_unique_id_event_round_group_index"

    check_constraints do
      check_constraint :registration_status, "round_entries_registration_status_must_be_valid",
        check:
          "registration_status IN ('expected', 'checked_in', 'no_show', 'withdrawn_before_start', 'replaced_before_start')",
        message: "must be a valid registration status"

      check_constraint :participation_status, "round_entries_participation_status_must_be_valid",
        check:
          "participation_status IN ('not_started', 'active', 'completed', 'withdrawn', 'disqualified')",
        message: "must be a valid participation status"
    end
  end

  actions do
    read :read do
      public? false
      primary? true
    end

    create :add_round_entry do
      public? false
      accept [:event_id, :round_id, :player_id]
      transaction? true
      change GolfScoring.Competition.Changes.CreateRoundEntry
    end

    update :check_in_round_entry do
      public? false
      accept []
      transaction? true
      require_atomic? false
      atomic_upgrade? false

      change {GolfScoring.Competition.RoundEntryLifecycleGuard, operation: :check_in_round_entry}
    end

    update :mark_no_show do
      public? false
      accept []
      transaction? true
      require_atomic? false
      atomic_upgrade? false
      change {GolfScoring.Competition.RoundEntryLifecycleGuard, operation: :mark_no_show}
    end

    update :withdraw_before_start do
      public? false
      accept []
      transaction? true
      require_atomic? false
      atomic_upgrade? false

      change {GolfScoring.Competition.RoundEntryLifecycleGuard, operation: :withdraw_before_start}
    end

    update :mark_replaced_before_start_internal do
      public? false
      accept []
      transaction? false
      require_atomic? false
      atomic_upgrade? false
      change GolfScoring.Competition.Changes.MarkReplacedBeforeStartInternal
    end

    create :create_replacement_entry_internal do
      public? false
      accept [:event_id, :round_id, :player_id, :playing_group_id]
      transaction? false
      change GolfScoring.Competition.Changes.CreateReplacementEntryInternal
    end

    update :assign_playing_group_internal do
      public? false
      accept [:playing_group_id]
      require_atomic? false
    end

    update :assign_round_tee_internal do
      public? false
      accept [:round_tee_profile_snapshot_id]
      require_atomic? false
    end

    update :mark_participation_active_internal do
      public? false
      accept []
      require_atomic? false
      atomic_upgrade? false

      change {GolfScoring.Competition.RoundEntryScoringLifecycleGuard,
              operation: :mark_participation_active}
    end

    update :mark_participation_completed_internal do
      public? false
      accept []
      require_atomic? false
      atomic_upgrade? false

      change {GolfScoring.Competition.RoundEntryScoringLifecycleGuard,
              operation: :mark_participation_completed}
    end
  end

  policies do
    policy action(:add_round_entry) do
      access_type :strict

      authorize_if {GolfScoring.Accounts.Checks.ActiveEventRole,
                    roles: [:event_admin, :competition_manager]}
    end

    for action <- [:check_in_round_entry, :mark_no_show, :withdraw_before_start] do
      policy action(action) do
        access_type :strict

        # RoundEntryLifecycleGuard checks the active role under Event authority.
        # Keep this Ash preflight query-free so its transaction boundary runs first.
        authorize_if always()
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :registration_status, :atom do
      allow_nil? false
      public? false
      writable? false

      constraints one_of: [
                    :expected,
                    :checked_in,
                    :no_show,
                    :withdrawn_before_start,
                    :replaced_before_start
                  ]
    end

    attribute :participation_status, :atom do
      allow_nil? false
      public? false
      writable? false

      constraints one_of: [:not_started, :active, :completed, :withdrawn, :disqualified]
    end

    attribute :checked_in_at, :utc_datetime_usec do
      allow_nil? true
      public? false
      writable? false
    end

    timestamps()
  end

  relationships do
    belongs_to :event, GolfScoring.Competition.Event do
      allow_nil? false
      public? false
    end

    belongs_to :round, GolfScoring.Competition.Round do
      allow_nil? false
      public? false
    end

    belongs_to :player, GolfScoring.Competition.Player do
      allow_nil? false
      public? false
    end

    belongs_to :checked_in_by_staff_user, GolfScoring.Accounts.StaffUser do
      allow_nil? true
      public? false
      attribute_public? false
    end

    belongs_to :playing_group, GolfScoring.Competition.PlayingGroup do
      allow_nil? true
      public? false
      attribute_public? false
    end

    belongs_to :round_tee_profile_snapshot, GolfScoring.Competition.RoundTeeProfileSnapshot do
      allow_nil? true
      public? false
      attribute_public? false
    end
  end

  identities do
    identity :unique_player_per_round, [:round_id, :player_id]
    identity :unique_id_per_round, [:id, :round_id]
    identity :unique_entry_scope, [:id, :event_id, :round_id, :playing_group_id]
  end
end

defmodule GolfScoring.Competition.GroupRoleAssignment do
  @moduledoc "Durable pre-open Primary Scorer and Designated Verifier authority for a PlayingGroup."

  use Ash.Resource,
    domain: GolfScoring.Competition,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "group_role_assignments"
    repo GolfScoring.Repo

    references do
      reference :round, on_delete: :restrict

      reference :playing_group,
        on_delete: :restrict,
        match_with: [round_id: :round_id]

      reference :round_entry,
        on_delete: :restrict,
        match_with: [round_id: :round_id]
    end

    check_constraints do
      check_constraint :role, "group_role_assignments_role_must_be_valid",
        check: "role IN ('primary_scorer', 'designated_verifier')",
        message: "must be primary_scorer or designated_verifier"

      check_constraint :state, "group_role_assignments_state_must_be_valid",
        check: "state IN ('active', 'handed_over', 'revoked')",
        message: "must be active, handed_over, or revoked"

      check_constraint :assignment_version, "group_role_assignments_version_must_be_positive",
        check: "assignment_version > 0",
        message: "must be a positive integer"
    end

    custom_indexes do
      index [:round_id]
      index [:playing_group_id]
      index [:round_entry_id]
    end

    identity_index_names unique_active_per_group_role:
                           "group_role_assignments_one_active_per_group_role_index",
                         unique_active_entry_per_group:
                           "group_role_assignments_one_active_entry_per_group_index",
                         unique_revision_per_group_role:
                           "group_role_assignments_unique_revision_index"

    identity_wheres_to_sql unique_active_per_group_role: "state = 'active'",
                           unique_active_entry_per_group: "state = 'active'"
  end

  actions do
    read :read do
      public? false
      primary? true
    end

    create :create_internal do
      public? false

      accept [
        :round_id,
        :playing_group_id,
        :round_entry_id,
        :role,
        :state,
        :assignment_version
      ]

      validate present([
                 :round_id,
                 :playing_group_id,
                 :round_entry_id,
                 :role,
                 :assignment_version
               ])

      validate compare(:assignment_version, greater_than: 0)
      validate one_of(:state, [:active])
      validate one_of(:role, [:primary_scorer, :designated_verifier])
    end

    create :create_for_vacancy_internal do
      public? false

      accept [
        :round_id,
        :playing_group_id,
        :round_entry_id,
        :role,
        :state,
        :assignment_version
      ]

      transaction? false

      change {GolfScoring.Competition.Services.FillGroupRoleVacancy.WriteGuard,
              operation: :create_for_vacancy_internal}
    end

    update :mark_handed_over_internal do
      public? false
      accept []
      require_atomic? false

      validate attribute_equals(:state, :active)

      change set_attribute(:state, :handed_over)
    end

    update :mark_revoked_internal do
      public? false
      accept []
      require_atomic? false

      validate attribute_equals(:state, :active)

      change set_attribute(:state, :revoked)
    end

    update :mark_revoked_for_withdrawal_internal do
      public? false
      accept []
      transaction? false
      require_atomic? false
      atomic_upgrade? false

      change {GolfScoring.Competition.Services.AcceptRoundEntryWithdrawal.WriteGuard,
              operation: :mark_revoked_for_withdrawal_internal}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      public? false
      constraints one_of: [:primary_scorer, :designated_verifier]
    end

    attribute :state, :atom do
      allow_nil? false
      public? false
      default :active
      constraints one_of: [:active, :handed_over, :revoked]
    end

    attribute :assignment_version, :integer do
      allow_nil? false
      public? false
      constraints min: 1
    end

    timestamps()
  end

  relationships do
    belongs_to :round, GolfScoring.Competition.Round do
      allow_nil? false
      public? false
    end

    belongs_to :playing_group, GolfScoring.Competition.PlayingGroup do
      allow_nil? false
      public? false
    end

    belongs_to :round_entry, GolfScoring.Competition.RoundEntry do
      allow_nil? false
      public? false
    end
  end

  identities do
    identity :unique_active_per_group_role, [:playing_group_id, :role],
      where: expr(state == :active)

    identity :unique_active_entry_per_group, [:playing_group_id, :round_entry_id],
      where: expr(state == :active)

    identity :unique_revision_per_group_role, [:playing_group_id, :role, :assignment_version]
  end
end

defmodule GolfScoring.Accounts.EventStaffAssignment do
  @moduledoc "An explicit Event-scoped operational role held by a staff member."

  use Ash.Resource,
    domain: GolfScoring.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "event_staff_assignments"
    repo GolfScoring.Repo

    references do
      reference :event, on_delete: :restrict
      reference :staff_user, on_delete: :restrict
    end

    check_constraints do
      check_constraint :role, "event_staff_assignments_role_must_be_valid",
        check:
          "role IN ('event_admin', 'competition_manager', 'registration_staff', 'scoring_support')",
        message: "must be a valid Event staff role"

      check_constraint :status, "event_staff_assignments_status_must_be_valid",
        check: "status IN ('active', 'revoked')",
        message: "must be active or revoked"
    end

    custom_indexes do
      index [:event_id, :staff_user_id, :role],
        unique: true,
        name: "event_staff_assignments_active_role_index",
        where: "status = 'active'"

      index [:event_id, :role],
        name: "event_staff_assignments_active_event_role_index",
        where: "status = 'active'"

      index [:staff_user_id], name: "event_staff_assignments_staff_user_id_index"
    end

    identity_index_names unique_id_event_staff_role:
                           "event_staff_assignments_unique_id_event_staff_role_index"
  end

  actions do
    read :read do
      public? false
      primary? true
    end

    create :assign_event_staff_role do
      public? false
      accept [:event_id, :staff_user_id, :role]
      transaction? true
      change {GolfScoring.Accounts.EventStaffAssignmentGuard, operation: :assign}
    end

    create :create_initial_event_admin_internal do
      public? false
      accept [:event_id, :staff_user_id]
      transaction? true
      change GolfScoring.Accounts.Changes.BootstrapInitialEventAdmin
    end

    update :revoke_event_staff_role do
      public? false
      accept []
      transaction? true
      require_atomic? false
      atomic_upgrade? false
      change {GolfScoring.Accounts.EventStaffAssignmentGuard, operation: :revoke}
    end
  end

  policies do
    policy action(:assign_event_staff_role) do
      access_type :strict
      authorize_if {GolfScoring.Accounts.Checks.ActiveEventRole, role: :event_admin}
    end

    policy action(:revoke_event_staff_role) do
      access_type :strict
      authorize_if {GolfScoring.Accounts.Checks.ActiveEventRole, role: :event_admin}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :event_admin,
                    :competition_manager,
                    :registration_staff,
                    :scoring_support
                  ]
    end

    attribute :status, :atom do
      allow_nil? false
      default :active
      public? false
      writable? false
      constraints one_of: [:active, :revoked]
    end

    timestamps()
  end

  relationships do
    belongs_to :event, GolfScoring.Competition.Event do
      allow_nil? false
      public? false
    end

    belongs_to :staff_user, GolfScoring.Accounts.StaffUser do
      allow_nil? false
      public? false
    end
  end

  identities do
    identity :unique_id_event_staff_role, [:id, :event_id, :staff_user_id, :role]
  end
end

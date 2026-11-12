defmodule GolfScoring.Competition.RoundEntryParticipationRuling do
  @moduledoc """
  Immutable accepted evidence of a RoundEntry participation ruling.

  A2 stores only `round_withdrawal` evidence. PostgreSQL scoped foreign keys,
  constraints, and append-only triggers protect the record. The later
  acceptance coordinator is responsible for validating the checkpoint and
  authority before inserting evidence.
  """

  use Ash.Resource,
    domain: GolfScoring.Competition,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "round_entry_participation_rulings"
    repo GolfScoring.Repo

    references do
      reference :event, on_delete: :restrict
      reference :round, on_delete: :restrict, match_with: [event_id: :event_id]

      reference :round_entry,
        on_delete: :restrict,
        match_with: [
          event_id: :event_id,
          round_id: :round_id,
          playing_group_id: :playing_group_id
        ],
        name: "round_entry_participation_rulings_round_entry_same_scope_fkey"

      reference :playing_group,
        on_delete: :restrict,
        match_with: [round_id: :round_id]

      reference :authorized_by_event_staff_assignment,
        on_delete: :restrict,
        match_with: [
          event_id: :event_id,
          authorized_by_staff_user_id: :staff_user_id,
          authorized_by_role: :role
        ],
        name: "round_entry_participation_rulings_authority_same_event_fkey"

      reference :authorized_by_staff_user, on_delete: :restrict

      reference :checkpoint_hole_submission,
        on_delete: :restrict,
        match_with: [
          round_id: :round_id,
          playing_group_id: :playing_group_id,
          checkpoint_round_hole_id: :round_hole_id
        ],
        name: "round_entry_participation_rulings_checkpoint_submission_same_scope_fkey"

      reference :checkpoint_round_hole,
        on_delete: :restrict,
        match_with: [round_id: :round_id]

      reference :effective_round_hole,
        on_delete: :restrict,
        match_with: [round_id: :round_id],
        name: "round_entry_participation_rulings_effective_hole_same_round_fkey"
    end

    custom_indexes do
      index [:round_id, :effective_round_hole_id],
        name: "round_entry_participation_rulings_round_hole_index"
    end

    identity_index_names unique_round_entry:
                           "round_entry_participation_rulings_unique_round_entry_index"

    check_constraints do
      check_constraint :ruling_kind,
                       "round_entry_participation_rulings_ruling_kind_allowed",
                       check: "ruling_kind = 'round_withdrawal'",
                       message: "only round withdrawal evidence is supported"

      check_constraint :authorized_by_role,
                       "round_entry_participation_rulings_authorized_by_role_allowed",
                       check: "authorized_by_role IN ('event_admin', 'competition_manager')",
                       message: "authority must be an Event Admin or Competition Manager"

      check_constraint :checkpoint_play_index,
                       "round_entry_participation_rulings_checkpoint_play_index_range",
                       check: "checkpoint_play_index BETWEEN 0 AND 17",
                       message: "checkpoint play index must be within the scheduled route"

      check_constraint :effective_play_index,
                       "round_entry_participation_rulings_effective_play_index_range",
                       check: "effective_play_index BETWEEN 0 AND 17",
                       message: "effective play index must be within the scheduled route"

      check_constraint :preplay_boundary_confirmed,
                       "round_entry_participation_rulings_preplay_boundary_confirmed",
                       check: "preplay_boundary_confirmed IS TRUE",
                       message: "effective boundary requires verified pre-play evidence"
    end
  end

  actions do
    read :read do
      public? false
      primary? true
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :ruling_kind, :string do
      allow_nil? false
      public? false
      writable? false
    end

    attribute :authorized_by_role, :string do
      allow_nil? false
      public? false
      writable? false
    end

    attribute :checkpoint_play_index, :integer do
      allow_nil? false
      public? false
      writable? false
      constraints min: 0, max: 17
    end

    attribute :effective_play_index, :integer do
      allow_nil? false
      public? false
      writable? false
      constraints min: 0, max: 17
    end

    attribute :preplay_boundary_confirmed, :boolean do
      allow_nil? false
      public? false
      writable? false
    end

    attribute :accepted_at, :utc_datetime_usec do
      allow_nil? false
      public? false
      writable? false
    end

    timestamps()
  end

  relationships do
    belongs_to :event, GolfScoring.Competition.Event, allow_nil?: false, public?: false
    belongs_to :round, GolfScoring.Competition.Round, allow_nil?: false, public?: false

    belongs_to :round_entry, GolfScoring.Competition.RoundEntry,
      allow_nil?: false,
      public?: false

    belongs_to :playing_group, GolfScoring.Competition.PlayingGroup,
      allow_nil?: false,
      public?: false

    belongs_to :authorized_by_event_staff_assignment, GolfScoring.Accounts.EventStaffAssignment,
      allow_nil?: false,
      public?: false,
      attribute_public?: false

    belongs_to :authorized_by_staff_user, GolfScoring.Accounts.StaffUser,
      allow_nil?: false,
      public?: false,
      attribute_public?: false

    belongs_to :checkpoint_hole_submission, GolfScoring.Scoring.HoleSubmission,
      allow_nil?: false,
      public?: false,
      attribute_public?: false

    belongs_to :checkpoint_round_hole, GolfScoring.Competition.RoundHole,
      allow_nil?: false,
      public?: false,
      attribute_public?: false

    belongs_to :effective_round_hole, GolfScoring.Competition.RoundHole,
      allow_nil?: false,
      public?: false,
      attribute_public?: false
  end

  identities do
    identity :unique_round_entry, [:round_entry_id]
  end
end

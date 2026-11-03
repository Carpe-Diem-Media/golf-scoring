defmodule GolfScoring.Scoring.HoleSubmission do
  @moduledoc "Immutable server receipt for one accepted whole-group-hole command."

  use Ash.Resource,
    domain: GolfScoring.Scoring,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "hole_submissions"
    repo GolfScoring.Repo

    references do
      reference :round, on_delete: :restrict

      reference :playing_group,
        on_delete: :restrict,
        match_with: [round_id: :round_id]

      reference :round_hole,
        on_delete: :restrict,
        match_with: [round_id: :round_id]

      reference :submitted_by_round_entry,
        on_delete: :restrict,
        match_with: [round_id: :round_id]

      reference :submitted_by_staff_user, on_delete: :restrict
      reference :group_role_assignment, on_delete: :restrict
    end

    custom_indexes do
      index [:round_id, :playing_group_id, :round_hole_id]
      index [:submitted_by_round_entry_id]
      index [:submitted_by_staff_user_id]
      index [:group_role_assignment_id]
      index [:client_submission_id]
    end

    identity_index_names unique_client_submission:
                           "hole_submissions_unique_client_submission_index"

    check_constraints do
      check_constraint :expected_group_score_revision,
                       "hole_submissions_expected_revision_non_negative",
                       check: "expected_group_score_revision >= 0",
                       message: "expected group score revision must be non-negative"

      check_constraint :role_assignment_version,
                       "hole_submissions_role_assignment_version_positive",
                       check: "role_assignment_version IS NULL OR role_assignment_version > 0",
                       message: "role assignment version must be positive when present"

      check_constraint :payload_fingerprint, "hole_submissions_payload_fingerprint_non_empty",
        check: "octet_length(payload_fingerprint) > 0",
        message: "payload fingerprint must be non-empty"

      check_constraint :submitted_by_round_entry_id, "hole_submissions_exactly_one_actor",
        check: """
        (
          (submitted_by_staff_user_id IS NOT NULL)::int +
          (submitted_by_round_entry_id IS NOT NULL)::int
        ) = 1
        """,
        message: "exactly one submitter actor type is required"

      check_constraint :submitted_by_round_entry_id, "hole_submissions_actor_assignment_shape",
        check: """
        (
          submitted_by_staff_user_id IS NOT NULL
          AND submitted_by_round_entry_id IS NULL
          AND group_role_assignment_id IS NULL
          AND role_assignment_version IS NULL
        )
        OR (
          submitted_by_staff_user_id IS NULL
          AND submitted_by_round_entry_id IS NOT NULL
          AND group_role_assignment_id IS NOT NULL
          AND role_assignment_version IS NOT NULL
          AND role_assignment_version > 0
        )
        """,
        message: "submitter actor and assignment fields are inconsistent"

      check_constraint :source, "hole_submissions_source_allowed",
        check: "source IN ('normal', 'paper_recovery')",
        message: "source must be normal or paper recovery"

      check_constraint :recovery_reason, "hole_submissions_source_reason",
        check: """
        (source = 'normal' AND recovery_reason IS NULL)
        OR (
          source = 'paper_recovery'
          AND recovery_reason IS NOT NULL
          AND recovery_reason = btrim(
            recovery_reason,
            chr(9) || chr(10) || chr(11) || chr(12) || chr(13) || chr(32) ||
              chr(133) || chr(160) || chr(5760) || chr(8192) || chr(8193) ||
              chr(8194) || chr(8195) || chr(8196) || chr(8197) || chr(8198) ||
              chr(8199) || chr(8200) || chr(8201) || chr(8202) || chr(8232) ||
              chr(8233) || chr(8239) || chr(8287) || chr(12288)
          )
          AND char_length(btrim(
            recovery_reason,
            chr(9) || chr(10) || chr(11) || chr(12) || chr(13) || chr(32) ||
              chr(133) || chr(160) || chr(5760) || chr(8192) || chr(8193) ||
              chr(8194) || chr(8195) || chr(8196) || chr(8197) || chr(8198) ||
              chr(8199) || chr(8200) || chr(8201) || chr(8202) || chr(8232) ||
              chr(8233) || chr(8239) || chr(8287) || chr(12288)
          )) > 0
        )
        """,
        message: "paper recovery requires a trimmed nonblank reason"

      check_constraint :submitted_by_staff_user_id,
                       "hole_submissions_paper_recovery_staff_only",
                       check:
                         "source <> 'paper_recovery' OR submitted_by_staff_user_id IS NOT NULL",
                       message: "paper recovery receipts require a staff submitter"
    end
  end

  actions do
    read :read do
      public? false
      primary? true
    end

    create :create_accepted_internal do
      public? false

      accept [
        :client_submission_id,
        :round_id,
        :playing_group_id,
        :round_hole_id,
        :expected_group_score_revision,
        :submitted_by_round_entry_id,
        :submitted_by_staff_user_id,
        :group_role_assignment_id,
        :role_assignment_version,
        :payload_fingerprint,
        :submitted_payload,
        :captured_at,
        :source,
        :recovery_reason
      ]

      change set_attribute(:accepted_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :client_submission_id, :uuid do
      allow_nil? false
      public? false
    end

    attribute :expected_group_score_revision, :integer do
      allow_nil? false
      public? false
      constraints min: 0
    end

    attribute :role_assignment_version, :integer do
      allow_nil? true
      public? false
      constraints min: 1
    end

    attribute :payload_fingerprint, :binary do
      allow_nil? false
      public? false
    end

    attribute :source, :string do
      allow_nil? false
      default "normal"
      public? false
    end

    attribute :recovery_reason, :string do
      allow_nil? true
      public? false
    end

    attribute :submitted_payload, :map do
      allow_nil? false
      public? false
    end

    attribute :captured_at, :utc_datetime_usec do
      allow_nil? false
      public? false
    end

    attribute :accepted_at, :utc_datetime_usec do
      allow_nil? false
      public? false
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

    belongs_to :round_hole, GolfScoring.Competition.RoundHole do
      allow_nil? false
      public? false
    end

    belongs_to :submitted_by_round_entry, GolfScoring.Competition.RoundEntry do
      allow_nil? true
      public? false
      attribute_public? false
    end

    belongs_to :submitted_by_staff_user, GolfScoring.Accounts.StaffUser do
      allow_nil? true
      public? false
      attribute_public? false
    end

    belongs_to :group_role_assignment, GolfScoring.Competition.GroupRoleAssignment do
      allow_nil? true
      public? false
      attribute_public? false
    end
  end

  identities do
    identity :unique_client_submission, [:client_submission_id]
  end
end

defmodule GolfScoring.Scoring.ScoreVerification do
  @moduledoc """
  Certification evidence for one exact HoleResult revision.

  Pending evidence is not certification. A pending record can become verified
  by an eligible player or overridden by authorized staff with an audit reason.
  A verified or overridden record can become superseded only after its result
  revision changes. Superseded evidence is retained and is terminal.

  Verification and correction share the scorecard `:score_row` lock. Internal
  writes require a single-use capability from their owning coordinator; private
  Ash actions and caller-supplied context alone do not authorize certification.
  """

  use Ash.Resource, domain: GolfScoring.Scoring, data_layer: AshPostgres.DataLayer

  postgres do
    table "score_verifications"
    repo GolfScoring.Repo

    references do
      reference :hole_result, on_delete: :restrict
      reference :scorecard, on_delete: :restrict, match_with: [round_id: :round_id]
      reference :round, on_delete: :restrict
      reference :playing_group, on_delete: :restrict, match_with: [round_id: :round_id]
      reference :subject_round_entry, on_delete: :restrict, match_with: [round_id: :round_id]
      reference :verifier_round_entry, on_delete: :restrict, match_with: [round_id: :round_id]
      reference :role_assignment, on_delete: :restrict
      reference :overridden_by_staff_user, on_delete: :restrict
    end

    custom_indexes do
      index [:role_assignment_id]
      index [:verifier_round_entry_id]
      index [:round_id, :playing_group_id]
    end

    identity_index_names unique_revision: "score_verifications_unique_revision_index"

    check_constraints do
      check_constraint :hole_result_revision, "score_verifications_revision_positive",
        check: "hole_result_revision > 0",
        message: "must be positive"

      check_constraint :status, "score_verifications_status_shape",
        check: """
        (status = 'pending' AND verifier_round_entry_id IS NULL AND role_assignment_id IS NULL AND role_assignment_version IS NULL AND overridden_by_staff_user_id IS NULL AND override_reason IS NULL)
        OR (status = 'verified' AND verifier_round_entry_id IS NOT NULL AND role_assignment_id IS NOT NULL AND role_assignment_version IS NOT NULL AND role_assignment_version > 0 AND overridden_by_staff_user_id IS NULL AND override_reason IS NULL)
        OR (status = 'overridden' AND verifier_round_entry_id IS NULL AND role_assignment_id IS NULL AND role_assignment_version IS NULL AND overridden_by_staff_user_id IS NOT NULL AND override_reason IS NOT NULL AND length(btrim(override_reason)) > 0)
        OR (status = 'superseded' AND ((verifier_round_entry_id IS NOT NULL AND role_assignment_id IS NOT NULL AND role_assignment_version IS NOT NULL AND role_assignment_version > 0 AND overridden_by_staff_user_id IS NULL AND override_reason IS NULL) OR (verifier_round_entry_id IS NULL AND role_assignment_id IS NULL AND role_assignment_version IS NULL AND overridden_by_staff_user_id IS NOT NULL AND override_reason IS NOT NULL AND length(btrim(override_reason)) > 0)))
        """,
        message: "must match its certification evidence"

      check_constraint :verifier_round_entry_id, "score_verifications_no_self_verification",
        check:
          "verifier_round_entry_id IS NULL OR verifier_round_entry_id <> subject_round_entry_id",
        message: "cannot verify their own result"
    end
  end

  actions do
    read :read do
      primary? true
      public? false
    end

    create :create_pending_internal do
      public? false
      change GolfScoring.Scoring.ScoreVerificationWriteGuard

      accept [
        :round_id,
        :playing_group_id,
        :scorecard_id,
        :subject_round_entry_id,
        :hole_result_id,
        :hole_result_revision
      ]
    end

    update :verify_internal do
      public? false
      change GolfScoring.Scoring.ScoreVerificationWriteGuard
      require_atomic? false
      accept [:verifier_round_entry_id, :role_assignment_id, :role_assignment_version]
      validate attribute_equals(:status, :pending)
      change set_attribute(:status, :verified)
    end

    update :override_internal do
      public? false
      change GolfScoring.Scoring.ScoreVerificationWriteGuard
      require_atomic? false
      accept [:overridden_by_staff_user_id, :override_reason]
      validate attribute_equals(:status, :pending)
      change set_attribute(:status, :overridden)
    end

    update :supersede_internal do
      public? false
      change GolfScoring.Scoring.ScoreVerificationWriteGuard
      require_atomic? false
      accept []
      validate one_of(:status, [:verified, :overridden])
      change GolfScoring.Scoring.ScoreVerification.StaleRevision
      change set_attribute(:status, :superseded)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :hole_result_revision, :integer do
      allow_nil? false
      public? false
      constraints min: 1
    end

    attribute :status, :atom do
      allow_nil? false
      public? false
      default :pending
      constraints one_of: [:pending, :verified, :overridden, :superseded]
    end

    attribute :role_assignment_version, :integer, public?: false
    attribute :override_reason, :string, public?: false
    timestamps()
  end

  relationships do
    belongs_to :hole_result, GolfScoring.Scoring.HoleResult, allow_nil?: false, public?: false
    belongs_to :scorecard, GolfScoring.Scoring.Scorecard, allow_nil?: false, public?: false
    belongs_to :round, GolfScoring.Competition.Round, allow_nil?: false, public?: false

    belongs_to :playing_group, GolfScoring.Competition.PlayingGroup,
      allow_nil?: false,
      public?: false

    belongs_to :subject_round_entry, GolfScoring.Competition.RoundEntry,
      allow_nil?: false,
      public?: false

    belongs_to :verifier_round_entry, GolfScoring.Competition.RoundEntry, public?: false
    belongs_to :role_assignment, GolfScoring.Competition.GroupRoleAssignment, public?: false
    belongs_to :overridden_by_staff_user, GolfScoring.Accounts.StaffUser, public?: false
  end

  identities do
    identity :unique_revision, [:hole_result_id, :hole_result_revision]
  end
end

defmodule GolfScoring.Scoring.ScoreVerification.StaleRevision do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &validate_revision/1)
  end

  defp validate_revision(changeset) do
    record = changeset.data

    with true <- GolfScoring.Repo.in_transaction?(),
         {:ok, _} <- GolfScoring.LockProtocol.acquire!(score_row: [record.scorecard_id]),
         [[revision]] <-
           GolfScoring.Repo.query!("SELECT revision FROM hole_results WHERE id = $1::uuid", [
             Ecto.UUID.dump!(record.hole_result_id)
           ]).rows,
         true <- revision != record.hole_result_revision do
      changeset
    else
      _ ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "requires a non-current result revision under the scorecard lock"
        )
    end
  end
end

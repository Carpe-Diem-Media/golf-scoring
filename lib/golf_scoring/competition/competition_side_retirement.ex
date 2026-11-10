defmodule GolfScoring.Competition.CompetitionSideRetirement do
  @moduledoc """
  Immutable accepted retirement evidence for one CompetitionSide in one RoundCompetition.

  PostgreSQL append-only guards and scoped foreign keys are authoritative. Accepted rows
  are never updated or destroyed through ordinary application paths.
  """

  use Ash.Resource,
    domain: GolfScoring.Competition,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "competition_side_retirements"
    repo GolfScoring.Repo

    references do
      reference :event, on_delete: :restrict
      reference :round, on_delete: :restrict, match_with: [event_id: :event_id]

      reference :round_competition,
        on_delete: :restrict,
        match_with: [event_id: :event_id, round_id: :round_id]

      reference :competition_side,
        on_delete: :restrict,
        match_with: [round_competition_id: :round_competition_id, round_id: :round_id]

      reference :competition_side_result,
        on_delete: :restrict,
        match_with: [competition_side_id: :competition_side_id]

      reference :playing_group,
        on_delete: :restrict,
        match_with: [round_id: :round_id]

      reference :checkpoint_round_hole, on_delete: :restrict, match_with: [round_id: :round_id]

      reference :effective_round_hole, on_delete: :restrict, match_with: [round_id: :round_id]

      reference :checkpoint_hole_submission,
        on_delete: :restrict,
        match_with: [round_id: :round_id]

      reference :authorized_by_staff_user, on_delete: :restrict
    end

    custom_indexes do
      index [:competition_side_id], unique: true, name: "competition_side_retirements_unique_side"

      index [:acceptance_command_id],
        unique: true,
        name: "competition_side_retirements_unique_command"

      index [:round_competition_id]
      index [:event_id]
      index [:competition_side_result_id]
    end

    check_constraints do
      check_constraint :reason, "competition_side_retirements_reason_present",
        check: """
        reason IS NOT NULL
        AND reason = btrim(
          reason,
          chr(9) || chr(10) || chr(11) || chr(12) || chr(13) || chr(32) ||
            chr(133) || chr(160) || chr(5760) || chr(8192) || chr(8193) ||
            chr(8194) || chr(8195) || chr(8196) || chr(8197) || chr(8198) ||
            chr(8199) || chr(8200) || chr(8201) || chr(8202) || chr(8232) ||
            chr(8233) || chr(8239) || chr(8287) || chr(12288)
        )
        AND char_length(btrim(
          reason,
          chr(9) || chr(10) || chr(11) || chr(12) || chr(13) || chr(32) ||
            chr(133) || chr(160) || chr(5760) || chr(8192) || chr(8193) ||
            chr(8194) || chr(8195) || chr(8196) || chr(8197) || chr(8198) ||
            chr(8199) || chr(8200) || chr(8201) || chr(8202) || chr(8232) ||
            chr(8233) || chr(8239) || chr(8287) || chr(12288)
        )) > 0
        """,
        message: "reason must be a trimmed nonblank string"

      check_constraint :effective_play_index,
                       "competition_side_retirements_effective_play_index_range",
                       check: "effective_play_index BETWEEN 0 AND 17",
                       message: "effective play index must be within the scheduled route"

      check_constraint :checkpoint_play_index,
                       "competition_side_retirements_checkpoint_play_index_range",
                       check: "checkpoint_play_index BETWEEN 0 AND 17",
                       message: "checkpoint play index must be within the scheduled route"

      check_constraint :preplay_boundary_confirmed,
                       "competition_side_retirements_preplay_boundary_confirmed",
                       check: "preplay_boundary_confirmed IS TRUE",
                       message: "effective boundary requires explicit pre-play staff attestation"
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
        :event_id,
        :round_id,
        :round_competition_id,
        :competition_side_id,
        :competition_side_result_id,
        :playing_group_id,
        :authorized_by_staff_user_id,
        :reason,
        :acceptance_command_id,
        :command_meaning_fingerprint,
        :checkpoint_hole_submission_id,
        :checkpoint_round_hole_id,
        :checkpoint_play_index,
        :effective_round_hole_id,
        :effective_play_index,
        :preplay_boundary_confirmed
      ]

      change set_attribute(:accepted_at, &DateTime.utc_now/0)
      change GolfScoring.Competition.CompetitionSideRetirementWriteGuard
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :reason, :string do
      allow_nil? false
      public? false
    end

    attribute :acceptance_command_id, :uuid do
      allow_nil? false
      public? false
    end

    attribute :command_meaning_fingerprint, :binary do
      allow_nil? false
      public? false
    end

    attribute :checkpoint_play_index, :integer do
      allow_nil? false
      public? false
      constraints min: 0, max: 17
    end

    attribute :effective_play_index, :integer do
      allow_nil? false
      public? false
      constraints min: 0, max: 17
    end

    attribute :preplay_boundary_confirmed, :boolean do
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
    belongs_to :event, GolfScoring.Competition.Event, allow_nil?: false, public?: false
    belongs_to :round, GolfScoring.Competition.Round, allow_nil?: false, public?: false

    belongs_to :round_competition, GolfScoring.Competition.RoundCompetition,
      allow_nil?: false,
      public?: false

    belongs_to :competition_side, GolfScoring.Competition.CompetitionSide,
      allow_nil?: false,
      public?: false

    belongs_to :competition_side_result, GolfScoring.Competition.CompetitionSideResult,
      allow_nil?: false,
      public?: false

    belongs_to :playing_group, GolfScoring.Competition.PlayingGroup,
      allow_nil?: false,
      public?: false

    belongs_to :checkpoint_round_hole, GolfScoring.Competition.RoundHole,
      allow_nil?: false,
      public?: false,
      attribute_public?: false

    belongs_to :effective_round_hole, GolfScoring.Competition.RoundHole,
      allow_nil?: false,
      public?: false,
      attribute_public?: false

    belongs_to :checkpoint_hole_submission, GolfScoring.Scoring.HoleSubmission,
      allow_nil?: false,
      public?: false,
      attribute_public?: false

    belongs_to :authorized_by_staff_user, GolfScoring.Accounts.StaffUser,
      allow_nil?: false,
      public?: false,
      attribute_public?: false
  end

  identities do
    identity :unique_acceptance_per_side, [:competition_side_id]
    identity :unique_acceptance_command, [:acceptance_command_id]
  end
end

defmodule GolfScoring.Scoring.Scorecard do
  @moduledoc "One player's authoritative scoring container for one RoundEntry."

  use Ash.Resource,
    domain: GolfScoring.Scoring,
    data_layer: AshPostgres.DataLayer

  @states [:not_started, :in_progress, :complete, :review_required, :verified]

  postgres do
    table "scorecards"
    repo GolfScoring.Repo

    references do
      reference :round, on_delete: :restrict

      reference :round_entry,
        on_delete: :restrict,
        match_with: [round_id: :round_id]
    end

    custom_indexes do
      index [:round_id, :state]
      index [:round_entry_id]
      index [:round_id]
    end

    identity_index_names unique_round_entry: "scorecards_unique_round_entry_index",
                         unique_id_per_round: "scorecards_unique_id_per_round_index"

    check_constraints do
      check_constraint :state, "scorecards_state_must_be_valid",
        check:
          "state IN ('not_started', 'in_progress', 'complete', 'review_required', 'verified')",
        message: "must be a valid scorecard state"
    end
  end

  actions do
    read :read do
      public? false
      primary? true
    end

    create :create_internal do
      public? false

      accept [:round_id, :round_entry_id, :state]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :state, :atom do
      allow_nil? false
      public? false
      default :not_started
      constraints one_of: @states
    end

    timestamps()
  end

  relationships do
    belongs_to :round, GolfScoring.Competition.Round do
      allow_nil? false
      public? false
    end

    belongs_to :round_entry, GolfScoring.Competition.RoundEntry do
      allow_nil? false
      public? false
    end
  end

  identities do
    identity :unique_round_entry, [:round_entry_id]
    identity :unique_id_per_round, [:id, :round_id]
  end

  def states, do: @states
end

defmodule GolfScoring.Competition.MysteryReveal do
  @moduledoc "One terminal, server-side reveal for a MysteryHoleRule."

  use Ash.Resource,
    domain: GolfScoring.Competition,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "mystery_reveals"
    repo GolfScoring.Repo

    references do
      reference :mystery_hole_rule, on_delete: :restrict
    end

    identity_index_names unique_mystery_hole_rule:
                           "mystery_reveals_unique_mystery_hole_rule_index"
  end

  actions do
    read :read do
      public? false
      primary? true
    end

    create :create_internal do
      public? false
      accept [:mystery_hole_rule_id]
      change GolfScoring.Competition.MysteryRevealGuard
    end
  end

  attributes do
    uuid_primary_key :id
    timestamps()
  end

  relationships do
    belongs_to :mystery_hole_rule, GolfScoring.Competition.MysteryHoleRule do
      allow_nil? false
      public? false
      attribute_public? false
    end
  end

  identities do
    identity :unique_mystery_hole_rule, [:mystery_hole_rule_id]
  end
end

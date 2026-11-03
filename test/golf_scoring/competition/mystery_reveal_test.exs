defmodule GolfScoring.Competition.MysteryRevealTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias GolfScoring.Competition
  alias GolfScoring.Competition.MysteryReveal
  alias GolfScoring.Competition.PlayingGroup
  alias GolfScoring.Competition.Policies.MysteryRevealEligibility

  test "resource is registered with private read and system create only" do
    assert MysteryReveal in Ash.Domain.Info.resources(Competition)

    assert %{public?: false} = Info.action(MysteryReveal, :read)
    assert %{public?: false} = Info.action(MysteryReveal, :create_internal)
    refute Info.action(MysteryReveal, :create)
    refute Info.action(MysteryReveal, :update)
    refute Info.action(MysteryReveal, :destroy)
    refute Info.attribute(MysteryReveal, :mystery_hole_rule_id).public?
    refute Info.relationship(MysteryReveal, :mystery_hole_rule).public?
    refute Info.relationship(MysteryReveal, :playing_group)
    refute Info.attribute(PlayingGroup, :mystery_reveal)
  end

  test "one unresolved required group blocks global reveal" do
    assert {:ok, %{eligible?: false, unresolved_group_ids: ["group-b"]}} =
             MysteryRevealEligibility.evaluate(
               ["group-b", "group-a"],
               [
                 %{playing_group_id: "group-a", resolution: :submitted},
                 %{playing_group_id: "group-b", resolution: :unresolved}
               ]
             )
  end

  test "all trusted resolved classifications allow global reveal" do
    assert {:ok, %{eligible?: true, unresolved_group_ids: []}} =
             MysteryRevealEligibility.evaluate(
               ["group-c", "group-a", "group-b"],
               [
                 %{playing_group_id: "group-a", resolution: :submitted},
                 %{playing_group_id: "group-b", resolution: :paper_recovered},
                 %{playing_group_id: "group-c", resolution: :not_applicable}
               ]
             )
  end

  test "disqualification without a resolution remains unresolved" do
    assert {:ok, %{eligible?: false, unresolved_group_ids: ["group-a"]}} =
             MysteryRevealEligibility.evaluate(
               ["group-a"],
               [
                 %{
                   playing_group_id: "group-a",
                   resolution: :unresolved,
                   disqualified?: true
                 }
               ]
             )
  end

  test "duplicate resolution facts fail closed" do
    assert {:error, {:duplicate_resolution_facts, ["group-a"]}} =
             MysteryRevealEligibility.evaluate(
               ["group-a"],
               [
                 %{playing_group_id: "group-a", resolution: :submitted},
                 %{playing_group_id: "group-a", resolution: :unresolved}
               ]
             )
  end

  test "missing required group facts fail closed deterministically" do
    assert {:error, {:missing_resolution_facts, ["group-a", "group-c"]}} =
             MysteryRevealEligibility.evaluate(
               ["group-c", "group-a", "group-b"],
               [%{playing_group_id: "group-b", resolution: :submitted}]
             )
  end

  test "an accepted submission remains resolved after disqualification or exclusion" do
    assert {:ok, %{eligible?: true, unresolved_group_ids: []}} =
             MysteryRevealEligibility.evaluate(
               ["group-a"],
               [
                 %{
                   playing_group_id: "group-a",
                   resolution: :submitted,
                   disqualified?: true,
                   excluded?: true
                 }
               ]
             )
  end
end

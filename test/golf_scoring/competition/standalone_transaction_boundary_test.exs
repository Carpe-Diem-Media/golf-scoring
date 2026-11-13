defmodule GolfScoring.Competition.StandaloneTransactionBoundaryTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Competition.Services.AssignEntryToGroup
  alias GolfScoring.Competition.Services.AssignGroupRole
  alias GolfScoring.Competition.Services.AssignPlayingGroupStart
  alias GolfScoring.Competition.Services.AssignRoundEntryCategories
  alias GolfScoring.Competition.Services.AssignRoundTee
  alias GolfScoring.Competition.Services.HandoverGroupRole
  alias GolfScoring.Competition.Services.ReplaceRoundEntry
  alias GolfScoring.Competition.Services.RevokeGroupRole
  alias GolfScoring.Competition.Services.SetSideMembership
  alias GolfScoring.Repo

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  test "all competition entrypoints reject an open transaction without issuing SQL" do
    actor = %{id: Ecto.UUID.generate()}

    [
      event_id,
      round_id,
      group_id,
      entry_id,
      player_id,
      competition_id,
      side_id,
      hole_id,
      snapshot_id,
      category_id
    ] = Enum.map(1..10, fn _ -> Ecto.UUID.generate() end)

    calls = [
      {:handover_group_role,
       fn ->
         HandoverGroupRole.run(actor, event_id, round_id, group_id, entry_id, :primary_scorer)
       end},
      {:assign_group_role,
       fn ->
         AssignGroupRole.run(actor, event_id, round_id, group_id, entry_id, :primary_scorer)
       end},
      {:revoke_group_role,
       fn -> RevokeGroupRole.run(actor, event_id, round_id, group_id, :primary_scorer, "test") end},
      {:replace_round_entry,
       fn -> ReplaceRoundEntry.run(actor, event_id, round_id, entry_id, player_id) end},
      {:assign_playing_group_start,
       fn -> AssignPlayingGroupStart.run(actor, event_id, round_id, group_id, hole_id, 1) end},
      {:assign_entry_to_group,
       fn -> AssignEntryToGroup.run(actor, event_id, round_id, entry_id, group_id) end},
      {:set_side_membership,
       fn ->
         SetSideMembership.run(actor, event_id, round_id, competition_id, side_id, [entry_id])
       end},
      {:assign_round_tee,
       fn -> AssignRoundTee.run(actor, event_id, round_id, entry_id, snapshot_id) end},
      {:assign_round_entry_categories,
       fn ->
         AssignRoundEntryCategories.run(actor, event_id, round_id, entry_id, [category_id])
       end}
    ]

    assert {:ok, :all_rejected} =
             Repo.transaction(fn ->
               handler = {__MODULE__, make_ref()}
               event = [:golf_scoring, :repo, :query]
               :ok = :telemetry.attach(handler, event, &__MODULE__.observe_query/4, self())

               try do
                 Enum.each(calls, fn {service, call} ->
                   assert {:error, :transaction_already_open} = call.(),
                          "#{service} did not reject the open transaction"
                 end)

                 refute_receive {:standalone_transaction_boundary_query, _metadata}, 0
               after
                 :telemetry.detach(handler)
               end

               :all_rejected
             end)
  end

  def observe_query(_event, _measurements, metadata, owner) do
    send(owner, {:standalone_transaction_boundary_query, metadata})
  end
end

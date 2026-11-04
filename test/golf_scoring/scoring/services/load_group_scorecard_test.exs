defmodule GolfScoring.Scoring.Services.LoadGroupScorecardTest do
  use GolfScoring.DataCase, async: false

  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Competition.Services.AssignPlayingGroupStart
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures

  setup do
    Process.put(:gls34_prefix, "gls72-read-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls34_prefix) end)

    :ok
  end

  test "loads the assigned roster, frozen hole facts and physical route" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    grant = issue_grant!(setup, hd(setup.entries))

    assert {:ok, scorecard} =
             Scoring.load_group_scorecard(grant, setup.event.id, setup.round.id, setup.group.id)

    assert scorecard.lifecycle == :scoring_active
    assert scorecard.group_label == "1A"
    assert scorecard.current_hole.display_hole_number == 1
    assert length(scorecard.rotated_route) == 18
    assert length(scorecard.players) == 2

    assert Enum.all?(scorecard.players, fn player ->
             player.hole_facts[scorecard.current_hole.id].par == 4 and
               is_integer(player.strokes_by_hole[scorecard.current_hole.id])
           end)
  end

  test "rejects a scorecard route from another event" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    other_event = PaperRecoveryFixtures.setup_submit_fixture!(2)
    grant = issue_grant!(setup, hd(setup.entries))

    assert {:error, :not_assigned} =
             Scoring.load_group_scorecard(
               grant,
               other_event.event.id,
               other_event.round.id,
               other_event.group.id
             )
  end

  test "rejects a group in the same round when the scorer is not assigned to it" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    grant = issue_grant!(setup, hd(setup.entries))
    PaperRecoveryFixtures.set_round_state!(setup.round, :draft)

    assert {:ok, other_group} =
             Competition.create_playing_group(setup.event.id, setup.round.id, actor: setup.admin)

    PaperRecoveryFixtures.set_round_state!(setup.round, :scoring_open)

    assert {:error, :not_primary_scorer} =
             Scoring.load_group_scorecard(grant, setup.event.id, setup.round.id, other_group.id)
  end

  test "rejects a group member who does not hold the active primary scorer assignment" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    grant = issue_grant!(setup, Enum.at(setup.entries, 1))

    assert {:error, :not_primary_scorer} =
             Scoring.load_group_scorecard(grant, setup.event.id, setup.round.id, setup.group.id)
  end

  test "finds the scorecard assigned to the current grant for player home" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    grant = issue_grant!(setup, hd(setup.entries))

    assert {:ok, scorecard} = Scoring.load_assigned_group_scorecard(grant)

    assert scorecard.event_id == setup.event.id
    assert scorecard.round_id == setup.round.id
    assert scorecard.group_id == setup.group.id
  end

  test "uses distinct group labels for shotgun groups starting at different holes" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    PaperRecoveryFixtures.set_round_state!(setup.round, :draft)

    assert {:ok, group_b} =
             Competition.create_playing_group(setup.event.id, setup.round.id, actor: setup.admin)

    start_hole_b = Enum.at(setup.route, 9)

    assert {:ok, _} =
             AssignPlayingGroupStart.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               group_b.id,
               start_hole_b.id,
               1
             )

    entries_b = PaperRecoveryFixtures.add_player_entries_to_group!(setup, group_b, 2)
    PaperRecoveryFixtures.set_round_state!(setup.round, :scoring_open)

    grant_a = issue_grant!(setup, hd(setup.entries))
    grant_b = issue_grant!(setup, hd(entries_b))

    assert {:ok, group_a_card} =
             Scoring.load_group_scorecard(grant_a, setup.event.id, setup.round.id, setup.group.id)

    assert {:ok, group_b_card} =
             Scoring.load_group_scorecard(grant_b, setup.event.id, setup.round.id, group_b.id)

    assert group_a_card.group_label == "1A"
    assert group_b_card.group_label == "10A"
  end

  defp issue_grant!(setup, entry) do
    {:ok, %{grant: grant}} =
      Accounts.issue_player_access(setup.admin, setup.event.id, entry.player_id)

    grant
  end
end

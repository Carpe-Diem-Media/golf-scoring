defmodule GolfScoringWeb.Scoring.GroupScorecardBrowserIntegrationTest do
  use GolfScoringWeb.ConnCase, async: false

  import Phoenix.ConnTest

  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Repo
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures
  alias GolfScoringWeb.Player.Session

  @moduletag :browser_integration

  setup do
    assert Mix.env() == :test

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    assert Repo.query!("SELECT current_database()").rows == [["golf_scoring_test"]]

    :ok
  end

  test "authenticated browser captures offline and reconciles the accepted final hole", %{
    conn: conn
  } do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    scorer = hd(setup.entries)

    for revision <- 0..16 do
      hole = route_hole_at_revision!(setup, revision)

      assert {:ok, _receipt} =
               Scoring.submit_group_hole(
                 setup.admin,
                 setup.event.id,
                 setup.round.id,
                 service_command(setup, revision, hole.id)
               )
    end

    {:ok, %{grant: grant}} =
      Accounts.issue_player_access(setup.admin, setup.event.id, scorer.player_id)

    session_conn =
      conn
      |> init_test_session(%{})
      |> Session.put_grant_id(grant.id)

    response_conn = get(session_conn, scorecard_path(setup))

    session_cookie =
      response_conn
      |> get_resp_cookies()
      |> Map.fetch!("_golf_scoring_key")
      |> Map.fetch!(:value)

    {:ok, server} =
      Bandit.start_link(
        plug: GolfScoringWeb.Endpoint,
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    Process.unlink(server)

    on_exit(fn ->
      if Process.alive?(server), do: Supervisor.stop(server)
    end)

    assert {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    fixture = %{
      base_url: "http://localhost:#{port}",
      scorecard_path: scorecard_path(setup),
      session_cookie: session_cookie,
      round_entry_ids: Enum.map(setup.entries, & &1.id),
      scenario: "final_hole"
    }

    {output, status} =
      System.cmd("npm", ["run", "test:browser:phoenix"],
        cd: File.cwd!(),
        env: [{"GLS37_BROWSER_FIXTURE", Jason.encode!(fixture)}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "1 passed", output

    assert [[36]] =
             Repo.query!(
               "SELECT count(*)::int FROM hole_results WHERE round_id = $1::uuid",
               [Ecto.UUID.dump!(setup.round.id)]
             ).rows

    assert [[18]] =
             Repo.query!(
               "SELECT count(*)::int FROM hole_submissions WHERE playing_group_id = $1::uuid",
               [Ecto.UUID.dump!(setup.group.id)]
             ).rows

    assert Repo.query!(
             "SELECT scoring_revision FROM playing_groups WHERE id = $1::uuid",
             [Ecto.UUID.dump!(setup.group.id)]
           ).rows == [[18]]
  end

  test "authenticated browser reconciles an accepted Hole 1 without a second score", %{
    conn: conn
  } do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)

    run_authenticated_browser!(conn, setup, "accepted_hole_1")

    assert [[2]] =
             Repo.query!(
               "SELECT count(*)::int FROM hole_results WHERE round_id = $1::uuid",
               [Ecto.UUID.dump!(setup.round.id)]
             ).rows

    assert [[1]] =
             Repo.query!(
               "SELECT count(*)::int FROM hole_submissions WHERE playing_group_id = $1::uuid",
               [Ecto.UUID.dump!(setup.group.id)]
             ).rows

    assert Repo.query!(
             "SELECT scoring_revision FROM playing_groups WHERE id = $1::uuid",
             [Ecto.UUID.dump!(setup.group.id)]
           ).rows == [[1]]
  end

  test "authenticated browser reconciles an accepted Hole 4 without a second score", %{
    conn: conn
  } do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)

    for revision <- 0..2 do
      hole = route_hole_at_revision!(setup, revision)

      assert {:ok, _receipt} =
               Scoring.submit_group_hole(
                 setup.admin,
                 setup.event.id,
                 setup.round.id,
                 service_command(setup, revision, hole.id)
               )
    end

    run_authenticated_browser!(conn, setup, "accepted_hole_4")

    hole_four = route_hole_at_revision!(setup, 3)

    assert [[1]] =
             Repo.query!(
               "SELECT count(*)::int FROM hole_submissions WHERE round_hole_id = $1::uuid",
               [Ecto.UUID.dump!(hole_four.id)]
             ).rows

    assert [[2]] =
             Repo.query!(
               "SELECT count(*)::int FROM hole_results WHERE round_hole_id = $1::uuid",
               [Ecto.UUID.dump!(hole_four.id)]
             ).rows

    assert Repo.query!(
             "SELECT scoring_revision FROM playing_groups WHERE id = $1::uuid",
             [Ecto.UUID.dump!(setup.group.id)]
           ).rows == [[4]]
  end

  test "authenticated browser keeps a never-accepted Hole 1 pending without writing a score", %{
    conn: conn
  } do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)

    run_authenticated_browser!(conn, setup, "unaccepted_hole_1")

    assert [[0]] =
             Repo.query!(
               "SELECT count(*)::int FROM hole_results WHERE round_id = $1::uuid",
               [Ecto.UUID.dump!(setup.round.id)]
             ).rows

    assert [[0]] =
             Repo.query!(
               "SELECT count(*)::int FROM hole_submissions WHERE playing_group_id = $1::uuid",
               [Ecto.UUID.dump!(setup.group.id)]
             ).rows

    assert Repo.query!(
             "SELECT scoring_revision FROM playing_groups WHERE id = $1::uuid",
             [Ecto.UUID.dump!(setup.group.id)]
           ).rows == [[0]]
  end

  test "authenticated browser stops when a pending command payload differs from its receipt", %{
    conn: conn
  } do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)

    run_authenticated_browser!(conn, setup, "payload_mismatch")

    assert [[2]] =
             Repo.query!(
               "SELECT count(*)::int FROM hole_results WHERE round_id = $1::uuid",
               [Ecto.UUID.dump!(setup.round.id)]
             ).rows

    assert [[1]] =
             Repo.query!(
               "SELECT count(*)::int FROM hole_submissions WHERE playing_group_id = $1::uuid",
               [Ecto.UUID.dump!(setup.group.id)]
             ).rows

    assert Repo.query!(
             "SELECT scoring_revision FROM playing_groups WHERE id = $1::uuid",
             [Ecto.UUID.dump!(setup.group.id)]
           ).rows == [[1]]
  end

  test "authenticated browser keeps a command stopped after scorer handover", %{conn: conn} do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)

    run_authenticated_browser!(conn, setup, "scorer_handover")

    assert [[2]] =
             Repo.query!(
               "SELECT count(*)::int FROM hole_results WHERE round_id = $1::uuid",
               [Ecto.UUID.dump!(setup.round.id)]
             ).rows

    assert [[1]] =
             Repo.query!(
               "SELECT count(*)::int FROM hole_submissions WHERE playing_group_id = $1::uuid",
               [Ecto.UUID.dump!(setup.group.id)]
             ).rows

    assert Repo.query!(
             "SELECT scoring_revision FROM playing_groups WHERE id = $1::uuid",
             [Ecto.UUID.dump!(setup.group.id)]
           ).rows == [[1]]
  end

  test "authenticated browser retains a command when its resolution receipt mismatches", %{
    conn: conn
  } do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)

    run_authenticated_browser!(conn, setup, "receipt_mismatch")

    assert [[2]] =
             Repo.query!(
               "SELECT count(*)::int FROM hole_results WHERE round_id = $1::uuid",
               [Ecto.UUID.dump!(setup.round.id)]
             ).rows

    assert [[1]] =
             Repo.query!(
               "SELECT count(*)::int FROM hole_submissions WHERE playing_group_id = $1::uuid",
               [Ecto.UUID.dump!(setup.group.id)]
             ).rows

    assert Repo.query!(
             "SELECT scoring_revision FROM playing_groups WHERE id = $1::uuid",
             [Ecto.UUID.dump!(setup.group.id)]
           ).rows == [[1]]
  end

  defp scorecard_path(setup) do
    "/player/events/#{setup.event.id}/rounds/#{setup.round.id}/groups/#{setup.group.id}/scorecard"
  end

  defp service_command(setup, revision, hole_id) do
    %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: setup.group.id,
      round_hole_id: hole_id,
      expected_group_score_revision: revision,
      captured_at: DateTime.utc_now(),
      results:
        Enum.map(setup.entries, fn entry ->
          %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 4}
        end)
    }
  end

  defp route_hole_at_revision!(setup, revision) do
    start_index = Enum.find_index(setup.route, &(&1.id == setup.start_hole.id))
    rotated_route = Enum.drop(setup.route, start_index) ++ Enum.take(setup.route, start_index)
    Enum.at(rotated_route, revision)
  end

  defp run_authenticated_browser!(conn, setup, scenario) do
    scorer = hd(setup.entries)

    {:ok, %{grant: grant}} =
      Accounts.issue_player_access(setup.admin, setup.event.id, scorer.player_id)

    session_conn =
      conn
      |> init_test_session(%{})
      |> Session.put_grant_id(grant.id)

    response_conn = get(session_conn, scorecard_path(setup))

    session_cookie =
      response_conn
      |> get_resp_cookies()
      |> Map.fetch!("_golf_scoring_key")
      |> Map.fetch!(:value)

    {:ok, server} =
      Bandit.start_link(
        plug: GolfScoringWeb.Endpoint,
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    Process.unlink(server)

    on_exit(fn ->
      if Process.alive?(server), do: Supervisor.stop(server)
    end)

    assert {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    fixture = %{
      base_url: "http://localhost:#{port}",
      scorecard_path: scorecard_path(setup),
      session_cookie: session_cookie,
      round_entry_ids: Enum.map(setup.entries, & &1.id),
      current_hole_number: if(scenario == "accepted_hole_4", do: 4, else: 1),
      scenario: scenario
    }

    fixture =
      if scenario == "scorer_handover" do
        fixture
        |> Map.put(:handover_url, start_handover_coordinator!(setup))
      else
        fixture
      end

    {output, status} =
      System.cmd("npm", ["run", "test:browser:phoenix"],
        cd: File.cwd!(),
        env: [{"GLS37_BROWSER_FIXTURE", Jason.encode!(fixture)}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "1 passed", output
  end

  defp start_handover_coordinator!(setup) do
    {:ok, coordinator} =
      Bandit.start_link(
        plug:
          {GolfScoringWeb.Scoring.GroupScorecardBrowserIntegrationTest.HandoverPlug,
           %{
             actor: setup.admin,
             event_id: setup.event.id,
             round_id: setup.round.id,
             group_id: setup.group.id,
             replacement_entry_id: Enum.at(setup.entries, 1).id
           }},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    Process.unlink(coordinator)

    on_exit(fn ->
      if Process.alive?(coordinator), do: Supervisor.stop(coordinator)
    end)

    assert {:ok, {_address, port}} = ThousandIsland.listener_info(coordinator)
    "http://localhost:#{port}/handover"
  end
end

defmodule GolfScoringWeb.Scoring.GroupScorecardBrowserIntegrationTest.HandoverPlug do
  import Plug.Conn

  alias GolfScoring.Competition

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", request_path: "/handover"} = conn, opts) do
    case Competition.handover_primary_scorer(
           opts.actor,
           opts.event_id,
           opts.round_id,
           opts.group_id,
           opts.replacement_entry_id
         ) do
      {:ok, _assignment} -> send_resp(conn, 200, "ok")
      {:error, _reason} -> send_resp(conn, 409, "handover rejected")
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "not found")
end

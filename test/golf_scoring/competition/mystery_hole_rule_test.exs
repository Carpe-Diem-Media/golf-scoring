defmodule GolfScoring.Competition.MysteryHoleRuleTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ash.Changeset
  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Competition.Event
  alias GolfScoring.Competition.MysteryHoleRule
  alias GolfScoring.Competition.Round
  alias GolfScoring.Competition.ScoringTrack
  alias GolfScoring.Competition.Services.ConfigureRoundCompetition
  alias GolfScoring.Competition.Services.ConfigureRoundLayout
  alias GolfScoring.Competition.Services.LockScoringTracksForRound
  alias GolfScoring.GolfCatalog
  alias GolfScoring.Repo

  @password "GLS-27 synthetic staff passphrase 2026"
  @primary_unique "scoring_tracks_one_primary_per_round_competition_index"
  @rule_unique "mystery_hole_rules_unique_track_hole_index"

  setup do
    Process.put(:gls27_email_prefix, "gls27-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls27_email_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    :ok
  end

  test "resources register without generic public CRUD" do
    assert ScoringTrack in Ash.Domain.Info.resources(Competition)
    assert MysteryHoleRule in Ash.Domain.Info.resources(Competition)

    refute Info.action(ScoringTrack, :create)
    refute Info.action(ScoringTrack, :update)
    refute Info.action(ScoringTrack, :destroy)
    refute Info.action(MysteryHoleRule, :create)
    refute Info.action(MysteryHoleRule, :update)
    refute Info.action(MysteryHoleRule, :destroy)

    assert function_exported?(Competition, :configure_scoring_track, 5)
    assert function_exported?(Competition, :configure_mystery_hole_rule, 6)
    assert function_exported?(Competition, :remove_mystery_hole_rule, 5)
    refute function_exported?(Competition, :lock_scoring_tracks_for_round, 1)
  end

  test "rule attribute is server-private and sensitive" do
    rule_attr = Info.attribute(MysteryHoleRule, :rule)
    assert rule_attr.public? == false
    assert rule_attr.sensitive? == true
    refute Info.action(MysteryHoleRule, :read_for_players)
  end

  test "valid mystery and standard better-ball scoring track configuration" do
    setup = setup_pre_open_round!()

    assert {:ok, mystery} =
             Competition.configure_scoring_track(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               %{
                 track_type: :mystery,
                 name: "Mystery Leaderboard",
                 is_primary: true,
                 visibility_policy_identifier: "staff_only_v1",
                 aggregation_policy_identifier: "mystery_v1",
                 tie_break_policy_identifier: "mystery_holes_then_countback_v1"
               }
             )

    assert mystery.track_type == :mystery
    assert mystery.configuration_state == :draft

    assert {:ok, standard} =
             Competition.configure_scoring_track(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               %{
                 track_type: :standard_better_ball,
                 name: "Better Ball",
                 is_primary: false,
                 visibility_policy_identifier: "leaderboard_v1",
                 aggregation_policy_identifier: "standard_better_ball_v1",
                 tie_break_policy_identifier: "standard_countback_v1"
               }
             )

    assert standard.track_type == :standard_better_ball
  end

  test "invalid track type rejected" do
    setup = setup_pre_open_round!()

    assert {:error, _} =
             Competition.configure_scoring_track(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               %{
                 track_type: :bogus,
                 name: "Bad",
                 is_primary: false,
                 visibility_policy_identifier: "leaderboard_v1",
                 aggregation_policy_identifier: "standard_better_ball_v1",
                 tie_break_policy_identifier: "standard_countback_v1"
               }
             )
  end

  test "PostgreSQL enforces at most one primary track per RoundCompetition" do
    setup = setup_pre_open_round!()

    assert {:ok, _primary} =
             Competition.configure_scoring_track(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               mystery_track_attrs(is_primary: true)
             )

    duplicate =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO scoring_tracks
            (id, track_type, name, is_primary, visibility_policy_identifier,
             aggregation_policy_identifier, tie_break_policy_identifier, configuration_state,
             event_id, round_id, round_competition_id, inserted_at, updated_at)
          VALUES
            (gen_random_uuid(), 'mystery', 'Dup Primary', true, 'staff_only_v1', 'mystery_v1',
             'mystery_holes_then_countback_v1', 'draft', $1::uuid, $2::uuid, $3::uuid, now(), now())
          """,
          [
            Ecto.UUID.dump!(setup.event.id),
            Ecto.UUID.dump!(setup.round.id),
            Ecto.UUID.dump!(setup.competition.id)
          ]
        )
      end

    assert duplicate.postgres.code == :unique_violation
    assert duplicate.postgres.constraint == @primary_unique
  end

  test "required nonblank configuration rejected at database" do
    setup = setup_pre_open_round!()

    blank_name =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO scoring_tracks
            (id, track_type, name, is_primary, visibility_policy_identifier,
             aggregation_policy_identifier, tie_break_policy_identifier, configuration_state,
             event_id, round_id, round_competition_id, inserted_at, updated_at)
          VALUES
            (gen_random_uuid(), 'mystery', '   ', false, 'staff_only_v1', 'mystery_v1',
             'mystery_holes_then_countback_v1', 'draft', $1::uuid, $2::uuid, $3::uuid, now(), now())
          """,
          [
            Ecto.UUID.dump!(setup.event.id),
            Ecto.UUID.dump!(setup.round.id),
            Ecto.UUID.dump!(setup.competition.id)
          ]
        )
      end

    assert blank_name.postgres.code == :check_violation
  end

  test "event admin and competition manager may configure before scoring opens" do
    setup = setup_pre_open_round!()
    manager = create_staff_user!()
    assign_role!(setup.admin, setup.event, manager, :competition_manager)

    assert {:ok, _} =
             Competition.configure_scoring_track(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               mystery_track_attrs()
             )

    assert {:ok, _} =
             Competition.configure_scoring_track(
               manager,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               standard_track_attrs()
             )
  end

  test "unauthorized role rejected" do
    setup = setup_pre_open_round!()
    staff = create_staff_user!()
    assign_role!(setup.admin, setup.event, staff, :registration_staff)

    assert {:error, :forbidden} =
             Competition.configure_scoring_track(
               staff,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               mystery_track_attrs()
             )
  end

  test "configuration accepted in draft and ready rounds" do
    draft = setup_pre_open_round!()
    assert draft.round.state == :draft

    assert {:ok, _} =
             Competition.configure_scoring_track(
               draft.admin,
               draft.event.id,
               draft.round.id,
               draft.competition.id,
               mystery_track_attrs()
             )

    ready = setup_pre_open_round!()
    set_round_state!(ready.round, :ready)

    assert {:ok, _} =
             Competition.configure_scoring_track(
               ready.admin,
               ready.event.id,
               ready.round.id,
               ready.competition.id,
               mystery_track_attrs()
             )
  end

  test "track mutation rejected after scoring opens" do
    setup = setup_pre_open_round!()

    assert {:ok, track} =
             Competition.configure_scoring_track(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               mystery_track_attrs()
             )

    set_round_state!(setup.round, :scoring_open)

    assert {:error, {:invalid_round_state, "scoring_open"}} =
             Competition.configure_scoring_track(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               Map.merge(mystery_track_attrs(), %{scoring_track_id: track.id, name: "Changed"})
             )
  end

  test "mystery rule values best worst both and unsupported rejected" do
    setup = setup_pre_open_round!(with_route: true)

    {:ok, track} =
      Competition.configure_scoring_track(
        setup.admin,
        setup.event.id,
        setup.round.id,
        setup.competition.id,
        mystery_track_attrs()
      )

    [hole_a, hole_b, hole_c | _] = setup.route

    for {rule, hole} <- [{:best, hole_a}, {:worst, hole_b}, {:both, hole_c}] do
      assert {:ok, %MysteryHoleRule{rule: ^rule}} =
               Competition.configure_mystery_hole_rule(
                 setup.admin,
                 setup.event.id,
                 setup.round.id,
                 track.id,
                 hole.id,
                 rule
               )
    end

    assert {:error, _} =
             Competition.configure_mystery_hole_rule(
               setup.admin,
               setup.event.id,
               setup.round.id,
               track.id,
               hole_a.id,
               :invalid
             )
  end

  test "duplicate scoring_track_id and round_hole_id rejected by database" do
    setup = setup_pre_open_round!(with_route: true)

    {:ok, track} =
      Competition.configure_scoring_track(
        setup.admin,
        setup.event.id,
        setup.round.id,
        setup.competition.id,
        mystery_track_attrs()
      )

    assert {:ok, _} =
             Competition.configure_mystery_hole_rule(
               setup.admin,
               setup.event.id,
               setup.round.id,
               track.id,
               setup.round_hole.id,
               :best
             )

    duplicate =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO mystery_hole_rules
            (id, rule, scoring_track_id, round_hole_id, round_id, inserted_at, updated_at)
          VALUES (gen_random_uuid(), 'worst', $1::uuid, $2::uuid, $3::uuid, now(), now())
          """,
          [
            Ecto.UUID.dump!(track.id),
            Ecto.UUID.dump!(setup.round_hole.id),
            Ecto.UUID.dump!(setup.round.id)
          ]
        )
      end

    assert duplicate.postgres.code == :unique_violation
    assert duplicate.postgres.constraint == @rule_unique
  end

  test "mystery rule against standard better-ball track rejected" do
    setup = setup_pre_open_round!(with_route: true)

    {:ok, track} =
      Competition.configure_scoring_track(
        setup.admin,
        setup.event.id,
        setup.round.id,
        setup.competition.id,
        standard_track_attrs()
      )

    assert {:error, :mystery_track_required} =
             Competition.configure_mystery_hole_rule(
               setup.admin,
               setup.event.id,
               setup.round.id,
               track.id,
               setup.round_hole.id,
               :best
             )
  end

  test "cross-round scoring track and round competition mismatch rejected by database" do
    setup_a = setup_pre_open_round!()
    setup_b = setup_pre_open_round!()

    assert_raise Postgrex.Error, fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          """
          INSERT INTO scoring_tracks
            (id, track_type, name, is_primary, visibility_policy_identifier,
             aggregation_policy_identifier, tie_break_policy_identifier, configuration_state,
             event_id, round_id, round_competition_id, inserted_at, updated_at)
          VALUES
            (gen_random_uuid(), 'mystery', 'Cross', false, 'staff_only_v1', 'mystery_v1',
             'mystery_holes_then_countback_v1', 'draft', $1::uuid, $2::uuid, $3::uuid, now(), now())
          """,
          [
            Ecto.UUID.dump!(setup_a.event.id),
            Ecto.UUID.dump!(setup_a.round.id),
            Ecto.UUID.dump!(setup_b.competition.id)
          ]
        )
      end)
    end
  end

  test "cross-round mystery hole rule mismatch rejected by database" do
    setup_a = setup_pre_open_round!(with_route: true)
    setup_b = setup_pre_open_round!(with_route: true)

    {:ok, track} =
      Competition.configure_scoring_track(
        setup_a.admin,
        setup_a.event.id,
        setup_a.round.id,
        setup_a.competition.id,
        mystery_track_attrs()
      )

    assert_raise Postgrex.Error, fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          """
          INSERT INTO mystery_hole_rules
            (id, rule, scoring_track_id, round_hole_id, round_id, inserted_at, updated_at)
          VALUES (gen_random_uuid(), 'best', $1::uuid, $2::uuid, $3::uuid, now(), now())
          """,
          [
            Ecto.UUID.dump!(track.id),
            Ecto.UUID.dump!(setup_b.round_hole.id),
            Ecto.UUID.dump!(setup_a.round.id)
          ]
        )
      end)
    end
  end

  test "ordinary round hole without mystery rule remains valid" do
    setup = setup_pre_open_round!(with_route: true)

    {:ok, track} =
      Competition.configure_scoring_track(
        setup.admin,
        setup.event.id,
        setup.round.id,
        setup.competition.id,
        mystery_track_attrs()
      )

    assert {:ok, []} =
             MysteryHoleRule
             |> Ash.Query.filter(scoring_track_id == ^track.id)
             |> Ash.read(authorize?: false)

    assert setup.round_hole.id
  end

  test "pre-open mystery rule removal returns hole to ordinary absence" do
    setup = setup_pre_open_round!(with_route: true)

    {:ok, track} =
      Competition.configure_scoring_track(
        setup.admin,
        setup.event.id,
        setup.round.id,
        setup.competition.id,
        mystery_track_attrs()
      )

    assert {:ok, %MysteryHoleRule{rule: :best}} =
             Competition.configure_mystery_hole_rule(
               setup.admin,
               setup.event.id,
               setup.round.id,
               track.id,
               setup.round_hole.id,
               :best
             )

    assert :ok =
             Competition.remove_mystery_hole_rule(
               setup.admin,
               setup.event.id,
               setup.round.id,
               track.id,
               setup.round_hole.id
             )

    assert {:ok, []} =
             MysteryHoleRule
             |> Ash.Query.filter(
               scoring_track_id == ^track.id and round_hole_id == ^setup.round_hole.id
             )
             |> Ash.read(authorize?: false)

    assert {:error, :mystery_hole_rule_not_found} =
             Competition.remove_mystery_hole_rule(
               setup.admin,
               setup.event.id,
               setup.round.id,
               track.id,
               setup.round_hole.id
             )
  end

  test "lock_scoring_tracks_for_round transitions draft tracks to locked" do
    setup = setup_pre_open_round!()

    assert {:ok, mystery} =
             Competition.configure_scoring_track(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               mystery_track_attrs(is_primary: true)
             )

    assert {:ok, standard} =
             Competition.configure_scoring_track(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               standard_track_attrs()
             )

    assert :ok = LockScoringTracksForRound.run(setup.round.id)

    mystery = Ash.get!(ScoringTrack, mystery.id, authorize?: false)
    standard = Ash.get!(ScoringTrack, standard.id, authorize?: false)
    assert mystery.configuration_state == :locked
    assert standard.configuration_state == :locked
  end

  test "locked scoring track rejects ordinary update while Round remains ready" do
    setup = setup_pre_open_round!()

    assert {:ok, track} =
             Competition.configure_scoring_track(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               mystery_track_attrs()
             )

    assert :ok = LockScoringTracksForRound.run(setup.round.id)
    set_round_state!(setup.round, :ready)

    assert {:error, :configuration_locked} =
             Competition.configure_scoring_track(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               %{
                 scoring_track_id: track.id,
                 name: "Renamed after lock"
               }
             )
  end

  test "locked mystery track rejects ordinary rule create update and remove" do
    setup = setup_pre_open_round!(with_route: true)

    {:ok, track} =
      Competition.configure_scoring_track(
        setup.admin,
        setup.event.id,
        setup.round.id,
        setup.competition.id,
        mystery_track_attrs()
      )

    assert {:ok, rule} =
             Competition.configure_mystery_hole_rule(
               setup.admin,
               setup.event.id,
               setup.round.id,
               track.id,
               setup.round_hole.id,
               :best
             )

    assert :ok = LockScoringTracksForRound.run(setup.round.id)
    set_round_state!(setup.round, :ready)

    [_configured | other_holes] = setup.route

    assert {:error, :configuration_locked} =
             Competition.configure_mystery_hole_rule(
               setup.admin,
               setup.event.id,
               setup.round.id,
               track.id,
               hd(other_holes).id,
               :worst
             )

    assert {:error, :configuration_locked} =
             Competition.configure_mystery_hole_rule(
               setup.admin,
               setup.event.id,
               setup.round.id,
               track.id,
               setup.round_hole.id,
               :both
             )

    assert {:error, :configuration_locked} =
             Competition.remove_mystery_hole_rule(
               setup.admin,
               setup.event.id,
               setup.round.id,
               track.id,
               setup.round_hole.id
             )

    assert Ash.get!(MysteryHoleRule, rule.id, authorize?: false).rule == :best
  end

  test "track_type is immutable after creation" do
    setup = setup_pre_open_round!()

    assert {:ok, track} =
             Competition.configure_scoring_track(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               mystery_track_attrs()
             )

    assert {:error, :track_type_immutable} =
             Competition.configure_scoring_track(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               %{
                 scoring_track_id: track.id,
                 track_type: :standard_better_ball,
                 name: track.name
               }
             )

    unchanged = Ash.get!(ScoringTrack, track.id, authorize?: false)
    assert unchanged.track_type == :mystery
  end

  defp mystery_track_attrs(overrides \\ []) do
    Map.merge(
      %{
        track_type: :mystery,
        name: "Mystery #{System.unique_integer([:positive])}",
        is_primary: false,
        visibility_policy_identifier: "staff_only_v1",
        aggregation_policy_identifier: "mystery_v1",
        tie_break_policy_identifier: "mystery_holes_then_countback_v1"
      },
      Map.new(overrides)
    )
  end

  defp standard_track_attrs do
    %{
      track_type: :standard_better_ball,
      name: "Standard #{System.unique_integer([:positive])}",
      is_primary: false,
      visibility_policy_identifier: "leaderboard_v1",
      aggregation_policy_identifier: "standard_better_ball_v1",
      tie_break_policy_identifier: "standard_countback_v1"
    }
  end

  defp setup_pre_open_round!(opts \\ []) do
    event = create_event!()
    admin = create_staff_user!()

    Repo.query!(
      "INSERT INTO event_staff_assignments (event_id, staff_user_id, role, status) VALUES ($1::uuid, $2::uuid, 'event_admin', 'active')",
      [Ecto.UUID.dump!(event.id), Ecto.UUID.dump!(admin.id)]
    )

    course = create_course!(event, admin)
    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)

    route =
      if Keyword.get(opts, :with_route, false) do
        catalog_holes = create_eighteen_holes!(event, admin, course)

        {:ok, route} =
          ConfigureRoundLayout.run(admin, round.id, Enum.map(catalog_holes, & &1.id))

        route
      end

    {:ok, competition} =
      ConfigureRoundCompetition.run(admin, event.id, round.id, %{})

    base = %{event: event, round: round, admin: admin, competition: competition}

    if Keyword.get(opts, :with_route, false) do
      [round_hole | _] = route
      base |> Map.put(:route, route) |> Map.put(:round_hole, round_hole)
    else
      base
    end
  end

  defp create_event! do
    Event
    |> Changeset.for_create(:create_internal, %{})
    |> Ash.create!(authorize?: false)
  end

  defp create_staff_user! do
    prefix = Process.get(:gls27_email_prefix)
    email = "#{prefix}-#{System.unique_integer([:positive])}@example.com"

    Accounts.StaffUser
    |> Changeset.for_create(:provision_staff_user, %{
      email: email,
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end

  defp assign_role!(_admin, event, staff, role) do
    Repo.query!(
      "INSERT INTO event_staff_assignments (event_id, staff_user_id, role, status) VALUES ($1::uuid, $2::uuid, $3, 'active')",
      [Ecto.UUID.dump!(event.id), Ecto.UUID.dump!(staff.id), Atom.to_string(role)]
    )
  end

  defp create_course!(event, admin) do
    {:ok, course} =
      GolfScoring.GolfCatalog.create_course(
        event.id,
        %{name: "Test #{System.unique_integer([:positive])}", location: "ZA"},
        actor: admin
      )

    course
  end

  defp create_eighteen_holes!(event, admin, course) do
    for n <- 1..18 do
      {:ok, hole} =
        GolfCatalog.configure_course_hole(
          event.id,
          %{course_id: course.id, hole_number: n},
          actor: admin
        )

      hole
    end
  end

  defp set_round_state!(round, state) do
    dumped = Ecto.UUID.dump!(round.id)

    Repo.query!(
      "UPDATE rounds SET state = $2 WHERE id = $1::uuid",
      [dumped, Atom.to_string(state)]
    )

    Ash.get!(Round, round.id, authorize?: false)
  end
end

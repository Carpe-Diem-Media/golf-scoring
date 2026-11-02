defmodule GolfScoring.Competition.Services.OpenRoundTest do
  use ExUnit.Case, async: false

  alias Decimal, as: D
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Competition
  alias GolfScoring.Competition.{Event, Player}

  alias GolfScoring.Competition.Services.{
    AssignEntryToGroup,
    AssignPlayingGroupStart,
    ConfigureRoundLayout,
    OpenRound,
    SnapshotRoundTeeProfiles
  }

  alias GolfScoring.GolfCatalog
  alias GolfScoring.Repo
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Calculators.{CourseHandicap, PlayingHandicap}

  setup tags do
    owner = unless tags[:connections], do: Sandbox.start_owner!(Repo, shared: true)
    if owner, do: on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  test "rejects invalid inputs before starting a transaction" do
    assert {:error, :invalid_input} = OpenRound.mark_ready(nil, nil, nil)
    assert {:error, :invalid_input} = OpenRound.run(nil, nil, nil)
  end

  test "empty draft is blocked using current persisted facts" do
    {actor, event, round} = empty_round!()

    assert {:error, {:round_opening_blocked, blockers, []}} =
             OpenRound.mark_ready(actor, event.id, round.id)

    assert :invalid_route in blockers
    assert :no_starters in blockers
    assert Repo.get!(GolfScoring.Competition.Round, round.id).state == :draft
  end

  test "authorization is checked inside the transaction and repeated states are rejected" do
    {actor, event, round} = empty_round!()

    Repo.query!(
      "UPDATE event_staff_assignments SET status = 'revoked' WHERE event_id = $1::uuid AND staff_user_id = $2::uuid",
      [Ecto.UUID.dump!(event.id), Ecto.UUID.dump!(actor.id)]
    )

    assert {:error, :forbidden} = OpenRound.mark_ready(actor, event.id, round.id)

    Repo.query!(
      "UPDATE event_staff_assignments SET status = 'active' WHERE event_id = $1::uuid AND staff_user_id = $2::uuid",
      [Ecto.UUID.dump!(event.id), Ecto.UUID.dump!(actor.id)]
    )

    assert {:error, {:invalid_round_state, "draft"}} = OpenRound.run(actor, event.id, round.id)
  end

  test "a complete draft becomes ready without locking tracks" do
    f = complete_round!()

    assert {:ok, %{round: round, warnings: []}} =
             OpenRound.mark_ready(f.admin, f.event.id, f.round.id)

    assert round.state == :ready

    assert Enum.all?(f.tracks, fn t ->
             Ash.get!(GolfScoring.Competition.ScoringTrack, t.id, authorize?: false).configuration_state ==
               :draft
           end)
  end

  test "opening revalidates, locks tracks and writes one audit" do
    f = complete_round!()
    assert {:ok, _} = OpenRound.mark_ready(f.admin, f.event.id, f.round.id)
    assert {:ok, %{round: opened}} = OpenRound.run(f.admin, f.event.id, f.round.id)
    assert opened.state == :scoring_open

    assert Enum.all?(f.tracks, fn t ->
             Ash.get!(GolfScoring.Competition.ScoringTrack, t.id, authorize?: false).configuration_state ==
               :locked
           end)

    assert [[1]] =
             Repo.query!(
               "SELECT count(*) FROM audit_events WHERE target_id = $1::uuid AND action = 'round_scoring_opened'",
               [Ecto.UUID.dump!(f.round.id)]
             ).rows

    assert {:error, {:invalid_round_state, "scoring_open"}} =
             OpenRound.run(f.admin, f.event.id, f.round.id)

    assert [[1]] =
             Repo.query!(
               "SELECT count(*) FROM audit_events WHERE target_id = $1::uuid AND action = 'round_scoring_opened'",
               [Ecto.UUID.dump!(f.round.id)]
             ).rows
  end

  test "public competition commands go through the opening gate" do
    {actor, event, round} = empty_round!()

    assert {:error, {:round_opening_blocked, _, _}} =
             Competition.mark_round_ready(actor, event.id, round.id)

    assert {:error, {:invalid_round_state, "draft"}} =
             Competition.open_round(actor, event.id, round.id)

    refute function_exported?(Competition, :open_scoring, 2)
    refute function_exported?(Competition, :lock_scoring_tracks_for_round, 1)
  end

  @tag :connections
  test "successful open broadcasts once after the durable commit" do
    f = committed_fixture!()
    topic = "round:#{f.round.id}"
    :ok = Phoenix.PubSub.subscribe(GolfScoring.PubSub, topic)

    assert {:ok, _} =
             Sandbox.unboxed_run(Repo, fn ->
               OpenRound.mark_ready(f.admin, f.event.id, f.round.id)
             end)

    refute_receive {:round_scoring_opened, _}, 100

    assert {:ok, %{round: %{state: :scoring_open}}} =
             Sandbox.unboxed_run(Repo, fn ->
               OpenRound.run(f.admin, f.event.id, f.round.id)
             end)

    assert_receive {:round_scoring_opened, payload}, 5_000
    assert payload == %{event_id: f.event.id, round_id: f.round.id}

    assert %{state: :scoring_open} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.get!(GolfScoring.Competition.Round, f.round.id)
             end)

    assert Enum.all?(f.tracks, fn track ->
             Sandbox.unboxed_run(Repo, fn ->
               Ash.get!(GolfScoring.Competition.ScoringTrack, track.id, authorize?: false).configuration_state ==
                 :locked
             end)
           end)

    assert [[1]] =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.query!(
                 "SELECT count(*) FROM audit_events WHERE target_id = $1::uuid AND action = 'round_scoring_opened'",
                 [Ecto.UUID.dump!(f.round.id)]
               ).rows
             end)

    assert {:error, {:invalid_round_state, "scoring_open"}} =
             Sandbox.unboxed_run(Repo, fn ->
               OpenRound.run(f.admin, f.event.id, f.round.id)
             end)

    refute_receive {:round_scoring_opened, _}, 100
  end

  test "blocked open does not broadcast" do
    f = complete_round!()
    assert {:ok, _} = OpenRound.mark_ready(f.admin, f.event.id, f.round.id)

    Repo.query!("DELETE FROM mystery_hole_rules WHERE round_id = $1::uuid", [
      Ecto.UUID.dump!(f.round.id)
    ])

    :ok = Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")

    assert {:error, {:round_opening_blocked, _, _}} =
             OpenRound.run(f.admin, f.event.id, f.round.id)

    refute_receive {:round_scoring_opened, _}, 100
  end

  for {name, sql, family} <- [
        {"route",
         "UPDATE round_holes SET play_order = 19 WHERE round_id = $1::uuid AND play_order = 18",
         :invalid_route},
        {"tee",
         "UPDATE round_entries SET round_tee_profile_snapshot_id = NULL WHERE round_id = $1::uuid",
         :tee},
        {"tee hole coverage", "DELETE FROM round_tee_hole_snapshots WHERE round_id = $1::uuid",
         :tee_holes},
        {"competition handicap", "DELETE FROM competition_handicaps WHERE round_id = $1::uuid",
         :competition_handicap},
        {"group assignment",
         "UPDATE round_entries SET playing_group_id = NULL WHERE round_id = $1::uuid", :group},
        {"group start",
         "UPDATE playing_groups SET starting_round_hole_id = NULL, starting_position = NULL WHERE round_id = $1::uuid",
         :group},
        {"scorer",
         "UPDATE group_role_assignments SET state = 'revoked' WHERE round_id = $1::uuid AND role = 'primary_scorer'",
         :role},
        {"verifier",
         "UPDATE group_role_assignments SET state = 'revoked' WHERE round_id = $1::uuid AND role = 'designated_verifier'",
         :role},
        {"competition policy",
         "UPDATE round_competitions SET pickup_policy_identifier = 'unsupported' WHERE round_id = $1::uuid",
         :competition},
        {"side membership", "DELETE FROM competition_side_memberships WHERE round_id = $1::uuid",
         :side},
        {"standard track",
         "UPDATE scoring_tracks SET name = 'changed' WHERE round_id = $1::uuid AND track_type = 'standard_better_ball'",
         :track},
        {"mystery track",
         "UPDATE scoring_tracks SET name = 'changed' WHERE round_id = $1::uuid AND track_type = 'mystery'",
         :track},
        {"mystery rule", "DELETE FROM mystery_hole_rules WHERE round_id = $1::uuid",
         :mystery_rule}
      ] do
    test "persisted invalid #{name} blocks marking ready" do
      f = complete_round!()
      Repo.query!(unquote(sql), [Ecto.UUID.dump!(f.round.id)])

      assert {:error, {:round_opening_blocked, blockers, _}} =
               OpenRound.mark_ready(f.admin, f.event.id, f.round.id)

      assert Enum.any?(blockers, fn b ->
               b == unquote(family) or (is_tuple(b) and elem(b, 0) == unquote(family))
             end)

      assert Repo.get!(GolfScoring.Competition.Round, f.round.id).state == :draft

      assert Enum.all?(f.tracks, fn t ->
               Ash.get!(GolfScoring.Competition.ScoringTrack, t.id, authorize?: false).configuration_state ==
                 :draft
             end)
    end
  end

  test "ready stays editable and opening rechecks invalidated handicaps" do
    f = complete_round!()
    assert {:ok, _} = OpenRound.mark_ready(f.admin, f.event.id, f.round.id)

    assert {:ok, _} =
             Competition.configure_round_competition(f.admin, f.event.id, f.round.id, %{
               handicap_allowance_percent: 85
             })

    assert {:error, {:round_opening_blocked, blockers, _}} =
             OpenRound.run(f.admin, f.event.id, f.round.id)

    assert Enum.any?(blockers, fn b -> is_tuple(b) and elem(b, 0) == :competition_handicap end)
    assert Repo.get!(GolfScoring.Competition.Round, f.round.id).state == :ready
  end

  test "audit failure after track freeze rolls the whole opening back" do
    f = complete_round!()
    assert {:ok, _} = OpenRound.mark_ready(f.admin, f.event.id, f.round.id)
    :ok = Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")

    Repo.query!("""
    CREATE FUNCTION gls29_reject_open_audit() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.action = 'round_scoring_opened' THEN RAISE EXCEPTION 'reject open audit'; END IF;
      RETURN NEW;
    END; $$
    """)

    Repo.query!(
      "CREATE TRIGGER gls29_reject_open_audit BEFORE INSERT ON audit_events FOR EACH ROW EXECUTE FUNCTION gls29_reject_open_audit()"
    )

    assert {:error, _} = OpenRound.run(f.admin, f.event.id, f.round.id)
    assert Repo.get!(GolfScoring.Competition.Round, f.round.id).state == :ready

    assert Enum.all?(f.tracks, fn t ->
             Ash.get!(GolfScoring.Competition.ScoringTrack, t.id, authorize?: false).configuration_state ==
               :draft
           end)

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM audit_events WHERE target_id = $1::uuid AND action = 'round_scoring_opened'",
               [Ecto.UUID.dump!(f.round.id)]
             ).rows

    refute_receive {:round_scoring_opened, _}, 100
  end

  test "track freeze failure does not broadcast or partially change configuration" do
    f = complete_round!()
    assert {:ok, _} = OpenRound.mark_ready(f.admin, f.event.id, f.round.id)
    :ok = Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")

    Repo.query!("""
    CREATE FUNCTION gls29_reject_track_freeze() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF OLD.configuration_state = 'draft' AND NEW.configuration_state = 'locked' THEN
        RAISE EXCEPTION 'reject track freeze';
      END IF;
      RETURN NEW;
    END; $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls29_reject_track_freeze
    BEFORE UPDATE OF configuration_state ON scoring_tracks
    FOR EACH ROW EXECUTE FUNCTION gls29_reject_track_freeze()
    """)

    assert {:error, _} = OpenRound.run(f.admin, f.event.id, f.round.id)
    refute_receive {:round_scoring_opened, _}, 100
    assert Repo.get!(GolfScoring.Competition.Round, f.round.id).state == :ready

    assert Enum.all?(f.tracks, fn track ->
             Ash.get!(GolfScoring.Competition.ScoringTrack, track.id, authorize?: false).configuration_state ==
               :draft
           end)

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM audit_events WHERE target_id = $1::uuid AND action = 'round_scoring_opened'",
               [Ecto.UUID.dump!(f.round.id)]
             ).rows
  end

  @tag :connections
  test "opening commits before a waiting tee writer" do
    f = committed_fixture!()

    assert {:ok, _} =
             Sandbox.unboxed_run(Repo, fn ->
               OpenRound.mark_ready(f.admin, f.event.id, f.round.id)
             end)

    [entry | _] = f.entries

    {first, second} = open_race!(f, entry)
    assert {:ok, %{round: %{state: :scoring_open}}} = first
    assert {:error, {:invalid_round_state, :scoring_open}} = second

    assert Sandbox.unboxed_run(Repo, fn ->
             Repo.get!(GolfScoring.Competition.RoundEntry, entry.id).round_tee_profile_snapshot_id
           end) == f.tee.id
  end

  @tag :connections
  test "a committed allowance change is observed by the waiting opener" do
    f = committed_fixture!()

    assert {:ok, _} =
             Sandbox.unboxed_run(Repo, fn ->
               OpenRound.mark_ready(f.admin, f.event.id, f.round.id)
             end)

    {first, second} =
      race!(
        fn ->
          Competition.configure_round_competition(f.admin, f.event.id, f.round.id, %{
            handicap_allowance_percent: 85
          })
        end,
        fn -> OpenRound.run(f.admin, f.event.id, f.round.id) end
      )

    assert {:ok, {:ok, _}} = first
    assert {:error, {:round_opening_blocked, blockers, _}} = second
    assert Enum.any?(blockers, fn b -> is_tuple(b) and elem(b, 0) == :competition_handicap end)

    assert Sandbox.unboxed_run(Repo, fn ->
             Repo.get!(GolfScoring.Competition.Round, f.round.id).state
           end) == :ready
  end

  test "raw lifecycle actions reject absent and forged gate contexts" do
    f = complete_round!()
    fake = %{round_id: f.round.id, operation: :mark_round_ready, token: make_ref()}

    changeset =
      f.round
      |> Ash.Changeset.for_update(:mark_round_ready, %{}, actor: f.admin)
      |> Ash.Changeset.set_context(%{round_opening_gate: fake})

    assert {:error, _} = Ash.update(changeset)
    assert Repo.get!(GolfScoring.Competition.Round, f.round.id).state == :draft
    assert {:ok, %{round: ready}} = OpenRound.mark_ready(f.admin, f.event.id, f.round.id)
    fake = %{round_id: ready.id, operation: :open_scoring, token: make_ref()}

    changeset =
      ready
      |> Ash.Changeset.for_update(:open_scoring, %{}, actor: f.admin)
      |> Ash.Changeset.set_context(%{round_opening_gate: fake})

    assert {:error, _} = Ash.update(changeset)
    assert Repo.get!(GolfScoring.Competition.Round, f.round.id).state == :ready
  end

  test "missing persisted handicap snapshots block even if other facts remain" do
    f = complete_round!()
    id = Ecto.UUID.dump!(f.round.id)
    Repo.query!("DELETE FROM competition_handicaps WHERE round_id = $1::uuid", [id])
    Repo.query!("DELETE FROM handicap_snapshots WHERE round_id = $1::uuid", [id])

    assert {:error, {:round_opening_blocked, blockers, _}} =
             OpenRound.mark_ready(f.admin, f.event.id, f.round.id)

    assert Enum.any?(blockers, fn b -> is_tuple(b) and elem(b, 0) == :handicap end)
    assert Repo.get!(GolfScoring.Competition.Round, f.round.id).state == :draft
  end

  test "missing primary competition blocks" do
    f = complete_round!()

    Repo.query!("UPDATE round_competitions SET is_primary = FALSE WHERE round_id = $1::uuid", [
      Ecto.UUID.dump!(f.round.id)
    ])

    assert {:error, {:round_opening_blocked, blockers, _}} =
             OpenRound.mark_ready(f.admin, f.event.id, f.round.id)

    assert {:competition, :missing_or_duplicate} in blockers
    assert Repo.get!(GolfScoring.Competition.Round, f.round.id).state == :draft
  end

  test "duplicate standard track is ambiguous" do
    f = complete_round!()
    [standard | _] = f.tracks

    {:ok, _} =
      Competition.configure_scoring_track(f.admin, f.event.id, f.round.id, f.competition.id, %{
        track_type: standard.track_type,
        name: standard.name,
        is_primary: false,
        visibility_policy_identifier: standard.visibility_policy_identifier,
        aggregation_policy_identifier: standard.aggregation_policy_identifier,
        tie_break_policy_identifier: standard.tie_break_policy_identifier
      })

    assert {:error, {:round_opening_blocked, blockers, _}} =
             OpenRound.mark_ready(f.admin, f.event.id, f.round.id)

    assert {:track, :standard_better_ball, :invalid} in blockers
  end

  defp empty_round! do
    event =
      Event |> Ash.Changeset.for_create(:create_internal, %{}) |> Ash.create!(authorize?: false)

    email = "gls29-#{Ecto.UUID.generate()}@example.com"

    actor =
      GolfScoring.Accounts.StaffUser
      |> Ash.Changeset.for_create(:provision_staff_user, %{
        email: email,
        password: "GLS-29 synthetic passphrase 2026",
        password_confirmation: "GLS-29 synthetic passphrase 2026"
      })
      |> Ash.create!(authorize?: false)

    Repo.query!(
      "INSERT INTO event_staff_assignments (event_id, staff_user_id, role, status) VALUES ($1::uuid, $2::uuid, 'event_admin', 'active')",
      [Ecto.UUID.dump!(event.id), Ecto.UUID.dump!(actor.id)]
    )

    {:ok, course} =
      GolfCatalog.create_course(event.id, %{name: "GLS 29", location: "Here"}, actor: actor)

    {:ok, round} = Competition.create_round(event.id, course.id, actor: actor)
    {actor, event, round}
  end

  defp complete_round! do
    {admin, event, round} = empty_round!()
    course = Repo.get!(GolfScoring.GolfCatalog.Course, round.course_id)

    holes =
      for n <- 1..18 do
        {:ok, hole} =
          GolfCatalog.configure_course_hole(event.id, %{course_id: course.id, hole_number: n},
            actor: admin
          )

        hole
      end

    {:ok, route} = ConfigureRoundLayout.run(admin, round.id, Enum.map(holes, & &1.id))

    {:ok, tee_set} =
      GolfCatalog.configure_tee_set(event.id, %{course_id: course.id, name: "White"},
        actor: admin
      )

    ratings =
      Enum.map(holes, fn hole ->
        %{course_hole_id: hole.id, par: 4, stroke_index: hole.hole_number, distance_m: 300}
      end)

    {:ok, profile} =
      GolfCatalog.configure_tee_rating_profile(
        event.id,
        %{
          tee_set_id: tee_set.id,
          rating_label: "Men",
          course_rating: D.new("72.0"),
          slope_rating: 113,
          total_par: 72,
          hole_ratings: ratings
        },
        actor: admin
      )

    {:ok, [tee]} = SnapshotRoundTeeProfiles.run(admin, round.id, [profile.id])

    {:ok, competition} =
      Competition.configure_round_competition(admin, event.id, round.id, %{
        handicap_allowance_percent: 100
      })

    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)
    {:ok, _} = AssignPlayingGroupStart.run(admin, event.id, round.id, group.id, hd(route).id, 1)

    entries =
      for n <- 1..2 do
        player =
          Player
          |> Ash.Changeset.for_create(:create_internal, %{first_name: "Player", surname: "#{n}"})
          |> Ash.create!(authorize?: false)

        {:ok, entry} = Competition.add_round_entry(event.id, round.id, player.id, actor: admin)
        {:ok, _} = AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group.id)
        {:ok, _} = Competition.assign_round_tee(admin, event.id, round.id, entry.id, tee.id)

        {:ok, _} =
          Scoring.confirm_handicap_input(admin, event.id, round.id, entry.id, %{
            source_handicap_index: D.new("10.0")
          })

        {:ok, attrs} =
          CourseHandicap.calculate(
            D.new("10.0"),
            tee.slope_rating,
            tee.course_rating,
            tee.applicable_par
          )

        {:ok, snapshot} = Scoring.build_handicap_snapshot(entry.id, attrs)
        {:ok, playing} = PlayingHandicap.calculate(snapshot.course_handicap_unrounded, 100)

        {:ok, _} =
          Scoring.build_competition_handicap(
            entry.id,
            competition.id,
            Map.merge(playing, %{
              policy_identifier: "whs_golfrsa_2026_v1",
              allowance_applied: true
            })
          )

        entry
      end

    [first, second] = entries
    {:ok, _} = Competition.assign_primary_scorer(admin, event.id, round.id, group.id, first.id)

    {:ok, _} =
      Competition.assign_designated_verifier(admin, event.id, round.id, group.id, second.id)

    {:ok, side} =
      Competition.create_competition_side(admin, event.id, round.id, competition.id, :partnership)

    {:ok, _} =
      Competition.set_side_membership(
        admin,
        event.id,
        round.id,
        competition.id,
        side.id,
        Enum.map(entries, & &1.id)
      )

    {:ok, standard} =
      Competition.configure_scoring_track(admin, event.id, round.id, competition.id, %{
        track_type: :standard_better_ball,
        name: "Standard Better-Ball",
        is_primary: false,
        visibility_policy_identifier: "leaderboard_v1",
        aggregation_policy_identifier: "standard_better_ball_v1",
        tie_break_policy_identifier: "standard_countback_v1"
      })

    {:ok, mystery} =
      Competition.configure_scoring_track(admin, event.id, round.id, competition.id, %{
        track_type: :mystery,
        name: "Mystery Leaderboard",
        is_primary: true,
        visibility_policy_identifier: "staff_only_v1",
        aggregation_policy_identifier: "mystery_v1",
        tie_break_policy_identifier: "mystery_holes_then_countback_v1"
      })

    {:ok, _} =
      Competition.configure_mystery_hole_rule(
        admin,
        event.id,
        round.id,
        mystery.id,
        hd(route).id,
        :best
      )

    %{
      admin: admin,
      event: event,
      round: round,
      competition: competition,
      entries: entries,
      tracks: [standard, mystery],
      route: route,
      group: group,
      tee: tee
    }
  end

  defp committed_fixture! do
    f = Sandbox.unboxed_run(Repo, &complete_round!/0)
    on_exit(fn -> cleanup_fixture!(f) end)
    f
  end

  defp open_race!(f, entry) do
    parent = self()

    blocker =
      Task.async(fn -> Sandbox.unboxed_run(Repo, fn -> hold_group(parent, f.group.id) end) end)

    assert_receive {:group_locked, blocker_pid}, 10_000

    opener =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          report_and_call(parent, :opener, fn ->
            OpenRound.run(f.admin, f.event.id, f.round.id)
          end)
        end)
      end)

    assert_receive {:opener, opener_pid}, 10_000
    await_blocked!(opener_pid, blocker_pid, System.monotonic_time(:millisecond) + 10_000)

    [[query]] =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("SELECT query FROM pg_stat_activity WHERE pid = $1", [opener_pid]).rows
      end)

    assert query =~ "playing_groups"

    writer =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          report_and_call(parent, :writer, fn ->
            Competition.assign_round_tee(f.admin, f.event.id, f.round.id, entry.id, f.tee.id)
          end)
        end)
      end)

    assert_receive {:writer, writer_pid}, 10_000
    assert length(Enum.uniq([blocker_pid, opener_pid, writer_pid])) == 3
    await_blocked!(writer_pid, opener_pid, System.monotonic_time(:millisecond) + 10_000)
    send(blocker.pid, :commit)
    assert {:ok, :ok} = Task.await(blocker, 15_000)
    {Task.await(opener, 15_000), Task.await(writer, 15_000)}
  end

  defp hold_group(parent, group_id) do
    Repo.transaction(fn ->
      {:ok, _} = GolfScoring.LockProtocol.acquire!(playing_group: [group_id])
      [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
      send(parent, {:group_locked, pid})

      receive do
        :commit -> :ok
      after
        15_000 -> Repo.rollback(:timeout)
      end
    end)
  end

  defp report_and_call(parent, tag, fun) do
    [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
    send(parent, {tag, pid})
    fun.()
  end

  defp race!(first_fun, second_fun) do
    parent = self()

    first =
      Task.async(fn -> Sandbox.unboxed_run(Repo, fn -> hold_first(parent, first_fun) end) end)

    assert_receive {:first_held, first_pid}, 10_000

    second =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:second_started, pid})
          second_fun.()
        end)
      end)

    assert_receive {:second_started, second_pid}, 10_000
    refute first_pid == second_pid
    await_blocked!(second_pid, first_pid, System.monotonic_time(:millisecond) + 10_000)
    send(first.pid, :commit)
    {Task.await(first, 15_000), Task.await(second, 15_000)}
  end

  defp hold_first(parent, first_fun) do
    Repo.transaction(fn ->
      result = first_fun.()
      [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
      send(parent, {:first_held, pid})

      receive do
        :commit -> result
      after
        15_000 -> Repo.rollback(:timeout)
      end
    end)
  end

  defp await_blocked!(pid, blocker, deadline) do
    [[blocked]] =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("SELECT $2::int = ANY(pg_blocking_pids($1::int))", [pid, blocker]).rows
      end)

    unless blocked do
      if System.monotonic_time(:millisecond) >= deadline,
        do: flunk("second backend did not block on first")

      await_blocked!(pid, blocker, deadline)
    end
  end

  defp delete_round_children!(round) do
    for table <-
          ~w(mystery_hole_rules competition_side_memberships group_role_assignments competition_sides competition_handicaps handicap_snapshots round_entries scoring_tracks round_competitions playing_groups round_tee_hole_snapshots round_tee_profile_snapshots round_holes) do
      Repo.query!("DELETE FROM #{table} WHERE round_id = $1::uuid", [round])
    end
  end

  defp delete_players!(entries) do
    Enum.each(entries, fn entry ->
      Repo.query!("DELETE FROM players WHERE id = $1::uuid", [Ecto.UUID.dump!(entry.player_id)])
    end)
  end

  defp cleanup_fixture!(f) do
    Sandbox.unboxed_run(Repo, fn ->
      round = Ecto.UUID.dump!(f.round.id)
      course = Ecto.UUID.dump!(f.round.course_id)
      event = Ecto.UUID.dump!(f.event.id)
      staff = Ecto.UUID.dump!(f.admin.id)

      Repo.transaction(fn ->
        Repo.query!(
          "DELETE FROM competition_side_results WHERE competition_side_id IN (SELECT id FROM competition_sides WHERE round_id = $1::uuid)",
          [round]
        )

        delete_round_children!(round)

        Repo.query!("DELETE FROM rounds WHERE id = $1::uuid", [round])

        delete_players!(f.entries)

        Repo.query!(
          "DELETE FROM tee_rating_profiles WHERE tee_set_id IN (SELECT id FROM tee_sets WHERE course_id = $1::uuid)",
          [course]
        )

        Repo.query!("DELETE FROM tee_sets WHERE course_id = $1::uuid", [course])
        Repo.query!("DELETE FROM course_holes WHERE course_id = $1::uuid", [course])
        Repo.query!("DELETE FROM courses WHERE id = $1::uuid", [course])
        Repo.query!("DELETE FROM audit_events WHERE actor_staff_user_id = $1::uuid", [staff])
        Repo.query!("DELETE FROM event_staff_assignments WHERE event_id = $1::uuid", [event])
        Repo.query!("DELETE FROM events WHERE id = $1::uuid", [event])
        Repo.query!("DELETE FROM staff_users WHERE id = $1::uuid", [staff])
      end)
    end)
  end
end

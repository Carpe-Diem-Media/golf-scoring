defmodule GolfScoringWeb.Admin.RoundConfigurationLiveTest do
  use GolfScoringWeb.ConnCase, async: false

  require Ash.Query

  import Phoenix.LiveViewTest

  alias Decimal, as: D
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Competition.Event
  alias GolfScoring.Competition.MysteryHoleRule
  alias GolfScoring.Competition.Player
  alias GolfScoring.Competition.ScoringTrack
  alias GolfScoring.Competition.Services.ConfigureRoundLayout
  alias GolfScoring.Competition.Services.SnapshotRoundTeeProfiles
  alias GolfScoring.GolfCatalog
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Calculators.CourseHandicap
  alias GolfScoring.Scoring.Calculators.PlayingHandicap
  alias GolfScoring.Scoring.CompetitionHandicap
  alias GolfScoring.Scoring.HandicapSnapshot

  @password "GLS-14 synthetic staff passphrase 2026"
  @sign_in_form "#staffuser-password-sign-in-with-password"
  @playing_handicap_policy "whs_golfrsa_2026_v1"
  @no_hi_provenance "Committee minutes 2026-03-15 item 4"

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  describe "A — authorization" do
    test "event admin can open round configuration", %{conn: conn} do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)

      {:ok, view, _html} = live(conn, setup_path(setup))

      assert has_element?(view, "#round-setup")
      assert has_element?(view, "#competition-allowance-form")
    end

    test "competition manager may access round configuration", %{conn: conn} do
      setup = seed_configuration_context!()
      manager = create_staff_user!()
      assign_role!(setup.admin, setup.event, manager, :competition_manager)
      conn = authenticate(conn, manager.email)

      {:ok, view, _html} = live(conn, setup_path(setup))

      assert has_element?(view, "#competition-allowance-form")
      assert has_element?(view, "#starting-entries-list")
    end

    test "registration staff is denied", %{conn: conn} do
      setup = seed_configuration_context!()
      staff = create_staff_user!()
      assign_role!(setup.admin, setup.event, staff, :registration_staff)
      conn = authenticate(conn, staff.email)

      assert {:error, {:live_redirect, %{to: "/admin"}}} =
               live(conn, setup_path(setup))
    end

    test "round/event URL mismatch is denied", %{conn: conn} do
      setup = seed_configuration_context!()
      other_event = create_event!()
      conn = authenticate(conn, setup.admin.email)

      assert {:error, {:live_redirect, %{to: "/admin"}}} =
               live(conn, ~p"/admin/events/#{other_event.id}/rounds/#{setup.round.id}/setup")
    end
  end

  describe "B — lifecycle (draft/ready editable, scoring_open read-only)" do
    test "draft round shows enabled allowance save", %{conn: conn} do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)

      {:ok, view, html} = live(conn, setup_path(setup))

      assert html =~ "State: draft"
      assert has_element?(view, "#competition-allowance-save")
      refute element_disabled?(html, "competition-allowance-save")
    end

    test "ready round remains editable", %{conn: conn} do
      setup = seed_configuration_context!(mark_ready: true)
      conn = authenticate(conn, setup.admin.email)

      {:ok, view, html} = live(conn, setup_path(setup))

      assert html =~ "State: ready"
      refute element_disabled?(html, "competition-allowance-save")

      render_submit(element(view, "#competition-allowance-form"), %{
        "allowance" => %{"handicap_allowance_percent" => "80"}
      })

      assert persisted_allowance_percent!(setup.round.id) == 80
    end

    test "scoring_open round is read-only in UI and blocks mutations", %{conn: conn} do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)

      {:ok, view, _} = live(conn, setup_path(setup))
      save_allowance!(view, 85)
      set_round_state!(setup.round, :scoring_open)
      {:ok, view, html} = live(conn, setup_path(setup))

      assert html =~ "State: scoring_open"
      assert element_disabled?(html, "competition-allowance-save")
      assert element_disabled?(html, "save-standard-track")

      before = persisted_allowance_percent!(setup.round.id)

      html =
        render_click(view, "save_allowance", %{
          "allowance" => %{"handicap_allowance_percent" => "50"}
        })

      assert html =~ "read-only"
      assert persisted_allowance_percent!(setup.round.id) == before
    end
  end

  describe "C — allowance create and update" do
    test "save_allowance creates primary competition and persists allowance", %{conn: conn} do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)

      {:ok, view, _html} = live(conn, setup_path(setup))

      refute primary_competition_id(setup.round.id)

      render_submit(element(view, "#competition-allowance-form"), %{
        "allowance" => %{"handicap_allowance_percent" => "85"}
      })

      competition_id = primary_competition_id(setup.round.id)
      assert competition_id
      assert persisted_allowance_percent!(setup.round.id) == 85
      assert checklist_done?(view, "competition")
    end

    test "save_allowance updates existing allowance", %{conn: conn} do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)

      {:ok, view, _html} = live(conn, setup_path(setup))

      render_submit(element(view, "#competition-allowance-form"), %{
        "allowance" => %{"handicap_allowance_percent" => "85"}
      })

      render_submit(element(view, "#competition-allowance-form"), %{
        "allowance" => %{"handicap_allowance_percent" => "90"}
      })

      assert persisted_allowance_percent!(setup.round.id) == 90
    end
  end

  describe "D — invalid allowance" do
    test "malformed allowance shows controlled error and does not persist", %{conn: conn} do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)

      {:ok, view, _html} = live(conn, setup_path(setup))

      html =
        render_submit(element(view, "#competition-allowance-form"), %{
          "allowance" => %{"handicap_allowance_percent" => "not-a-number"}
        })

      assert html =~ "Handicap allowance must be an integer from 0 to 100"
      refute primary_competition_id(setup.round.id)

      html =
        render_submit(element(view, "#competition-allowance-form"), %{
          "allowance" => %{"handicap_allowance_percent" => "150"}
        })

      assert html =~ "Handicap allowance must be an integer from 0 to 100"
    end
  end

  describe "E — allowance invalidates playing handicaps" do
    test "allowance change clears playing handicaps and shows notice", %{conn: conn} do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)
      [entry_a, entry_b] = setup.entries

      {:ok, view, _html} = live(conn, setup_path(setup))

      save_allowance!(view, 85)
      configure_entry_handicap_pipeline!(view, setup, entry_a, setup.tee_a.id, "10.0")
      configure_entry_handicap_pipeline!(view, setup, entry_b, setup.tee_b.id, "21.0")
      render_click(element(view, "#build-playing-handicap-#{entry_a.id}"))
      render_click(element(view, "#build-playing-handicap-#{entry_b.id}"))

      assert competition_handicap_count(setup.round.id) == 2

      render_submit(element(view, "#competition-allowance-form"), %{
        "allowance" => %{"handicap_allowance_percent" => "75"}
      })

      assert competition_handicap_count(setup.round.id) == 0
      html = render(view)
      assert has_element?(view, "#allowance-invalidation-notice")
      assert html =~ "Rebuild playing handicaps"
      refute checklist_done?(view, "entry_playing")
    end
  end

  describe "F — mixed tees and course handicap calculator path" do
    test "two entries on different snapshots get independent calculated course handicaps", %{
      conn: conn
    } do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)
      [entry_a, entry_b] = setup.entries

      {:ok, view, _html} = live(conn, setup_path(setup))
      save_allowance!(view, 85)

      render_submit(element(view, "#entry-tee-form-#{entry_a.id}"), %{
        "entry" => %{"round_entry_id" => entry_a.id, "snapshot_id" => setup.tee_a.id}
      })

      render_submit(element(view, "#entry-tee-form-#{entry_b.id}"), %{
        "entry" => %{"round_entry_id" => entry_b.id, "snapshot_id" => setup.tee_b.id}
      })

      assert tee_assignment(entry_a.id) == setup.tee_a.id
      assert tee_assignment(entry_b.id) == setup.tee_b.id

      render_submit(element(view, "#entry-handicap-form-#{entry_a.id}"), %{
        "handicap" => %{"round_entry_id" => entry_a.id, "source_handicap_index" => "9.0"}
      })

      render_submit(element(view, "#entry-handicap-form-#{entry_b.id}"), %{
        "handicap" => %{"round_entry_id" => entry_b.id, "source_handicap_index" => "21.0"}
      })

      render_click(element(view, "#build-course-handicap-#{entry_a.id}"))
      render_click(element(view, "#build-course-handicap-#{entry_b.id}"))

      snap_a = fetch_snapshot!(entry_a.id)
      snap_b = fetch_snapshot!(entry_b.id)

      {:ok, expected_a} =
        CourseHandicap.calculate(
          D.new("9.0"),
          setup.tee_a.slope_rating,
          setup.tee_a.course_rating,
          setup.tee_a.applicable_par
        )

      {:ok, expected_b} =
        CourseHandicap.calculate(
          D.new("21.0"),
          setup.tee_b.slope_rating,
          setup.tee_b.course_rating,
          setup.tee_b.applicable_par
        )

      assert snap_a.course_handicap_rounded == expected_a.course_handicap_rounded
      assert snap_b.course_handicap_rounded == expected_b.course_handicap_rounded
      assert snap_a.round_tee_profile_snapshot_id == setup.tee_a.id
      assert snap_b.round_tee_profile_snapshot_id == setup.tee_b.id
      assert snap_a.id != snap_b.id
    end
  end

  describe "G — playing handicap with whs_golfrsa_2026_v1" do
    test "build_playing_handicap persists policy and calculated playing handicap", %{conn: conn} do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)
      entry = hd(setup.entries)

      {:ok, view, _html} = live(conn, setup_path(setup))
      save_allowance!(view, 85)
      configure_entry_handicap_pipeline!(view, setup, entry, setup.tee_a.id, "10.0")

      render_click(element(view, "#build-playing-handicap-#{entry.id}"))

      snapshot = fetch_snapshot!(entry.id)

      {:ok, playing} =
        PlayingHandicap.calculate(snapshot.course_handicap_unrounded, 85)

      row =
        CompetitionHandicap
        |> Ash.Query.filter(round_entry_id == ^entry.id)
        |> Ash.read_one!(authorize?: false)

      assert row.playing_handicap == playing.playing_handicap
      assert row.policy_identifier == @playing_handicap_policy
      assert row.allowance_applied == true
      assert row.handicap_allowance_percent == 85
    end
  end

  describe "H — no-HI deemed basis and provenance" do
    test "apply_no_hi persists deemed basis and explicit committee provenance reference", %{
      conn: conn
    } do
      setup = seed_configuration_context!(include_no_hi_entry: true)
      no_hi_entry = setup.no_hi_entry
      conn = authenticate(conn, setup.admin.email)

      {:ok, view, _html} = live(conn, setup_path(setup))
      save_allowance!(view, 85)

      render_submit(element(view, "#entry-tee-form-#{no_hi_entry.id}"), %{
        "entry" => %{"round_entry_id" => no_hi_entry.id, "snapshot_id" => setup.tee_a.id}
      })

      html =
        render_submit(element(view, "#entry-no-hi-form-#{no_hi_entry.id}"), %{
          "no_hi" => %{
            "round_entry_id" => no_hi_entry.id,
            "deemed_handicap_basis" => "18.5",
            "source_reference" => @no_hi_provenance
          }
        })

      assert html =~ "No-HI policy applied"

      snapshot = fetch_snapshot!(no_hi_entry.id)
      assert snapshot.basis_source == :committee_deemed
      assert snapshot.deemed_handicap_basis == D.new("18.5")
      assert is_nil(snapshot.source_handicap_index)
      assert snapshot.source_reference == @no_hi_provenance
      refute snapshot.source_reference == @playing_handicap_policy

      assert [] ==
               Repo.query!(
                 "SELECT deemed_handicap_basis FROM handicap_snapshots WHERE round_entry_id = $1::uuid AND deemed_handicap_basis IN ('14', '20', '14.0', '20.0')",
                 [Ecto.UUID.dump!(no_hi_entry.id)]
               ).rows
    end

    test "missing provenance reference does not create a handicap snapshot", %{conn: conn} do
      setup = seed_configuration_context!(include_no_hi_entry: true)
      no_hi_entry = setup.no_hi_entry
      conn = authenticate(conn, setup.admin.email)

      {:ok, view, _html} = live(conn, setup_path(setup))
      save_allowance!(view, 85)

      render_submit(element(view, "#entry-tee-form-#{no_hi_entry.id}"), %{
        "entry" => %{"round_entry_id" => no_hi_entry.id, "snapshot_id" => setup.tee_a.id}
      })

      html =
        render_submit(element(view, "#entry-no-hi-form-#{no_hi_entry.id}"), %{
          "no_hi" => %{
            "round_entry_id" => no_hi_entry.id,
            "deemed_handicap_basis" => "18.5",
            "source_reference" => ""
          }
        })

      assert html =~ "provenance"
      refute fetch_snapshot_optional(no_hi_entry.id)
    end

    test "empty deemed basis does not create a handicap snapshot", %{conn: conn} do
      setup = seed_configuration_context!(include_no_hi_entry: true)
      no_hi_entry = setup.no_hi_entry
      conn = authenticate(conn, setup.admin.email)

      {:ok, view, _html} = live(conn, setup_path(setup))
      save_allowance!(view, 85)

      render_submit(element(view, "#entry-tee-form-#{no_hi_entry.id}"), %{
        "entry" => %{"round_entry_id" => no_hi_entry.id, "snapshot_id" => setup.tee_a.id}
      })

      html =
        render_submit(element(view, "#entry-no-hi-form-#{no_hi_entry.id}"), %{
          "no_hi" => %{
            "round_entry_id" => no_hi_entry.id,
            "deemed_handicap_basis" => "",
            "source_reference" => @no_hi_provenance
          }
        })

      assert html =~ "valid"
      refute fetch_snapshot_optional(no_hi_entry.id)
    end
  end

  describe "I — standard and mystery tracks" do
    test "locked scoring tracks are read-only in the UI", %{conn: conn} do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)

      {:ok, view, _html} = live(conn, setup_path(setup))
      save_allowance!(view, 85)
      render_click(element(view, "#save-standard-track"))
      render_click(element(view, "#save-mystery-track"))

      assert :ok =
               GolfScoring.Competition.Services.LockScoringTracksForRound.run(setup.round.id)

      {:ok, view, html} = live(conn, setup_path(setup))

      assert has_element?(view, "#scoring-tracks-locked-notice")
      assert element_disabled?(html, "save-standard-track")
      assert element_disabled?(html, "save-mystery-track")
      assert html =~ "locked"

      html = render_click(view, "save_standard_track", %{})
      assert html =~ "locked"
    end

    test "save_standard_track and save_mystery_track persist exact attrs idempotently", %{
      conn: conn
    } do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)

      {:ok, view, _html} = live(conn, setup_path(setup))
      save_allowance!(view, 85)

      render_click(element(view, "#save-standard-track"))
      render_click(element(view, "#save-standard-track"))

      render_click(element(view, "#save-mystery-track"))
      render_click(element(view, "#save-mystery-track"))

      standard =
        ScoringTrack
        |> Ash.Query.filter(round_id == ^setup.round.id and track_type == :standard_better_ball)
        |> Ash.read!(authorize?: false)

      mystery =
        ScoringTrack
        |> Ash.Query.filter(round_id == ^setup.round.id and track_type == :mystery)
        |> Ash.read!(authorize?: false)

      assert length(standard) == 1
      assert length(mystery) == 1

      std = hd(standard)
      mys = hd(mystery)

      assert std.name == "Standard Better-Ball"
      assert std.is_primary == false
      assert std.visibility_policy_identifier == "leaderboard_v1"
      assert std.aggregation_policy_identifier == "standard_better_ball_v1"
      assert std.tie_break_policy_identifier == "standard_countback_v1"

      assert mys.name == "Mystery Leaderboard"
      assert mys.is_primary == true
      assert mys.visibility_policy_identifier == "staff_only_v1"
      assert mys.aggregation_policy_identifier == "mystery_v1"
      assert mys.tie_break_policy_identifier == "mystery_holes_then_countback_v1"
    end

    test "correctly configured locked tracks still satisfy track checklist items", %{conn: conn} do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)

      {:ok, view, _html} = live(conn, setup_path(setup))
      save_both_tracks!(view)

      assert :ok =
               GolfScoring.Competition.Services.LockScoringTracksForRound.run(setup.round.id)

      {:ok, view, _html} = live(conn, setup_path(setup))

      assert checklist_done?(view, "standard_track")
      assert checklist_done?(view, "mystery_track")
    end
  end

  describe "J — mystery hole rules BEST/WORST/BOTH/NONE" do
    test "persists mystery selections for admin", %{conn: conn} do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)
      hole = hd(setup.round_holes)

      {:ok, view, _html} = live(conn, setup_path(setup))
      save_allowance!(view, 85)
      render_click(element(view, "#save-mystery-track"))

      for {selection, expected_rule} <- [
            {"BEST", :best},
            {"WORST", :worst},
            {"BOTH", :both},
            {"NONE", nil}
          ] do
        render_submit(element(view, "#mystery-rule-form-#{hole.id}"), %{
          "rule" => %{"round_hole_id" => hole.id, "selection" => selection}
        })

        rule = fetch_mystery_rule(setup.round.id, hole.id)

        if expected_rule do
          assert rule.rule == expected_rule
        else
          assert is_nil(rule)
        end
      end
    end

    test "competition manager may configure mystery hole rules", %{conn: conn} do
      setup = seed_configuration_context!()
      manager = create_staff_user!()
      assign_role!(setup.admin, setup.event, manager, :competition_manager)
      hole = hd(setup.round_holes)
      conn = authenticate(conn, manager.email)

      {:ok, view, _html} = live(conn, setup_path(setup))
      save_allowance!(view, 85)
      render_click(element(view, "#save-mystery-track"))

      assert has_element?(view, "#mystery-hole-rules")

      render_submit(element(view, "#mystery-rule-form-#{hole.id}"), %{
        "rule" => %{"round_hole_id" => hole.id, "selection" => "BEST"}
      })

      rule = fetch_mystery_rule(setup.round.id, hole.id)
      assert rule.rule == :best
    end

    test "locked mystery track keeps rules visible but rejects server-side mutations", %{
      conn: conn
    } do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)
      hole = hd(setup.round_holes)

      {:ok, view, _html} = live(conn, setup_path(setup))
      save_both_tracks!(view)

      render_submit(element(view, "#mystery-rule-form-#{hole.id}"), %{
        "rule" => %{"round_hole_id" => hole.id, "selection" => "BEST"}
      })

      assert fetch_mystery_rule(setup.round.id, hole.id).rule == :best

      assert :ok =
               GolfScoring.Competition.Services.LockScoringTracksForRound.run(setup.round.id)

      {:ok, view, html} = live(conn, setup_path(setup))

      assert has_element?(view, "#mystery-hole-rules")
      assert element_disabled?(html, "mystery-rule-#{hole.id}")
      assert element_disabled?(html, "mystery-rule-save-#{hole.id}")

      html =
        render_submit(element(view, "#mystery-rule-form-#{hole.id}"), %{
          "rule" => %{"round_hole_id" => hole.id, "selection" => "WORST"}
        })

      assert html =~ "locked"
      assert fetch_mystery_rule(setup.round.id, hole.id).rule == :best

      html =
        render_submit(element(view, "#mystery-rule-form-#{hole.id}"), %{
          "rule" => %{"round_hole_id" => hole.id, "selection" => "NONE"}
        })

      assert html =~ "locked"
      assert fetch_mystery_rule(setup.round.id, hole.id).rule == :best
    end
  end

  describe "K — configuration checklist" do
    test "checklist shows missing items on fresh context", %{conn: conn} do
      setup = seed_configuration_context!(skip_competition_seed: true)
      conn = authenticate(conn, setup.admin.email)

      {:ok, view, _html} = live(conn, setup_path(setup))

      assert has_element?(view, "#competition-configuration-status")
      assert checklist_done?(view, "route")
      assert checklist_done?(view, "tee_snapshots")
      refute checklist_done?(view, "competition")
      refute checklist_done?(view, "mystery_rules")
    end

    test "checklist requires exact V1 standard track configuration, not type presence alone",
         %{conn: conn} do
      for {column, wrong_value} <- standard_track_wrong_v1_cases() do
        setup = seed_configuration_context!()
        conn = authenticate(conn, setup.admin.email)

        {:ok, view, _html} = live(conn, setup_path(setup))
        save_both_tracks!(view)

        standard = fetch_scoring_track!(setup.round.id, :standard_better_ball)
        set_scoring_track_column!(standard.id, column, wrong_value)

        {:ok, view, _html} = live(conn, setup_path(setup))
        refute checklist_done?(view, "standard_track")
      end
    end

    test "checklist requires exact V1 mystery track configuration, not type presence alone",
         %{conn: conn} do
      for {column, wrong_value} <- mystery_track_wrong_v1_cases() do
        setup = seed_configuration_context!()
        conn = authenticate(conn, setup.admin.email)

        {:ok, view, _html} = live(conn, setup_path(setup))
        save_both_tracks!(view)

        mystery = fetch_scoring_track!(setup.round.id, :mystery)
        set_scoring_track_column!(mystery.id, column, wrong_value)

        {:ok, view, _html} = live(conn, setup_path(setup))
        refute checklist_done?(view, "mystery_track")
      end
    end

    test "checklist completes after full configuration pipeline", %{conn: conn} do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)
      [entry_a, entry_b] = setup.entries
      hole = hd(setup.round_holes)

      {:ok, view, _html} = live(conn, setup_path(setup))

      save_allowance!(view, 85)
      render_click(element(view, "#save-standard-track"))
      render_click(element(view, "#save-mystery-track"))

      render_submit(element(view, "#mystery-rule-form-#{hole.id}"), %{
        "rule" => %{"round_hole_id" => hole.id, "selection" => "BEST"}
      })

      configure_entry_handicap_pipeline!(view, setup, entry_a, setup.tee_a.id, "10.0")
      configure_entry_handicap_pipeline!(view, setup, entry_b, setup.tee_b.id, "21.0")
      render_click(element(view, "#build-playing-handicap-#{entry_a.id}"))
      render_click(element(view, "#build-playing-handicap-#{entry_b.id}"))

      for key <-
            ~w(route tee_snapshots competition standard_track mystery_track mystery_rules entry_tees entry_basis entry_course entry_playing) do
        assert checklist_done?(view, key)
      end
    end
  end

  describe "L — malformed inputs and no scoring-open controls" do
    test "malformed entry tee and handicap inputs show controlled errors", %{conn: conn} do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)
      entry = hd(setup.entries)

      {:ok, view, _html} = live(conn, setup_path(setup))

      html =
        render_submit(element(view, "#entry-tee-form-#{entry.id}"), %{
          "entry" => %{"round_entry_id" => "bad", "snapshot_id" => setup.tee_a.id}
        })

      assert html =~ "valid"

      render_submit(element(view, "#entry-tee-form-#{entry.id}"), %{
        "entry" => %{"round_entry_id" => entry.id, "snapshot_id" => setup.tee_a.id}
      })

      html =
        render_submit(element(view, "#entry-handicap-form-#{entry.id}"), %{
          "handicap" => %{
            "round_entry_id" => entry.id,
            "source_handicap_index" => "not-a-decimal"
          }
        })

      assert html =~ "valid"
      refute fetch_snapshot_optional(entry.id)
    end

    test "malformed mystery rule selection shows controlled error without crashing", %{
      conn: conn
    } do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)
      hole = hd(setup.round_holes)

      {:ok, view, _html} = live(conn, setup_path(setup))
      save_allowance!(view, 85)
      render_click(element(view, "#save-mystery-track"))

      html =
        render_submit(element(view, "#mystery-rule-form-#{hole.id}"), %{
          "rule" => %{"round_hole_id" => hole.id, "selection" => "not-valid"}
        })

      assert html =~ "NONE, BEST, WORST, or BOTH"
      refute fetch_mystery_rule(setup.round.id, hole.id)
    end

    test "stale handicap build surfaces friendly error and refreshes entry state", %{conn: conn} do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)
      entry = hd(setup.entries)

      {:ok, view, _html} = live(conn, setup_path(setup))
      save_allowance!(view, 85)
      configure_entry_handicap_pipeline!(view, setup, entry, setup.tee_a.id, "10.0")

      snapshot = fetch_snapshot!(entry.id)

      Repo.query!(
        "UPDATE handicap_snapshots SET course_handicap_unrounded = $1 WHERE id = $2::uuid",
        [D.new("999.9"), Ecto.UUID.dump!(snapshot.id)]
      )

      html = render_click(element(view, "#build-playing-handicap-#{entry.id}"))
      assert html =~ "Handicap inputs changed"
      refute fetch_competition_handicap_optional(entry.id)
    end

    test "no open_scoring control is exposed", %{conn: conn} do
      setup = seed_configuration_context!()
      conn = authenticate(conn, setup.admin.email)

      {:ok, view, html} = live(conn, setup_path(setup))

      refute html =~ "open_scoring"
      refute has_element?(view, "[phx-click=\"open_scoring\"]")
    end
  end

  defp setup_path(%{event: event, round: round}) do
    ~p"/admin/events/#{event.id}/rounds/#{round.id}/setup"
  end

  defp seed_configuration_context!(opts \\ []) do
    event = create_event!()
    admin = create_event_admin!(event)
    course = create_course!(event, admin)
    holes = create_eighteen_holes!(event, admin, course)
    white = create_tee_set!(event, admin, course, "White")
    red = create_tee_set!(event, admin, course, "Red")
    profile_a = create_profile!(event, admin, white, holes, "Men", par: 4, slope: 120)
    profile_b = create_profile!(event, admin, red, holes, "Women", par: 5, slope: 125)

    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    {:ok, _} = ConfigureRoundLayout.run(admin, round.id, Enum.map(holes, & &1.id))

    {:ok, snapshots} = SnapshotRoundTeeProfiles.run(admin, round.id, [profile_a.id, profile_b.id])

    tee_a =
      load_snapshot_ratings!(
        Enum.find(snapshots, &(&1.source_tee_rating_profile_id == profile_a.id))
      )

    tee_b =
      load_snapshot_ratings!(
        Enum.find(snapshots, &(&1.source_tee_rating_profile_id == profile_b.id))
      )

    hi_player_a = create_player!(%{latest_handicap_index: D.new("10.0")})
    hi_player_b = create_player!(%{latest_handicap_index: D.new("21.0")})
    no_hi_player = create_player!(%{latest_handicap_index: nil})

    {:ok, entry_hi_a} =
      Competition.add_round_entry(event.id, round.id, hi_player_a.id, actor: admin)

    {:ok, entry_hi_b} =
      Competition.add_round_entry(event.id, round.id, hi_player_b.id, actor: admin)

    no_hi_entry =
      if Keyword.get(opts, :include_no_hi_entry) do
        {:ok, entry_no_hi} =
          Competition.add_round_entry(event.id, round.id, no_hi_player.id, actor: admin)

        entry_no_hi
      end

    round_holes = list_round_holes(round.id)

    if Keyword.get(opts, :mark_ready) do
      set_round_state!(round, :ready)
    end

    unless Keyword.get(opts, :skip_competition_seed) do
      # default allowance seed via service so scoring_open tests have a baseline competition row
      :ok
    end

    %{
      event: event,
      admin: admin,
      round: round,
      holes: holes,
      entries: [entry_hi_a, entry_hi_b],
      no_hi_entry: no_hi_entry,
      tee_a: tee_a,
      tee_b: tee_b,
      round_holes: round_holes
    }
  end

  defp save_allowance!(view, percent) do
    render_submit(element(view, "#competition-allowance-form"), %{
      "allowance" => %{"handicap_allowance_percent" => to_string(percent)}
    })
  end

  defp save_both_tracks!(view) do
    save_allowance!(view, 85)
    render_click(element(view, "#save-standard-track"))
    render_click(element(view, "#save-mystery-track"))
  end

  defp standard_track_wrong_v1_cases do
    [
      {"aggregation_policy_identifier", "wrong_standard_v1"},
      {"tie_break_policy_identifier", "wrong_countback_v1"},
      {"visibility_policy_identifier", "wrong_visibility_v1"},
      {"name", "Wrong Standard Name"}
    ]
  end

  defp mystery_track_wrong_v1_cases do
    [
      {"aggregation_policy_identifier", "wrong_mystery_v1"},
      {"tie_break_policy_identifier", "wrong_mystery_countback_v1"},
      {"visibility_policy_identifier", "leaderboard_v1"},
      {"name", "Wrong Mystery Name"},
      {"is_primary", false}
    ]
  end

  defp fetch_scoring_track!(round_id, track_type) do
    ScoringTrack
    |> Ash.Query.filter(round_id == ^round_id and track_type == ^track_type)
    |> Ash.read_one!(authorize?: false)
  end

  defp set_scoring_track_column!(track_id, "is_primary", value) when is_boolean(value) do
    Repo.query!(
      "UPDATE scoring_tracks SET is_primary = $1 WHERE id = $2::uuid",
      [value, Ecto.UUID.dump!(track_id)]
    )
  end

  defp set_scoring_track_column!(track_id, column, value) when is_binary(column) do
    Repo.query!(
      "UPDATE scoring_tracks SET #{column} = $1 WHERE id = $2::uuid",
      [value, Ecto.UUID.dump!(track_id)]
    )
  end

  defp configure_entry_handicap_pipeline!(view, _setup, entry, tee_id, hi) do
    render_submit(element(view, "#entry-tee-form-#{entry.id}"), %{
      "entry" => %{"round_entry_id" => entry.id, "snapshot_id" => tee_id}
    })

    render_submit(element(view, "#entry-handicap-form-#{entry.id}"), %{
      "handicap" => %{"round_entry_id" => entry.id, "source_handicap_index" => hi}
    })

    render_click(element(view, "#build-course-handicap-#{entry.id}"))
  end

  defp fetch_snapshot!(entry_id) do
    HandicapSnapshot
    |> Ash.Query.filter(round_entry_id == ^entry_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp fetch_snapshot_optional(entry_id) do
    HandicapSnapshot
    |> Ash.Query.filter(round_entry_id == ^entry_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, row} -> row
      _ -> nil
    end
  end

  defp fetch_mystery_rule(round_id, round_hole_id) do
    MysteryHoleRule
    |> Ash.Query.filter(round_hole_id == ^round_hole_id)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [rule | _]} ->
        if rule.round_id == round_id, do: rule, else: nil

      _ ->
        nil
    end
  end

  defp competition_handicap_count(round_id) do
    [[count]] =
      Repo.query!("SELECT count(*) FROM competition_handicaps WHERE round_id = $1::uuid", [
        Ecto.UUID.dump!(round_id)
      ]).rows

    count
  end

  defp fetch_competition_handicap_optional(entry_id) do
    CompetitionHandicap
    |> Ash.Query.filter(round_entry_id == ^entry_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, row} -> row
      _ -> nil
    end
  end

  defp primary_competition_id(round_id) do
    case Repo.query!(
           "SELECT id::text FROM round_competitions WHERE round_id = $1::uuid AND is_primary = true LIMIT 1",
           [Ecto.UUID.dump!(round_id)]
         ).rows do
      [[id]] when is_binary(id) -> Ecto.UUID.cast!(id)
      _ -> nil
    end
  end

  defp load_snapshot_ratings!(snapshot) do
    [[slope, course_rating, par]] =
      Repo.query!(
        """
        SELECT slope_rating, course_rating::text, applicable_par
        FROM round_tee_profile_snapshots
        WHERE id = $1::uuid
        """,
        [Ecto.UUID.dump!(snapshot.id)]
      ).rows

    Map.merge(snapshot, %{
      slope_rating: slope,
      course_rating: D.new(course_rating),
      applicable_par: par
    })
  end

  defp persisted_allowance_percent!(round_id) do
    [[allowance]] =
      Repo.query!(
        """
        SELECT handicap_allowance_percent
        FROM round_competitions
        WHERE round_id = $1::uuid AND is_primary = true
        LIMIT 1
        """,
        [Ecto.UUID.dump!(round_id)]
      ).rows

    allowance
  end

  defp tee_assignment(entry_id) do
    [[tee_id]] =
      Repo.query!(
        "SELECT round_tee_profile_snapshot_id::text FROM round_entries WHERE id = $1::uuid",
        [Ecto.UUID.dump!(entry_id)]
      ).rows

    if tee_id, do: Ecto.UUID.cast!(tee_id), else: nil
  end

  defp list_round_holes(round_id) do
    Repo.query!(
      """
      SELECT id::text, play_order, display_hole_number
      FROM round_holes
      WHERE round_id = $1::uuid
      ORDER BY play_order
      """,
      [Ecto.UUID.dump!(round_id)]
    ).rows
    |> Enum.map(fn [id, play_order, display] ->
      %{id: Ecto.UUID.cast!(id), play_order: play_order, display_hole_number: display}
    end)
  end

  defp element_disabled?(html, element_id) do
    html =~ ~r/id="#{element_id}"[^>]*disabled/
  end

  defp checklist_done?(view, key) do
    has_element?(view, "#competition-check-#{key} span.text-success")
  end

  defp set_round_state!(round, state) do
    Repo.query!("UPDATE rounds SET state = $1 WHERE id = $2::uuid", [
      Atom.to_string(state),
      Ecto.UUID.dump!(round.id)
    ])
  end

  defp authenticate(conn, email) do
    {:ok, view, _html} = live(conn, "/admin/sign-in")

    form =
      form(view, @sign_in_form, %{
        "staffuser" => %{"email" => to_string(email), "password" => @password}
      })

    render_submit(form)
    follow_trigger_action(form, conn)
  end

  defp create_event! do
    Event
    |> Ash.Changeset.for_create(:create_internal, %{})
    |> Ash.create!(authorize?: false)
  end

  defp create_event_admin!(event) do
    staff = create_staff_user!()

    Repo.query!(
      "INSERT INTO event_staff_assignments (event_id, staff_user_id, role, status) VALUES ($1::uuid, $2::uuid, 'event_admin', 'active')",
      [Ecto.UUID.dump!(event.id), Ecto.UUID.dump!(staff.id)]
    )

    staff
  end

  defp create_staff_user! do
    email = "gls28-config-#{System.unique_integer([:positive])}@example.com"

    Accounts.StaffUser
    |> Ash.Changeset.for_create(:provision_staff_user, %{
      email: email,
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end

  defp assign_role!(actor, event, staff, role) do
    {:ok, _} =
      Accounts.assign_event_staff_role(
        %{event_id: event.id, staff_user_id: staff.id, role: role},
        actor: actor
      )
  end

  defp create_player!(attrs) do
    defaults = %{
      first_name: "Pat",
      surname: "Golfer#{System.unique_integer([:positive])}"
    }

    Player
    |> Ash.Changeset.for_create(:create_internal, Map.merge(defaults, attrs))
    |> Ash.create!(authorize?: false)
  end

  defp create_course!(event, admin) do
    {:ok, course} =
      GolfCatalog.create_course(event.id, %{name: "Course", location: "ZA"}, actor: admin)

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

  defp create_tee_set!(event, admin, course, name) do
    {:ok, tee_set} =
      GolfCatalog.configure_tee_set(event.id, %{course_id: course.id, name: name}, actor: admin)

    tee_set
  end

  defp create_profile!(event, admin, tee_set, holes, label, opts) do
    par = Keyword.get(opts, :par, 4)
    slope = Keyword.get(opts, :slope, 113)

    hole_ratings =
      Enum.map(holes, fn hole ->
        %{
          course_hole_id: hole.id,
          par: par,
          stroke_index: hole.hole_number,
          distance_m: 300 + hole.hole_number
        }
      end)

    {:ok, profile} =
      GolfCatalog.configure_tee_rating_profile(
        event.id,
        %{
          tee_set_id: tee_set.id,
          rating_label: label,
          course_rating: D.new("72.0"),
          slope_rating: slope,
          total_par: par * 18,
          hole_ratings: hole_ratings
        },
        actor: admin
      )

    profile
  end
end

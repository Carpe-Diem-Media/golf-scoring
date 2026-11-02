defmodule GolfScoring.Scoring.HandicapRecordsTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ash.Resource.Info
  alias Decimal, as: D
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Audit.AuditEvent
  alias GolfScoring.Competition
  alias GolfScoring.Competition.Event
  alias GolfScoring.Competition.Player
  alias GolfScoring.Competition.Round
  alias GolfScoring.Competition.RoundCompetition
  alias GolfScoring.Competition.Services.ConfigureRoundCompetition
  alias GolfScoring.Competition.Services.ConfigureRoundLayout
  alias GolfScoring.Competition.Services.SnapshotRoundTeeProfiles
  alias GolfScoring.GolfCatalog
  alias GolfScoring.Repo
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Calculators.CourseHandicap
  alias GolfScoring.Scoring.Calculators.PlayingHandicap
  alias GolfScoring.Scoring.CompetitionHandicap
  alias GolfScoring.Scoring.HandicapRowLock
  alias GolfScoring.Scoring.HandicapSnapshot

  @password "GLS-22 synthetic staff passphrase 2026"

  setup tags do
    Process.put(:gls22_prefix, "gls22-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls22_prefix) end)

    unless tags[:gls75_connections] do
      owner = Sandbox.start_owner!(Repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(owner) end)
    end

    :ok
  end

  test "Scoring domain registers only expected GLS-22 resources" do
    resources = Ash.Domain.Info.resources(Scoring)
    assert HandicapSnapshot in resources
    assert CompetitionHandicap in resources
    assert length(resources) == 2
    refute Info.action(HandicapSnapshot, :create)
    refute Info.action(CompetitionHandicap, :create)
  end

  test "handicap resources expose named internal actions only" do
    refute Info.action(HandicapSnapshot, :create)
    refute Info.action(HandicapSnapshot, :update)
    refute Info.action(HandicapSnapshot, :destroy)
    refute Info.action(CompetitionHandicap, :create)
    refute Info.action(CompetitionHandicap, :destroy)

    assert Info.action(HandicapSnapshot, :create_configured_internal)
    assert Info.action(CompetitionHandicap, :build_internal)
  end

  test "assign_round_tee authorizes managers only and rejects scoring_open round" do
    setup = setup_round_with_tees!()
    staff = create_staff_user!()
    assign_role!(setup.admin, setup.event, staff, :registration_staff)

    assert {:error, :forbidden} =
             Competition.assign_round_tee(
               staff,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               setup.tee_a.id
             )

    scoring_open = set_round_state!(setup.round, :scoring_open)

    assert {:error, {:invalid_round_state, :scoring_open}} =
             Competition.assign_round_tee(
               setup.admin,
               setup.event.id,
               scoring_open.id,
               setup.entry.id,
               setup.tee_a.id
             )

    assert is_nil(
             Ash.get!(GolfScoring.Competition.RoundEntry, setup.entry.id, authorize?: false).round_tee_profile_snapshot_id
           )
  end

  test "post-open handicap operations reject without changing their records" do
    setup = setup_round_with_tees!(assign_tee: true, competition: true)

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.entry.player_id)

    assert {:ok, snapshot} =
             Scoring.confirm_handicap_input(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{source_handicap_index: D.new("10.0")}
             )

    assert {:ok, built} =
             Scoring.build_handicap_snapshot(
               setup.entry.id,
               course_attrs!(D.new("10.0"), setup.tee_a)
             )

    attrs = playing_attrs!(setup.entry.id, 85)
    set_round_state!(setup.round, :scoring_open)
    error = {:error, {:invalid_round_state, :scoring_open}}

    assert ^error =
             Scoring.confirm_handicap_input(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{source_handicap_index: D.new("11.0")}
             )

    assert ^error =
             Scoring.confirm_handicap_input_for_player_grant(
               grant.id,
               setup.round.id,
               setup.entry.id,
               %{source_handicap_index: D.new("11.0")}
             )

    assert ^error =
             Scoring.build_handicap_snapshot(
               setup.entry.id,
               course_attrs!(D.new("10.0"), setup.tee_a)
             )

    assert ^error =
             Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, attrs)

    after_snapshot = fetch_snapshot!(setup.entry.id)
    assert after_snapshot.id == snapshot.id
    assert after_snapshot.source_handicap_index == snapshot.source_handicap_index
    assert after_snapshot.built_at == built.built_at
    assert competition_count(setup.entry.id) == 0
  end

  @tag :gls75_connections
  test "opening barrier rejects waiting tee assignment" do
    setup = committed_gls75_fixture!()

    {first, second} =
      gls75_race!(
        fn ->
          lock_round_row!(setup.round.id)
        end,
        fn ->
          Competition.assign_round_tee(
            setup.admin,
            setup.event.id,
            setup.round.id,
            setup.entry.id,
            setup.tee_b.id
          )
        end,
        fn -> set_round_state!(setup.round, :scoring_open) end
      )

    assert {:ok, _} = first
    assert {:error, {:invalid_round_state, :scoring_open}} = second

    Sandbox.unboxed_run(Repo, fn ->
      assert fetch_snapshot!(setup.entry.id).round_tee_profile_snapshot_id == setup.tee_a.id

      assert Ash.get!(GolfScoring.Competition.RoundEntry, setup.entry.id, authorize?: false).round_tee_profile_snapshot_id ==
               setup.tee_a.id
    end)
  end

  @tag :gls75_connections
  test "opening barrier rejects waiting handicap mutation" do
    setup = committed_gls75_fixture!()

    {first, second} =
      gls75_race!(
        fn ->
          lock_round_row!(setup.round.id)
        end,
        fn ->
          Scoring.confirm_handicap_input(
            setup.admin,
            setup.event.id,
            setup.round.id,
            setup.entry.id,
            %{source_handicap_index: D.new("11.0")}
          )
        end,
        fn -> set_round_state!(setup.round, :scoring_open) end
      )

    assert {:ok, _} = first
    assert {:error, {:invalid_round_state, :scoring_open}} = second

    Sandbox.unboxed_run(Repo, fn ->
      assert D.equal?(fetch_snapshot!(setup.entry.id).source_handicap_index, D.new("10.0"))
    end)
  end

  @tag :gls75_connections
  test "round locker sees a committed handicap mutation" do
    setup = committed_gls75_fixture!()

    {first, second} =
      gls75_race!(
        fn ->
          Scoring.confirm_handicap_input(
            setup.admin,
            setup.event.id,
            setup.round.id,
            setup.entry.id,
            %{source_handicap_index: D.new("11.0")}
          )
        end,
        fn ->
          Repo.transaction(fn ->
            lock_round_row!(setup.round.id)
            fetch_snapshot!(setup.entry.id).source_handicap_index
          end)
        end
      )

    assert {:ok, {:ok, _}} = first
    assert {:ok, basis} = second
    assert D.equal?(basis, D.new("11.0"))
  end

  test "cross-round tee assignment fails at database layer" do
    setup = setup_round_with_tees!()
    other = setup_round_with_tees!()

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        """
        UPDATE round_entries
        SET round_tee_profile_snapshot_id = $1::uuid
        WHERE id = $2::uuid
        """,
        [Ecto.UUID.dump!(other.tee_a.id), Ecto.UUID.dump!(setup.entry.id)]
      )
    end
  end

  test "started entry rejects ordinary tee and handicap mutation" do
    setup = setup_round_with_tees!()

    force_participation!(setup.entry.id, :active)

    assert {:error, :entry_not_not_started} =
             Competition.assign_round_tee(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               setup.tee_a.id
             )

    assert {:error, :entry_not_not_started} =
             Scoring.confirm_handicap_input(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{source_handicap_index: D.new("12.4")}
             )
  end

  test "official HI is distinguishable from committee deemed basis" do
    setup = setup_round_with_tees!(assign_tee: true)

    assert {:ok, official} =
             Scoring.confirm_handicap_input(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{source_handicap_index: D.new("10.2")}
             )

    assert official.basis_source == :official_or_preloaded
    assert official.source_handicap_index == D.new("10.2")
    assert is_nil(official.deemed_handicap_basis)

    entry2 = add_entry!(setup)

    assert {:ok, _} =
             Competition.assign_round_tee(
               setup.admin,
               setup.event.id,
               setup.round.id,
               entry2.id,
               setup.tee_a.id
             )

    assert {:ok, deemed} =
             Scoring.apply_no_hi_policy(
               setup.admin,
               setup.event.id,
               setup.round.id,
               entry2.id,
               %{deemed_handicap_basis: D.new("18.0"), policy_reference: "committee discretion"}
             )

    assert deemed.basis_source == :committee_deemed
    assert deemed.deemed_handicap_basis == D.new("18.0")
    assert is_nil(deemed.source_handicap_index)
  end

  test "staff cannot forge player round entry confirmer provenance" do
    setup = setup_round_with_tees!(assign_tee: true)

    assert {:ok, staff_snapshot} =
             Scoring.confirm_handicap_input(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{source_handicap_index: D.new("8.1")},
               basis_source: :player_declared
             )

    assert staff_snapshot.basis_source == :player_declared
    assert staff_snapshot.confirmed_by_staff_user_id == setup.admin.id
    assert is_nil(staff_snapshot.confirmed_by_round_entry_id)

    assert {:ok, ignored_confirmer} =
             Scoring.confirm_handicap_input(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{source_handicap_index: D.new("8.2")},
               basis_source: :player_declared,
               confirmer: :player_entry
             )

    assert ignored_confirmer.confirmed_by_staff_user_id == setup.admin.id
    assert is_nil(ignored_confirmer.confirmed_by_round_entry_id)
  end

  test "active player grant confirms only matching round entry" do
    setup = setup_round_with_tees!(assign_tee: true)

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.entry.player_id)

    assert {:ok, snapshot} =
             Scoring.confirm_handicap_input_for_player_grant(
               grant.id,
               setup.round.id,
               setup.entry.id,
               %{source_handicap_index: D.new("9.4")}
             )

    assert snapshot.basis_source == :player_declared
    assert snapshot.confirmed_by_round_entry_id == setup.entry.id
    assert is_nil(snapshot.confirmed_by_staff_user_id)
  end

  test "player grant cannot confirm another player's entry" do
    setup = setup_round_with_tees!(profiles: 2, entries: 2, assign_tee: true)
    [entry_a, entry_b] = setup.entries

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, entry_a.player_id)

    assert {:error, :invalid_player_session} =
             Scoring.confirm_handicap_input_for_player_grant(
               grant.id,
               setup.round.id,
               entry_b.id,
               %{source_handicap_index: D.new("7.0")}
             )
  end

  test "revoked grant cannot confirm handicap input" do
    setup = setup_round_with_tees!(assign_tee: true)

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.entry.player_id)

    assert {:ok, _} =
             Accounts.revoke_player_access(setup.admin, setup.event.id, setup.entry.player_id)

    assert {:error, :invalid_player_session} =
             Scoring.confirm_handicap_input_for_player_grant(
               grant.id,
               setup.round.id,
               setup.entry.id,
               %{source_handicap_index: D.new("6.0")}
             )
  end

  test "committee deemed requires nonblank provenance" do
    setup = setup_round_with_tees!(assign_tee: true)

    assert {:error, :provenance_reference_required} =
             Scoring.apply_no_hi_policy(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{deemed_handicap_basis: D.new("18.0")}
             )

    assert {:error, :provenance_reference_required} =
             Scoring.apply_no_hi_policy(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{deemed_handicap_basis: D.new("18.0"), policy_reference: "   "}
             )
  end

  test "apply_no_hi_policy rejects players with existing handicap index" do
    setup = setup_round_with_tees!(assign_tee: true)

    Repo.query!(
      "UPDATE players SET latest_handicap_index = $1::numeric WHERE id = $2::uuid",
      [D.new("12.0"), Ecto.UUID.dump!(setup.entry.player_id)]
    )

    assert {:error, :player_has_handicap_index} =
             Scoring.apply_no_hi_policy(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{deemed_handicap_basis: D.new("18.0"), policy_reference: "committee discretion"}
             )
  end

  test "build_competition_handicap requires explicit allowance_applied" do
    setup = setup_round_with_tees!(assign_tee: true, competition: true)
    build_built_snapshot!(setup)

    assert {:error, :allowance_applied_required} =
             Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, %{
               playing_handicap: 8,
               policy_identifier: "policy_a"
             })
  end

  test "tee reassignment realigns snapshot tee and clears derived handicap output" do
    setup = setup_round_with_tees!(profiles: 2, assign_tee: true, competition: true)
    build_built_snapshot!(setup)

    assert {:ok, _} =
             Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, %{
               playing_handicap: valid_playing!(setup.entry.id, 85),
               policy_identifier: "policy_keep",
               allowance_applied: true
             })

    assert competition_count(setup.entry.id) == 1

    assert {:ok, _} =
             Competition.assign_round_tee(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               setup.tee_b.id
             )

    snapshot = fetch_snapshot!(setup.entry.id)
    assert snapshot.round_tee_profile_snapshot_id == setup.tee_b.id
    assert is_nil(snapshot.built_at)
    assert is_nil(snapshot.course_rating)
    assert competition_count(setup.entry.id) == 0

    assert {:ok, rebuilt} =
             Scoring.build_handicap_snapshot(
               setup.entry.id,
               course_attrs!(D.new("10.0"), setup.tee_b)
             )

    assert rebuilt.course_rating == setup.tee_b.course_rating
    assert rebuilt.slope_rating == setup.tee_b.slope_rating
    assert rebuilt.applicable_par == setup.tee_b.applicable_par
  end

  test "basis mutation rolls back when derived invalidation fails" do
    setup = setup_round_with_tees!(assign_tee: true, competition: true)
    build_built_snapshot!(setup)

    assert {:ok, _} =
             Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, %{
               playing_handicap: valid_playing!(setup.entry.id, 85),
               policy_identifier: "policy_keep",
               allowance_applied: false
             })

    before = fetch_snapshot!(setup.entry.id)
    assert before.built_at
    assert competition_count(setup.entry.id) == 1

    install_competition_handicap_destroy_failure_trigger!()

    on_exit(fn -> drop_competition_handicap_destroy_failure_trigger!() end)

    assert {:error, _reason} =
             Scoring.override_handicap_basis(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{deemed_handicap_basis: D.new("13.0"), override_reason: "correct basis"}
             )

    after_snapshot = fetch_snapshot!(setup.entry.id)
    assert after_snapshot.basis_source == before.basis_source
    assert after_snapshot.built_at
    assert after_snapshot.course_handicap_rounded == before.course_handicap_rounded
    assert competition_count(setup.entry.id) == 1
  end

  test "PostgreSQL rejects asymmetric confirmation facts" do
    setup = setup_round_with_tees!(assign_tee: true)

    assert {:ok, _} =
             Scoring.confirm_handicap_input(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{source_handicap_index: D.new("7.0")}
             )

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          UPDATE handicap_snapshots
          SET confirmed_at = NULL, confirmed_by_staff_user_id = $1::uuid
          WHERE round_entry_id = $2::uuid
          """,
          [Ecto.UUID.dump!(setup.admin.id), Ecto.UUID.dump!(setup.entry.id)]
        )
      end

    assert error.postgres.constraint == "handicap_snapshots_confirmer_shape"
  end

  test "missing HI does not silently default to 14 or 20" do
    setup = setup_round_with_tees!(assign_tee: true)

    assert {:error, :deemed_handicap_basis_required} =
             Scoring.apply_no_hi_policy(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{policy_reference: "no default"}
             )

    assert [] =
             Repo.query!(
               "SELECT deemed_handicap_basis FROM handicap_snapshots WHERE round_entry_id = $1::uuid",
               [Ecto.UUID.dump!(setup.entry.id)]
             ).rows
  end

  test "committee override requires reason and staff authorization" do
    setup = setup_round_with_tees!(assign_tee: true)
    staff = create_staff_user!()
    assign_role!(setup.admin, setup.event, staff, :registration_staff)

    assert {:error, :forbidden} =
             Scoring.override_handicap_basis(
               staff,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{deemed_handicap_basis: D.new("16.0"), override_reason: "known ability"}
             )

    assert {:error, :override_reason_required} =
             Scoring.override_handicap_basis(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{deemed_handicap_basis: D.new("16.0"), override_reason: "  "}
             )
  end

  test "override audit and mutation are atomic" do
    setup = setup_round_with_tees!(assign_tee: true)
    before = audit_count()

    assert {:ok, snapshot} =
             Scoring.override_handicap_basis(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{
                 deemed_handicap_basis: D.new("15.5"),
                 override_reason: "committee correction"
               }
             )

    assert snapshot.basis_source == :committee_override
    assert audit_count() == before + 1

    assert [%AuditEvent{action: "override_handicap_basis"}] =
             AuditEvent
             |> Ash.Query.filter(
               target_id == ^setup.entry.id and action == "override_handicap_basis"
             )
             |> Ash.read!(authorize?: false)
  end

  test "build_handicap_snapshot copies tee facts and stores supplied course handicaps only" do
    setup = setup_round_with_tees!(assign_tee: true)

    assert {:ok, _} =
             Scoring.confirm_handicap_input(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{source_handicap_index: D.new("11.0")}
             )

    assert {:ok, built} =
             Scoring.build_handicap_snapshot(
               setup.entry.id,
               course_attrs!(D.new("11.0"), setup.tee_a)
             )

    assert built.course_rating == setup.tee_a.course_rating
    assert built.slope_rating == setup.tee_a.slope_rating
    assert built.applicable_par == setup.tee_a.applicable_par

    assert D.equal?(
             built.course_handicap_unrounded,
             course_attrs!(D.new("11.0"), setup.tee_a).course_handicap_unrounded
           )

    assert built.course_handicap_rounded ==
             course_attrs!(D.new("11.0"), setup.tee_a).course_handicap_rounded

    assert built.built_at
  end

  test "rejects a course handicap calculated from a stale tee" do
    setup = setup_round_with_tees!(assign_tee: true, profiles: 2)

    assert {:ok, _} =
             Scoring.confirm_handicap_input(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{source_handicap_index: D.new("11.0")}
             )

    assert {:ok, stale} =
             CourseHandicap.calculate(
               D.new("11.0"),
               setup.tee_a.slope_rating,
               setup.tee_a.course_rating,
               setup.tee_a.applicable_par
             )

    assert {:ok, _} =
             Competition.assign_round_tee(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               setup.tee_b.id
             )

    assert {:error, :stale_handicap_output} =
             Scoring.build_handicap_snapshot(setup.entry.id, stale)

    snapshot = fetch_snapshot!(setup.entry.id)
    assert snapshot.round_tee_profile_snapshot_id == setup.tee_b.id
    assert is_nil(snapshot.built_at)
    assert is_nil(snapshot.course_handicap_unrounded)
    assert is_nil(snapshot.course_handicap_rounded)
  end

  test "course output comparisons reject each mismatch and accept equivalent decimals" do
    setup = setup_round_with_tees!(assign_tee: true)

    assert {:ok, _} =
             Scoring.confirm_handicap_input(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{
                 source_handicap_index: D.new("10.0")
               }
             )

    attrs = course_attrs!(D.new("10.0"), setup.tee_a)

    for invalid <- [
          Map.update!(attrs, :course_handicap_unrounded, &D.add(&1, 1)),
          Map.update!(attrs, :course_handicap_rounded, &(&1 + 1))
        ] do
      assert {:error, :stale_handicap_output} =
               Scoring.build_handicap_snapshot(setup.entry.id, invalid)

      snapshot = fetch_snapshot!(setup.entry.id)
      assert is_nil(snapshot.built_at)
      assert is_nil(snapshot.course_handicap_unrounded)
      assert is_nil(snapshot.course_handicap_rounded)
    end

    equivalent = Map.update!(attrs, :course_handicap_unrounded, &D.mult(&1, D.new("1.0")))
    assert {:ok, _} = Scoring.build_handicap_snapshot(setup.entry.id, equivalent)
  end

  test "playing output accepts an omitted or correct unrounded value and rejects a mismatch" do
    setup = setup_round_with_tees!(assign_tee: true, competition: true)
    build_built_snapshot!(setup)
    snapshot = fetch_snapshot!(setup.entry.id)

    {:ok, calculated} =
      PlayingHandicap.calculate(
        snapshot.course_handicap_unrounded,
        85
      )

    attrs = Map.merge(calculated, %{policy_identifier: "test_policy", allowance_applied: true})

    wrong = Map.update!(attrs, :unrounded_allowed_handicap, &D.add(&1, 1))

    assert {:error, :stale_handicap_output} =
             Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, wrong)

    assert competition_count(setup.entry.id) == 0

    assert {:ok, row} =
             Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, attrs)

    assert D.equal?(row.unrounded_allowed_handicap, calculated.unrounded_allowed_handicap)

    other = create_non_primary_round_competition!(setup, handicap_allowance_percent: 85)

    assert {:ok, row} =
             Scoring.build_competition_handicap(
               setup.entry.id,
               other.id,
               Map.delete(attrs, :unrounded_allowed_handicap)
             )

    assert is_nil(row.unrounded_allowed_handicap)
  end

  @tag :gls75_connections
  test "tee correction commits before a waiting stale course build" do
    setup = committed_gls75_fixture!()
    stale = course_attrs!(D.new("10.0"), setup.tee_a)

    {first, second} =
      gls75_race!(
        fn ->
          Competition.assign_round_tee(
            setup.admin,
            setup.event.id,
            setup.round.id,
            setup.entry.id,
            setup.tee_b.id
          )
        end,
        fn -> Scoring.build_handicap_snapshot(setup.entry.id, stale) end
      )

    assert {:ok, {:ok, _}} = first
    assert {:error, :stale_handicap_output} = second

    Sandbox.unboxed_run(Repo, fn ->
      snapshot = fetch_snapshot!(setup.entry.id)
      assert snapshot.round_tee_profile_snapshot_id == setup.tee_b.id
      assert_unbuilt!(snapshot)
    end)
  end

  @tag :gls75_connections
  test "basis correction commits before a waiting stale course build" do
    setup = committed_gls75_fixture!()
    stale = course_attrs!(D.new("10.0"), setup.tee_a)

    {first, second} =
      gls75_race!(
        fn ->
          Scoring.override_handicap_basis(
            setup.admin,
            setup.event.id,
            setup.round.id,
            setup.entry.id,
            %{deemed_handicap_basis: D.new("16.0"), override_reason: "correction"}
          )
        end,
        fn -> Scoring.build_handicap_snapshot(setup.entry.id, stale) end
      )

    assert {:ok, {:ok, _}} = first
    assert {:error, :stale_handicap_output} = second

    Sandbox.unboxed_run(Repo, fn ->
      snapshot = fetch_snapshot!(setup.entry.id)
      assert snapshot.basis_source == :committee_override
      assert D.equal?(snapshot.deemed_handicap_basis, D.new("16.0"))
      assert_unbuilt!(snapshot)
    end)
  end

  @tag :gls75_connections
  test "course build commits before waiting tee correction invalidates it" do
    setup = committed_gls75_fixture!()
    attrs = course_attrs!(D.new("10.0"), setup.tee_a)

    {first, second} =
      gls75_race!(
        fn -> Scoring.build_handicap_snapshot(setup.entry.id, attrs) end,
        fn ->
          Competition.assign_round_tee(
            setup.admin,
            setup.event.id,
            setup.round.id,
            setup.entry.id,
            setup.tee_b.id
          )
        end
      )

    assert {:ok, {:ok, _}} = first
    assert {:ok, _} = second

    Sandbox.unboxed_run(Repo, fn ->
      snapshot = fetch_snapshot!(setup.entry.id)
      assert snapshot.round_tee_profile_snapshot_id == setup.tee_b.id
      assert_unbuilt!(snapshot)
    end)
  end

  @tag :gls75_connections
  test "allowance correction commits before waiting stale playing build" do
    setup = committed_gls75_fixture!(built: true)
    attrs = Sandbox.unboxed_run(Repo, fn -> playing_attrs!(setup.entry.id, 85) end)

    {first, second} =
      gls75_race!(
        fn ->
          ConfigureRoundCompetition.run(setup.admin, setup.event.id, setup.round.id, %{
            handicap_allowance_percent: 90
          })
        end,
        fn -> Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, attrs) end
      )

    assert {:ok, {:ok, _}} = first
    assert {:error, :stale_handicap_output} = second

    Sandbox.unboxed_run(Repo, fn ->
      assert persisted_allowance_percent!(setup.competition.id) == 90
      assert competition_count(setup.entry.id) == 0
    end)
  end

  @tag :gls75_connections
  test "playing build commits before waiting allowance correction invalidates it" do
    setup = committed_gls75_fixture!(built: true)
    attrs = Sandbox.unboxed_run(Repo, fn -> playing_attrs!(setup.entry.id, 85) end)

    {first, second} =
      gls75_race!(
        fn -> Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, attrs) end,
        fn ->
          ConfigureRoundCompetition.run(setup.admin, setup.event.id, setup.round.id, %{
            handicap_allowance_percent: 90
          })
        end
      )

    assert {:ok, {:ok, _}} = first
    assert {:ok, _} = second

    Sandbox.unboxed_run(Repo, fn ->
      assert persisted_allowance_percent!(setup.competition.id) == 90
      assert competition_count(setup.entry.id) == 0
    end)
  end

  test "mixed tees produce independent handicap snapshots" do
    setup = setup_round_with_tees!(profiles: 2, entries: 2)
    [entry_a, entry_b] = setup.entries

    assert {:ok, _} =
             Competition.assign_round_tee(
               setup.admin,
               setup.event.id,
               setup.round.id,
               entry_a.id,
               setup.tee_a.id
             )

    assert {:ok, _} =
             Competition.assign_round_tee(
               setup.admin,
               setup.event.id,
               setup.round.id,
               entry_b.id,
               setup.tee_b.id
             )

    assert {:ok, snap_a} =
             Scoring.confirm_handicap_input(
               setup.admin,
               setup.event.id,
               setup.round.id,
               entry_a.id,
               %{source_handicap_index: D.new("9.0")}
             )

    assert {:ok, snap_b} =
             Scoring.confirm_handicap_input(
               setup.admin,
               setup.event.id,
               setup.round.id,
               entry_b.id,
               %{source_handicap_index: D.new("21.0")}
             )

    assert snap_a.round_tee_profile_snapshot_id == setup.tee_a.id
    assert snap_b.round_tee_profile_snapshot_id == setup.tee_b.id
    assert snap_a.id != snap_b.id
  end

  test "PostgreSQL rejects duplicate base handicap snapshot per entry" do
    setup = setup_round_with_tees!(assign_tee: true)

    assert {:ok, _} =
             Scoring.confirm_handicap_input(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{source_handicap_index: D.new("7.0")}
             )

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO handicap_snapshots
            (round_id, round_entry_id, round_tee_profile_snapshot_id, basis_source,
             source_handicap_index, inserted_at, updated_at)
          VALUES ($1::uuid, $2::uuid, $3::uuid, 'official_or_preloaded', 7.0, now(), now())
          """,
          [
            Ecto.UUID.dump!(setup.round.id),
            Ecto.UUID.dump!(setup.entry.id),
            Ecto.UUID.dump!(setup.tee_a.id)
          ]
        )
      end

    assert error.postgres.code == :unique_violation
    assert error.postgres.constraint == "handicap_snapshots_unique_base_per_entry_index"
  end

  test "PostgreSQL rejects cross-round handicap snapshot ownership" do
    setup = setup_round_with_tees!(assign_tee: true)
    other = setup_round_with_tees!()

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO handicap_snapshots
            (round_id, round_entry_id, round_tee_profile_snapshot_id, basis_source,
             source_handicap_index, inserted_at, updated_at)
          VALUES ($1::uuid, $2::uuid, $3::uuid, 'official_or_preloaded', 7.0, now(), now())
          """,
          [
            Ecto.UUID.dump!(other.round.id),
            Ecto.UUID.dump!(setup.entry.id),
            Ecto.UUID.dump!(setup.tee_a.id)
          ]
        )
      end

    assert error.postgres.code == :foreign_key_violation
  end

  describe "GLS-74 allowance correction invalidates competition handicaps" do
    test "no-op allowance save preserves derived competition handicaps" do
      setup = setup_round_with_tees!(assign_tee: true, competition: true)
      build_built_snapshot!(setup)

      assert {:ok, _} =
               Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, %{
                 playing_handicap: valid_playing!(setup.entry.id, 85),
                 policy_identifier: "gls74_policy",
                 allowance_applied: true
               })

      assert competition_count_for_round_competition!(setup.competition.id) == 1

      assert {:ok, updated} =
               ConfigureRoundCompetition.run(setup.admin, setup.event.id, setup.round.id, %{
                 handicap_allowance_percent: setup.competition.handicap_allowance_percent
               })

      assert updated.handicap_allowance_percent == setup.competition.handicap_allowance_percent
      assert competition_count_for_round_competition!(setup.competition.id) == 1
    end

    test "unrelated round competition configuration preserves derived competition handicaps" do
      setup = setup_round_with_tees!(assign_tee: true, competition: true)
      build_built_snapshot!(setup)

      assert {:ok, _} =
               Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, %{
                 playing_handicap: valid_playing!(setup.entry.id, 85),
                 policy_identifier: "gls74_policy",
                 allowance_applied: true
               })

      assert {:ok, _} =
               ConfigureRoundCompetition.run(setup.admin, setup.event.id, setup.round.id, %{
                 solo_sides_permitted: true
               })

      assert competition_count_for_round_competition!(setup.competition.id) == 1
    end

    test "allowance change removes competition handicaps for the target round competition only" do
      setup = setup_round_with_tees!(assign_tee: true, competition: true)
      other = create_non_primary_round_competition!(setup, handicap_allowance_percent: 75)
      build_built_snapshot!(setup)

      assert {:ok, primary_row} =
               Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, %{
                 playing_handicap: valid_playing!(setup.entry.id, 85),
                 policy_identifier: "gls74_primary",
                 allowance_applied: true
               })

      assert {:ok, other_row} =
               Scoring.build_competition_handicap(setup.entry.id, other.id, %{
                 playing_handicap: valid_playing!(setup.entry.id, 75),
                 policy_identifier: "gls74_other",
                 allowance_applied: true
               })

      assert primary_row.handicap_allowance_percent ==
               setup.competition.handicap_allowance_percent

      assert other_row.handicap_allowance_percent == 75

      assert {:ok, updated} =
               ConfigureRoundCompetition.run(setup.admin, setup.event.id, setup.round.id, %{
                 handicap_allowance_percent: 90
               })

      assert updated.handicap_allowance_percent == 90
      assert competition_count_for_round_competition!(setup.competition.id) == 0
      assert competition_count_for_round_competition!(other.id) == 1
      assert fetch_competition_handicap!(other_row.id).handicap_allowance_percent == 75
    end

    test "allowance invalidation preserves handicap snapshot facts" do
      setup = setup_round_with_tees!(assign_tee: true, competition: true)
      build_built_snapshot!(setup)
      before = fetch_snapshot!(setup.entry.id)

      assert {:ok, _} =
               Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, %{
                 playing_handicap: valid_playing!(setup.entry.id, 85),
                 policy_identifier: "gls74_policy",
                 allowance_applied: true
               })

      assert {:ok, _} =
               ConfigureRoundCompetition.run(setup.admin, setup.event.id, setup.round.id, %{
                 handicap_allowance_percent: 90
               })

      after_snapshot = fetch_snapshot!(setup.entry.id)
      assert after_snapshot.built_at
      assert after_snapshot.course_handicap_rounded == before.course_handicap_rounded
      assert after_snapshot.course_handicap_unrounded == before.course_handicap_unrounded
      assert after_snapshot.round_tee_profile_snapshot_id == before.round_tee_profile_snapshot_id
    end

    test "allowance correction rolls back when competition handicap invalidation fails" do
      setup = setup_round_with_tees!(assign_tee: true, competition: true)
      build_built_snapshot!(setup)

      assert {:ok, _} =
               Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, %{
                 playing_handicap: valid_playing!(setup.entry.id, 85),
                 policy_identifier: "gls74_policy",
                 allowance_applied: true
               })

      install_competition_handicap_destroy_failure_trigger!()
      on_exit(fn -> drop_competition_handicap_destroy_failure_trigger!() end)

      assert {:error, _reason} =
               ConfigureRoundCompetition.run(setup.admin, setup.event.id, setup.round.id, %{
                 handicap_allowance_percent: 90
               })

      assert persisted_allowance_percent!(setup.competition.id) ==
               setup.competition.handicap_allowance_percent

      assert competition_count_for_round_competition!(setup.competition.id) == 1
    end

    test "build after allowance correction persists the corrected allowance" do
      setup = setup_round_with_tees!(assign_tee: true, competition: true)
      build_built_snapshot!(setup)

      assert {:ok, _} =
               ConfigureRoundCompetition.run(setup.admin, setup.event.id, setup.round.id, %{
                 handicap_allowance_percent: 90
               })

      assert {:ok, row} =
               Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, %{
                 playing_handicap: valid_playing!(setup.entry.id, 90),
                 policy_identifier: "gls74_policy",
                 allowance_applied: true
               })

      assert row.handicap_allowance_percent == 90
      refute stale_allowance_rows?(setup.competition.id, 90)
    end

    test "concurrent allowance correction and build serialize on the round competition row lock" do
      setup = setup_round_with_tees!(assign_tee: true, competition: true)
      build_built_snapshot!(setup)
      parent = self()

      blocker =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())

          Repo.transaction(fn ->
            lock_round_row!(setup.round.id)

            assert {:ok, _} =
                     HandicapRowLock.lock_round_competition!(setup.competition.id, setup.round.id)

            send(parent, :gls74_round_competition_locked)

            receive do
              :gls74_release_round_competition_lock -> :released
            after
              15_000 -> Repo.rollback(:gls74_blocker_timeout)
            end
          end)
        end)

      assert_receive :gls74_round_competition_locked, 5_000

      build_task =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())

          Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, %{
            playing_handicap: valid_playing!(setup.entry.id, 85),
            policy_identifier: "gls74_policy",
            allowance_applied: true
          })
        end)

      refute Task.yield(build_task, 200)

      configure_task =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())

          ConfigureRoundCompetition.run(setup.admin, setup.event.id, setup.round.id, %{
            handicap_allowance_percent: 90
          })
        end)

      refute Task.yield(configure_task, 200)

      send(blocker.pid, :gls74_release_round_competition_lock)
      assert {:ok, :released} = Task.await(blocker, 10_000)
      build_result = Task.await(build_task, 10_000)
      assert {:ok, updated} = Task.await(configure_task, 10_000)
      assert updated.handicap_allowance_percent == 90
      assert match?({:ok, _}, build_result) or build_result == {:error, :stale_handicap_output}
      refute stale_allowance_rows?(setup.competition.id, updated.handicap_allowance_percent)
    end

    test "racing allowance correction and build never leaves stale allowance rows" do
      setup = setup_round_with_tees!(assign_tee: true, competition: true, entries: 2)

      for entry <- setup.entries do
        assert {:ok, _} =
                 Competition.assign_round_tee(
                   setup.admin,
                   setup.event.id,
                   setup.round.id,
                   entry.id,
                   setup.tee_a.id
                 )

        build_built_snapshot!(Map.put(setup, :entry, entry))
      end

      parent = self()

      for _ <- 1..20 do
        reset_primary_allowance!(setup.competition.id, 85)
        clear_competition_handicaps_for!(setup.competition.id)

        tasks =
          for entry <- setup.entries do
            Task.async(fn ->
              Sandbox.allow(Repo, parent, self())

              Scoring.build_competition_handicap(entry.id, setup.competition.id, %{
                playing_handicap: valid_playing!(entry.id, 85),
                policy_identifier: "gls74_race",
                allowance_applied: true
              })
            end)
          end ++
            [
              Task.async(fn ->
                Sandbox.allow(Repo, parent, self())

                ConfigureRoundCompetition.run(setup.admin, setup.event.id, setup.round.id, %{
                  handicap_allowance_percent: 90
                })
              end)
            ]

        Enum.each(tasks, &Task.await(&1, 30_000))

        allowance = persisted_allowance_percent!(setup.competition.id)
        refute stale_allowance_rows?(setup.competition.id, allowance)
      end
    end
  end

  test "build_competition_handicap persists allowance from RoundCompetition" do
    setup = setup_round_with_tees!(assign_tee: true, competition: true)

    assert {:ok, _} =
             Scoring.confirm_handicap_input(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{source_handicap_index: D.new("10.0")}
             )

    assert {:ok, _} =
             Scoring.build_handicap_snapshot(
               setup.entry.id,
               course_attrs!(D.new("10.0"), setup.tee_a)
             )

    assert {:ok, competition_row} =
             Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, %{
               playing_handicap: valid_playing!(setup.entry.id, 85),
               policy_identifier: "gls22_test_policy_v1",
               allowance_applied: true
             })

    assert competition_row.handicap_allowance_percent ==
             setup.competition.handicap_allowance_percent

    assert competition_row.playing_handicap == valid_playing!(setup.entry.id, 85)
  end

  test "PostgreSQL enforces unique competition handicap per entry and competition" do
    setup = setup_round_with_tees!(assign_tee: true, competition: true)
    build_built_snapshot!(setup)

    assert {:ok, first} =
             Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, %{
               playing_handicap: valid_playing!(setup.entry.id, 85),
               policy_identifier: "policy_a",
               allowance_applied: false
             })

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO competition_handicaps
            (round_id, round_entry_id, round_competition_id, handicap_snapshot_id,
             handicap_allowance_percent, allowance_applied, playing_handicap, policy_identifier,
             inserted_at, updated_at)
          VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, 100, true, 9, 'policy_b', now(), now())
          """,
          [
            Ecto.UUID.dump!(setup.round.id),
            Ecto.UUID.dump!(setup.entry.id),
            Ecto.UUID.dump!(setup.competition.id),
            Ecto.UUID.dump!(first.handicap_snapshot_id)
          ]
        )
      end

    assert error.postgres.constraint == "competition_handicaps_unique_entry_competition_index"
  end

  test "pre-start basis change clears stale built and competition handicap output" do
    setup = setup_round_with_tees!(assign_tee: true, competition: true)
    build_built_snapshot!(setup)

    assert {:ok, _} =
             Scoring.build_competition_handicap(setup.entry.id, setup.competition.id, %{
               playing_handicap: valid_playing!(setup.entry.id, 85),
               policy_identifier: "policy_keep",
               allowance_applied: true
             })

    assert competition_count(setup.entry.id) == 1

    assert {:ok, _} =
             Scoring.override_handicap_basis(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{deemed_handicap_basis: D.new("13.0"), override_reason: "correct basis"}
             )

    snapshot = fetch_snapshot!(setup.entry.id)
    assert is_nil(snapshot.built_at)
    assert is_nil(snapshot.course_handicap_rounded)
    assert competition_count(setup.entry.id) == 0
  end

  test "RESTRICT foreign keys preserve handicap history" do
    setup = setup_round_with_tees!(assign_tee: true)

    assert {:ok, _} =
             Scoring.confirm_handicap_input(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{source_handicap_index: D.new("5.0")}
             )

    assert_raise Postgrex.Error, fn ->
      Repo.query!("DELETE FROM round_entries WHERE id = $1::uuid", [
        Ecto.UUID.dump!(setup.entry.id)
      ])
    end
  end

  defp build_built_snapshot!(setup) do
    assert {:ok, _} =
             Scoring.confirm_handicap_input(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               %{source_handicap_index: D.new("10.0")}
             )

    assert {:ok, _} =
             Scoring.build_handicap_snapshot(
               setup.entry.id,
               course_attrs!(D.new("10.0"), setup.tee_a)
             )
  end

  defp committed_gls75_fixture!(opts \\ []) do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        setup = setup_round_with_tees!(profiles: 2, assign_tee: true, competition: true)

        assert {:ok, _} =
                 Scoring.confirm_handicap_input(
                   setup.admin,
                   setup.event.id,
                   setup.round.id,
                   setup.entry.id,
                   %{source_handicap_index: D.new("10.0")}
                 )

        if Keyword.get(opts, :built, false) do
          assert {:ok, _} =
                   Scoring.build_handicap_snapshot(
                     setup.entry.id,
                     course_attrs!(D.new("10.0"), setup.tee_a)
                   )
        end

        setup
      end)

    on_exit(fn -> cleanup_gls75_fixture!(fixture) end)
    fixture
  end

  defp cleanup_gls75_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      round = Ecto.UUID.dump!(fixture.round.id)
      course = Ecto.UUID.dump!(fixture.course.id)
      event = Ecto.UUID.dump!(fixture.event.id)
      staff = Ecto.UUID.dump!(fixture.admin.id)
      player = Ecto.UUID.dump!(fixture.entry.player_id)

      Repo.transaction(fn ->
        delete_gls75_round_children!(round)

        Repo.query!("DELETE FROM rounds WHERE id = $1::uuid", [round])
        Repo.query!("DELETE FROM players WHERE id = $1::uuid", [player])

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
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> flunk("fixture cleanup failed: #{inspect(reason)}")
      end
    end)
  end

  defp delete_gls75_round_children!(round) do
    for table <-
          ~w(competition_handicaps handicap_snapshots round_entries round_competitions round_tee_hole_snapshots round_tee_profile_snapshots round_holes) do
      Repo.query!("DELETE FROM #{table} WHERE round_id = $1::uuid", [round])
    end
  end

  defp gls75_race!(first_fun, second_fun, before_commit \\ fn -> :ok end) do
    parent = self()

    first =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn -> run_gls75_first!(parent, first_fun) end)
      end)

    assert_receive {:gls75_first_held, first_pid}, 10_000

    second =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:gls75_second_started, pid})
          second_fun.()
        end)
      end)

    assert_receive {:gls75_second_started, second_pid}, 10_000
    refute first_pid == second_pid
    await_gls75_lock!(second_pid, System.monotonic_time(:millisecond) + 10_000)
    send(first.pid, {:gls75_commit, before_commit})
    {Task.await(first, 15_000), Task.await(second, 15_000)}
  end

  defp run_gls75_first!(parent, first_fun) do
    Repo.transaction(fn -> hold_gls75_transaction!(parent, first_fun) end)
  end

  defp hold_gls75_transaction!(parent, first_fun) do
    result = first_fun.()
    [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
    send(parent, {:gls75_first_held, pid})

    receive do
      {:gls75_commit, before_commit} ->
        before_commit.()
        result
    after
      15_000 -> Repo.rollback(:timeout)
    end
  end

  defp await_gls75_lock!(pid, deadline) do
    waiting =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = $1", [pid]).rows
      end)

    if waiting != [[true]] do
      if System.monotonic_time(:millisecond) >= deadline,
        do: flunk("second backend did not wait on a lock")

      await_gls75_lock!(pid, deadline)
    end
  end

  defp assert_unbuilt!(snapshot) do
    assert is_nil(snapshot.built_at)
    assert is_nil(snapshot.course_rating)
    assert is_nil(snapshot.slope_rating)
    assert is_nil(snapshot.applicable_par)
    assert is_nil(snapshot.course_handicap_unrounded)
    assert is_nil(snapshot.course_handicap_rounded)
  end

  defp playing_attrs!(entry_id, allowance) do
    {:ok, attrs} =
      PlayingHandicap.calculate(fetch_snapshot!(entry_id).course_handicap_unrounded, allowance)

    Map.merge(attrs, %{policy_identifier: "gls75_test", allowance_applied: true})
  end

  defp course_attrs!(basis, tee) do
    {:ok, attrs} =
      CourseHandicap.calculate(
        basis,
        tee.slope_rating,
        tee.course_rating,
        tee.applicable_par
      )

    attrs
  end

  defp valid_playing!(entry_id, allowance) do
    snapshot = fetch_snapshot!(entry_id)

    {:ok, attrs} =
      PlayingHandicap.calculate(
        snapshot.course_handicap_unrounded,
        allowance
      )

    attrs.playing_handicap
  end

  defp fetch_snapshot!(entry_id) do
    HandicapSnapshot
    |> Ash.Query.filter(round_entry_id == ^entry_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp competition_count(entry_id) do
    [[count]] =
      Repo.query!("SELECT count(*) FROM competition_handicaps WHERE round_entry_id = $1::uuid", [
        Ecto.UUID.dump!(entry_id)
      ]).rows

    count
  end

  defp audit_count do
    [[count]] = Repo.query!("SELECT count(*) FROM audit_events").rows
    count
  end

  defp setup_round_with_tees!(opts \\ []) do
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

    profile_ids =
      if Keyword.get(opts, :profiles, 1) > 1,
        do: [profile_a.id, profile_b.id],
        else: [profile_a.id]

    {:ok, snapshots} = SnapshotRoundTeeProfiles.run(admin, round.id, profile_ids)
    tee_a = Enum.find(snapshots, &(&1.source_tee_rating_profile_id == profile_a.id))
    assert tee_a.round_id == round.id

    tee_b =
      if Keyword.get(opts, :profiles, 1) > 1 do
        Enum.find(snapshots, &(&1.source_tee_rating_profile_id == profile_b.id))
      end

    ctx = %{event: event, round: round, admin: admin}

    entries =
      for _ <- 1..Keyword.get(opts, :entries, 1) do
        add_entry!(ctx)
      end

    entry = hd(entries)

    if Keyword.get(opts, :assign_tee) do
      assert {:ok, _} =
               Competition.assign_round_tee(
                 admin,
                 event.id,
                 round.id,
                 entry.id,
                 tee_a.id
               )
    end

    competition =
      if Keyword.get(opts, :competition) do
        {:ok, competition} =
          ConfigureRoundCompetition.run(admin, event.id, round.id, %{
            handicap_allowance_percent: 85
          })

        competition
      end

    %{
      event: event,
      round: round,
      course: course,
      admin: admin,
      entry: entry,
      entries: entries,
      tee_a: tee_a,
      tee_b: tee_b,
      competition: competition
    }
  end

  defp add_entry!(%{event: event, round: round, admin: admin}) do
    player = create_player!()

    {:ok, entry} =
      Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    entry
  end

  defp force_participation!(round_entry_id, status) do
    Repo.query!(
      "UPDATE round_entries SET participation_status = $1 WHERE id = $2::uuid",
      [Atom.to_string(status), Ecto.UUID.dump!(round_entry_id)]
    )
  end

  defp set_round_state!(round, state) do
    Repo.query!("UPDATE rounds SET state = $1 WHERE id = $2::uuid", [
      Atom.to_string(state),
      Ecto.UUID.dump!(round.id)
    ])

    Repo.get!(Round, round.id)
  end

  defp assign_role!(actor, event, staff, role) do
    {:ok, _} =
      Accounts.assign_event_staff_role(
        %{event_id: event.id, staff_user_id: staff.id, role: role},
        actor: actor
      )
  end

  defp create_player!(attrs \\ %{}) do
    defaults = %{
      first_name: "Pat",
      surname: "Golfer#{System.unique_integer([:positive])}"
    }

    Player
    |> Ash.Changeset.for_create(:create_internal, Map.merge(defaults, attrs))
    |> Ash.create!(authorize?: false)
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
    email = "#{Process.get(:gls22_prefix)}-#{System.unique_integer([:positive])}@example.com"

    Accounts.StaffUser
    |> Ash.Changeset.for_create(:provision_staff_user, %{
      email: email,
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_course!(event, admin, suffix \\ "Main") do
    {:ok, course} =
      GolfCatalog.create_course(
        event.id,
        %{name: "Test Course #{suffix}", location: "Here"},
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

  defp install_competition_handicap_destroy_failure_trigger! do
    Repo.query!("""
    CREATE FUNCTION gls22_reject_competition_handicap_delete() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'gls22_invalidation_blocked';
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls22_reject_competition_handicap_delete
    BEFORE DELETE ON competition_handicaps
    FOR EACH ROW EXECUTE FUNCTION gls22_reject_competition_handicap_delete()
    """)
  end

  defp drop_competition_handicap_destroy_failure_trigger! do
    Repo.query!(
      "DROP TRIGGER IF EXISTS gls22_reject_competition_handicap_delete ON competition_handicaps"
    )

    Repo.query!("DROP FUNCTION IF EXISTS gls22_reject_competition_handicap_delete()")
  end

  defp create_non_primary_round_competition!(setup, attrs) do
    defaults = %{
      event_id: setup.event.id,
      round_id: setup.round.id,
      is_primary: false,
      scoring_policy_identifier: "four_ball_stableford_v1",
      handicap_allowance_percent: 100,
      solo_sides_permitted: false,
      solo_normalization_policy_identifier: "companion_max_p_minus_one_v1",
      pickup_policy_identifier: "standard_pickup_v1"
    }

    RoundCompetition
    |> Ash.Changeset.for_create(:configure_internal, Map.merge(defaults, Map.new(attrs)))
    |> Ash.create!(authorize?: false)
  end

  defp competition_count_for_round_competition!(round_competition_id) do
    [[count]] =
      Repo.query!(
        "SELECT count(*) FROM competition_handicaps WHERE round_competition_id = $1::uuid",
        [Ecto.UUID.dump!(round_competition_id)]
      ).rows

    count
  end

  defp fetch_competition_handicap!(id) do
    CompetitionHandicap
    |> Ash.get!(id, authorize?: false)
  end

  defp persisted_allowance_percent!(round_competition_id) do
    [[allowance]] =
      Repo.query!(
        "SELECT handicap_allowance_percent FROM round_competitions WHERE id = $1::uuid",
        [Ecto.UUID.dump!(round_competition_id)]
      ).rows

    allowance
  end

  defp reset_primary_allowance!(round_competition_id, allowance) do
    Repo.query!(
      "UPDATE round_competitions SET handicap_allowance_percent = $1 WHERE id = $2::uuid",
      [allowance, Ecto.UUID.dump!(round_competition_id)]
    )
  end

  defp clear_competition_handicaps_for!(round_competition_id) do
    Repo.query!(
      "DELETE FROM competition_handicaps WHERE round_competition_id = $1::uuid",
      [Ecto.UUID.dump!(round_competition_id)]
    )
  end

  defp stale_allowance_rows?(round_competition_id, current_allowance) do
    [[count]] =
      Repo.query!(
        """
        SELECT count(*)
        FROM competition_handicaps
        WHERE round_competition_id = $1::uuid
          AND handicap_allowance_percent <> $2
        """,
        [Ecto.UUID.dump!(round_competition_id), current_allowance]
      ).rows

    count > 0
  end

  defp lock_round_row!(round_id) do
    case Repo.query!(
           "SELECT id FROM rounds WHERE id = $1::uuid FOR UPDATE",
           [Ecto.UUID.dump!(round_id)]
         ).rows do
      [[_id]] -> :ok
      [] -> raise "round not found"
    end
  end
end

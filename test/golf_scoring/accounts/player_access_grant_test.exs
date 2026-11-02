defmodule GolfScoring.Accounts.PlayerAccessGrantTest do
  use ExUnit.Case, async: false
  use GolfScoringWeb.ConnCase, only: []

  require Ash.Query

  alias Ash.Changeset
  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Accounts.PlayerAccessExchange
  alias GolfScoring.Accounts.PlayerAccessGrant
  alias GolfScoring.Accounts.PlayerAccessGrantGuard
  alias GolfScoring.Accounts.PlayerAccessToken
  alias GolfScoring.Accounts.Services.IssuePlayerAccess
  alias GolfScoring.Accounts.Services.ReissuePlayerAccess
  alias GolfScoring.Accounts.Services.RevokePlayerAccess
  alias GolfScoring.Audit.AuditEvent
  alias GolfScoring.Competition
  alias GolfScoring.Competition.Event
  alias GolfScoring.Competition.Player
  alias GolfScoring.Competition.Services.ReplaceRoundEntry
  alias GolfScoring.Repo
  alias GolfScoringWeb.Player.RequirePlayerAccess
  alias GolfScoringWeb.Player.Session

  @password "GLS-21 synthetic staff passphrase 2026"
  @digest_index "player_access_grants_token_digest_index"
  @active_pair_index "player_access_grants_one_active_event_player_index"

  setup do
    Process.put(:gls21_email_prefix, "gls21-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls21_email_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    :ok
  end

  test "PlayerAccessGrant is registered in Accounts without generic public CRUD" do
    assert PlayerAccessGrant in Ash.Domain.Info.resources(Accounts)
    refute Info.action(PlayerAccessGrant, :create)
    refute Info.action(PlayerAccessGrant, :update)
    refute Info.action(PlayerAccessGrant, :destroy)
    assert Info.action(PlayerAccessGrant, :create_internal)
    assert Info.action(PlayerAccessGrant, :mark_superseded_internal)
    assert Info.action(PlayerAccessGrant, :mark_revoked_internal)
    assert Info.action(PlayerAccessGrant, :mark_expired_internal)
  end

  test "issue creates active Event+Player grant and returns plaintext token once" do
    setup = setup_event_player!()

    assert {:ok, %{grant: grant, token: token}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    assert grant.state == :active
    assert grant.event_id == setup.event.id
    assert grant.player_id == setup.player.id
    assert is_binary(token) and byte_size(token) > 20
    assert is_nil(grant.expires_at)
  end

  test "plaintext token is absent from persisted grant reads" do
    setup = setup_event_player!()

    assert {:ok, %{grant: grant, token: token}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    reloaded = Ash.get!(PlayerAccessGrant, grant.id, authorize?: false)
    refute Map.has_key?(reloaded, :token)
    assert is_binary(token)
    refute inspect(reloaded) =~ token
  end

  test "digest differs from plaintext and uniquely identifies the grant" do
    setup = setup_event_player!()

    assert {:ok, %{grant: grant, token: token}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    digest = PlayerAccessToken.digest(token)
    assert digest == grant.token_digest
    assert digest != token

    assert [row] =
             PlayerAccessGrant
             |> Ash.Query.filter(token_digest == ^digest)
             |> Ash.read!(authorize?: false)

    assert row.id == grant.id
  end

  test "PostgreSQL enforces unique token_digest and one active event+player pair" do
    setup = setup_event_player!()

    assert {:ok, %{grant: first, token: first_token}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    duplicate_digest =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO player_access_grants (event_id, player_id, token_digest, state)
          VALUES ($1::uuid, $2::uuid, $3, 'superseded')
          """,
          [
            Ecto.UUID.dump!(setup.event.id),
            Ecto.UUID.dump!(setup.player.id),
            first.token_digest
          ]
        )
      end

    assert duplicate_digest.postgres.code == :unique_violation
    assert duplicate_digest.postgres.constraint == @digest_index

    duplicate_active =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO player_access_grants (event_id, player_id, token_digest, state)
          VALUES ($1::uuid, $2::uuid, $3, 'active')
          """,
          [
            Ecto.UUID.dump!(setup.event.id),
            Ecto.UUID.dump!(setup.player.id),
            PlayerAccessToken.digest(first_token <> "-other")
          ]
        )
      end

    assert duplicate_active.postgres.code == :unique_violation
    assert duplicate_active.postgres.constraint == @active_pair_index
  end

  test "foreign keys reject invalid event and player references" do
    setup = setup_event_player!()
    digest = :crypto.strong_rand_bytes(32)

    bad_event =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO player_access_grants (event_id, player_id, token_digest, state)
          VALUES ($1::uuid, $2::uuid, $3, 'active')
          """,
          [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(setup.player.id), digest]
        )
      end

    assert bad_event.postgres.code == :foreign_key_violation

    bad_player =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO player_access_grants (event_id, player_id, token_digest, state)
          VALUES ($1::uuid, $2::uuid, $3, 'active')
          """,
          [Ecto.UUID.dump!(setup.event.id), Ecto.UUID.dump!(Ecto.UUID.generate()), digest]
        )
      end

    assert bad_player.postgres.code == :foreign_key_violation
  end

  test "issue authorization by staff role" do
    setup = setup_event_player!()
    manager = create_staff_user!()
    registration = create_staff_user!()
    scoring = create_staff_user!()
    other = create_staff_user!()

    assign_role!(setup.admin, setup.event, manager, :competition_manager)
    assign_role!(setup.admin, setup.event, registration, :registration_staff)
    assign_role!(setup.admin, setup.event, scoring, :scoring_support)

    for staff <- [setup.admin, manager, registration] do
      assert {:ok, _} = Accounts.issue_player_access(staff, setup.event.id, setup.player.id)

      assert {:ok, _} =
               Accounts.revoke_player_access(setup.admin, setup.event.id, setup.player.id)
    end

    assert {:error, :forbidden} =
             Accounts.issue_player_access(scoring, setup.event.id, setup.player.id)

    assert {:error, :forbidden} =
             Accounts.issue_player_access(other, setup.event.id, setup.player.id)
  end

  test "issue requires RoundEntry membership in the same Event" do
    setup_a = setup_event_player!()
    setup_b = setup_event_player!()
    orphan = create_player!()

    assert {:error, :player_not_in_event} =
             Accounts.issue_player_access(setup_a.admin, setup_a.event.id, orphan.id)

    assert {:error, :player_not_in_event} =
             Accounts.issue_player_access(
               setup_a.admin,
               setup_a.event.id,
               setup_b.player.id
             )
  end

  test "issue rejects existing usable active grant" do
    setup = setup_event_player!()

    assert {:ok, _} = Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    assert {:error, :active_player_access_exists} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)
  end

  test "reissue supersedes prior grant and returns a distinct token" do
    setup = setup_event_player!()

    assert {:ok, %{grant: original, token: original_token}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    assert {:ok, %{grant: replacement, token: new_token}} =
             Accounts.reissue_player_access(setup.admin, setup.event.id, setup.player.id)

    assert replacement.id != original.id
    assert new_token != original_token

    reloaded_original = Ash.get!(PlayerAccessGrant, original.id, authorize?: false)
    assert reloaded_original.state == :superseded
    assert replacement.state == :active
  end

  test "old token and browser session invalidate after reissue" do
    setup = setup_event_player!()

    assert {:ok, %{token: original_token}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    conn =
      build_conn()
      |> get("/player/access?token=#{URI.encode(original_token)}")
      |> fetch_session()

    grant_id = Session.grant_id(conn)
    assert grant_id

    assert {:ok, %{token: _new_token}} =
             Accounts.reissue_player_access(setup.admin, setup.event.id, setup.player.id)

    assert {:error, :invalid_credentials} =
             PlayerAccessExchange.exchange(original_token)

    conn =
      build_conn()
      |> init_test_session(%{})
      |> Session.put_grant_id(grant_id)
      |> invoke_require_player_access()

    assert redirected_to(conn) == "/player/access-denied"
  end

  test "reissue authorization by staff role" do
    setup = setup_event_player!()
    manager = create_staff_user!()
    registration = create_staff_user!()
    scoring = create_staff_user!()
    other = create_staff_user!()

    assign_role!(setup.admin, setup.event, manager, :competition_manager)
    assign_role!(setup.admin, setup.event, registration, :registration_staff)
    assign_role!(setup.admin, setup.event, scoring, :scoring_support)

    assert {:ok, _} = Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    for staff <- [setup.admin, manager, registration, scoring] do
      assert {:ok, _} =
               Accounts.reissue_player_access(staff, setup.event.id, setup.player.id)
    end

    assert {:error, :forbidden} =
             Accounts.reissue_player_access(other, setup.event.id, setup.player.id)
  end

  test "reissue audit exists without token or digest material" do
    setup = setup_event_player!()

    assert {:ok, _} = Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    assert {:ok, %{grant: grant, token: token}} =
             Accounts.reissue_player_access(setup.admin, setup.event.id, setup.player.id)

    audits =
      AuditEvent
      |> Ash.Query.filter(action == "reissue_player_access" and target_id == ^setup.player.id)
      |> Ash.read!(authorize?: false)

    assert length(audits) == 1
    audit = hd(audits)
    blob = inspect(audit) <> inspect(audit.context) <> inspect(audit.changes)
    refute blob =~ token
    refute blob =~ Base.encode16(grant.token_digest, case: :lower)
  end

  test "simulated reissue audit failure rolls back supersession and replacement" do
    setup = setup_event_player!()

    assert {:ok, %{grant: original}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    install_reissue_audit_failure_trigger!()

    assert {:error, _} =
             ReissuePlayerAccess.run(setup.admin, setup.event.id, setup.player.id)

    drop_reissue_audit_failure_trigger!()

    reloaded = Ash.get!(PlayerAccessGrant, original.id, authorize?: false)
    assert reloaded.state == :active

    active_count = active_grant_count(setup.event.id, setup.player.id)
    assert active_count == 1
  end

  test "revoke transitions active grant to revoked and blocks exchange" do
    setup = setup_event_player!()

    assert {:ok, %{grant: grant, token: token}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    assert {:ok, revoked} =
             Accounts.revoke_player_access(setup.admin, setup.event.id, setup.player.id)

    assert revoked.id == grant.id
    assert revoked.state == :revoked

    assert {:error, :invalid_credentials} =
             PlayerAccessExchange.exchange(token)
  end

  test "revoke authorization excludes registration and scoring support" do
    setup = setup_event_player!()
    registration = create_staff_user!()
    scoring = create_staff_user!()
    manager = create_staff_user!()

    assign_role!(setup.admin, setup.event, registration, :registration_staff)
    assign_role!(setup.admin, setup.event, scoring, :scoring_support)
    assign_role!(setup.admin, setup.event, manager, :competition_manager)

    assert {:ok, _} = Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    for staff <- [setup.admin, manager] do
      assert {:ok, _} = Accounts.revoke_player_access(staff, setup.event.id, setup.player.id)
      assert {:ok, _} = Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)
    end

    assert {:error, :forbidden} =
             Accounts.revoke_player_access(registration, setup.event.id, setup.player.id)

    assert {:error, :forbidden} =
             Accounts.revoke_player_access(scoring, setup.event.id, setup.player.id)
  end

  test "existing session invalidates after revoke" do
    setup = setup_event_player!()

    assert {:ok, %{token: token}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    conn =
      build_conn()
      |> get("/player/access?token=#{URI.encode(token)}")
      |> fetch_session()

    grant_id = Session.grant_id(conn)
    assert grant_id

    assert {:ok, _} = Accounts.revoke_player_access(setup.admin, setup.event.id, setup.player.id)

    conn =
      build_conn()
      |> init_test_session(%{})
      |> Session.put_grant_id(grant_id)
      |> invoke_require_player_access()

    assert redirected_to(conn) == "/player/access-denied"
  end

  test "revoke audit exists without sensitive material and rolls back on failure" do
    setup = setup_event_player!()

    assert {:ok, %{grant: _grant, token: token}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    assert {:ok, _} = Accounts.revoke_player_access(setup.admin, setup.event.id, setup.player.id)

    audits =
      AuditEvent
      |> Ash.Query.filter(action == "revoke_player_access" and target_id == ^setup.player.id)
      |> Ash.read!(authorize?: false)

    assert length(audits) == 1
    audit = hd(audits)
    blob = inspect(audit) <> inspect(audit.context) <> inspect(audit.changes)
    refute blob =~ token

    assert {:ok, %{grant: active_grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    install_revoke_audit_failure_trigger!()

    assert {:error, _} =
             RevokePlayerAccess.run(setup.admin, setup.event.id, setup.player.id)

    drop_revoke_audit_failure_trigger!()

    reloaded = Ash.get!(PlayerAccessGrant, active_grant.id, authorize?: false)
    assert reloaded.state == :active
  end

  test "explicit expires_at supports nil default and future validity" do
    setup = setup_event_player!()
    future = DateTime.add(DateTime.utc_now(), 3600, :second)

    assert {:ok, %{grant: with_expiry}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id,
               expires_at: future
             )

    refute is_nil(with_expiry.expires_at)

    assert {:ok, _} = Accounts.revoke_player_access(setup.admin, setup.event.id, setup.player.id)

    assert {:ok, %{grant: without_expiry}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    assert is_nil(without_expiry.expires_at)
  end

  test "due expires_at prevents exchange and invalidates session" do
    setup = setup_event_player!()
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    assert {:ok, %{grant: grant, token: token}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id,
               expires_at: past
             )

    assert {:error, :invalid_credentials} =
             PlayerAccessExchange.exchange(token)

    reloaded = Ash.get!(PlayerAccessGrant, grant.id, authorize?: false)
    assert reloaded.state == :expired

    future = DateTime.add(DateTime.utc_now(), 3600, :second)

    assert {:ok, %{token: valid_token}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id,
               expires_at: future
             )

    conn =
      build_conn()
      |> get("/player/access?token=#{URI.encode(valid_token)}")
      |> fetch_session()

    grant_id = Session.grant_id(conn)
    assert grant_id

    Repo.query!(
      "UPDATE player_access_grants SET expires_at = $1 WHERE id = $2::uuid",
      [DateTime.add(DateTime.utc_now(), -10, :second), Ecto.UUID.dump!(grant_id)]
    )

    conn =
      build_conn()
      |> init_test_session(%{})
      |> Session.put_grant_id(grant_id)
      |> invoke_require_player_access()

    assert redirected_to(conn) == "/player/access-denied"
  end

  test "failed lazy expiry persistence denies authorization without silent success" do
    setup = setup_event_player!()
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    assert {:ok, %{grant: grant, token: token}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id,
               expires_at: past
             )

    install_lazy_expiry_failure_trigger!()

    assert {:error, :invalid_credentials} = PlayerAccessExchange.exchange(token)

    reloaded = Ash.get!(PlayerAccessGrant, grant.id, authorize?: false)
    assert reloaded.state == :active

    assert {:error, :invalid_player_session} =
             PlayerAccessGrantGuard.load_grant_for_session(grant.id)

    assert match?({:error, _}, lazy_expiry_grant_id_transaction(grant.id))

    drop_lazy_expiry_failure_trigger!()
  end

  test "terminal historical rows remain preserved" do
    setup = setup_event_player!()

    assert {:ok, _} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    assert {:ok, _} = Accounts.reissue_player_access(setup.admin, setup.event.id, setup.player.id)
    assert {:ok, _} = Accounts.revoke_player_access(setup.admin, setup.event.id, setup.player.id)

    past = DateTime.add(DateTime.utc_now(), -30, :second)

    assert {:ok, %{token: expired_token}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id,
               expires_at: past
             )

    assert {:error, :invalid_credentials} =
             PlayerAccessExchange.exchange(expired_token)

    states =
      PlayerAccessGrant
      |> Ash.Query.filter(event_id == ^setup.event.id and player_id == ^setup.player.id)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.state)
      |> Enum.sort()

    assert :superseded in states
    assert :revoked in states
    assert :expired in states
  end

  test "RoundEntry replacement does not transfer PlayerAccessGrant" do
    setup = setup_event_player!()
    manager = create_staff_user!()
    assign_role!(setup.admin, setup.event, manager, :competition_manager)

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    replacement_player = create_player!()

    assert {:ok, %{original: _marked, replacement: _new_entry}} =
             ReplaceRoundEntry.run(
               manager,
               setup.event.id,
               setup.round.id,
               setup.entry.id,
               replacement_player.id
             )

    reloaded = Ash.get!(PlayerAccessGrant, grant.id, authorize?: false)
    assert reloaded.player_id == setup.player.id
    assert reloaded.event_id == setup.event.id

    assert [] =
             PlayerAccessGrant
             |> Ash.Query.filter(player_id == ^replacement_player.id and state == :active)
             |> Ash.read!(authorize?: false)
  end

  @tag :real_concurrency
  test "concurrent issue attempts cannot leave two active grants" do
    email_prefix = Process.get(:gls21_email_prefix)

    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        setup_committed_issue_race_fixture!(email_prefix)
      end)

    try do
      parent = self()

      task_one =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:gls21_ready, :one})

            receive do
              :gls21_go ->
                IssuePlayerAccess.run(fixture.admin, fixture.event_id, fixture.player_id)
            after
              10_000 -> flunk("GLS-21 concurrency worker one did not receive go")
            end
          end)
        end)

      task_two =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:gls21_ready, :two})

            receive do
              :gls21_go ->
                IssuePlayerAccess.run(fixture.admin, fixture.event_id, fixture.player_id)
            after
              10_000 -> flunk("GLS-21 concurrency worker two did not receive go")
            end
          end)
        end)

      assert_receive {:gls21_ready, :one}, 10_000
      assert_receive {:gls21_ready, :two}, 10_000

      send(task_one.pid, :gls21_go)
      send(task_two.pid, :gls21_go)

      results = [Task.await(task_one, 30_000), Task.await(task_two, 30_000)]
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1

      assert Enum.any?(results, fn
               {:error, :active_player_access_exists} -> true
               {:error, _} -> true
               _ -> false
             end)

      active_count =
        Sandbox.unboxed_run(Repo, fn ->
          active_grant_count(fixture.event_id, fixture.player_id)
        end)

      assert active_count <= 1
    after
      cleanup_committed_issue_race_fixture!(fixture)
    end
  end

  defp setup_event_player! do
    event = create_event!()
    admin = create_event_admin!(event)
    course = create_course!(event, admin)
    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    player = create_player!()

    {:ok, entry} =
      Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    %{event: event, round: round, admin: admin, player: player, entry: entry}
  end

  defp setup_committed_issue_race_fixture!(email_prefix) do
    event = create_event!()
    admin = create_staff_user_for_prefix!(email_prefix)

    Repo.query!(
      "INSERT INTO event_staff_assignments (event_id, staff_user_id, role, status) VALUES ($1::uuid, $2::uuid, 'event_admin', 'active')",
      [Ecto.UUID.dump!(event.id), Ecto.UUID.dump!(admin.id)]
    )

    course = create_course!(event, admin)
    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    player = create_player!()

    {:ok, _entry} =
      Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    %{event_id: event.id, player_id: player.id, admin: admin}
  end

  defp cleanup_committed_issue_race_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "DELETE FROM player_access_grants WHERE event_id = $1::uuid",
        [Ecto.UUID.dump!(fixture.event_id)]
      )

      Repo.query!(
        "DELETE FROM event_staff_assignments WHERE event_id = $1::uuid",
        [Ecto.UUID.dump!(fixture.event_id)]
      )

      Repo.query!(
        "DELETE FROM round_entries WHERE event_id = $1::uuid",
        [Ecto.UUID.dump!(fixture.event_id)]
      )

      Repo.query!("DELETE FROM rounds WHERE event_id = $1::uuid", [
        Ecto.UUID.dump!(fixture.event_id)
      ])

      Repo.query!("DELETE FROM events WHERE id = $1::uuid", [Ecto.UUID.dump!(fixture.event_id)])
    end)
  end

  defp active_grant_count(event_id, player_id) do
    [[count]] =
      Repo.query!(
        """
        SELECT count(*)::int FROM player_access_grants
        WHERE event_id = $1::uuid AND player_id = $2::uuid AND state = 'active'
        """,
        [Ecto.UUID.dump!(event_id), Ecto.UUID.dump!(player_id)]
      ).rows

    count
  end

  defp install_reissue_audit_failure_trigger! do
    Repo.query!("""
    CREATE FUNCTION gls21_reject_reissue_audit() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.action = 'reissue_player_access' THEN
        RAISE EXCEPTION 'simulated GLS-21 reissue audit failure';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls21_reject_reissue_audit
    BEFORE INSERT ON audit_events
    FOR EACH ROW EXECUTE FUNCTION gls21_reject_reissue_audit()
    """)
  end

  defp drop_reissue_audit_failure_trigger! do
    Repo.query!("DROP TRIGGER IF EXISTS gls21_reject_reissue_audit ON audit_events")
    Repo.query!("DROP FUNCTION IF EXISTS gls21_reject_reissue_audit()")
  end

  defp install_revoke_audit_failure_trigger! do
    Repo.query!("""
    CREATE FUNCTION gls21_reject_revoke_audit() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.action = 'revoke_player_access' THEN
        RAISE EXCEPTION 'simulated GLS-21 revoke audit failure';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls21_reject_revoke_audit
    BEFORE INSERT ON audit_events
    FOR EACH ROW EXECUTE FUNCTION gls21_reject_revoke_audit()
    """)
  end

  defp drop_revoke_audit_failure_trigger! do
    Repo.query!("DROP TRIGGER IF EXISTS gls21_reject_revoke_audit ON audit_events")
    Repo.query!("DROP FUNCTION IF EXISTS gls21_reject_revoke_audit()")
  end

  defp install_lazy_expiry_failure_trigger! do
    Repo.query!("""
    CREATE FUNCTION gls21_reject_mark_expired() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF OLD.state = 'active' AND NEW.state = 'expired' THEN
        RAISE EXCEPTION 'simulated GLS-21 lazy expiry persistence failure';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls21_reject_mark_expired
    BEFORE UPDATE ON player_access_grants
    FOR EACH ROW EXECUTE FUNCTION gls21_reject_mark_expired()
    """)
  end

  defp drop_lazy_expiry_failure_trigger! do
    Repo.query!("DROP TRIGGER IF EXISTS gls21_reject_mark_expired ON player_access_grants")
    Repo.query!("DROP FUNCTION IF EXISTS gls21_reject_mark_expired()")
  end

  defp lazy_expiry_grant_id_transaction(grant_id) do
    Repo.transaction(fn ->
      case PlayerAccessGrantGuard.apply_lazy_expiry_for_grant_id(Repo, grant_id) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp invoke_require_player_access(conn) do
    conn
    |> Plug.Conn.fetch_session()
    |> RequirePlayerAccess.call(RequirePlayerAccess.init([]))
  end

  defp assign_role!(actor, event, staff, role) do
    {:ok, _} =
      Accounts.assign_event_staff_role(
        %{event_id: event.id, staff_user_id: staff.id, role: role},
        actor: actor
      )
  end

  defp create_event! do
    Event
    |> Changeset.for_create(:create_internal, %{})
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

  defp create_staff_user_for_prefix!(prefix) do
    email = "#{prefix}-#{System.unique_integer([:positive])}@example.com"

    GolfScoring.Accounts.StaffUser
    |> Changeset.for_create(:provision_staff_user, %{
      email: email,
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_staff_user! do
    create_staff_user_for_prefix!(Process.get(:gls21_email_prefix))
  end

  defp create_player!(attrs \\ %{}) do
    defaults = %{first_name: "Test", surname: "Player#{System.unique_integer([:positive])}"}

    Player
    |> Changeset.for_create(:create_internal, Map.merge(defaults, attrs))
    |> Ash.create!(authorize?: false)
  end

  defp create_course!(event, admin, suffix \\ "Main") do
    {:ok, course} =
      GolfScoring.GolfCatalog.create_course(
        event.id,
        %{name: "Test Course #{suffix}", location: "Here"},
        actor: admin
      )

    course
  end
end

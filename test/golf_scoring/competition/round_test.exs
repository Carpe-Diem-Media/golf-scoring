defmodule GolfScoring.Competition.RoundTest do
  use ExUnit.Case, async: false

  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Accounts.EventStaffAssignment
  alias GolfScoring.Competition
  alias GolfScoring.Competition.Event
  alias GolfScoring.Competition.Round
  alias GolfScoring.Competition.RoundHole
  alias GolfScoring.Competition.Services.ConfigureRoundLayout
  alias GolfScoring.GolfCatalog
  alias GolfScoring.Repo

  @password "GLS-15 synthetic staff passphrase 2026"

  setup do
    Process.put(:gls15_email_prefix, "gls15-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls15_email_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    :ok
  end

  test "Round is registered in Competition with guarded create_round" do
    assert Round in Ash.Domain.Info.resources(Competition)
    assert RoundHole in Ash.Domain.Info.resources(Competition)
    assert Info.action(Round, :create_round)
    assert is_nil(Info.action(Round, :create))
    assert is_nil(Info.action(Round, :update))
    assert is_nil(Info.action(RoundHole, :read_route))
    refute function_exported?(Competition, :list_round_route, 1)
  end

  test "active Event Admin creates a draft Round for an active Course on a mutable Event" do
    event = create_event!()
    admin = create_event_admin!(event)
    course = create_course!(event, admin)
    holes = create_eighteen_holes!(event, admin, course)

    assert {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    assert round.state == :draft
    assert round.event_id == event.id
    assert round.course_id == course.id

    assert {:ok, route} =
             ConfigureRoundLayout.run(admin, round.id, Enum.map(holes, & &1.id))

    assert length(route) == 18
    assert Enum.map(route, & &1.play_order) == Enum.to_list(1..18)
  end

  test "create_round authorization matrix and state guardrails" do
    event = create_event!()
    admin = create_event_admin!(event)
    manager = create_staff_user!()
    assign_role!(admin, event, manager, :competition_manager)
    staff = create_staff_user!()
    assign_role!(admin, event, staff, :registration_staff)
    system_admin = create_system_admin!()
    course = create_course!(event, admin)

    assert {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    assert round.state == :draft

    assert {:error, %Ash.Error.Forbidden{}} =
             Competition.create_round(event.id, course.id, actor: manager)

    assert {:error, %Ash.Error.Forbidden{}} =
             Competition.create_round(event.id, course.id, actor: staff)

    assert {:error, %Ash.Error.Forbidden{}} =
             Competition.create_round(event.id, course.id, actor: system_admin)

    archived_course = create_course!(event, admin)

    assert {:ok, _} = GolfCatalog.archive_course(archived_course, event.id, actor: admin)

    assert {:error, _error} =
             Competition.create_round(event.id, archived_course.id, actor: admin)

    terminal_event = create_event!()
    terminal_admin = create_event_admin!(terminal_event)
    terminal_course = create_course!(terminal_event, terminal_admin)
    set_event_state!(terminal_event, :cancelled)

    assert {:error, _error} =
             Competition.create_round(terminal_event.id, terminal_course.id,
               actor: terminal_admin
             )

    changeset =
      Round
      |> Ash.Changeset.for_create(:create_round, %{
        event_id: event.id,
        course_id: course.id,
        state: :scoring_open
      })

    assert {:error, %Ash.Error.Invalid{}} = Ash.create(changeset, actor: admin)
  end

  test "configure_round_layout validates route shape, auth, lifecycle, atomic rollback, and stable ids" do
    event = create_event!()
    admin = create_event_admin!(event)
    manager = create_staff_user!()
    assign_role!(admin, event, manager, :competition_manager)
    staff = create_staff_user!()
    assign_role!(admin, event, staff, :registration_staff)
    course = create_course!(event, admin)
    holes = create_eighteen_holes!(event, admin, course)
    hole_ids = Enum.map(holes, & &1.id)

    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)

    assert {:ok, route} = ConfigureRoundLayout.run(admin, round.id, hole_ids)
    assert length(route) == 18

    reversed = Enum.reverse(hole_ids)
    assert {:ok, reordered} = ConfigureRoundLayout.run(manager, round.id, reversed)

    hole_18 = List.last(holes)

    first =
      reordered
      |> Enum.sort_by(& &1.play_order)
      |> hd()

    assert first.play_order == 1
    assert first.display_hole_number == 18
    assert first.course_hole_id == hole_18.id

    id_by_course_hole = Map.new(route, fn row -> {row.course_hole_id, row.id} end)

    for row <- reordered do
      assert row.id == id_by_course_hole[row.course_hole_id]
      refute row.play_order == row.display_hole_number
    end

    assert {:error, :duplicate_course_hole} =
             ConfigureRoundLayout.run(admin, round.id, List.duplicate(hd(hole_ids), 18))

    short = Enum.take(hole_ids, 17)

    assert {:error, :invalid_hole_count} = ConfigureRoundLayout.run(admin, round.id, short)

    long =
      hole_ids ++
        (create_eighteen_holes!(event, admin, create_course!(event, admin, "Extra"))
         |> Enum.take(1)
         |> Enum.map(& &1.id))

    assert {:error, :invalid_hole_count} = ConfigureRoundLayout.run(admin, round.id, long)

    other_course = create_course!(event, admin)
    other_hole = hd(create_eighteen_holes!(event, admin, other_course))
    cross = List.replace_at(hole_ids, 0, other_hole.id)

    assert {:error, :cross_course_hole} = ConfigureRoundLayout.run(admin, round.id, cross)

    assert {:error, :forbidden} = ConfigureRoundLayout.run(staff, round.id, hole_ids)

    before = route_snapshot(round.id)

    assert {:error, :cross_course_hole} =
             ConfigureRoundLayout.run(admin, round.id, cross)

    assert route_snapshot(round.id) == before

    set_round_state!(round, :scoring_open)

    assert {:error, {:invalid_round_state, "scoring_open"}} =
             ConfigureRoundLayout.run(admin, round.id, hole_ids)
  end

  test "Round lifecycle guards, audits, and fail-closed future transitions" do
    event = create_event!()
    admin = create_event_admin!(event)
    manager = create_staff_user!()
    assign_role!(admin, event, manager, :competition_manager)
    course = create_course!(event, admin)
    holes = create_eighteen_holes!(event, admin, course)
    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    {:ok, _} = ConfigureRoundLayout.run(admin, round.id, Enum.map(holes, & &1.id))

    assert {:error, _error} =
             round
             |> Ash.Changeset.for_update(:mark_round_ready, %{}, actor: manager)
             |> Ash.update()

    assert round_state(round.id) == "draft"

    ready_round = set_round_state!(round, :ready)

    assert {:error, _error} =
             ready_round
             |> Ash.Changeset.for_update(:open_scoring, %{}, actor: manager)
             |> Ash.update()

    assert round_state(round.id) == "ready"

    scoring_open = set_round_state!(round, :scoring_open)
    assert {:ok, closed} = Competition.close_scoring(scoring_open, actor: manager)
    assert closed.state == :scoring_closed
    assert [%{action: "round_scoring_closed"}] = round_audits(round.id)

    assert {:error, _error} = Competition.finalize_round(closed, actor: manager)

    finalized = set_round_state!(round, :finalized)
    assert {:error, _error} = Competition.reopen_round(finalized, "  ", actor: admin)

    assert {:ok, reopened} =
             Competition.reopen_round(finalized, "official correction required", actor: admin)

    assert reopened.state == :scoring_closed

    assert Enum.any?(round_audits(round.id), fn audit ->
             audit.action == "round_reopened" &&
               audit.changes["state"]["from"] == "finalized" &&
               get_in(audit.context, ["reason"]) == "official correction required"
           end)

    cancel_event = create_event!()
    cancel_admin = create_event_admin!(cancel_event)
    cancel_course = create_course!(cancel_event, cancel_admin)

    assert {:ok, draft_round} =
             Competition.create_round(cancel_event.id, cancel_course.id, actor: cancel_admin)

    assert {:ok, cancelled} = Competition.cancel_round(draft_round, actor: cancel_admin)
    assert cancelled.state == :cancelled
    assert Enum.any?(round_audits(draft_round.id), &(&1.action == "round_cancelled"))
    assert {:error, _error} = Competition.cancel_round(cancelled, actor: cancel_admin)
  end

  test "audit failure rolls back a Round lifecycle mutation" do
    event = create_event!()
    admin = create_event_admin!(event)
    course = create_course!(event, admin)
    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    scoring_open = set_round_state!(round, :scoring_open)
    install_round_audit_failure_trigger!()

    assert {:error, _error} = Competition.close_scoring(scoring_open, actor: admin)
    assert round_state(round.id) == "scoring_open"
    refute Enum.any?(round_audits(round.id), &(&1.action == "round_scoring_closed"))

    drop_round_audit_failure_trigger!()
  end

  test "stale Event Admin struct cannot create_round after assignment revocation" do
    event = create_event!()
    admin = create_event_admin!(event)
    replacement = create_event_admin!(event)
    stale_admin = admin
    course = create_course!(event, replacement)

    assignment = active_assignment_record(event, admin)

    assert {:ok, _revoked} =
             Accounts.revoke_event_staff_role(assignment, actor: replacement)

    rounds_before = round_count_for_event(event.id)

    assert {:error, _error} =
             Competition.create_round(event.id, course.id, actor: stale_admin)

    assert round_count_for_event(event.id) == rounds_before
  end

  test "stale Competition Manager struct cannot configure_round_layout after assignment revocation" do
    event = create_event!()
    admin = create_event_admin!(event)
    manager = create_staff_user!()
    assign_role!(admin, event, manager, :competition_manager)
    stale_manager = manager
    course = create_course!(event, admin)
    holes = create_eighteen_holes!(event, admin, course)
    hole_ids = Enum.map(holes, & &1.id)

    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    assert {:ok, _} = ConfigureRoundLayout.run(admin, round.id, hole_ids)

    before = route_snapshot(round.id)

    assert {:ok, revoked} =
             Accounts.revoke_event_staff_role(
               active_assignment_record(event, manager, :competition_manager),
               actor: admin
             )

    assert revoked.status == :revoked

    assert {:error, :forbidden} =
             ConfigureRoundLayout.run(stale_manager, round.id, Enum.reverse(hole_ids))

    assert route_snapshot(round.id) == before
  end

  defp assign_role!(actor, event, staff, role) do
    {:ok, _} =
      GolfScoring.Accounts.assign_event_staff_role(
        %{event_id: event.id, staff_user_id: staff.id, role: role},
        actor: actor
      )
  end

  defp create_system_admin! do
    staff = create_staff_user!()

    Repo.query!("UPDATE staff_users SET system_admin = TRUE WHERE id = $1::uuid", [
      Ecto.UUID.dump!(staff.id)
    ])

    Repo.get!(GolfScoring.Accounts.StaffUser, staff.id)
  end

  defp set_event_state!(event, state) do
    Repo.query!("UPDATE events SET state = $1 WHERE id = $2::uuid", [
      Atom.to_string(state),
      Ecto.UUID.dump!(event.id)
    ])
  end

  defp set_round_state!(round, state) do
    Repo.query!("UPDATE rounds SET state = $1 WHERE id = $2::uuid", [
      Atom.to_string(state),
      Ecto.UUID.dump!(round.id)
    ])

    Repo.get!(Round, round.id)
  end

  defp round_state(round_id) do
    [[state]] =
      Repo.query!("SELECT state FROM rounds WHERE id = $1::uuid", [Ecto.UUID.dump!(round_id)]).rows

    state
  end

  defp route_snapshot(round_id) do
    Repo.query!(
      "SELECT id::text, course_hole_id::text, play_order FROM round_holes WHERE round_id = $1::uuid ORDER BY play_order",
      [Ecto.UUID.dump!(round_id)]
    ).rows
  end

  defp round_count_for_event(event_id) do
    [[count]] =
      Repo.query!("SELECT count(*) FROM rounds WHERE event_id = $1::uuid", [
        Ecto.UUID.dump!(event_id)
      ]).rows

    count
  end

  defp active_assignment_record(event, staff, role \\ :event_admin) do
    [[assignment_id]] =
      Repo.query!(
        "SELECT id::text FROM event_staff_assignments WHERE event_id = $1::uuid AND staff_user_id = $2::uuid AND role = $3 AND status = 'active'",
        [
          Ecto.UUID.dump!(event.id),
          Ecto.UUID.dump!(staff.id),
          Atom.to_string(role)
        ]
      ).rows

    EventStaffAssignment
    |> Ash.get!(assignment_id, authorize?: false)
  end

  defp round_audits(round_id) do
    Repo.query!(
      "SELECT action, changes, context FROM audit_events WHERE target_type = 'round' AND target_id = $1::uuid ORDER BY occurred_at, id",
      [Ecto.UUID.dump!(round_id)]
    ).rows
    |> Enum.map(fn [action, changes, context] ->
      %{action: action, changes: changes, context: context}
    end)
  end

  defp install_round_audit_failure_trigger! do
    Repo.query!("""
    CREATE FUNCTION gls15_reject_round_audit() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.action LIKE 'round_%' THEN
        RAISE EXCEPTION 'simulated GLS-15 round audit failure';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls15_reject_round_audit
    BEFORE INSERT ON audit_events
    FOR EACH ROW EXECUTE FUNCTION gls15_reject_round_audit()
    """)
  end

  defp drop_round_audit_failure_trigger! do
    Repo.query!("DROP TRIGGER gls15_reject_round_audit ON audit_events")
    Repo.query!("DROP FUNCTION gls15_reject_round_audit()")
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
    email =
      "#{Process.get(:gls15_email_prefix)}-#{System.unique_integer([:positive])}@example.com"

    GolfScoring.Accounts.StaffUser
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
end

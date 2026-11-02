defmodule GolfScoring.Scoring.ScoreResourcesTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ash.Changeset
  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Competition.Event
  alias GolfScoring.Competition.RoundHole
  alias GolfScoring.Competition.Services.AssignEntryToGroup
  alias GolfScoring.Competition.Services.ConfigureRoundLayout
  alias GolfScoring.GolfCatalog
  alias GolfScoring.Repo
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.HoleResult
  alias GolfScoring.Scoring.HoleSubmission
  alias GolfScoring.Scoring.Scorecard

  @password "GLS-32 synthetic staff passphrase 2026"

  @scorecard_state_check "scorecards_state_must_be_valid"
  @scorecard_unique_entry "scorecards_unique_round_entry_index"
  @scorecard_entry_fkey "scorecards_round_entry_id_fkey"

  @hole_result_unique "hole_results_unique_scorecard_hole_index"
  @hole_result_gross_check "hole_results_outcome_gross_shape"
  @hole_result_revision_check "hole_results_revision_must_be_positive"
  @hole_result_scorecard_fkey "hole_results_scorecard_id_fkey"
  @hole_result_hole_fkey "hole_results_round_hole_id_fkey"

  @submission_unique_client "hole_submissions_unique_client_submission_index"
  @submission_actor_check "hole_submissions_exactly_one_actor"
  @submission_shape_check "hole_submissions_actor_assignment_shape"
  @submission_revision_check "hole_submissions_expected_revision_non_negative"
  @submission_role_version_check "hole_submissions_role_assignment_version_positive"
  @submission_fingerprint_check "hole_submissions_payload_fingerprint_non_empty"
  @submission_group_fkey "hole_submissions_playing_group_id_fkey"
  @submission_hole_fkey "hole_submissions_round_hole_id_fkey"
  @submission_entry_fkey "hole_submissions_submitted_by_round_entry_id_fkey"

  setup do
    Process.put(:gls32_prefix, "gls32-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls32_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    :ok
  end

  test "Scoring domain registers GLS-32 score resources without public raw writes" do
    resources = Ash.Domain.Info.resources(Scoring)

    assert Scorecard in resources
    assert HoleResult in resources
    assert HoleSubmission in resources

    refute function_exported?(Scoring, :create_scorecard, 1)
    refute function_exported?(Scoring, :create_hole_result, 1)
    refute function_exported?(Scoring, :create_hole_submission, 1)
    refute function_exported?(Scoring, :update_hole_result, 2)
  end

  test "score resources expose only private internal mutation actions" do
    for resource <- [Scorecard, HoleResult, HoleSubmission] do
      refute Info.action(resource, :create)
      refute Info.action(resource, :update)
      refute Info.action(resource, :destroy)
    end

    assert Info.action(Scorecard, :create_internal)
    assert Info.action(HoleResult, :record_internal)
    assert Info.action(HoleSubmission, :create_accepted_internal)
  end

  test "named internal create actions are private and omit lifecycle fields from accept" do
    scorecard_create = Info.action(Scorecard, :create_internal)
    hole_result_create = Info.action(HoleResult, :record_internal)
    hole_submission_create = Info.action(HoleSubmission, :create_accepted_internal)

    refute scorecard_create.public?
    refute hole_result_create.public?
    refute hole_submission_create.public?

    assert scorecard_create.accept == [:round_id, :round_entry_id]
    refute :state in scorecard_create.accept

    assert hole_result_create.accept == [
             :round_id,
             :scorecard_id,
             :round_hole_id,
             :outcome,
             :gross_strokes
           ]

    refute :revision in hole_result_create.accept

    refute Info.attribute(Scorecard, :state).writable?
    refute Info.attribute(HoleResult, :revision).writable?
  end

  test "caller-supplied Scorecard state and HoleResult revision cannot override defaults" do
    entry_setup = setup_round_with_entry!()

    assert {:error, %Ash.Error.Invalid{}} =
             Scorecard
             |> Changeset.for_create(:create_internal, %{
               round_id: entry_setup.round.id,
               round_entry_id: entry_setup.entry.id,
               state: :in_progress
             })
             |> Ash.create(authorize?: false)

    scorecard = create_scorecard!(entry_setup.round.id, entry_setup.entry.id)
    assert scorecard.state == :not_started

    hole_setup = setup_scorecard_fixture!()

    assert {:error, %Ash.Error.Invalid{}} =
             HoleResult
             |> Changeset.for_create(:record_internal, %{
               round_id: hole_setup.round.id,
               scorecard_id: hole_setup.scorecard.id,
               round_hole_id: hole_setup.round_hole.id,
               outcome: :holed_out,
               gross_strokes: 3,
               revision: 99
             })
             |> Ash.create(authorize?: false)

    result = record_hole_result!(hole_setup, :holed_out, 3)
    assert result.revision == 1
  end

  test "valid Scorecard persists with default not_started state" do
    setup = setup_round_with_entry!()

    scorecard =
      create_scorecard!(setup.round.id, setup.entry.id)

    assert scorecard.state == :not_started
    assert scorecard.round_id == setup.round.id
    assert scorecard.round_entry_id == setup.entry.id
  end

  test "same RoundEntry cannot get second Scorecard" do
    setup = setup_round_with_entry!()
    create_scorecard!(setup.round.id, setup.entry.id)

    assert_constraint_violation(
      fn ->
        Repo.query!(
          """
          INSERT INTO scorecards (round_id, round_entry_id, state, inserted_at, updated_at)
          VALUES ($1::uuid, $2::uuid, 'not_started', now(), now())
          """,
          [
            Ecto.UUID.dump!(setup.round.id),
            Ecto.UUID.dump!(setup.entry.id)
          ]
        )
      end,
      @scorecard_unique_entry,
      :unique_violation
    )
  end

  test "cross-Round RoundEntry relationship rejected at DB for Scorecard" do
    setup_a = setup_round_with_entry!()
    setup_b = setup_round_with_entry!()

    assert_constraint_violation(
      fn ->
        Repo.query!(
          """
          INSERT INTO scorecards (round_id, round_entry_id, state, inserted_at, updated_at)
          VALUES ($1::uuid, $2::uuid, 'not_started', now(), now())
          """,
          [
            Ecto.UUID.dump!(setup_a.round.id),
            Ecto.UUID.dump!(setup_b.entry.id)
          ]
        )
      end,
      @scorecard_entry_fkey,
      :foreign_key_violation
    )
  end

  test "invalid Scorecard state rejected at DB" do
    setup = setup_round_with_entry!()

    assert_constraint_violation(
      fn ->
        Repo.query!(
          """
          INSERT INTO scorecards (round_id, round_entry_id, state, inserted_at, updated_at)
          VALUES ($1::uuid, $2::uuid, 'finalized', now(), now())
          """,
          [
            Ecto.UUID.dump!(setup.round.id),
            Ecto.UUID.dump!(setup.entry.id)
          ]
        )
      end,
      @scorecard_state_check,
      :check_violation
    )
  end

  test "holed_out with positive gross persists" do
    setup = setup_scorecard_fixture!()

    result =
      record_hole_result!(setup, :holed_out, 4)

    assert result.outcome == :holed_out
    assert result.gross_strokes == 4
    assert result.revision == 1
  end

  test "picked_up with nil gross persists" do
    setup = setup_scorecard_fixture!()

    result = record_hole_result!(setup, :picked_up, nil)
    assert result.outcome == :picked_up
    assert is_nil(result.gross_strokes)
  end

  test "HoleResult PostgreSQL rejects invalid outcome and gross combinations" do
    setup = setup_scorecard_fixture!()
    base = hole_result_sql_params(setup)

    assert_constraint_violation(
      fn ->
        insert_hole_result_row!(Map.merge(base, %{outcome: "holed_out", gross_strokes: nil}))
      end,
      @hole_result_gross_check,
      :check_violation
    )

    assert_constraint_violation(
      fn ->
        insert_hole_result_row!(Map.merge(base, %{outcome: "holed_out", gross_strokes: 0}))
      end,
      @hole_result_gross_check,
      :check_violation
    )

    assert_constraint_violation(
      fn ->
        insert_hole_result_row!(Map.merge(base, %{outcome: "picked_up", gross_strokes: 3}))
      end,
      @hole_result_gross_check,
      :check_violation
    )

    assert_constraint_violation(
      fn -> insert_hole_result_row!(Map.put(base, :outcome, "withdrawn")) end,
      :check_violation,
      fn constraint ->
        constraint in [
          "hole_results_outcome_must_be_valid",
          "hole_results_outcome_gross_shape"
        ]
      end
    )
  end

  test "duplicate Scorecard and RoundHole HoleResult rejected at DB" do
    setup = setup_scorecard_fixture!()
    record_hole_result!(setup, :holed_out, 5)
    base = hole_result_sql_params(setup)

    assert_constraint_violation(
      fn -> insert_hole_result_row!(base) end,
      @hole_result_unique,
      :unique_violation
    )
  end

  test "cross-Round Scorecard and RoundHole references rejected at DB" do
    setup_a = setup_scorecard_fixture!()
    setup_b = setup_scorecard_fixture!()
    base = hole_result_sql_params(setup_a)

    assert_constraint_violation(
      fn ->
        insert_hole_result_row!(%{
          base
          | round_hole_id: setup_b.round_hole.id,
            round_id: setup_a.round.id
        })
      end,
      @hole_result_hole_fkey,
      :foreign_key_violation
    )

    assert_constraint_violation(
      fn ->
        insert_hole_result_row!(%{
          base
          | scorecard_id: setup_b.scorecard.id,
            round_id: setup_a.round.id
        })
      end,
      @hole_result_scorecard_fkey,
      :foreign_key_violation
    )
  end

  test "HoleResult revision defaults to 1 and rejects non-positive revision at DB" do
    setup = setup_scorecard_fixture!()
    base = hole_result_sql_params(setup)

    assert_constraint_violation(
      fn -> insert_hole_result_row!(Map.put(base, :revision, 0)) end,
      @hole_result_revision_check,
      :check_violation
    )
  end

  test "valid normal scorer HoleSubmission persists with round-tripped fields" do
    setup = setup_submission_fixture!(:scorer)
    payload = %{"player_results" => [%{"entry_id" => setup.entry.id, "strokes" => 4}]}
    fingerprint = :crypto.hash(:sha256, "gls32-normal")
    client_id = Ecto.UUID.generate()
    captured = DateTime.utc_now()

    submission =
      create_scorer_submission!(setup, %{
        client_submission_id: client_id,
        expected_group_score_revision: 2,
        payload_fingerprint: fingerprint,
        submitted_payload: payload,
        captured_at: captured
      })

    assert submission.client_submission_id == client_id
    assert submission.expected_group_score_revision == 2
    assert submission.payload_fingerprint == fingerprint
    assert submission.submitted_payload == payload
    assert submission.submitted_by_round_entry_id == setup.entry.id
    assert submission.group_role_assignment_id == setup.role_assignment.id
    assert submission.role_assignment_version == setup.role_assignment.assignment_version
    assert is_nil(submission.submitted_by_staff_user_id)
    assert %DateTime{} = submission.accepted_at
  end

  test "valid staff actor HoleSubmission persists" do
    setup = setup_submission_fixture!(:staff)
    staff = setup.admin

    submission =
      create_staff_submission!(setup, %{
        client_submission_id: Ecto.UUID.generate(),
        expected_group_score_revision: 0,
        payload_fingerprint: <<1, 2, 3>>,
        submitted_payload: %{"emergency" => true},
        captured_at: DateTime.utc_now(),
        submitted_by_staff_user_id: staff.id
      })

    assert submission.submitted_by_staff_user_id == staff.id
    assert is_nil(submission.submitted_by_round_entry_id)
    assert is_nil(submission.group_role_assignment_id)
    assert is_nil(submission.role_assignment_version)
  end

  test "duplicate client_submission_id rejected at DB" do
    setup = setup_submission_fixture!(:scorer)
    client_id = Ecto.UUID.generate()
    params = Map.put(submission_sql_params(setup), :client_submission_id, client_id)

    insert_submission_row!(setup, params)

    assert_constraint_violation(
      fn -> insert_submission_row!(setup, params) end,
      @submission_unique_client,
      :unique_violation
    )
  end

  test "HoleSubmission cross-Round references rejected at DB" do
    setup_a = setup_submission_fixture!(:scorer)
    setup_b = setup_submission_fixture!(:scorer)
    base = submission_sql_params(setup_a)

    assert_constraint_violation(
      fn ->
        insert_submission_row!(setup_a, Map.put(base, :playing_group_id, setup_b.group.id))
      end,
      @submission_group_fkey,
      :foreign_key_violation
    )

    assert_constraint_violation(
      fn ->
        insert_submission_row!(setup_a, Map.put(base, :round_hole_id, setup_b.round_hole.id))
      end,
      @submission_hole_fkey,
      :foreign_key_violation
    )

    assert_constraint_violation(
      fn ->
        insert_submission_row!(
          setup_a,
          Map.put(base, :submitted_by_round_entry_id, setup_b.entry.id)
        )
      end,
      @submission_entry_fkey,
      :foreign_key_violation
    )
  end

  test "HoleSubmission actor and assignment shape rejected at DB" do
    setup = setup_submission_fixture!(:scorer)
    base = submission_sql_params(setup)

    assert_constraint_violation(
      fn ->
        insert_submission_row!(setup, %{
          base
          | submitted_by_round_entry_id: nil,
            submitted_by_staff_user_id: nil,
            group_role_assignment_id: nil,
            role_assignment_version: nil
        })
      end,
      :check_violation,
      fn constraint ->
        constraint in [@submission_actor_check, @submission_shape_check]
      end
    )

    assert_constraint_violation(
      fn ->
        insert_submission_row!(
          setup,
          Map.merge(submission_sql_params(setup), %{
            submitted_by_staff_user_id: setup.admin.id,
            submitted_by_round_entry_id: setup.entry.id
          })
        )
      end,
      :check_violation,
      fn constraint ->
        constraint in [
          @submission_actor_check,
          @submission_shape_check
        ]
      end
    )

    assert_constraint_violation(
      fn ->
        insert_submission_row!(setup, %{
          base
          | group_role_assignment_id: nil,
            role_assignment_version: nil
        })
      end,
      @submission_shape_check,
      :check_violation
    )

    assert_constraint_violation(
      fn ->
        insert_submission_row!(setup, %{
          base
          | submitted_by_staff_user_id: setup.admin.id,
            submitted_by_round_entry_id: nil,
            group_role_assignment_id: setup.role_assignment.id,
            role_assignment_version: 1
        })
      end,
      @submission_shape_check,
      :check_violation
    )
  end

  test "HoleSubmission revision fingerprint and role version constraints at DB" do
    setup = setup_submission_fixture!(:scorer)
    base = submission_sql_params(setup)

    assert_constraint_violation(
      fn -> insert_submission_row!(setup, Map.put(base, :expected_group_score_revision, -1)) end,
      @submission_revision_check,
      :check_violation
    )

    assert_constraint_violation(
      fn -> insert_submission_row!(setup, Map.put(base, :role_assignment_version, 0)) end,
      :check_violation,
      fn constraint ->
        constraint in [
          @submission_role_version_check,
          @submission_shape_check
        ]
      end
    )

    assert_constraint_violation(
      fn -> insert_submission_row!(setup, Map.put(base, :payload_fingerprint, <<>>)) end,
      @submission_fingerprint_check,
      :check_violation
    )
  end

  defp create_scorecard!(round_id, round_entry_id) do
    Scorecard
    |> Changeset.for_create(:create_internal, %{
      round_id: round_id,
      round_entry_id: round_entry_id
    })
    |> Ash.create!(authorize?: false)
  end

  defp record_hole_result!(setup, outcome, gross_strokes) do
    attrs = %{
      round_id: setup.round.id,
      scorecard_id: setup.scorecard.id,
      round_hole_id: setup.round_hole.id,
      outcome: outcome,
      gross_strokes: gross_strokes
    }

    HoleResult
    |> Changeset.for_create(:record_internal, attrs)
    |> Ash.create!(authorize?: false)
  end

  defp create_scorer_submission!(setup, attrs) do
    merged =
      Map.merge(
        %{
          round_id: setup.round.id,
          playing_group_id: setup.group.id,
          round_hole_id: setup.round_hole.id,
          submitted_by_round_entry_id: setup.entry.id,
          group_role_assignment_id: setup.role_assignment.id,
          role_assignment_version: setup.role_assignment.assignment_version,
          submitted_by_staff_user_id: nil
        },
        attrs
      )

    HoleSubmission
    |> Changeset.for_create(:create_accepted_internal, merged)
    |> Ash.create!(authorize?: false)
  end

  defp create_staff_submission!(setup, attrs) do
    merged =
      Map.merge(
        %{
          round_id: setup.round.id,
          playing_group_id: setup.group.id,
          round_hole_id: setup.round_hole.id,
          submitted_by_round_entry_id: nil,
          group_role_assignment_id: nil,
          role_assignment_version: nil
        },
        attrs
      )

    HoleSubmission
    |> Changeset.for_create(:create_accepted_internal, merged)
    |> Ash.create!(authorize?: false)
  end

  defp setup_scorecard_fixture! do
    setup = setup_round_with_hole!()

    scorecard = create_scorecard!(setup.round.id, setup.entry.id)
    Map.put(setup, :scorecard, scorecard)
  end

  defp setup_submission_fixture!(mode) do
    setup = setup_round_with_hole_and_group!()

    role_assignment =
      case mode do
        :scorer ->
          assert {:ok, role} =
                   Competition.assign_primary_scorer(
                     setup.admin,
                     setup.event.id,
                     setup.round.id,
                     setup.group.id,
                     setup.entry.id
                   )

          role

        :staff ->
          nil
      end

    setup
    |> Map.put(:role_assignment, role_assignment)
    |> Map.put(:mode, mode)
  end

  defp setup_round_with_entry! do
    event = create_event!()
    admin = create_event_admin!(event)
    course = create_course!(event, admin)
    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    player = create_player!()

    {:ok, entry} =
      Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    %{event: event, round: round, admin: admin, entry: entry, course: course}
  end

  defp setup_round_with_hole! do
    base = setup_round_with_entry!()
    holes = create_eighteen_holes!(base.event, base.admin, base.course)

    {:ok, _} =
      ConfigureRoundLayout.run(base.admin, base.round.id, Enum.map(holes, & &1.id))

    round_hole =
      RoundHole
      |> Ash.Query.filter(round_id == ^base.round.id)
      |> Ash.Query.sort(play_order: :asc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(authorize?: false)

    Map.put(base, :round_hole, round_hole)
  end

  defp setup_round_with_hole_and_group! do
    base = setup_round_with_hole!()

    {:ok, group} =
      Competition.create_playing_group(base.event.id, base.round.id, actor: base.admin)

    assert {:ok, _} =
             AssignEntryToGroup.run(
               base.admin,
               base.event.id,
               base.round.id,
               base.entry.id,
               group.id
             )

    Map.put(base, :group, group)
  end

  defp hole_result_sql_params(setup) do
    %{
      round_id: setup.round.id,
      scorecard_id: setup.scorecard.id,
      round_hole_id: setup.round_hole.id,
      outcome: "holed_out",
      gross_strokes: 4,
      revision: 1
    }
  end

  defp insert_hole_result_row!(params) do
    Repo.query!(
      """
      INSERT INTO hole_results
        (round_id, scorecard_id, round_hole_id, outcome, gross_strokes, revision, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, $3::uuid, $4, $5, $6, now(), now())
      """,
      [
        Ecto.UUID.dump!(params.round_id),
        Ecto.UUID.dump!(params.scorecard_id),
        Ecto.UUID.dump!(params.round_hole_id),
        params.outcome,
        params.gross_strokes,
        params.revision
      ]
    )
  end

  defp submission_sql_params(setup) do
    role = setup.role_assignment

    %{
      client_submission_id: Ecto.UUID.generate(),
      round_id: setup.round.id,
      playing_group_id: setup.group.id,
      round_hole_id: setup.round_hole.id,
      expected_group_score_revision: 1,
      submitted_by_round_entry_id: setup.entry.id,
      submitted_by_staff_user_id: nil,
      group_role_assignment_id: role.id,
      role_assignment_version: role.assignment_version,
      payload_fingerprint: <<4, 5, 6>>,
      submitted_payload: Jason.encode!(%{"x" => 1}),
      captured_at: DateTime.utc_now(),
      accepted_at: DateTime.utc_now()
    }
  end

  defp insert_submission_row!(_setup, params) do
    payload =
      case params[:submitted_payload] do
        %{} = map -> Jason.encode!(map)
        other -> other
      end

    Repo.query!(
      """
      INSERT INTO hole_submissions
        (client_submission_id, round_id, playing_group_id, round_hole_id,
         expected_group_score_revision, submitted_by_round_entry_id, submitted_by_staff_user_id,
         group_role_assignment_id, role_assignment_version, payload_fingerprint, submitted_payload,
         captured_at, accepted_at, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5, $6::uuid, $7::uuid, $8::uuid, $9,
              $10, $11::jsonb, $12, $13, now(), now())
      """,
      [
        Ecto.UUID.dump!(params.client_submission_id),
        Ecto.UUID.dump!(params.round_id),
        Ecto.UUID.dump!(params.playing_group_id),
        Ecto.UUID.dump!(params.round_hole_id),
        params.expected_group_score_revision,
        params.submitted_by_round_entry_id && Ecto.UUID.dump!(params.submitted_by_round_entry_id),
        params.submitted_by_staff_user_id && Ecto.UUID.dump!(params.submitted_by_staff_user_id),
        params.group_role_assignment_id && Ecto.UUID.dump!(params.group_role_assignment_id),
        params.role_assignment_version,
        params.payload_fingerprint,
        payload,
        params.captured_at,
        params.accepted_at
      ]
    )
  end

  defp assert_constraint_violation(fun, expected_constraint, expected_code)
       when is_binary(expected_constraint) and is_atom(expected_code) do
    error = assert_raise Postgrex.Error, fun
    assert error.postgres.code == expected_code
    assert error.postgres.constraint == expected_constraint
  end

  defp assert_constraint_violation(fun, expected_code, constraint_predicate)
       when is_atom(expected_code) and is_function(constraint_predicate, 1) do
    error = assert_raise Postgrex.Error, fun
    assert error.postgres.code == expected_code
    assert constraint_predicate.(error.postgres.constraint)
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

  defp create_course!(event, admin) do
    {:ok, course} =
      GolfCatalog.create_course(
        event.id,
        %{name: "GLS-32 Course", location: "Test"},
        actor: admin
      )

    course
  end

  defp create_player! do
    GolfScoring.Competition.Player
    |> Changeset.for_create(:create_internal, %{
      first_name: "Pat",
      surname: "Golfer#{System.unique_integer([:positive])}"
    })
    |> Ash.create!(authorize?: false)
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

  defp create_staff_user! do
    email =
      "#{Process.get(:gls32_prefix)}-#{System.unique_integer([:positive])}@example.com"

    Accounts.StaffUser
    |> Changeset.for_create(:provision_staff_user, %{
      email: email,
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end
end

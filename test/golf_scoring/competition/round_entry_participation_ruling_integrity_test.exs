defmodule GolfScoring.Competition.RoundEntryParticipationRulingIntegrityTest do
  use GolfScoring.DataCase, async: false

  alias Ash.Resource.Info
  alias GolfScoring.Competition.RoundEntryParticipationRuling
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures
  alias GolfScoring.Scoring.Services.SubmitGroupHole

  test "the resource exposes only the coordinator-guarded internal create action" do
    actions = Info.actions(RoundEntryParticipationRuling)

    create_action =
      Info.action(RoundEntryParticipationRuling, :create_accepted_withdrawal_internal)

    assert Enum.map(actions, & &1.type) == [:read, :create]
    assert Info.public_actions(RoundEntryParticipationRuling) == []
    assert create_action.type == :create
    refute create_action.public?
    refute Enum.any?(actions, &(&1.type in [:update, :destroy]))
  end

  test "direct Ash creation without withdrawal coordinator evidence inserts no ruling" do
    setup = PaperRecoveryFixtures.setup_two_group_mystery_fixture!()
    checkpoint = checkpoint_for!(setup, setup.group, setup.entries)
    entry = hd(setup.entries)

    attrs =
      setup
      |> ruling_attrs(entry, setup.group, checkpoint)
      |> Map.take([
        :event_id,
        :round_id,
        :round_entry_id,
        :playing_group_id,
        :authorized_by_event_staff_assignment_id,
        :authorized_by_staff_user_id,
        :checkpoint_hole_submission_id,
        :checkpoint_round_hole_id,
        :effective_round_hole_id
      ])

    assert {:error, %Ash.Error.Invalid{} = error} =
             RoundEntryParticipationRuling
             |> Ash.Changeset.for_create(:create_accepted_withdrawal_internal, attrs)
             |> Ash.create(authorize?: false)

    assert inspect(error) =~
             "withdrawal writes require the active acceptance coordinator transaction"

    assert [[0]] ==
             Repo.query!(
               "SELECT count(*)::int FROM round_entry_participation_rulings WHERE round_entry_id = $1::uuid",
               [Ecto.UUID.dump!(entry.id)]
             ).rows
  end

  test "migration installs scoped indexes, composite references, and always-on append-only triggers" do
    assert table_exists?("round_entry_participation_rulings")
    assert index_exists?("round_entry_participation_rulings_unique_round_entry_index")
    assert index_exists?("round_entry_participation_rulings_round_hole_index")

    for constraint <- [
          "round_entry_participation_rulings_round_entry_same_scope_fkey",
          "round_entry_participation_rulings_checkpoint_submission_same_scope_fkey",
          "round_entry_participation_rulings_effective_hole_same_round_fkey",
          "round_entry_participation_rulings_authority_same_event_fkey"
        ] do
      assert composite_fkey?(constraint)
    end

    assert trigger_enabled_always?("round_entry_participation_rulings_reject_mutation")
    assert trigger_enabled_always?("round_entry_participation_rulings_reject_truncate")
  end

  test "postgres enforces ruling kind, required provenance, group scope, and per-entry uniqueness" do
    setup = PaperRecoveryFixtures.setup_two_group_mystery_fixture!()
    checkpoint = checkpoint_for!(setup, setup.group, setup.entries)
    checkpoint_b = checkpoint_for!(setup, setup.group_b, setup.entries_b)
    entry = hd(setup.entries)
    group_b_entry = hd(setup.entries_b)
    attrs = ruling_attrs(setup, entry, setup.group, checkpoint)
    attrs_b = ruling_attrs(setup, group_b_entry, setup.group_b, checkpoint_b)

    assert :ok = insert_ruling(attrs)

    assert_constraint_violation!(
      insert_sql(),
      [Ecto.UUID.dump!(Ecto.UUID.generate()) | tl(insert_params(attrs))],
      :unique_violation,
      "round_entry_participation_rulings_unique_round_entry_index"
    )

    assert_constraint_violation!(
      insert_sql(),
      replace_param(insert_params(%{attrs_b | id: Ecto.UUID.generate()}), 6, "unsupported_kind"),
      :check_violation,
      "round_entry_participation_rulings_ruling_kind_allowed"
    )

    assert_constraint_violation!(
      insert_sql(),
      replace_param(insert_params(%{attrs_b | id: Ecto.UUID.generate()}), 15, false),
      :check_violation,
      "round_entry_participation_rulings_preplay_boundary_confirmed"
    )

    assert_constraint_violation!(
      insert_sql(),
      replace_param(insert_params(%{attrs_b | id: Ecto.UUID.generate()}), 14, 18),
      :check_violation,
      "round_entry_participation_rulings_effective_play_index_range"
    )

    wrong_group = %{attrs_b | id: Ecto.UUID.generate(), playing_group_id: setup.group.id}

    assert_constraint_violation!(
      insert_sql(),
      insert_params(wrong_group),
      :foreign_key_violation,
      "round_entry_participation_rulings_round_entry_same_scope_fkey"
    )

    other_event = PaperRecoveryFixtures.create_event!()
    wrong_event = %{attrs_b | id: Ecto.UUID.generate(), event_id: other_event.id}

    assert_constraint_violation!(
      insert_sql(),
      insert_params(wrong_event),
      :foreign_key_violation,
      "round_entry_participation_rulings_round_id_fkey"
    )

    wrong_effective_hole = %{
      attrs_b
      | id: Ecto.UUID.generate(),
        effective_round_hole_id: Ecto.UUID.generate()
    }

    assert_constraint_violation!(
      insert_sql(),
      insert_params(wrong_effective_hole),
      :foreign_key_violation,
      "round_entry_participation_rulings_effective_hole_same_round_fkey"
    )

    wrong_checkpoint = %{
      attrs_b
      | id: Ecto.UUID.generate(),
        checkpoint_hole_submission_id: checkpoint.submission_id,
        checkpoint_round_hole_id: checkpoint.checkpoint_hole_id
    }

    assert_constraint_violation!(
      insert_sql(),
      insert_params(wrong_checkpoint),
      :foreign_key_violation,
      "round_entry_participation_rulings_checkpoint_submission_same_scope_fkey"
    )

    wrong_authority = %{
      attrs_b
      | id: Ecto.UUID.generate(),
        authorized_by_role: "competition_manager"
    }

    assert_constraint_violation!(
      insert_sql(),
      insert_params(wrong_authority),
      :foreign_key_violation,
      "round_entry_participation_rulings_authority_same_event_fkey"
    )

    missing_provenance = %{
      attrs_b
      | id: Ecto.UUID.generate(),
        authorized_by_staff_user_id: nil
    }

    assert_constraint_violation!(
      insert_sql(),
      insert_params(missing_provenance),
      :not_null_violation,
      nil
    )
  end

  test "postgres prevents update, delete, and truncate of accepted evidence" do
    setup = PaperRecoveryFixtures.setup_two_group_mystery_fixture!()
    checkpoint = checkpoint_for!(setup, setup.group, setup.entries)
    attrs = ruling_attrs(setup, hd(setup.entries), setup.group, checkpoint)
    assert :ok = insert_ruling(attrs)

    assert_trigger_rejects!(
      "UPDATE round_entry_participation_rulings SET ruling_kind = 'round_withdrawal' WHERE id = $1::uuid",
      [Ecto.UUID.dump!(attrs.id)]
    )

    assert_trigger_rejects!(
      "DELETE FROM round_entry_participation_rulings WHERE id = $1::uuid",
      [Ecto.UUID.dump!(attrs.id)]
    )

    assert_trigger_rejects!("TRUNCATE round_entry_participation_rulings", [])
  end

  defp checkpoint_for!(setup, group, entries) do
    checkpoint_hole = hd(setup.route)
    effective_hole = Enum.at(setup.route, 1)

    revision =
      Repo.query!("SELECT scoring_revision FROM playing_groups WHERE id = $1::uuid", [
        Ecto.UUID.dump!(group.id)
      ]).rows
      |> hd()
      |> hd()

    assert {:ok, _} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               %{
                 client_submission_id: Ecto.UUID.generate(),
                 playing_group_id: group.id,
                 round_hole_id: checkpoint_hole.id,
                 expected_group_score_revision: revision,
                 results:
                   Enum.map(entries, fn entry ->
                     %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 5}
                   end),
                 captured_at: DateTime.utc_now()
               }
             )

    [[submission_id]] =
      Repo.query!(
        """
        SELECT id::text FROM hole_submissions
        WHERE round_id = $1::uuid AND playing_group_id = $2::uuid AND round_hole_id = $3::uuid
        """,
        [
          Ecto.UUID.dump!(setup.round.id),
          Ecto.UUID.dump!(group.id),
          Ecto.UUID.dump!(checkpoint_hole.id)
        ]
      ).rows

    %{
      submission_id: Ecto.UUID.cast!(submission_id),
      checkpoint_hole_id: checkpoint_hole.id,
      effective_hole_id: effective_hole.id
    }
  end

  defp ruling_attrs(setup, entry, group, checkpoint) do
    [[assignment_id, role]] =
      Repo.query!(
        """
        SELECT id::text, role FROM event_staff_assignments
        WHERE event_id = $1::uuid AND staff_user_id = $2::uuid
          AND role = 'event_admin' AND status = 'active'
        """,
        [Ecto.UUID.dump!(setup.event.id), Ecto.UUID.dump!(setup.admin.id)]
      ).rows

    %{
      id: Ecto.UUID.generate(),
      event_id: setup.event.id,
      round_id: setup.round.id,
      round_entry_id: entry.id,
      playing_group_id: group.id,
      ruling_kind: "round_withdrawal",
      authorized_by_event_staff_assignment_id: Ecto.UUID.cast!(assignment_id),
      authorized_by_staff_user_id: setup.admin.id,
      authorized_by_role: role,
      checkpoint_hole_submission_id: checkpoint.submission_id,
      checkpoint_round_hole_id: checkpoint.checkpoint_hole_id,
      checkpoint_play_index: 0,
      effective_round_hole_id: checkpoint.effective_hole_id,
      effective_play_index: 1,
      preplay_boundary_confirmed: true,
      accepted_at: DateTime.utc_now()
    }
  end

  defp insert_ruling(attrs) do
    case Repo.query(insert_sql(), insert_params(attrs)) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp insert_sql do
    """
    INSERT INTO round_entry_participation_rulings (
      id, event_id, round_id, round_entry_id, playing_group_id, ruling_kind,
      authorized_by_event_staff_assignment_id, authorized_by_staff_user_id, authorized_by_role,
      checkpoint_hole_submission_id, checkpoint_round_hole_id, checkpoint_play_index,
      effective_round_hole_id, effective_play_index, preplay_boundary_confirmed, accepted_at
    ) VALUES (
      $1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6, $7::uuid, $8::uuid, $9,
      $10::uuid, $11::uuid, $12, $13::uuid, $14, $15, $16
    )
    """
  end

  defp insert_params(attrs) do
    [
      Ecto.UUID.dump!(attrs.id),
      Ecto.UUID.dump!(attrs.event_id),
      Ecto.UUID.dump!(attrs.round_id),
      Ecto.UUID.dump!(attrs.round_entry_id),
      Ecto.UUID.dump!(attrs.playing_group_id),
      attrs.ruling_kind,
      Ecto.UUID.dump!(attrs.authorized_by_event_staff_assignment_id),
      uuid_param(attrs.authorized_by_staff_user_id),
      attrs.authorized_by_role,
      Ecto.UUID.dump!(attrs.checkpoint_hole_submission_id),
      Ecto.UUID.dump!(attrs.checkpoint_round_hole_id),
      attrs.checkpoint_play_index,
      Ecto.UUID.dump!(attrs.effective_round_hole_id),
      attrs.effective_play_index,
      attrs.preplay_boundary_confirmed,
      attrs.accepted_at
    ]
  end

  defp replace_param(params, index, value) do
    List.replace_at(params, index - 1, value)
  end

  defp uuid_param(nil), do: nil
  defp uuid_param(value), do: Ecto.UUID.dump!(value)

  defp assert_constraint_violation!(query, params, code, constraint) do
    case Repo.query(query, params) do
      {:error, error} ->
        assert error.postgres.code == code
        expected_constraint = if is_binary(constraint), do: String.slice(constraint, 0, 63)
        assert Map.get(error.postgres, :constraint) == expected_constraint

      {:ok, _} ->
        flunk("expected #{constraint} violation")
    end
  end

  defp assert_trigger_rejects!(query, params) do
    case Repo.query(query, params) do
      {:error, error} ->
        assert error.postgres.code == :raise_exception
        assert error.postgres.message =~ "append-only"

      {:ok, _} ->
        flunk("expected append-only trigger rejection")
    end
  end

  defp table_exists?(table) do
    Repo.query!(
      "SELECT to_regclass($1)::text IS NOT NULL",
      ["public." <> table]
    ).rows == [[true]]
  end

  defp index_exists?(name) do
    Repo.query!(
      "SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = $1",
      [name]
    ).rows != []
  end

  defp composite_fkey?(name) do
    Repo.query!(
      """
      SELECT count(*)::int
      FROM information_schema.key_column_usage
      WHERE constraint_schema = 'public' AND constraint_name = $1
        AND position_in_unique_constraint IS NOT NULL
      """,
      [String.slice(name, 0, 63)]
    ).rows
    |> hd()
    |> hd()
    |> Kernel.>(1)
  end

  defp trigger_enabled_always?(name) do
    Repo.query!(
      """
      SELECT tgenabled = 'A'
      FROM pg_trigger
      WHERE tgrelid = 'public.round_entry_participation_rulings'::regclass
        AND tgname = $1 AND NOT tgisinternal
      """,
      [name]
    ).rows == [[true]]
  end
end

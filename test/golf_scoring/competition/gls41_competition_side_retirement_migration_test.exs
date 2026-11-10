defmodule GolfScoring.Competition.Gls41CompetitionSideRetirementMigrationTest do
  use GolfScoring.DataCase, async: false

  alias GolfScoring.Competition.CompetitionSideResult
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures
  alias GolfScoring.Scoring.Services.SubmitGroupHole

  @parent_indexes [
    {"round_competitions", "round_competitions_unique_id_event_round_index"},
    {"competition_side_results", "competition_side_results_unique_id_competition_side_index"},
    {"hole_submissions", "hole_submissions_unique_id_round_index"}
  ]

  @scoped_fkeys [
    "competition_side_retirements_round_competition_id_fkey",
    "competition_side_retirements_competition_side_result_id_fkey",
    "competition_side_retirements_checkpoint_hole_submission_id_fkey"
  ]

  test "gls41 retirement migration is applied and parent scope indexes exist" do
    assert migration_applied?("20261110074853")

    refute File.exists?(
             Path.expand(
               "priv/repo/migrations/20261110084649_gls41_competition_side_retirement_scope_restore.exs",
               File.cwd!()
             )
           )

    for {table, index_name} <- @parent_indexes do
      assert index_exists?(table, index_name)
    end
  end

  test "competition_side_retirements composite foreign keys reference scoped parents" do
    for fkey <- @scoped_fkeys do
      assert composite_fkey?(fkey)
    end
  end

  test "competition_side_retirements composite foreign keys reject wrong-side result scope" do
    setup = PaperRecoveryFixtures.setup_two_group_mystery_fixture!()
    group_a = setup.group
    group_b = setup.group_b
    side_a = side_id_for_entries!(setup.entries)
    side_b = side_id_for_group!(group_b.id)
    result = side_result_for_side!(side_a)

    other_result = side_result_for_side!(side_b)

    assert other_result.id != result.id

    {checkpoint, effective} = checkpoint_and_effective_for_group!(setup, group_a, setup.entries)

    fingerprint = :crypto.strong_rand_bytes(32)

    try do
      Repo.query!(
        """
        INSERT INTO competition_side_retirements (
          event_id, round_id, round_competition_id, competition_side_id,
          competition_side_result_id, playing_group_id, authorized_by_staff_user_id,
          reason, acceptance_command_id, command_meaning_fingerprint,
          checkpoint_hole_submission_id, checkpoint_round_hole_id, checkpoint_play_index,
          effective_round_hole_id, effective_play_index, preplay_boundary_confirmed, accepted_at
        )
        SELECT
          r.event_id, r.id, cs.round_competition_id, $2::uuid, $4::uuid, $3::uuid, $5::uuid,
          'scope probe', gen_random_uuid(), $9::bytea,
          $6::uuid, $7::uuid, 0, $8::uuid, 1, true, now()
        FROM rounds r
        JOIN competition_sides cs ON cs.id = $2::uuid
        WHERE r.id = $1::uuid
        """,
        [
          Ecto.UUID.dump!(setup.round.id),
          Ecto.UUID.dump!(side_a),
          Ecto.UUID.dump!(group_a.id),
          Ecto.UUID.dump!(other_result.id),
          Ecto.UUID.dump!(setup.admin.id),
          Ecto.UUID.dump!(checkpoint.submission_id),
          Ecto.UUID.dump!(checkpoint.hole_id),
          Ecto.UUID.dump!(effective.hole_id),
          fingerprint
        ]
      )

      flunk("expected competition_side_retirements_competition_side_result_id_fkey violation")
    rescue
      error in Postgrex.Error ->
        assert error.postgres.code == :foreign_key_violation

        assert error.postgres.constraint ==
                 "competition_side_retirements_competition_side_result_id_fkey"
    end
  end

  defp migration_applied?(version) do
    Repo.query!(
      "SELECT 1 FROM schema_migrations WHERE version = $1::bigint",
      [String.to_integer(version)]
    ).rows != []
  end

  defp index_exists?(table, name) do
    Repo.query!(
      "SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = $1 AND indexname = $2",
      [table, name]
    ).rows != []
  end

  defp composite_fkey?(constraint_name) do
    Repo.query!(
      """
      SELECT count(*)::int
      FROM information_schema.referential_constraints rc
      JOIN information_schema.key_column_usage kcu
        ON kcu.constraint_name = rc.constraint_name
       AND kcu.constraint_schema = rc.constraint_schema
      WHERE rc.constraint_schema = 'public'
        AND rc.constraint_name = $1
      """,
      [constraint_name]
    ).rows
    |> hd()
    |> hd()
    |> Kernel.>(1)
  end

  defp checkpoint_and_effective_for_group!(setup, group, entries) do
    holes =
      Repo.query!(
        "SELECT id::text FROM round_holes WHERE round_id = $1::uuid ORDER BY play_order",
        [Ecto.UUID.dump!(setup.round.id)]
      ).rows
      |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end)

    start_id = group.starting_round_hole_id || hd(holes)
    start_index = Enum.find_index(holes, &(&1 == start_id))
    rotated = rotate(holes, start_index)
    checkpoint_hole = hd(rotated)
    effective_hole = Enum.at(rotated, 1)

    revision =
      Repo.query!(
        "SELECT scoring_revision FROM playing_groups WHERE id = $1::uuid",
        [Ecto.UUID.dump!(group.id)]
      ).rows
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
                 round_hole_id: checkpoint_hole,
                 expected_group_score_revision: revision,
                 results:
                   Enum.map(entries, fn e ->
                     %{round_entry_id: e.id, outcome: :holed_out, gross_strokes: 5}
                   end),
                 captured_at: DateTime.utc_now()
               }
             )

    submission_id =
      Repo.query!(
        """
        SELECT id::text FROM hole_submissions
        WHERE round_id = $1::uuid AND playing_group_id = $2::uuid AND round_hole_id = $3::uuid
        """,
        [
          Ecto.UUID.dump!(setup.round.id),
          Ecto.UUID.dump!(group.id),
          Ecto.UUID.dump!(checkpoint_hole)
        ]
      ).rows
      |> hd()
      |> hd()
      |> Ecto.UUID.cast!()

    {%{submission_id: submission_id, hole_id: checkpoint_hole}, %{hole_id: effective_hole}}
  end

  defp side_id_for_group!(group_id) do
    [[side_id]] =
      Repo.query!(
        """
        SELECT DISTINCT csm.competition_side_id::text
        FROM competition_side_memberships csm
        JOIN round_entries re ON re.id = csm.round_entry_id
        WHERE re.playing_group_id = $1::uuid
        """,
        [Ecto.UUID.dump!(group_id)]
      ).rows

    Ecto.UUID.cast!(side_id)
  end

  defp rotate(holes, start_index) do
    {head, tail} = Enum.split(holes, start_index)
    tail ++ head
  end

  defp side_id_for_entries!(entries) do
    entry_ids = Enum.map(entries, &Ecto.UUID.dump!(&1.id))

    [[side_id]] =
      Repo.query!(
        """
        SELECT DISTINCT competition_side_id::text
        FROM competition_side_memberships
        WHERE round_entry_id = ANY($1::uuid[])
        """,
        [entry_ids]
      ).rows

    Ecto.UUID.cast!(side_id)
  end

  defp side_result_for_side!(side_id) do
    [[id]] =
      Repo.query!(
        "SELECT id::text FROM competition_side_results WHERE competition_side_id = $1::uuid",
        [Ecto.UUID.dump!(side_id)]
      ).rows

    CompetitionSideResult
    |> Ash.get!(Ecto.UUID.cast!(id), authorize?: false)
  end
end

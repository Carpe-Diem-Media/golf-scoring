defmodule GolfScoring.Repo.Migrations.EnforceScoreRevisionImmutability do
  @moduledoc """
  Rejects ordinary rewrites and removal of committed correction evidence.

  PostgreSQL installs both guards transactionally, without scanning or rewriting
  existing rows. ALTER TABLE takes strong locks; the five-second lock timeout
  bounds acquisition, not transaction duration. Schedule deployment separately
  from long-running corrections and retry the entire migration on lock timeout.

  Down removes only these guards and their function, preserving every row and
  existing constraint. It removes the audit guarantee, so production rollback
  requires release-owner review; prefer forward repair after evidence exists.
  Table owners/superusers can still alter DDL. Production must separate runtime
  privileges from migration ownership; this migration adds no runtime bypass.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    CREATE FUNCTION public.reject_score_revision_mutation()
    RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog AS $$
    BEGIN
      RAISE EXCEPTION 'ScoreRevision evidence is append-only'
        USING ERRCODE = '55000', SCHEMA = 'public', TABLE = 'score_revisions';
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER score_revisions_immutable_rows
    BEFORE UPDATE OR DELETE ON public.score_revisions
    FOR EACH ROW EXECUTE FUNCTION public.reject_score_revision_mutation()
    """)

    execute("""
    CREATE TRIGGER score_revisions_immutable_truncate
    BEFORE TRUNCATE ON public.score_revisions
    FOR EACH STATEMENT EXECUTE FUNCTION public.reject_score_revision_mutation()
    """)

    execute(
      "ALTER TABLE public.score_revisions ENABLE ALWAYS TRIGGER score_revisions_immutable_rows"
    )

    execute(
      "ALTER TABLE public.score_revisions ENABLE ALWAYS TRIGGER score_revisions_immutable_truncate"
    )
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("DROP TRIGGER score_revisions_immutable_rows ON public.score_revisions")
    execute("DROP TRIGGER score_revisions_immutable_truncate ON public.score_revisions")
    execute("DROP FUNCTION public.reject_score_revision_mutation()")
  end
end

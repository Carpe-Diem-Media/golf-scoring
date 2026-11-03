# Golf Scoring V2 — Shared PostgreSQL Lock Protocol (GLS-30)

Authority: `docs/golf_live_scoring_v2_implementation_architecture.md` (Phase 4B/5 concurrency gate), `docs/golf_live_scoring_v2_spec_v1.0.md` §64 (atomic transactions, finalization under lock).

Implementation: `GolfScoring.LockProtocol` (`lib/golf_scoring/lock_protocol.ex`). Executable characterization: `test/golf_scoring/lock_protocol_test.exs`.

## Purpose

One deterministic **row-lock protocol** for gameplay/scoring concurrency. Consumers acquire explicit row IDs inside a short local `Repo.transaction/1`, re-read guards while locks are held, then commit or rollback. Conflicts are reported/retried—never silent authority overwrites. No Redis, advisory locks, or network I/O while locks are held.

## Total relation-class order

Acquire **only** in this order (caller input order is ignored):

| Order | Class | PostgreSQL table (V1) | GLS-30 SQL |
|------:|-------|----------------------|------------|
| 1 | `:round` | `rounds` | yes |
| 2 | `:playing_group` | `playing_groups` | yes |
| 3 | `:group_role_assignment` | `group_role_assignments` | yes |
| 4 | `:competition_side` | `competition_sides` | yes |
| 5 | `:competition_side_result` | `competition_side_results` | yes |
| 6 | `:score_row` | `scorecards` (one row per Scorecard UUID) | yes (GLS-34) |
| 7 | `:verification_row` | (future verification rows) | no — class reserved |
| 8 | `:query_row` | (future query rows) | no — class reserved |
| 9 | `:mystery_hole_rule` | `mystery_hole_rules` | yes |
| 10 | `:mystery_reveal` | (future `mystery_reveals`) | no — class reserved |

### Why this order

Derived from frozen transaction paths already in the codebase and spec:

- **Round before PlayingGroup / assignments**: staff configuration, role handover, side membership, and round lifecycle guards lock `rounds` then `playing_groups` / `group_role_assignments` (`HandoverGroupRole`, `AssignGroupRole`, `SetSideMembership`, round guards).
- **Authority revisions before side/result mutation**: active `group_role_assignments` are locked when roles change; side membership and results depend on stable group/entry authority.
- **CompetitionSide before CompetitionSideResult**: sides are configured and locked before result readiness/finalization (spec §64.10 side finalization locks `CompetitionSideResult` after side/score state is consistent; side rows are parent context).
- **Score / verification / query rows after side result**: hole submission, verification, and query resolution (spec §64.4–§64.7) mutate score artifacts that must not race side finalization; they follow side/result in the total order.
- **MysteryHoleRule then MysteryReveal**: reveal eligibility rechecks lock the rule row before creating the global reveal (architecture Phase 5; spec §64.9–§64.10). Rules belong to `ScoringTrack` configuration, not a separate lock class (see below).

If a future path cannot be expressed with this order, STOP and revise the protocol before implementing that path.

## Same-class ID ordering

Within each class, IDs are:

1. `nil` IDs are ignored during normalization (dropped, not locked),
2. de-duplicated (`Enum.uniq/1`),
3. sorted by `Ecto.UUID.dump!/1` ascending,

then locked one row at a time with `SELECT … FOR UPDATE`.

## Duplicate IDs

Duplicate IDs in the request collapse to a single lock for that class (no duplicate `FOR UPDATE` work).

## Transaction required

`LockProtocol.acquire!/1` **raises** `ArgumentError` if `Repo.in_transaction?/0` is false. Callers must open `Repo.transaction/1` first (same convention as `EventAuthorityLock`).

## Missing rows

If any requested ID does not exist, acquisition returns `{:error, reason}` (e.g. `:round_not_found`, `:playing_group_not_found`) **without** returning `{:ok, partial}`. The caller must `Repo.rollback/1`; PostgreSQL releases any rows locked earlier in that transaction.

## Lock duration and release

Locks are transaction-scoped only:

- **Commit** → locks released; other sessions may proceed.
- **Rollback** → locks released; waiting sessions may proceed.

No durable lock registry.

## Guard re-read

After `acquire!/1` returns `{:ok, %{acquired: …}}`, consumers must re-read lifecycle/authority state from the returned row maps (and any further local SQL) before mutating. Do not rely on pre-transaction checks alone (spec §64.10).

## Deadlock avoidance

All consumers use the same total class order and UUID order within a class. Two transactions requesting the same multiset of rows in opposite **caller** order still acquire in identical canonical order (characterized in tests).

## Conflicts and retries

The protocol does not mutate business data. On conflict (missing row, stale state, uniqueness violation), consumers roll back and return structured errors; higher layers retry or report. Never overwrite authority rows to “force success.”

## No external work while locked

No HTTP, PubSub, email, or job dispatch inside the locked transaction. Broadcasts and async work run **after** commit (spec §64.4).

## EventAuthorityLock composition

`GolfScoring.Accounts.EventAuthorityLock` is a **separate** scope for event/staff authority:

1. Open `Repo.transaction/1`.
2. `EventAuthorityLock.lock_scope!(event_id, staff_ids, …)` — locks `events`, relevant `staff_users`, and `event_staff_assignments` in UUID order.
3. `LockProtocol.acquire!(…)` for round/gameplay/scoring rows in the total order above.
4. Re-read guards; perform local DB work; commit.

Event/staff rows are **not** part of the shared gameplay list. Always take **event authority before** shared protocol rows so staff/event invariants are settled first (matches existing services). Do not lock gameplay rows before event authority when both are needed.

## ScoringTrack and RoundOpening (GLS-27)

`ScoringTrack` is **not** a global lock class. Pre-open configuration is serialized through existing round-scoped services; **RoundOpening** (GLS-29) will lock the `Round` and freeze configuration (including tracks and mystery rules) in one guarded transaction. Concurrent mystery/scoring consumers lock `MysteryHoleRule` rows via `:mystery_hole_rule`, not `:scoring_track`.

## Future row policy

V1 `:score_row` locks **`scorecards`** rows by Scorecard UUID (GLS-34). `:verification_row`, `:query_row`, and `:mystery_reveal` remain reserved; requests for unimplemented classes return `{:error, {:lock_class_not_yet_available, class}}`.

## Consumer contract (adopt later — not implemented in GLS-30)

Known consumers that must adopt this protocol:

- GLS-29 — RoundOpening (includes GLS-27 configuration-lock primitive inside the same transaction)
- GLS-33
- GLS-34
- GLS-35
- GLS-39
- GLS-41
- GLS-46
- GLS-47

GLS-30 does not retrofit OpenRound, role handover, hole submission, mystery reveal, verification, query resolution, side finalization, or round finalization/reopen.

## API (V1)

```elixir
LockProtocol.acquire!(
  round: [round_id],
  playing_group: [group_id],
  group_role_assignment: [assignment_id],
  competition_side: [side_id],
  competition_side_result: [result_id],
  mystery_hole_rule: [rule_id]
)
```

Returns `{:ok, %{acquired: [%{class:, id:, row:}, …]}}` in canonical order, or `{:error, reason}`.

Unknown keys: `{:error, {:unknown_lock_class, class}}`.

Non-list ID values: `{:error, {:invalid_lock_request, class}}` or `{:error, :invalid_lock_request}`.

Reserved future classes with IDs: `{:error, {:lock_class_not_yet_available, class}}`.

Inspect-only helpers: `relation_order/0`, `implemented_lock_classes/0` (closed list of classes with row-lock SQL in GLS-30).

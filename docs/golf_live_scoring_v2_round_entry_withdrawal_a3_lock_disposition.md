# GLS-42A A3 lock disposition for RoundEntry withdrawal

- **Status:** PROPOSED, NOT ADOPTED
- **Task:** GLS-42A-A3-L0
- **Reviewed baseline:** `main` at `51f02b35f0aad9e728dbaad6b8bbf88597d9b608`
- **Scope:** Lock order and caller compatibility for a future in-round withdrawal acceptance coordinator. No production code, migration, acceptance action, status mutation, or GLS-30 change is authorized by this proposal.

## Disposition

The existing top-level submission and role-handover paths share the Round row as their first gameplay lock. That row can serialize withdrawal with those paths. A `RoundEntry` row lock after the existing Round, PlayingGroup, and GroupRoleAssignment locks would not require a new GLS-30 class for the inspected top-level paths.

This is not enough to adopt the candidate. Three gaps remain:

1. `HandoverGroupRole`, `AssignGroupRole`, `ReplaceRoundEntry`, and the registration lifecycle actions do not reject an existing caller transaction. No in-repository production caller was found that wraps these paths in an outer transaction, and this review found no demonstrated deadlock. The services do not enforce the first-lock assumption, so the review cannot prove compatibility for caller-owned transactions that already hold lower-level rows.
2. The frozen scoring specification says withdrawal must recalculate dependent Side results. The candidate lock sequence does not say whether that recalculation is a derived read or a persisted `CompetitionSideResult` update. If it writes Side or SideResult rows, the candidate is incomplete and needs an approved order using the existing GLS-30 classes. This proposal does not infer that behavior.
3. A1 requires verified pre-play evidence but does not name a separate evidence record or fully specify the facts that satisfy that requirement. The route and assigned group start hole are persisted, but this proposal does not adopt them as the complete evidence contract without owner confirmation.

The proposed Round-gated sequence is therefore **not approved for A3 implementation**. Keep GLS-30 unchanged. Before adoption, resolve the caller-boundary contract, required Side-result effect, and pre-play evidence contract. Do not treat the source characterization tests below as proof of a withdrawal coordinator that does not exist.

## Authority reviewed

- `docs/golf_scoring_v2_lock_protocol.md` defines the GLS-30 order and transaction rules.
- `docs/golf_live_scoring_v2_round_entry_withdrawal_a1_adoption.md` adopts in-round withdrawal only, active Event Admin or Competition Manager authority, next-unsubmitted-hole semantics, preservation of Side membership and score history, and rejection of ambiguous evidence. It leaves the lock arrangement for A3 approval.
- `docs/golf_live_scoring_v2_spec_v1.0.md` defines terminal participation states in §56, Side continuation and independent verification in §46, and the `withdraw_round_entry` contract in §61.8. The frozen specification remains unchanged.
- A2 is implemented by `lib/golf_scoring/competition/round_entry_participation_ruling.ex` and `priv/repo/migrations/20261112165828_gls42a_round_entry_participation_rulings.exs`. The record stores accepted evidence only. It does not validate a checkpoint or write `RoundEntry.participation_status`.
- `docs/golf_live_scoring_v2_implementation_architecture.md` maps execution tracking to Plane project `GLS`. The connected project contains no matching GLS-42A/A3 item by the supplied task label or withdrawal wording. No issue was created.

## Proposed lock order, subject to owner approval

For a supported top-level staff acceptance, the candidate sequence is:

1. Begin a standalone `Repo.transaction/1`. Reject an already-open application transaction before acquiring any row lock.
2. Call `EventAuthorityLock.lock_scope!/2` for the Event and accepting staff member. Revalidate the active Event Admin or Competition Manager assignment while these locks remain held.
3. Call `LockProtocol.acquire!/1` for the target Round and PlayingGroup. It locks Round before PlayingGroup.
4. Read active GroupRoleAssignment IDs for that group and lock them through `LockProtocol.acquire!/1`. The protocol sorts IDs before `FOR UPDATE`.
5. Lock the target RoundEntry with a scoped `SELECT ... FOR UPDATE`. Revalidate its Event, Round, PlayingGroup, registration state, and `participation_status` from the locked row.
6. Read the route and accepted submission checkpoint, validate all guards, then write accepted A2 evidence, the `active` to `withdrawn` status change, and the required audit in the same transaction.
7. Commit. Publish any client notification only after commit.

`RoundEntry` is not a GLS-30 relation class. This proposal treats its explicit row lock as a scoped extension after the existing GLS-30 classes. It does not add a `:round_entry` key to `LockProtocol`, and it does not authorize acquiring any later GLS-30 class after that entry lock. This extension is only compatible if every supported writer reaches the same Round lock before it holds a conflicting lower-level row, and if the Side-result question above requires no later lock. A3 must fail closed when the standalone transaction requirement is not met.

## Lock matrix

`R` means the target Round, `G` the target PlayingGroup, `A` the active GroupRoleAssignment rows, and `E` a RoundEntry row. The order below describes source paths as written. Database locks remain held until the transaction commits or rolls back.

| Path | Observed acquisition order | Relevant writes and compatibility |
|---|---|---|
| `EventAuthorityLock.lock_scope!/3` (`lib/golf_scoring/accounts/event_authority_lock.ex:6-23,43-92`) | `Event FOR UPDATE` → active Event Admin IDs read → `StaffUser FOR UPDATE` by UUID → matching `EventStaffAssignment FOR UPDATE` by ID | This is outside GLS-30. Staff submission, handover, assignment, replacement, registration transitions, and A3 use this lock before gameplay rows. |
| `SubmitGroupHole`, staff actor (`lib/golf_scoring/scoring/services/submit_group_hole.ex:293-323,325-385,869-883,906-918,1002-1013,1117-1137,1364-1378`) | Event authority → `R` → `G` through `LockProtocol` → active `A` rows through `LockProtocol` → required `E` rows by ID with `FOR UPDATE` → Scorecards → score writes and audit → applicable MysteryHoleRule recheck | The submission and current required-entry set are re-read under the locks. It commits the whole hole or rolls back. PubSub runs after the transaction. A3 and submission serialize at `R` when both are standalone. |
| `SubmitGroupHole`, player actor (`lib/golf_scoring/scoring/services/submit_group_hole.ex:857-867,920-955`) | Player access grant lock and expiry validation → `R` → `G` → active `A` → required `E` rows → Scorecards → score writes and audit → applicable MysteryHoleRule recheck | Player submission does not acquire EventAuthorityLock. A3 does not lock the player grant, so `R` is their shared serialization row. Current `SubmitGroupHole` entrypoints reject an already-open transaction before this path. |
| `VerifyHoleResult`, player actor (`lib/golf_scoring/scoring/services/verify_hole_result.ex:20-75,78-95,109-137,183-206`) | Player access grant → `R` → `G` → active `A` → Scorecard → verifier `E` | This path locks Scorecard before verifier Entry, opposite the submission Entry-before-Scorecard order. Both paths reject an existing transaction and acquire `R` first among gameplay rows, preventing that pair from holding the conflicting lower locks while waiting for `R`. |
| `VerifyHoleResult`, staff override (`lib/golf_scoring/scoring/services/verify_hole_result.ex:20-75,97-105`) | Event authority → `R` → `G` → active `A` → Scorecard | The service rejects an existing transaction. It does not lock the verifier Entry for staff override. |
| `HandoverGroupRole` (`lib/golf_scoring/competition/services/handover_group_role.ex:21-50,72-154`) | Event authority → `R` → `G` → active `A` rows → replacement `E` → assignment update/create → audit | This is the in-play role writer. It revalidates the replacement after locking it. It has no `Repo.in_transaction?/0` entry guard. The direct top-level race tests cover handover and submission, but do not close caller-owned transaction composition. |
| `AssignGroupRole` (`lib/golf_scoring/competition/services/assign_group_role.ex:17-42,56-131`) | Event authority → `R` → `G` → active `A` rows → target `E` → assignment create | The Round guard limits assignment to `draft` or `ready`, so it cannot validly assign a role during A3's `scoring_open` state. The service has no existing-transaction guard. |
| `RevokeGroupRole` (`lib/golf_scoring/competition/services/revoke_group_role.ex:17-43,67-125`) | Event authority → `R` → `G` → active assignment → assignment update → audit | The Round guard limits revocation to `draft` or `ready`; it is not an in-play repair path. |
| `ReplaceRoundEntry` (`lib/golf_scoring/competition/services/replace_round_entry.ex:18-47,61-139`) | Event authority → `R` → read current group ID → `G` when present → scoped RoundCompetition and Side rows → original `E` → replacement checks and entry writes | Replacement only accepts `draft` or `ready` and a `not_started` original. The Round lock serializes it with A3; the service has no existing-transaction guard. |
| `RoundEntryLifecycleGuard` (`lib/golf_scoring/competition/round_entry_lifecycle_guard.ex:15-45,55-103,120-145`) | Event authority → `R` → `E` | Check-in, no-show, and `withdraw_before_start` change registration state only. They require participation to remain `not_started`. They do not implement in-round withdrawal and have no existing-transaction guard. |
| `RoundEntryScoringLifecycleGuard` (`lib/golf_scoring/competition/round_entry_scoring_lifecycle_guard.ex:10-80`) | Runs inside `SubmitGroupHole` after required `E` rows are locked and score evidence is written | It permits `not_started` to `active` only with verified submission progression and durable HoleResult evidence. It permits `active` to `completed` only with all scheduled results. It has no independent writer path. |
| Proposed A3 | Event authority → `R` → `G` → `A` → target `E` → checkpoint reads and validation → evidence/status/audit writes | No current implementation exists. This row describes a candidate only. |

### Explicit and implicit database locks

`LockProtocol.acquire!/1` uses one-row-at-a-time `SELECT ... FOR UPDATE` and canonical UUID ordering for `R`, `G`, and `A`. The direct entry locks in the services above use `SELECT ... FOR UPDATE`; `SubmitGroupHole` locks all required entries in `ORDER BY id` order. Ash updates later update rows already locked by the same transaction. Inserts into A2 and audit tables also cause PostgreSQL foreign-key checks to take key-share locks on referenced rows. The candidate must hold the mutable parent rows through the same transaction and must not acquire a new earlier lock after the Entry lock.

The current first-lock guards are material. `SubmitGroupHole` and `VerifyHoleResult` reject an existing transaction. `HandoverGroupRole`, `AssignGroupRole`, `RevokeGroupRole`, `ReplaceRoundEntry`, and the Ash registration actions do not. Their inspected application call graph did not show an in-repository production caller wrapping these operations in a transaction, but the entrypoints do not enforce that contract. A caller that holds `E`, a Scorecard, or another lower-level row and then invokes one of these paths could wait for Event authority or `R` while a standalone A3 transaction waits for the held row. That is a possible composition, not a demonstrated runtime deadlock.

## Withdrawal lifecycle and role guard

The proposed acceptance transition is `active` to `withdrawn` only.

- Accept only through an active Event Admin or Competition Manager assignment for the same Event. A player or scorer may request withdrawal, but the acceptance actor must satisfy the adopted A1 authority rule.
- Require an explicit reason and audit it. A2 does not store a reason field, so A3 must preserve it in the accepted audit record required by the frozen specification.
- Reject `not_started`, `completed`, `withdrawn`, and `disqualified` for ordinary in-round withdrawal. `not_started` uses the existing `withdraw_before_start` registration action and does not create an in-round participation ruling.
- Lock and re-read all active assignments for the group before checking the target Entry. If the target still holds an active primary-scorer or designated-verifier assignment, reject acceptance until a separate explicit handover succeeds. Do not silently reassign or revoke a role in the withdrawal transaction.
- Revalidate independent verification for any player or Side expected to continue under A1 D5 and frozen spec §46. A1 does not define the recovery outcome when no eligible independent verifier remains. That outcome needs owner direction before A3 can promise continued competitive eligibility.
- Insert the accepted A2 evidence, update the target `RoundEntry.participation_status`, and write the audit in one local transaction. Any failure rolls back all three. Do not edit existing HoleResults, change CompetitionSideMembership, or call `MysteryRevealCoordinator` as part of this acceptance.
- After commit, notify clients if needed. A failed or rolled-back acceptance must emit no PubSub event.

The frozen spec's §61.8 action row also says to recalculate dependent Side results. `CompetitionSideResult` stores readiness state and exclusion evidence; the A1 and A2 records do not say which of those rows withdrawal changes. Resolve whether this is a read-only derived recalculation or a persisted update. If A3 must update a Side or SideResult, this candidate is incomplete. Propose an order using only existing GLS-30 classes before implementation; do not add Side or SideResult locks after `E` without a separate compatibility proof. Do not resolve Mystery obligations or alter Side membership as a substitute.

## Checkpoint and ambiguity rules

The submission code already defines the authoritative route calculation (`lib/golf_scoring/scoring/services/submit_group_hole.ex:1002-1039,1070-1103`). It reads the 18 `RoundHole` rows by `play_order`, rotates that route at `PlayingGroup.starting_round_hole_id`, and selects the hole at the locked `scoring_revision`. A3 can reuse those persisted facts only after it holds `R` and `G` and re-reads them.

For an in-play withdrawal with accepted scoring, let `n` be the locked group `scoring_revision`:

- Require `1 <= n < 18`, an assigned start hole in the valid 18-hole route, and a target Entry whose locked participation state is `active`.
- Require exactly one accepted `HoleSubmission` for the latest accepted group revision, with `expected_group_score_revision = n - 1` and `round_hole_id` equal to the rotated route element at `n - 1`.
- Set `checkpoint_play_index = n - 1` and the effective next unsubmitted hole to the rotated route element at index `n`. Set `effective_play_index = n`.
- Set `preplay_boundary_confirmed` only after the coordinator validates persisted Round, route, group-start, and checkpoint facts. The A2 database check that this flag is true is a storage constraint, not proof of those facts. A1 does not name a separate pre-play evidence record; treating `scoring_open`, the valid ordered route, and the assigned start hole as the required evidence is an inference that the owner must confirm before adoption.
- Reject missing, duplicate, stale, or route-mismatched checkpoint rows; a missing start hole; a route other than the expected 18 holes; a completed group; or a client-supplied checkpoint that differs from the locked facts. Rejection writes nothing.

A zero-submission group is distinct from an active participant withdrawing after accepted scoring. The current scoring lifecycle can mark an Entry `active` only after a valid accepted HoleResult exists in the same SubmitGroupHole transaction. The A2 evidence shape also requires non-null checkpoint submission and checkpoint hole references. Therefore, if `n = 0`, an ordinary active-entry withdrawal is invalid. Reject an inconsistent `active` Entry with no accepted submission; use the existing pre-start registration withdrawal for a `not_started` Entry. Do not fabricate a checkpoint submission or effective-play evidence.

## Existing concurrency evidence

The following tests characterize current components. They were inspected for this proposal and were not run in this task.

- `test/golf_scoring/lock_protocol_test.exs:116-168,170-214,244-295`: tests row-lock blocking, canonical acquisition when callers request IDs in opposite orders, and lock release after rollback. These tests characterize GLS-30 primitives, not an A3 coordinator or a RoundEntry lock extension.
- `test/golf_scoring/scoring/services/submit_group_hole_test.exs:1336-1432`, `simultaneous submissions serialize on the playing group lock`: two accepted-command candidates serialize and only one revision advances.
- The same file's tests at `1434-1521` and `1523-1603` exercise both top-level lock winners for submission and handover and recheck scorer authority. They do not involve withdrawal or caller-owned transactions.
- `test/golf_scoring/competition/group_role_assignment_test.exs:470-500`, `completed, withdrawn, and disqualified participants cannot receive an in-play handover`: proves a withdrawn replacement is rejected after status is set. It does not race handover against withdrawal acceptance.
- `test/golf_scoring/scoring/services/submit_group_hole_test.exs:1605-1635`, `withdrawn participant is excluded from the next required result set`: manually sets participation to withdrawn and checks later result membership. It does not exercise accepted A2 evidence, atomic status change, or a concurrent withdrawal request.

No current test proves that withdrawal and submission, withdrawal and handover, evidence/status atomicity, checkpoint ambiguity rejection, or post-commit notification behavior work together.

## Required A3 integration tests

After this disposition and its open authority questions are approved, use independent PostgreSQL sessions, transaction barriers, and bounded lock/test timeouts. Exercise the actual acceptance coordinator and assert final database state, not only return values.

1. Run withdrawal against whole-hole submission in both Round-lock winner orders. If submission wins, withdrawal must checkpoint from that committed receipt and the next rotated hole. If withdrawal wins, a stale submission with the old active-player set must fail without score, receipt, audit, revision, or notification changes.
2. Run withdrawal against primary-scorer and designated-verifier handover in both winner orders. Assert that acceptance never leaves an active assignment on a withdrawn Entry, a handover never installs a withdrawn replacement, and all rejected operations leave assignments and audit history unchanged.
3. Test zero accepted submissions separately from accepted scoring. A `not_started` Entry must use pre-start registration withdrawal; an inconsistent active Entry without a receipt must fail closed.
4. Test shotgun route wraparound, current revision, exact latest receipt, missing or duplicate latest-revision receipts, stale client claims, invalid start hole, wrong route size, and completed groups. Every ambiguous checkpoint must leave A2 evidence, participation status, scores, audit, and PubSub unchanged.
5. Inject failures at accepted-evidence insertion, RoundEntry status update, and audit insertion. Assert the evidence and status always commit or roll back together, prior HoleResults remain unchanged, Side membership remains unchanged, and no Mystery obligation is resolved.
6. Test the standalone transaction guard before any authority or gameplay lock. Characterize any supported nested caller contract for handover and other competing writers before claiming global deadlock safety.
7. Once the Side-result effect is resolved, test its exact behavior and verify that any persisted Side/SideResult locks follow the approved GLS-30 order.

## Performance and scope

Keep acceptance inside one short local PostgreSQL transaction. Use existing EventAuthorityLock and GLS-30 row locks, indexed scope lookups, and no HTTP or PubSub while locks are held. The current schema provides a Round/PlayingGroup index for RoundEntry, a RoundEntry participation index, a group index for role assignments, a unique `(round_id, play_order)` route index, and scoped HoleSubmission indexes. A group has at most four entries and a route has 18 holes, so the latest-receipt lookup is bounded to one group's submissions. `HoleSubmission` has no index on `expected_group_score_revision`; do not assume an index on that field.

The Round row serializes all groups in the same Round, as it already does for current writers. This proposal makes no throughput or 100,000-user readiness claim. It adds no Redis lock, polling, process registry, or new infrastructure.

## Gate result

**STOP: do not adopt the sequence yet.** Source inspection supports Round serialization for current top-level submission, verification, role, and lifecycle paths. It does not establish a safe caller-owned transaction boundary for every competing writer, the frozen Side-result recalculation effect, or the exact persisted facts that satisfy A1's pre-play evidence requirement. Resolve those points with the owner, then approve or reject this proposal before A3 implementation. No GLS-30 change is proposed here.

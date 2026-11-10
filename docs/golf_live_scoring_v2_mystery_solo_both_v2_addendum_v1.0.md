# Mystery Solo BOTH V2 addendum v1.0

## Adoption record and implementation status

- Adoption date: 2026-11-09.
- Plane issue: [GLS-41](https://app.plane.so/symphony-development/browse/GLS-41).
- Owner-decision record: INTERNAL Plane comment `de91baf2-ecb7-431d-89fd-ea7e55490d34`.
- Frozen specification: `docs/golf_live_scoring_v2_spec_v1.0.md`.
- Frozen specification Git blob: `117eeb7745552f1f91beae3b1b96ae6dc85cfd69`.
- Repository baseline HEAD: `edeb541aaecc1a00fbb371318646c28828cd503b`.
- V2 policy identifier: `solo_both_2p_minus_one_v2`.

The owner approved the rule recorded in the referenced Plane comment. The agent
recorded that decision; the agent did not grant owner approval. The owner
separately authorized publication of this authority wording in Checkpoint 1B.2C.
The wording is submitted for independent Master Gate review.

This document publishes a policy contract. It does not implement the calculation
or establish that V2 is executable or deployed. Downstream implementation gates
remain open.

Immutable source reference:
[frozen specification at the baseline](https://github.com/JCSchoeman96/golf-scoring/blob/edeb541aaecc1a00fbb371318646c28828cd503b/docs/golf_live_scoring_v2_spec_v1.0.md).

## Scope and precedence

This addendum supplements frozen §40. It supersedes the earlier solo BOTH
calculation only for a RoundCompetition explicitly selecting
`solo_both_2p_minus_one_v2`.

The existing identifier `companion_max_p_minus_one_v1` retains its original
meaning, including `BOTH = P + max(P - 1, 0)`. No global alteration of V1 scoring
is permitted. The frozen source file remains unchanged. All unrelated frozen
authority, GLS-30 and existing adopted addenda remain intact, including the
[Scorecard review-clearance addendum](golf_live_scoring_v2_scorecard_review_addendum_v1.0.md).

## Exact scoring rules

For exactly one proven eligible and applicable contribution under V2:

```text
P = nonnegative integer individual Stableford/IPS points
V2 solo BOTH = (2 * P) - 1

P=0 -> -1
P=1 -> 1
P=2 -> 3
P=3 -> 5
P=4 -> 7
P=5 -> 9
```

The formula is exact. No clamping, floor-at-zero, rounding or alternative
normalization is permitted.

The other rules remain:

```text
solo BEST  = P
solo WORST = max(P - 1, 0)
two-player BOTH = P1 + P2
```

Solo BEST and WORST do not change under V2. Two-player BEST, WORST and BOTH
aggregation do not change. V1 solo BOTH remains zero when P is zero.

## Scoring concepts and evidence

Individual Stableford/IPS points are nonnegative values derived from a real
player's accepted golf outcome. They are not gross strokes. A format-permitted,
accepted picked-up/no-points outcome supplies individual P=0; it is not missing
evidence.

An eligible contribution is a real accepted individual result whose hole-level
applicability and countability are proven under the governing policy. A derived
Mystery side-hole result combines eligible contributions using the selected
version and Mystery rule. V2 solo BOTH may therefore produce -1.

This amendment permits -1 only as the V2-derived Mystery side-hole outcome,
not as individual Stableford points or a synthetic partner contribution. Totals
and tie-break components derived from valid signed side-hole values must preserve
their arithmetic; their executable contracts remain implementation gates.

A non-applicable contribution requires authoritative evidence that the player
need not contribute on that hole. A missing result means required evidence has
not been established. These conditions are not interchangeable.

Never create a fictitious partner HoleResult or write calculated points into raw
stroke facts. Do not silently reinterpret the generic nonnegative-contributor
calculator contract or change solo normalization to `[0, -1]`.

## Eligibility and applicability

Before applying V2 solo scoring, prove exactly one eligible/applicable
contribution, continued Side eligibility, authoritative V2 selection and current
accepted scoring evidence. No unresolved required partner contribution may be
silently ignored.

- Authorized intentional solo side: apply the selected version only after its
  permitted membership, eligibility and accepted contribution are established.
- Withdrawn partner: prove the effective hole-level non-applicability and the
  remaining Side's eligibility. Participation status alone is insufficient.
- Scoped disqualification: use explicit applicability/countability and Side
  consequences. DQ status alone neither establishes solo scoring nor excludes
  the whole Side.
- Missing partner score: leave eligibility unresolved; do not substitute zero
  or apply the solo formula.
- Pending/offline partner submission: unaccepted evidence does not establish
  non-applicability or solo eligibility.
- Both players eligible and applicable: require both accepted contributions and
  use ordinary two-player aggregation.
- No eligible contribution: do not manufacture zero, -1 or a scoring result.
- Partner joining later, where separately allowed: require the separate
  governing authority and effective membership/applicability evidence. This
  addendum grants no joining, replacement or participation transition.

Unknown or missing required evidence prevents V2 application. It does not permit
an eligibility inference from a smaller available result set.

## Version selection and lifecycle

Existing configuration defaults to V1. Selecting V2 is explicit, supported,
event-scoped pre-opening configuration, never an automatic conversion. Existing
V1 competitions remain V1 unless an authorized permitted pre-opening selection
changes the policy.

The following are normative requirements for future implementation, not claims
that the current actions enforce them all.

| Round state | Selection permitted | Authority, guards, audit and transaction |
| --- | --- | --- |
| `draft` | Yes, supported V1 or V2 | Authenticated active same-event Event Admin or Competition Manager; validate scope, expected current configuration and terms; EventAuthorityLock then serialized Round lock; selection and old/new policy audit commit atomically. |
| `ready` | Yes, supported V1 or V2 | Same authority, validation, stale-write protection and audit as draft; opening must revalidate the selected policy under the same Round boundary. |
| `scoring_open` | No ordinary mutation | Opening has frozen the validated version; reject changes before any policy mutation or success audit. |
| `scoring_closed` | No ordinary mutation | Closure does not unlock selection; retain the frozen version. |
| `finalized` | No ordinary mutation | Finalization and ordinary reopening do not unlock selection. |
| `cancelled` | No ordinary mutation | Cancellation grants no policy-edit pathway. |

Opening must validate and freeze the selected supported version atomically with
its existing opening guards and audit. Unauthorized, unsupported, stale or
cross-event selections must fail without changing configuration. Direct private
actions must not bypass the coordinator boundary.

Historical recalculation uses the actual frozen policy version, never a current
default. There is no automatic historical conversion or rescoring. Competition
terms must disclose the selected policy and possible V2 -1 result before opening.

## Implementation gates remain open

At the baseline:

- `RoundOpening.valid_competition?/2` admits only V1.
- `RoundCompetition.update_configuration_internal` does not itself prove
  post-opening freeze enforcement, although its configuration service checks
  Round state. A protected coordinator/action boundary remains required.
- `Countback.valid_points?/1` rejects negative per-hole contributions.
- `MysteryAggregation.calculate/2` accepts only nonnegative input contributions.
  Preserve that individual/V1 contributor contract; do not globally allow
  negative individual inputs to implement V2.
- Projection, ranking, serialization and UI support for signed derived Mystery
  values are not verified end to end. Unimplemented consumers are not thereby
  classified as defective.
- Authoritative participation eligibility, withdrawal and DQ evidence remain
  separate gates.

Allowing signed Countback input alone does not prove tie-break correctness. The
future implementation must preserve the locked Mystery-hole-subtotal and
subsequent standard-countback semantics separately, establish which track's
values each component uses and test that mapping. This addendum does not settle
that unresolved consumer contract by inference.

## Future security and integrity requirements

Use authoritative persisted policy selection and trusted event-scoped staff
authorization. Acquire EventAuthorityLock before the established Round/gameplay
lock order. Configuration and mandatory audit effects must commit or roll back
together. No private-action bypass, post-opening ordinary policy mutation or
silent retroactive rescoring is permitted.

Keep signed side/track outputs separate from nonnegative individual scoring
inputs. Preserve immutable score evidence and do not disclose unrevealed Mystery
rules through reads, diagnostics, notifications or client state. PostgreSQL
remains authoritative; this document introduces no cache or distributed lock.

## Exclusions and stop boundary

Publication does not authorize participation or DQ writers, scoring-pipeline
implementation, new calculators, a Scorecard evaluator, E3, Scorecard/SideResult
readiness transitions, a migration, a new leaderboard, historical-data changes,
production release or merge.

The other owner-approved participation/ruling design directions remain scheduled
for separate reconciliation. All existing evidence, writer, eligibility and
release gates remain open. PR #57 must remain Draft and unmerged pending
independent review. No historical unowned fixture may be modified.

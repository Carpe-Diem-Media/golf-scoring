# Scorecard review-clearance addendum v1.0

## Adoption record

The owner adopted the exact wording below against baseline
`f66cf23a09398b0764104e4e46040e4b3c09768f`.
The owner approval is recorded in Plane GLS-41 comment
`6fde06f4-9cb8-4849-93d5-6150ef964a82`.

Current status: owner-adopted authority wording only. The original proposed
wording, including its pre-approval DRAFT sentence, is reproduced unchanged
below. That pending owner approval has now been supplied by the referenced
owner decision. Document creation and publication were separately authorized
as a documentation-only checkpoint.

This adoption does not certify evidence or writer coverage. The following gates
remain open:

- Effective participation/ruling evidence.
- Post-start competition eligibility.
- Executable projection and policy coverage.
- Complete integrity-predicate coverage.
- Mystery caller-lock proof and remaining writer boundaries.

Staff-attention visibility and scorer/verifier agreement remain separate gates.
Neither evaluator, guarded actions nor E3 implementation is authorized.
The frozen specification and GLS-30 remain unchanged. PR #57 must remain Draft
and unmerged. No production migration is authorized. The historical fixture
with unverified ownership must remain unchanged.

## Exact adopted wording

**Golf Live Scoring V2 — Scorecard review-clearance addendum v1.0**

**Status:** DRAFT, pending explicit owner approval. Technical review does not adopt this document as authority or authorize implementation.

**Precedence:** This addendum supplements frozen §62.7 by authorizing guarded `review_required → in_progress` clearance and clarifying selection between that transition and `review_required → complete`. All unrelated frozen provisions, approved amendments and GLS-30 remain unchanged.

**Completeness:** Required scoring is classified as:

- `complete`: the applicable required-hole set is established and every required result is validly accounted for.
- `incomplete`: scope and applicability are established, but one or more required results are absent.
- `unknown`: scope, applicability, policy or required evidence cannot be established.

A known absent member Scorecard or unplayed required hole is evidence of incompleteness when membership and required participation are established. Unknown membership or participation policy is not ordinary incompleteness.

Completeness must use the authoritative Round route, current accepted HoleResults and applicable participation/ruling evidence. A raw count of eighteen, group progress counter, remembered state or client assertion is insufficient.

**Review evaluation:** Query/integrity review status is classified as:

- `clear`: every applicable predicate has been evaluated and no blocker exists.
- `blocked`: every applicable predicate has been evaluated and at least one known blocker exists.
- `not_evaluated`: required coverage or evidence remains unknown.

Known blockers may be reported alongside unknown evidence, but do not convert `not_evaluated` into `blocked` or `clear`.

**Scorecard clearance:** From `review_required`, permit:

- `clear` and `incomplete` → `in_progress`.
- `clear` and `complete` → `complete`.
- `blocked` → retain `review_required`.
- `not_evaluated` or `unknown` completeness → reject clearance without mutation.

Pending independent certification does not itself make scoring incomplete. Clearance never creates certification or transitions a card to `verified`.

Returning an incomplete card to `in_progress` while its Round is `scoring_closed` is descriptive only. It does not authorize further submission, reopen the Round or bypass an exceptional recovery workflow.

A final-hole submission during active review preserves `review_required`. Subsequent clearance derives completeness from current facts, including that submission.

**Side readiness:** Evaluate every applicable member and scoring track. Permit `review_required → ready_to_finalize` only when scoring completion, current-revision certification, unresolved-query absence, participation, eligibility and projection reproducibility are fully established. Otherwise retain review for known blockers or reject mutation on unknown required evidence. Never use a return to `provisional` as clearance.

Withdrawal or disqualification status alone does not establish hole non-applicability or competitive eligibility. Apply the authorized policy and effective ruling scope; otherwise return unknown.

**First integrated E3 workflow:** Unknown required completeness or readiness evidence causes the entire resolution transaction to roll back. Known remaining blockers may permit an audited dispute resolution while retaining the applicable review states and truthful blocker classifications. No decision-only exception is implied.

**Security and transactionality:** Read assessments are authorized snapshot observations, never write capabilities. Mutation must re-evaluate persisted evidence under the approved complete lock set. Query resolution, eligible clearance, conditional readiness changes and audit commit or roll back together.

Evaluation has no scoring, certification, reveal, audit or notification side effects. Unrevealed Mystery content must not appear in returned evidence or diagnostics.

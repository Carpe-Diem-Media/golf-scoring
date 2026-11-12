# GLS-42A A1 owner adoption: withdrawal-only MVP

**Status:** Adopted by the owner task instruction on 2026-11-12.

**Scope:** In-round RoundEntry withdrawal only. This record does not adopt disqualification behavior or a new shared lock protocol.

## Adopted decisions

- **D1. Effective hole.** Use the next unsubmitted hole in the authoritative rotated route, with verified pre-play evidence.
- **D3. Authority.** Require an active Event Admin or Competition Manager assignment for the same Event.
- **D4. Reversal and backdating.** Ordinary reversal and backdating are prohibited. Exceptional recovery requires separate authorization.
- **D5. Remaining partner.** The remaining partner may continue when the CompetitionSide remains eligible and independent score verification remains available.
- **D6. Ambiguous evidence.** Reject ambiguous evidence and leave applicability unknown.
- **D8. Historical data.** Do not create synthetic historical rulings or silently backfill them.

## Deferred decisions

- **D2 and D7. Disqualification.** Disqualification behavior remains deferred. This A1 adoption does not define disqualification semantics or add disqualification evidence.

## A2 implementation boundary

A2 defines the immutable PostgreSQL record shape for accepted `round_withdrawal` evidence. It does not add proposed or rejected ruling records, a write action, an acceptance coordinator, a client endpoint, a RoundEntry status mutation, scoring changes, or disqualification rules. The accepted ruling record does not change historical Side membership or score results.

The record may contain the route checkpoint, effective-hole reference, staff provenance, and required context needed by a later coordinator. A2 does not decide that a checkpoint is valid. A later coordinator must enforce the adopted decisions under an approved transaction and lock arrangement before inserting an accepted record.

## Unresolved technical constraints

- GLS-30 remains unchanged and does not define a RoundEntry lock class.
- The safe lock order for withdrawal against hole submission and role handover remains unapproved and unproven.
- A3 must not begin until the withdrawal-versus-submission and withdrawal-versus-handover lock arrangement has explicit approval and concurrency evidence.

## Authority precedence

This owner adoption supersedes conflicting withdrawal-only recommendations in the local GLS-42A L1 review proposal. It does not supersede the frozen scoring specification, `docs/golf_scoring_v2_lock_protocol.md` (GLS-30), or other adopted authority. The frozen specification remains unchanged.

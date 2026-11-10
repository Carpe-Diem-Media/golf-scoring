# Adoption record — CompetitionSide Retirement and Administrative Closure Addendum v1.0

**Current status:** Owner-adopted lifecycle/technical authority wording (Checkpoint 1B.3H). This document is an authority contract, **not** an implementation, migration, E3, deployment, PR-readiness or merge authorization.

**Adoption authority:** [Plane GLS-41](https://app.plane.so/symphony-development/browse/GLS-41), INTERNAL comment `ba2ee55b-cdf3-4a9d-a5dd-c16368be5c9b`.

**Approved source:** Exact 570-line R2A Markdown body, normalized to LF with no terminal newline, SHA-256 `9a14a5acafc21380338793bcf6319f94451a7c3a131f649ad2d1b22aad4206dc`.

**Frozen authority:** `docs/golf_live_scoring_v2_spec_v1.0.md`, Git blob `117eeb7745552f1f91beae3b1b96ae6dc85cfd69`; adopted additions and Plane decisions remain in force. Baseline PR #57 HEAD at adoption: `320444444f1c11f25b8e922194fb6aee0089588e`.

**Verbatim-preservation note:** The original owner-adopted R2A body is reproduced **unchanged** below. Its historical opening phrase “pending explicit authority approval” describes the draft *before* Checkpoint 1B.3H; the owner has since adopted that exact wording, as recorded above. This adoption record states the current authority status without changing the approved body or its fingerprint. Any substantive modification requires a new review and owner decision.

---

# CompetitionSide Retirement and Administrative Closure Addendum v1.0

## 1. Status and authority

Status: Proposed consolidated lifecycle wording, pending explicit
authority approval. Not published or implemented by this proposal.

Proposed document path:
docs/golf_live_scoring_v2_side_retirement_addendum_v1.0.md

Repository: JCSchoeman96/golf-scoring
Issue: GLS-41
Baseline: 320444444f1c11f25b8e922194fb6aee0089588e

Frozen specification:
docs/golf_live_scoring_v2_spec_v1.0.md

Frozen specification blob:
117eeb7745552f1f91beae3b1b96ae6dc85cfd69

Adopted owner business decisions:

- Side retirement:
  f755e61e-a509-4695-84cd-af2bd9eace69
- Retired Side administrative closure:
  efe404d3-78ae-4d72-a5a9-f343586c2390
- Post-closure shared-score correction:
  e83dc9cb-6803-47f3-b7ed-f1c06d795f0e
- Mystery Solo BOTH V2:
  de91baf2-ecb7-431d-89fd-ea7e55490d34

These records establish business authority. They do not establish that
the proposed resources, transitions, database protections or writers
exist.

This document proposes the lifecycle representation and enforcement
contract needed to implement those decisions. Adoption of this wording
does not authorize implementation or deployment.

## 2. Scope and precedence

Upon explicit adoption, this addendum supplements frozen §62.6 with a
separate terminal retired disposition and supplements §64.10 with
retired-result finalization predicates.

It does not replace ordinary competitive finalization or exclusion.

Frozen §61.15 certification and query semantics remain intact.
Mystery A2, its fixed global cohort and its three resolution outcomes
remain intact. GLS-30 lock ordering remains unchanged.

Existing Scorecard semantics and the adopted Scorecard review-clearance
addendum remain unchanged. This addendum does not authorize artificial
Scorecard completion or verification.

The adopted Mystery V1/V2 policies remain unchanged, including V2 solo
BOTH = 2P - 1 and P=0 producing -1.

The frozen specification source file shall remain unchanged.

## 3. Independent domain facts

The system shall distinguish:

1. RoundEntry participation.
2. CompetitionSide eligibility within one RoundCompetition.
3. Accepted immutable retirement evidence.
4. SideResult review and terminal administrative disposition.
5. Revision-specific score certification.
6. ScoreQuery lifecycle.
7. PlayingGroup operational progress.
8. Group-hole and global Mystery resolution.
9. Round finalization.

Side retirement shall not implicitly mutate RoundEntry participation,
finish a PlayingGroup, resolve a query, certify a score or reveal a
Mystery rule.

A golfer may continue legitimate group scoring for another competition.
The retired competition shall apply its authoritative prospective
boundary when determining applicable contributions.

No duplicate writable eligibility flag shall compete with accepted
retirement evidence as the source of prospective ineligibility.

## 4. Retirement business meaning

Retirement is non-punitive, prospective and specific to one
CompetitionSide in one RoundCompetition. Acceptance requires an
authorized, evidenced staff ruling and is distinct from individual
withdrawal, disqualification and punitive exclusion.

An accepted retirement ruling establishes prospective competitive
ineligibility from its validated effective boundary.

The retired Side is ineligible for official placing and prizes in that
RoundCompetition. Unrelated competitions and prizes are not
automatically forfeited.

Historical partial results may remain visible when clearly labelled
Retired. Accepted scores and revisions shall remain preserved.

Retirement is distinct from individual withdrawal, disqualification,
Side exclusion and ordinary successful finalization.

There is no ordinary reinstatement, ruling reversal or terminal-state
reversal. Exceptional recovery requires separate authority.

## 5. Accepted retirement evidence

An accepted ruling shall identify:

- Event, Round, RoundCompetition, Side and SideResult.
- Relevant PlayingGroup and membership scope.
- Authorizing staff actor and validated event authority.
- Reason and decision evidence.
- Command identity and canonical command meaning.
- Server-accepted group scoring checkpoint.
- Authoritative rotated route and prospective effective position.
- Physical-hole identity and supporting pre-play evidence.
- Applicable participation, eligibility and policy evidence.
- Mandatory acceptance audit.

Acceptance requires an active same-event Event Admin or Competition
Manager.

The effective boundary shall follow the authoritative accepted
checkpoint and rotated play order. Client timestamps shall not establish
ordering.

Accepted receipts remain preserved. A physically played but unaccepted
hole, pending offline evidence or unknown prior-play evidence shall not
be silently treated as unplayed.

If the proposed boundary cannot be established, acceptance shall reject
pending an authorized recovery or adjudication path.

Accepted ruling evidence is immutable. Exact retries return the original
accepted outcome without duplicate evidence or audit. Conflicting reuse
of a command identity rejects.

## 6. Proposed SideResult lifecycle

This section proposes new lifecycle authority. It does not describe
currently implemented support.

Authorized retirement acceptance shall apply:

- provisional -> review_required
- review_required -> review_required

Existing historical blockers shall remain present.

Independently authorized administrative closure shall apply:

- review_required -> retired

Subsequent authorized shared-score correction or reassessment shall
preserve:

- retired -> retired

The retired disposition is terminal. Ordinary transitions from retired
to review_required, finalized, excluded or provisional are prohibited.

An already excluded or finalized SideResult shall reject ordinary
retirement acceptance. A finalized Round shall reject mutation until
properly reopened under existing authority. Reopening a Round does not
reinstate a retired Side or authorize a terminal SideResult reversal.

Unsupported source states shall reject without mutation.

## 7. Retirement acceptance transaction

One coordinator shall own the acceptance transaction.

It shall atomically:

1. Validate current authority, scope, checkpoint and effective boundary.
2. Insert immutable retirement evidence.
3. Establish prospective Side-specific ineligibility.
4. Apply or preserve review_required.
5. Record the mandatory acceptance audit.
6. Perform any mandatory affected Mystery eligibility recheck.

Failure of any mandatory effect shall roll back the entire acceptance.

Acceptance shall not resolve historical ScoreQueries, clear review,
verify Scorecards, rewrite HoleResults, change score revisions or
manufacture future results.

A public coordinator that rejects nested transactions shall not be
called inside this transaction. Any future internal cooperation requires
an independently reviewed, transaction-bound proof contract.

Notifications occur only after commit.

## 8. Initial administrative closure

Closure is a separate authorized decision from retirement acceptance.

An active same-event Event Admin or Competition Manager shall authorize
closure through a guarded coordinator.

Before closure, the coordinator shall establish:

- Valid accepted retirement and effective scope.
- The complete applicable historical scoring set.
- Valid integrity and revision history.
- Independent certification or valid audited staff override for every
  applicable accepted current pre-retirement HoleResult revision.
- No applicable ScoreQuery may remain open or escalated. A query in
  resolved or lawfully dismissed status satisfies the query-status
  requirement only when its required decision, authorization and audit
  evidence are valid. Query termination does not waive current-revision
  certification or any other administrative-closure guard.
- Complete participation, ruling and applicability evidence.
- Resolution or positive non-applicability proof for the Side's
  applicable Mystery A2 obligations.
- Mandatory immutable assessment and closure audit.

Superseded historical revisions remain preserved. They do not require
fresh certification as current results.

Closure shall not require manufactured HoleResults, unplayed
future-hole scores, an artificial eighteen-hole Scorecard or a normal
verified Scorecard state that cannot lawfully represent the partial
retired history.

Unknown required evidence prevents closure.

The guarded transition, immutable assessment evidence and closure audit
shall commit atomically.

## 9. Immutable assessment provenance

Each immutable assessment item shall record:

- Retirement, Side, RoundCompetition, Round, Scorecard and HoleResult.
- Exact assessed HoleResult revision and validated scoring evidence.
- ScoreVerification identity.
- Observed certification kind, verified or overridden.
- For verification, the subject, verifier, role-assignment identity and
  version validated for that certification.
- For override, the responsible staff identity and immutable reason and
  audit evidence.
- Assessment identity, assessing actor, server-recorded time,
  applicable policy and scope-evidence versions, and assessment audit.

The writer shall validate complete relationships and certification
provenance under the owning transaction's locks. Foreign-key existence
alone is insufficient.

Later certification supersession shall not erase what the assessment
validly established at assessment time.

Historical assessment validity shall depend on its immutable snapshot
and validated provenance. It shall not require the certification row to
retain its former current-status value.

The snapshot is historical evidence, not another mutable certification
source. It shall not certify a later HoleResult revision.

Missing or contradictory provenance prevents assessment acceptance.

## 10. Complete current historical-review coverage

Terminal retirement, historical assessment validity and current
historical-review coverage are separate facts.

Current coverage is clear only when all required predicates are proven:

1. Valid retirement and immutable initial closure provenance exist for
   the exact Side and RoundCompetition.
2. Current eligibility, membership, route, participation, ruling,
   policy and scoring-scope evidence establishes the complete presently
   applicable historical result set.
3. That set is covered without gaps, duplicates or stale scope
   dependencies.
4. Every applicable accepted result's latest current revision has valid
   independent certification or an authorized audited override.
5. Immutable assessment evidence covers those exact current revisions
   and remains valid for their current scope dependencies.
6. Every required correction obligation targets the latest applicable
   revision and has matching valid assessment evidence.
7. No applicable open or escalated ScoreQuery remains.
8. Required historical integrity, audit and Side-specific Mystery
   predicates are proven.
9. No required predicate is unknown or unevaluated.

Previous immutable assessment items may contribute only while their
exact revisions remain current and their applicable eligibility,
membership, route, policy and scoring-scope evidence remains valid.

Otherwise coverage fails closed pending authorized reassessment or
recovery.

Neither retired state, absence of an obligation, a matching revision
number, an old certification identity nor a cached flag proves clearance.

Known failures remain visible as blockers. Unknown required predicates
prevent clearance even when other known blockers exist.

A new applicable unresolved query blocks coverage without requiring a
score correction.

Changed applicability or scope evidence prevents clearance until an
authorized workflow establishes valid current coverage.

Superseded certification preserves historical assessment evidence but
cannot certify a newer current revision. Contradictory certification and
revision evidence is an integrity blocker.

Newly discovered played-but-unaccepted history prevents clearance until
authorized recovery or adjudication establishes its treatment.

Query resolution alone does not clear unrelated predicates.

A complete approved integrity-predicate inventory and closed
authoritative writer inventory remain implementation prerequisites.

## 11. Shared-score corrections

Authorized shared HoleResult corrections may proceed after terminal
retirement, subject to Round lifecycle and every affected competition's
authorized correction rules.

Retirement grants no universal correction permission.

The correction shall preserve the original ruling, closure audit and
revision-specific assessment evidence.

A relevant correction shall atomically create the new score revision,
apply required certification handling, update all mandatory affected
competition effects, create or advance retirement reassessment
obligations, and record mandatory audit evidence.

The Side remains retired and unranked.

The correction must not silently corrupt another competition or block
its legitimate scoring solely because one affected Side is retired.

During pre-closure retirement review, a separately approved historical
correction workflow is required. Current narrow correction writers
shall not be represented as supporting it.

Current query, revision, certification and audit guards remain required.
No correction shall imply query resolution or artificial Scorecard
completion.

## 12. Reassessment obligations

Use one operational obligation per retirement and affected HoleResult.

It shall identify the latest required revision, triggering correction
evidence and any satisfying immutable assessment item.

Pending and satisfied are derived operational conditions. No independent
writable clearance flag is permitted.

Required transitions:

- Absent -> pending N+1:
  Relevant authorized correction creates the obligation atomically.
- Pending N+1 -> satisfied N+1:
  Reassessment succeeds only while N+1 remains current and all target,
  certification, query and integrity guards pass.
- Pending N+1 -> pending N+2:
  Further correction atomically advances the target.
- Satisfied N+1 -> pending N+2:
  Further correction advances the target and preserves prior evidence.
- Pending N+2 with assessment N+1:
  Reject as stale without satisfaction or success audit.
- Satisfied N+2 with an exact accepted retry:
  Return the original outcome without duplicate assessment or audit.

Targets shall never move backwards.

Satisfaction shall conditionally match the obligation identity, expected
target and current HoleResult revision. Exactly one intended obligation
must match.

The correction coordinator owns target creation and advancement.
The reassessment coordinator owns immutable assessment insertion,
conditional satisfaction and audit in one transaction.

An assessment of N+1 cannot clear a target for N+2.

Per-result satisfaction contributes to whole-Side coverage. It does not
certify other results or clear queries, scope or integrity predicates.

## 13. Historical query dependency

This addendum does not automatically authorize new ScoreQueries against
terminal retired results.

Post-closure query creation requires separately adopted historical-review
authority and a guarded workflow covering all affected sides.

Until that workflow is implemented, unsupported query-opening commands
shall reject without mutation.

A future independently authorized workflow shall:

- Validate trusted event-scoped authority and exact current revision.
- Establish applicable historical scope and unresolved-query uniqueness.
- Preserve retirement review for review_required SideResults.
- Preserve terminal retired disposition and original closure evidence.
- Block current coverage when a relevant query is opened.
- Preserve existing reassessment obligations.
- Apply every mandatory effect in other affected competitions.
- Commit query creation, mandatory effects and audit atomically.

Post-boundary scoring relevant only to another competition shall not
automatically invalidate this Side's historical coverage.

Finalized Rounds require proper reopening before authorized mutation.
Reopening does not reinstate the Side.

Query opening does not imply correction, certification, resolution or
reassessment satisfaction.

## 14. Group scoring and Mystery A2

Side retirement alone does not change RoundEntry participation.

Valid group submissions may continue for golfers with applicable
obligations in other competitions. Group progression may advance
normally while the retired competition excludes contributions from its
effective boundary.

The following remain separate:

- Side prospective ineligibility.
- Group-hole A2 resolution.
- Global Mystery reveal.
- Side administrative closure and current coverage.

The fixed global reveal cohort remains unchanged.

The only A2 resolution outcomes remain:

- SUBMITTED
- PAPER_RECOVERED
- NOT_APPLICABLE

Retirement is not another resolution outcome.

NOT_APPLICABLE requires current scoped proof that no applicable eligible
Side remained before physical play of the target hole.

Withdrawal, disqualification, retirement or finished_playing alone is
insufficient.

An accepted submission remains valid resolution evidence despite a later
ruling. Offline capture is not an accepted receipt.

Played or unknown physical holes shall not be labelled NOT_APPLICABLE
merely because no submission was accepted.

Side closure shall establish its applicable obligations without requiring
unrelated groups to complete the global cohort. It shall not falsely
resolve a shared group-hole still required by another eligible Side.

No hidden Mystery policy shall appear in unauthorized diagnostics,
notifications or errors.

## 15. Round finalization amendment

This section proposes the narrow extension to frozen §64.10.

Round finalization may recognize:

- Valid finalized eligible SideResults.
- Valid explicitly excluded terminal SideResults.
- Administratively closed retired SideResults with current historical
  review coverage.

A retired state with pending reassessment, unresolved applicable queries,
unknown scope or incomplete required coverage is not finalization-ready.

The finalization transaction shall recheck terminal provenance, current
revision certification, queries, participation and ruling evidence,
reassessment obligations, applicable Mystery obligations and required
reproducible scoring projections.

Retired Sides remain excluded from official placing and prizes.
Their partial accepted history remains reproducible.

Finalized Rounds prohibit scoring mutation until properly reopened.
Round reopening never implies Side reinstatement.

## 16. Transaction, locking and writer requirements

PostgreSQL is authoritative for rulings, assessments and obligations.

Each coupled command has one transaction owner.

Where required, acquire EventAuthorityLock before canonical gameplay
locks:

Round -> PlayingGroups -> active GroupRoleAssignments ->
CompetitionSides -> CompetitionSideResults -> Scorecards ->
MysteryHoleRules.

Acquire complete affected scope and canonical UUID ordering within each
class. Do not acquire an earlier class after a later class.

Reserved query, verification and reveal lock classes remain unavailable.

Existing RoundEntry FOR UPDATE usage and additional operational-row
locking require explicit compatible writer proof. This addendum does not
claim that proof is complete or create new GLS-30 lock classes.

Re-read authority, scope, revisions and guards under locks.

Private actions require exact transaction-bound coordinator proof.
public? false alone is insufficient.

All mandatory state, evidence and audit effects commit or roll back
together. Public exclusion coordinators shall not be naively nested.

Mystery rechecks require verified owning Round serialization and exact
caller scope. An open transaction alone is insufficient.

No external work occurs while database locks are held. PubSub and cache
invalidation occur after commit.

## 17. Database and implementation gates

Future implementation review shall establish:

- Scoped foreign keys and relationship consistency.
- Unique command identities and conflict detection.
- One accepted retirement outcome per Side under this policy.
- Database-enforced immutable accepted evidence.
- Revision-bound assessment provenance.
- Unique obligation identity per retirement and HoleResult.
- Monotonic target advancement and conditional satisfaction.
- Terminal disposition provenance and reversal protections.
- Indexed current-revision, membership and unresolved-query lookups.
- Closed authoritative writer coverage and safe legacy reconciliation.
- Compatible correction, certification, query and finalization writers.
- Verified Mystery caller and serialization boundaries.

Legacy records without proven coverage remain unknown.

Queries shall be bounded by RoundCompetition, Side, membership,
historical scope and result identity. No whole-event score scan is
required in the hot transaction.

Caches and read models may support presentation but cannot establish
authority or clearance. No Redis authority or evidence expiry is
introduced.

## 18. Exclusions

This addendum does not authorize:

- Source or database implementation.
- New resources, migrations or guarded actions.
- Participation or disqualification writers.
- Historical query authority reserved by section 13.
- Scorecard evaluators, clearance or E3.
- New scoring calculators or leaderboards.
- Silent historical rescoring.
- Ordinary reinstatement or exceptional recovery.
- Production deployment, PR readiness or merge.

Implementation requires separate scoped approval and independent review.

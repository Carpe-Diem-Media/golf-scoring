# GLS-34 Submit Group Hole Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement task-by-task.

**Goal:** Idempotent whole-hole `SubmitGroupHole` service with PlayingGroup scoring revision, `:score_row` locks, and lifecycle transitions per Master Gate JIT `8a4cd2f1-a19e-4169-9c18-cc9ee59c9c88`.

**Architecture:** One short `Repo.transaction` per new hole; LockProtocol order unchanged; server-derived expected hole from `starting_round_hole_id + scoring_revision + play_order` wrap; player grant + primary scorer or staff emergency authority; post-commit PubSub only.

**Tech Stack:** Elixir, Ash, AshPostgres, PostgreSQL row locks, `:crypto` SHA-256 fingerprint.

## Global Constraints

- BASE: `da50b4155df8013d94f9b1d253c7572ab2342c03` (continued from drifted main)
- Only migration: `playing_groups.scoring_revision`
- No MysteryReveal, UI, Redis, or second scoring path

---

### Task 1: PlayingGroup scoring_revision + lifecycle hooks

**Files:** `playing_group.ex`, `playing_group_lifecycle_guard.ex`, `changes/increment_playing_group_scoring_revision.ex`, Ash codegen migration/snapshot

- TDD: extend `playing_group_test.exs` for revision default 0 and increment action
- Add `scoring_revision` attribute, check constraint, `increment_scoring_revision_internal`
- Fix lifecycle guard for `mark_group_playing` / `mark_group_finished` on submit path

### Task 2: RoundEntry + Scorecard internal lifecycle actions

**Files:** `round_entry.ex`, `round_entry_scoring_lifecycle_guard.ex`, `scorecard.ex`, `scorecard_scoring_lifecycle_guard.ex`

- TDD in resource tests: `not_started→active`, `active→completed`, scorecard `not_started→in_progress→complete`

### Task 3: LockProtocol `:score_row`

**Files:** `lock_protocol.ex`, `docs/golf_scoring_v2_lock_protocol.md`, `lock_protocol_test.exs`

- TDD score_row FOR UPDATE, UUID order, transaction requirement

### Task 4: SubmitGroupHole service + domain wrapper

**Files:** `submit_group_hole.ex`, `scoring.ex`

- TDD comprehensive `submit_group_hole_test.exs` per ticket matrix

### Task 5: Verification + draft PR

- `mix precommit`, signed commits, draft PR, CI watch

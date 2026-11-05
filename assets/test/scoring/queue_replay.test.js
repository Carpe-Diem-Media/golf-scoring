import { expect, test } from "@playwright/test";

const eventId = "11111111-1111-4111-8111-111111111111";
const roundId = "22222222-2222-4222-8222-222222222222";
const groupId = "33333333-3333-4333-8333-333333333333";
const scorerId = "44444444-4444-4444-8444-444444444444";
const assignmentId = "55555555-5555-4555-8555-555555555555";
const secondPlayerId = "66666666-6666-4666-8666-666666666666";
const secondAssignmentId = "99999999-9999-4999-8999-999999999999";

function submission(index, capturedAt, { scorerId: selectedScorerId = scorerId, assignmentId: selectedAssignmentId = assignmentId } = {}) {
  const suffix = String(index).padStart(12, "0");

  return {
    scope: {
      event_id: eventId,
      round_id: roundId,
      playing_group_id: groupId,
      scorer: { type: "player", round_entry_id: selectedScorerId },
    },
    assignment: {
      id: selectedAssignmentId,
      round_entry_id: selectedScorerId,
      assignment_version: 3,
    },
    active_round_entry_ids: [scorerId, secondPlayerId],
    command: {
      client_submission_id: `88888888-8888-4888-8888-${suffix}`,
      playing_group_id: groupId,
      round_hole_id: `77777777-7777-4777-8777-${suffix}`,
      expected_group_score_revision: 8 + index - 1,
      role_assignment_version: 3,
      captured_at: capturedAt,
      results: [
        { round_entry_id: scorerId, outcome: "holed_out", gross_strokes: 4 + index },
        {
          round_entry_id: secondPlayerId,
          outcome: "picked_up",
          gross_strokes: null,
          strokes_taken: 5,
        },
      ],
    },
  };
}

async function enqueueInBrowser(page, commands) {
  return page.evaluate(async (inputs) => {
    const { enqueueSubmission } = await import("/scoring/queue.js");
    const saved = [];
    for (const input of inputs) saved.push(await enqueueSubmission(input));
    return saved;
  }, commands);
}

async function sequenceRecordInBrowser(page, scope) {
  return page.evaluate(async (scoringScope) => {
    const { scopeKeyFor } = await import("/scoring/submission_serializer.js");
    const { openScoringDatabase, SCORING_STORE_NAMES } = await import("/scoring/indexed_db.js");
    const db = await openScoringDatabase();
    try {
      const transaction = db.transaction(SCORING_STORE_NAMES.sequences, "readonly");
      const request = transaction.objectStore(SCORING_STORE_NAMES.sequences).get(scopeKeyFor(scoringScope));
      let result;
      request.onsuccess = () => { result = request.result; };
      await new Promise((resolve, reject) => {
        transaction.oncomplete = resolve;
        transaction.onabort = () => reject(transaction.error);
        transaction.onerror = () => reject(transaction.error);
      });
      return result || null;
    } finally {
      db.close();
    }
  }, scope);
}

async function updateSequenceRecordInBrowser(page, scope, changes) {
  return page.evaluate(async ({ scoringScope, changes }) => {
    const { scopeKeyFor } = await import("/scoring/submission_serializer.js");
    const { openScoringDatabase, SCORING_STORE_NAMES } = await import("/scoring/indexed_db.js");
    const db = await openScoringDatabase();
    try {
      const transaction = db.transaction(SCORING_STORE_NAMES.sequences, "readwrite");
      const store = transaction.objectStore(SCORING_STORE_NAMES.sequences);
      const request = store.get(scopeKeyFor(scoringScope));
      request.onsuccess = () => {
        if (request.result) store.put({ ...request.result, ...changes });
      };
      await new Promise((resolve, reject) => {
        transaction.oncomplete = resolve;
        transaction.onabort = () => reject(transaction.error);
        transaction.onerror = () => reject(transaction.error);
      });
    } finally {
      db.close();
    }
  }, { scoringScope: scope, changes });
}

async function replayInBrowser(page, scopeOrCommands, options = {}) {
  const scope = Array.isArray(scopeOrCommands) ? scopeOrCommands[0].scope : scopeOrCommands;
  return page.evaluate(async ({ scope, options }) => {
    try {
      const { createConnectionState } = await import("/scoring/connection_state.js");
      const { recoverPending } = await import("/scoring/queue.js");
      const calls = [];
      const attempts = new Map();
      const controller = createConnectionState({
        scope,
        isOnline: () => options.online !== false,
        ...(options.withoutLocks ? { lockManager: null } : {}),
        transport: async (command, context) => {
          const attempt = (attempts.get(context.sequence) || 0) + 1;
          attempts.set(context.sequence, attempt);
          calls.push({
            submissionId: command.client_submission_id,
            sequence: context.sequence,
            command: structuredClone(command),
          });
          const plan = options.responses?.[context.sequence]?.[attempt - 1];
          if (plan?.status === "throw") throw new Error(plan.message || "transport timed out");
          if (plan?.status === "rejected") {
            return { status: "rejected", reason: plan.reason };
          }
          if (plan?.status === "invalidate-sequence-before-rejection") {
            const { openScoringDatabase, SCORING_STORE_NAMES } = await import("/scoring/indexed_db.js");
            const db = await openScoringDatabase();
            const transaction = db.transaction(SCORING_STORE_NAMES.sequences, "readwrite");
            const store = transaction.objectStore(SCORING_STORE_NAMES.sequences);
            const request = store.get(context.scope_key);
            request.onsuccess = () => store.put({ ...request.result, last_sequence: "unavailable" });
            await new Promise((resolve, reject) => {
              transaction.oncomplete = resolve;
              transaction.onabort = () => reject(transaction.error);
              transaction.onerror = () => reject(transaction.error);
            });
            db.close();
            return { status: "rejected", reason: plan.reason };
          }

          let receipt = window.__scoringTestReceipt(command, context);
          if (plan?.status === "malformed") {
            receipt = { ...receipt, client_submission_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" };
          }
          if (plan?.status === "replace-before-ack") {
            const { openScoringDatabase, SCORING_STORE_NAMES } = await import("/scoring/indexed_db.js");
            const db = await openScoringDatabase();
            const transaction = db.transaction(SCORING_STORE_NAMES.pending, "readwrite");
            const store = transaction.objectStore(SCORING_STORE_NAMES.pending);
            const recordKey = JSON.stringify([
              context.scope_key,
              command.client_submission_id.toLowerCase(),
            ]);
            const request = store.get(recordKey);
            request.onsuccess = () => {
              const stored = request.result;
              stored.command.results[0].gross_strokes += 2;
              store.put(stored);
            };
            await new Promise((resolve, reject) => {
              transaction.oncomplete = resolve;
              transaction.onabort = () => reject(transaction.error);
              transaction.onerror = () => reject(transaction.error);
            });
            db.close();
          }

          return {
            status: "accepted",
            ...(plan?.status === "duplicate" ? { duplicate: true } : {}),
            receipt,
          };
        },
      });
      const states = [await controller.replay()];
      const pendingSnapshots = [
        (await recoverPending(scope)).map(({ sequence, command }) => ({ sequence, command })),
      ];
      for (let retry = 1; retry < (options.replayCount || 1); retry += 1) {
        states.push(await controller.replay());
        pendingSnapshots.push(
          (await recoverPending(scope)).map(({ sequence, command }) => ({ sequence, command })),
        );
      }
      return {
        state: states.at(-1),
        states,
        calls,
        pendingSnapshots,
        pending: pendingSnapshots.at(-1),
        conflict: controller.conflict,
      };
    } catch (error) {
      return { moduleError: error.name, message: error.message };
    }
  }, { scope, options });
}

async function recoverAfterIntentInBrowser(page, scope) {
  return page.evaluate(async (scoringScope) => {
    const { createConnectionState } = await import("/scoring/connection_state.js");
    const { recoverPending } = await import("/scoring/queue.js");
    const calls = [];
    const controller = createConnectionState({
      scope: scoringScope,
      isOnline: () => true,
      transport: async (command, context) => {
        calls.push(command.client_submission_id);
        return {
          status: "accepted",
          receipt: window.__scoringTestReceipt(command, context),
        };
      },
    });
    const before = await controller.refresh();
    const automatic = await controller.replay();
    const withoutAuthorization = await controller.recover();
    const afterAuthorization = await controller.recover({
      authorize: async ({ scope_key, conflict, assignment }) => ({
        status: "authorized",
        scope_key,
        submission_id: conflict.submission_id,
        assignment_id: assignment.id,
        assignment_version: assignment.assignment_version,
      }),
    });
    const replayed = await controller.replay();
    return {
      before,
      automatic,
      withoutAuthorization,
      afterAuthorization,
      replayed,
      calls,
      pending: await recoverPending(scoringScope),
    };
  }, scope);
}

test.beforeEach(async ({ page, context }) => {
  await context.addInitScript(() => {
    window.__scoringTestReceipt = (command, context) => ({
      id: command.client_submission_id,
      client_submission_id: command.client_submission_id,
      round_id: context.scope.round_id,
      playing_group_id: command.playing_group_id,
      round_hole_id: command.round_hole_id,
      expected_group_score_revision: command.expected_group_score_revision,
      group_role_assignment_id: context.assignment.id,
      role_assignment_version: command.role_assignment_version,
      submitted_by_round_entry_id: context.scope.scorer.round_entry_id,
      payload_fingerprint: "a".repeat(64),
      captured_at: command.captured_at,
      submitted_payload: {
        playing_group_id: command.playing_group_id,
        round_hole_id: command.round_hole_id,
        expected_group_score_revision: command.expected_group_score_revision,
        role_assignment_version: command.role_assignment_version,
        captured_at: command.captured_at,
        actor: {
          type: "player",
          round_entry_id: context.scope.scorer.round_entry_id,
          role_assignment_version: command.role_assignment_version,
        },
        results: command.results.map((result) => ({
          ...result,
          strokes_taken: result.strokes_taken ?? null,
        })).sort((left, right) => left.round_entry_id.localeCompare(right.round_entry_id)),
      },
    });
  });
  await page.goto("/");
});

test("replays commands in stored sequence and reaches caught up after valid receipts", async ({ page }) => {
  const commands = [
    submission(1, "2026-11-05T12:00:00.000Z"),
    submission(2, "2026-11-04T12:00:00.000Z"),
  ];
  await enqueueInBrowser(page, commands);

  const result = await replayInBrowser(page, commands);
  const sequenceRecord = await sequenceRecordInBrowser(page, commands[0].scope);

  expect(result.moduleError).toBeUndefined();
  expect(result.state).toBe("CAUGHT_UP");
  expect(result.calls).toEqual([
    {
      submissionId: commands[0].command.client_submission_id,
      sequence: 1,
      command: commands[0].command,
    },
    {
      submissionId: commands[1].command.client_submission_id,
      sequence: 2,
      command: commands[1].command,
    },
  ]);
  expect(result.pending).toEqual([]);
  expect(sequenceRecord.replay_intent).toBeUndefined();
});

test("valid acknowledgement removes only its matching command", async ({ page }) => {
  const commands = [
    submission(1, "2026-11-05T12:00:00.000Z"),
    submission(2, "2026-11-04T12:00:00.000Z"),
  ];
  await enqueueInBrowser(page, commands);

  const result = await replayInBrowser(page, commands, {
    responses: { 2: [{ status: "throw" }] },
  });

  expect(result.state).toBe("PENDING");
  expect(result.calls.map(({ sequence }) => sequence)).toEqual([1, 2]);
  expect(result.pending).toEqual([{ sequence: 2, command: commands[1].command }]);
});

test("moves offline capture to pending only after the whole-hole command is stored", async ({ page }) => {
  const input = submission(1, "2026-11-05T12:00:00.000Z");
  const result = await page.evaluate(async (command) => {
    const { createConnectionState } = await import("/scoring/connection_state.js");
    const controller = createConnectionState({
      scope: command.scope,
      isOnline: () => false,
      lockManager: null,
      transport: async () => {
        throw new Error("offline commands must not be submitted");
      },
    });
    const initial = controller.state;
    const saved = await controller.persistSubmission(command);
    const state = await controller.refresh();
    return { initial, state, savedState: saved.state };
  }, input);

  expect(result).toEqual({ initial: "OFFLINE", state: "PENDING", savedState: "PERSISTED" });
});

test("retries an uncertain submission with the original retry key and payload", async ({ page }) => {
  const commands = [
    submission(1, "2026-11-05T12:00:00.000Z"),
    submission(2, "2026-11-04T12:00:00.000Z"),
  ];
  await enqueueInBrowser(page, commands);

  const result = await replayInBrowser(page, commands, {
    replayCount: 2,
    responses: { 1: [{ status: "throw" }, { status: "duplicate" }] },
  });

  expect(result.states).toEqual(["PENDING", "CAUGHT_UP"]);
  expect(result.pendingSnapshots[0]).toHaveLength(2);
  expect(result.pending).toEqual([]);
  expect(result.calls.map(({ submissionId }) => submissionId)).toEqual([
    commands[0].command.client_submission_id,
    commands[0].command.client_submission_id,
    commands[1].command.client_submission_id,
  ]);
  expect(result.calls[0].command).toEqual(commands[0].command);
  expect(result.calls[1].command).toEqual(commands[0].command);
  expect(result.calls[0].command.client_submission_id).toBe(
    result.calls[1].command.client_submission_id,
  );
});

test("blocks an unresolved replay intent after a browser restart", async ({ page }) => {
  const command = submission(1, "2026-11-05T12:00:00.000Z");
  await enqueueInBrowser(page, [command]);

  const interrupted = await replayInBrowser(page, command.scope, {
    responses: { 1: [{ status: "throw" }] },
  });
  await page.reload();
  const recovered = await replayInBrowser(page, command.scope);

  expect(interrupted.state).toBe("PENDING");
  expect(interrupted.calls).toHaveLength(1);
  expect(recovered.state).toBe("CONFLICT_STOP");
  expect(recovered.calls).toEqual([]);
  expect(recovered.pending).toEqual([{ sequence: 1, command: command.command }]);
});

test("does not transmit when the pre-send replay intent cannot be persisted", async ({ page }) => {
  const command = submission(1, "2026-11-05T12:00:00.000Z");
  await enqueueInBrowser(page, [command]);
  await updateSequenceRecordInBrowser(page, command.scope, { last_sequence: "unavailable" });

  const result = await replayInBrowser(page, command.scope);

  expect(result.state).toBe("PENDING");
  expect(result.calls).toEqual([]);
  expect(result.pending).toEqual([{ sequence: 1, command: command.command }]);
});

test("keeps a command pending when the transport returns a malformed receipt", async ({ page }) => {
  const command = submission(1, "2026-11-05T12:00:00.000Z");
  await enqueueInBrowser(page, [command]);

  const result = await replayInBrowser(page, command.scope, {
    responses: { 1: [{ status: "malformed" }] },
  });

  expect(result.state).toBe("PENDING");
  expect(result.calls).toHaveLength(1);
  expect(result.pending).toEqual([{ sequence: 1, command: command.command }]);
});

test("does not acknowledge a command from a receipt that only repeats its retry key", async ({ page }) => {
  const command = submission(1, "2026-11-05T12:00:00.000Z");
  await enqueueInBrowser(page, [command]);

  const result = await page.evaluate(async (scope) => {
    const { acknowledgeSubmission, recoverPending } = await import("/scoring/queue.js");
    const pending = await recoverPending(scope);
    const acknowledged = await acknowledgeSubmission(pending[0], {
      client_submission_id: pending[0].command.client_submission_id,
    });
    return { acknowledged, pending: await recoverPending(scope) };
  }, command.scope);

  expect(result.acknowledged).toBe(false);
  expect(result.pending).toHaveLength(1);
  expect(result.pending[0].command).toEqual(command.command);
});

for (const [label, reason] of [
  ["stale scorer", "stale_role_assignment"],
  ["changed assignment", "idempotency_actor_mismatch"],
  ["wrong group revision", "stale_scoring_revision"],
  ["wrong hole progression", "wrong_round_hole"],
  ["payload fingerprint conflict", "idempotency_payload_conflict"],
]) {
  test(`stops replay on ${label} and retains the rejected command`, async ({ page }) => {
    const command = submission(1, "2026-11-05T12:00:00.000Z");
    await enqueueInBrowser(page, [command]);

    const result = await replayInBrowser(page, command.scope, {
      responses: { 1: [{ status: "rejected", reason }] },
    });

    expect(result.state).toBe("CONFLICT_STOP");
    expect(result.conflict).toMatchObject({
      submission_id: command.command.client_submission_id,
      sequence: 1,
      reason,
    });
    expect(result.calls).toHaveLength(1);
    expect(result.pending).toEqual([{ sequence: 1, command: command.command }]);
  });
}

test("preserves the rejected and all later commands after the first conflict", async ({ page }) => {
  const commands = [
    submission(1, "2026-11-05T12:00:00.000Z"),
    submission(2, "2026-11-04T12:00:00.000Z"),
    submission(3, "2026-11-03T12:00:00.000Z"),
  ];
  await enqueueInBrowser(page, commands);

  const result = await replayInBrowser(page, commands, {
    responses: { 2: [{ status: "rejected", reason: "wrong_round_hole" }] },
  });

  expect(result.state).toBe("CONFLICT_STOP");
  expect(result.calls.map(({ submissionId }) => submissionId)).toEqual([
    commands[0].command.client_submission_id,
    commands[1].command.client_submission_id,
  ]);
  expect(result.pending.map(({ sequence }) => sequence)).toEqual([2, 3]);
  expect(result.pending.map(({ command: pending }) => pending)).toEqual([
    commands[1].command,
    commands[2].command,
  ]);
});

test("recovers persisted commands after a browser reload", async ({ page }) => {
  const command = submission(1, "2026-11-05T12:00:00.000Z");
  await enqueueInBrowser(page, [command]);
  await page.reload();

  const result = await replayInBrowser(page, command.scope);

  expect(result.state).toBe("CAUGHT_UP");
  expect(result.calls).toHaveLength(1);
  expect(result.calls[0].command).toEqual(command.command);
  expect(result.pending).toEqual([]);
});

test("does not delete a queue record replaced while its receipt is in flight", async ({ page }) => {
  const command = submission(1, "2026-11-05T12:00:00.000Z");
  await enqueueInBrowser(page, [command]);

  const result = await replayInBrowser(page, command.scope, {
    responses: { 1: [{ status: "replace-before-ack" }] },
  });

  expect(result.state).toBe("PENDING");
  expect(result.pending).toEqual([{
    sequence: 1,
    command: {
      ...command.command,
      results: [
        { ...command.command.results[0], gross_strokes: command.command.results[0].gross_strokes + 2 },
        command.command.results[1],
      ],
    },
  }]);
});

test("fails closed when the browser has no cross-tab lock manager", async ({ page }) => {
  const command = submission(1, "2026-11-05T12:00:00.000Z");
  await enqueueInBrowser(page, [command]);

  const result = await replayInBrowser(page, command.scope, { withoutLocks: true });

  expect(result.state).toBe("PENDING");
  expect(result.calls).toEqual([]);
  expect(result.pending).toEqual([{ sequence: 1, command: command.command }]);
});

test("does not automatically replay a conflict after browser recovery", async ({ page }) => {
  const command = submission(1, "2026-11-05T12:00:00.000Z");
  await enqueueInBrowser(page, [command]);

  const stopped = await replayInBrowser(page, command.scope, {
    responses: { 1: [{ status: "rejected", reason: "stale_role_assignment" }] },
  });
  await page.reload();
  const recovered = await replayInBrowser(page, command.scope);

  expect(stopped.state).toBe("CONFLICT_STOP");
  expect(recovered.state).toBe("CONFLICT_STOP");
  expect(recovered.calls).toEqual([]);
  expect(recovered.pending).toEqual([{ sequence: 1, command: command.command }]);
});

test("retains the durable intent when conflict persistence fails, then requires authorization after storage recovery", async ({ page }) => {
  const command = submission(1, "2026-11-05T12:00:00.000Z");
  await enqueueInBrowser(page, [command]);

  const rejected = await replayInBrowser(page, command.scope, {
    responses: { 1: [{ status: "invalidate-sequence-before-rejection", reason: "stale_role_assignment" }] },
  });
  const failedStorage = await sequenceRecordInBrowser(page, command.scope);
  await updateSequenceRecordInBrowser(page, command.scope, { last_sequence: 1 });
  await page.reload();
  const recovered = await recoverAfterIntentInBrowser(page, command.scope);

  expect(rejected.state).toBe("CONFLICT_STOP");
  expect(failedStorage.conflict_stop).toBeUndefined();
  expect(failedStorage.replay_intent).toMatchObject({
    submission_id: command.command.client_submission_id,
    sequence: 1,
  });
  expect(recovered.before).toBe("CONFLICT_STOP");
  expect(recovered.automatic).toBe("CONFLICT_STOP");
  expect(recovered.withoutAuthorization).toBe("CONFLICT_STOP");
  expect(recovered.afterAuthorization).toBe("RECOVERY");
  expect(recovered.replayed).toBe("CAUGHT_UP");
  expect(recovered.calls).toEqual([command.command.client_submission_id]);
  expect(recovered.pending).toEqual([]);
});

test("keeps the conflict stop when a later command is queued before browser recovery", async ({ page }) => {
  const commands = [
    submission(1, "2026-11-05T12:00:00.000Z"),
    submission(2, "2026-11-04T12:00:00.000Z"),
  ];
  await enqueueInBrowser(page, [commands[0]]);
  await replayInBrowser(page, commands[0].scope, {
    responses: { 1: [{ status: "rejected", reason: "stale_role_assignment" }] },
  });
  await enqueueInBrowser(page, [commands[1]]);
  await page.reload();

  const recovered = await replayInBrowser(page, commands);

  expect(recovered.state).toBe("CONFLICT_STOP");
  expect(recovered.calls).toEqual([]);
  expect(recovered.pending).toEqual([
    { sequence: 1, command: commands[0].command },
    { sequence: 2, command: commands[1].command },
  ]);
});

test("requires explicit renewed authorization before leaving conflict stop", async ({ page }) => {
  const command = submission(1, "2026-11-05T12:00:00.000Z");
  await enqueueInBrowser(page, [command]);
  await replayInBrowser(page, command.scope, {
    responses: { 1: [{ status: "rejected", reason: "stale_role_assignment" }] },
  });
  await page.reload();

  const result = await page.evaluate(async (scope) => {
    const { createConnectionState } = await import("/scoring/connection_state.js");
    const { recoverPending } = await import("/scoring/queue.js");
    const calls = [];
    const controller = createConnectionState({
      scope,
      isOnline: () => true,
      transport: async (storedCommand, context) => {
        calls.push(storedCommand.client_submission_id);
        return {
          status: "accepted",
          receipt: window.__scoringTestReceipt(storedCommand, context),
        };
      },
    });
    if (typeof controller.recover !== "function") {
      return { missingRecover: true, state: await controller.refresh() };
    }

    const before = await controller.refresh();
    const automatic = await controller.replay();
    const withoutAuthorization = await controller.recover();
    const recovery = await controller.recover({
      authorize: async ({ scope_key, conflict, assignment }) => ({
        status: "authorized",
        scope_key,
        submission_id: conflict.submission_id,
        assignment_id: assignment.id,
        assignment_version: assignment.assignment_version,
      }),
    });
    const replayed = await controller.replay();
    return {
      before,
      automatic,
      withoutAuthorization,
      recovery,
      replayed,
      calls,
      pending: await recoverPending(scope),
    };
  }, command.scope);

  expect(result.missingRecover).toBeUndefined();
  expect(result.before).toBe("CONFLICT_STOP");
  expect(result.automatic).toBe("CONFLICT_STOP");
  expect(result.withoutAuthorization).toBe("CONFLICT_STOP");
  expect(result.recovery).toBe("RECOVERY");
  expect(result.replayed).toBe("CAUGHT_UP");
  expect(result.calls).toEqual([command.command.client_submission_id]);
  expect(result.pending).toEqual([]);
});

test("serializes different scorers replaying the same group across tabs", async ({ page, context }) => {
  const firstCommand = submission(1, "2026-11-05T12:00:00.000Z");
  const secondCommand = submission(2, "2026-11-04T12:00:00.000Z", {
    scorerId: secondPlayerId,
    assignmentId: secondAssignmentId,
  });
  await enqueueInBrowser(page, [firstCommand]);
  await page.evaluate(async (scope) => {
    const { createConnectionState } = await import("/scoring/connection_state.js");
    let resolveStarted;
    let resolveTransport;
    let submittedCommand;
    let submittedContext;
    const started = new Promise((resolve) => { resolveStarted = resolve; });
    const controller = createConnectionState({
      scope,
      isOnline: () => true,
      transport: (storedCommand, context) => {
        submittedCommand = storedCommand;
        submittedContext = context;
        window.__heldCalls = [{
          submissionId: storedCommand.client_submission_id,
          sequence: context.sequence,
        }];
        resolveStarted();
        return new Promise((resolve) => { resolveTransport = resolve; });
      },
    });
    window.__heldRelease = () => resolveTransport({
      status: "accepted",
      receipt: window.__scoringTestReceipt(submittedCommand, submittedContext),
    });
    window.__heldController = controller;
    window.__heldReplay = controller.replay();
    await started;
  }, firstCommand.scope);

  const secondPage = await context.newPage();
  await secondPage.goto("/");
  await enqueueInBrowser(secondPage, [secondCommand]);
  const secondTab = await replayInBrowser(secondPage, secondCommand.scope);
  const heldState = await page.evaluate(() => ({
    state: window.__heldController.state,
    calls: window.__heldCalls,
  }));
  await page.evaluate(() => window.__heldRelease());
  const firstTabState = await page.evaluate(() => window.__heldReplay);

  expect(heldState.state).toBe("REPLAYING");
  expect(heldState.calls).toEqual([{
    submissionId: firstCommand.command.client_submission_id,
    sequence: 1,
  }]);
  expect(secondTab.state).toBe("PENDING");
  expect(secondTab.calls).toEqual([]);
  expect(secondTab.pending).toEqual([{ sequence: 1, command: secondCommand.command }]);
  expect(firstTabState).toBe("CAUGHT_UP");
});

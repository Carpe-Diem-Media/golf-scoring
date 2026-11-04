import { expect, test } from "@playwright/test";

const eventId = "11111111-1111-4111-8111-111111111111";
const roundId = "22222222-2222-4222-8222-222222222222";
const groupId = "33333333-3333-4333-8333-333333333333";
const otherGroupId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const scorerId = "44444444-4444-4444-8444-444444444444";
const assignmentId = "55555555-5555-4555-8555-555555555555";
const secondPlayerId = "66666666-6666-4666-8666-666666666666";
const thirdPlayerId = "99999999-9999-4999-8999-999999999999";
const fourthPlayerId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const holeId = "77777777-7777-4777-8777-777777777777";
const submissionId = "88888888-8888-4888-8888-888888888888";

function submission() {
  return {
    scope: {
      event_id: eventId,
      round_id: roundId,
      playing_group_id: groupId,
      scorer: { type: "player", round_entry_id: scorerId },
    },
    assignment: {
      id: assignmentId,
      round_entry_id: scorerId,
      assignment_version: 3,
    },
    active_round_entry_ids: [scorerId, secondPlayerId],
    command: {
      client_submission_id: submissionId,
      playing_group_id: groupId,
      round_hole_id: holeId,
      expected_group_score_revision: 8,
      role_assignment_version: 3,
      captured_at: "2026-11-04T12:37:45.123Z",
      results: [
        { round_entry_id: scorerId, outcome: "holed_out", gross_strokes: 4 },
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

async function serializeInBrowser(page, value) {
  return page.evaluate(async (input) => {
    try {
      const { serializeSubmission } = await import("/scoring/submission_serializer.js");
      return { ok: true, record: serializeSubmission(input) };
    } catch (error) {
      return { ok: false, name: error.name, message: error.message };
    }
  }, value);
}

async function queueInBrowser(page, method, ...args) {
  return page.evaluate(async ({ method, args }) => {
    try {
      const queue = await import("/scoring/queue.js");
      if (typeof queue[method] !== "function") {
        return { ok: false, name: "MissingExport", message: `${method} is not exported` };
      }
      return { ok: true, value: await queue[method](...args) };
    } catch (error) {
      return { ok: false, name: error.name, message: error.message };
    }
  }, { method, args });
}

async function seedVersionOneDatabase(page, name, inputs) {
  return page.evaluate(async ({ name, inputs }) => {
    const { serializeSubmission } = await import("/scoring/submission_serializer.js");
    const { SCORING_STORE_NAMES } = await import("/scoring/indexed_db.js");
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open(name, 1);
      request.onupgradeneeded = () => {
        const pending = request.result.createObjectStore(SCORING_STORE_NAMES.pending, {
          keyPath: "record_key",
        });
        pending.createIndex("by_scope_order", ["scope_key", "sequence"], { unique: true });
        request.result.createObjectStore(SCORING_STORE_NAMES.sequences, { keyPath: "scope_key" });
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    const transaction = db.transaction(
      [SCORING_STORE_NAMES.pending, SCORING_STORE_NAMES.sequences],
      "readwrite",
    );
    const pending = transaction.objectStore(SCORING_STORE_NAMES.pending);
    const sequences = transaction.objectStore(SCORING_STORE_NAMES.sequences);
    const lastSequences = new Map();

    for (const input of inputs) {
      const record = serializeSubmission(input);
      const sequence = (lastSequences.get(record.scope_key) || 0) + 1;
      lastSequences.set(record.scope_key, sequence);
      pending.add({
        ...record,
        state: "PERSISTED",
        sequence,
        record_key: JSON.stringify([
          record.scope_key,
          record.command.client_submission_id.toLowerCase(),
        ]),
      });
      sequences.put({ scope_key: record.scope_key, last_sequence: sequence });
    }

    await new Promise((resolve, reject) => {
      transaction.oncomplete = resolve;
      transaction.onabort = () => reject(transaction.error);
      transaction.onerror = () => reject(transaction.error);
    });
    const version = db.version;
    db.close();
    return version;
  }, { name, inputs });
}

test.beforeEach(async ({ page }) => {
  await page.goto("/");
});

test("serializes a complete hole without changing its SubmitGroupHole payload", async ({ page }) => {
  const input = submission();
  const result = await serializeInBrowser(page, input);

  expect(result.ok).toBe(true);
  expect(result.record.state).toBe("VALIDATED");
  expect(result.record.command).toEqual(input.command);
  expect(result.record.scope).toEqual(input.scope);
  expect(result.record.metadata.captured_assignment).toEqual(input.assignment);
  expect(result.record.metadata.active_round_entry_ids).toEqual(input.active_round_entry_ids);
});

test("accepts complete outcomes for groups of two through four players", async ({ page }) => {
  for (const playerIds of [
    [scorerId, secondPlayerId],
    [scorerId, secondPlayerId, thirdPlayerId],
    [scorerId, secondPlayerId, thirdPlayerId, fourthPlayerId],
  ]) {
    const input = submission();
    input.active_round_entry_ids = playerIds;
    input.command.results = playerIds.map((round_entry_id, index) => ({
      round_entry_id,
      outcome: "holed_out",
      gross_strokes: index + 3,
    }));

    const result = await serializeInBrowser(page, input);
    expect(result.ok).toBe(true);
    expect(result.record.command.results).toHaveLength(playerIds.length);
  }
});

test("rejects a hole command that omits an active player's outcome", async ({ page }) => {
  const input = submission();
  input.active_round_entry_ids = [scorerId, secondPlayerId, thirdPlayerId];

  const result = await serializeInBrowser(page, input);

  expect(result.ok).toBe(false);
  expect(result.name).toBe("SubmissionSerializationError");
  expect(result.message).toMatch(/every active player/);
});

test("rejects unsupported credential and hidden Mystery fields", async ({ page }) => {
  const input = submission();
  input.scope.player_access_token = "must-not-be-stored";

  const result = await serializeInBrowser(page, input);

  expect(result.ok).toBe(false);
  expect(result.message).toMatch(/unsupported field/);

  const mysteryInput = submission();
  mysteryInput.command.results[0].mystery_contribution = 12;
  const mysteryResult = await serializeInBrowser(page, mysteryInput);

  expect(mysteryResult.ok).toBe(false);
  expect(mysteryResult.message).toMatch(/unsupported field/);
});

test("rejects invalid capture data and lifecycle transitions", async ({ page }) => {
  const invalidTimestamp = submission();
  invalidTimestamp.command.captured_at = "not-a-timestamp";
  const timestampResult = await serializeInBrowser(page, invalidTimestamp);

  expect(timestampResult.ok).toBe(false);
  expect(timestampResult.message).toMatch(/captured_at/);

  const invalidState = submission();
  invalidState.state = "PERSISTED";
  const stateResult = await serializeInBrowser(page, invalidState);

  expect(stateResult.ok).toBe(false);
  expect(stateResult.name).toBe("InvalidLifecycleTransitionError");
});

test("persists one command atomically and recovers its original payload", async ({ page }) => {
  const input = submission();
  const saved = await queueInBrowser(page, "enqueueSubmission", input);

  expect(saved.ok).toBe(true);
  expect(saved.value.state).toBe("PERSISTED");
  expect(saved.value.sequence).toBe(1);
  expect(saved.value.command).toEqual(input.command);
  expect(saved.value.metadata.captured_assignment).toEqual(input.assignment);
  expect(saved.value.command).not.toHaveProperty("assignment_id");

  const recovered = await queueInBrowser(page, "recoverPending", input.scope);

  expect(recovered.ok).toBe(true);
  expect(recovered.value).toHaveLength(1);
  expect(recovered.value[0].state).toBe("RECOVERED");
  expect(recovered.value[0].command).toEqual(input.command);
  expect(recovered.value[0].command.client_submission_id).toBe(input.command.client_submission_id);
  expect(recovered.value[0].command.captured_at).toBe(input.command.captured_at);
});

test("retains pending commands in insertion order and isolates scorer scopes", async ({ page }) => {
  const first = submission();
  const second = submission();
  const third = submission();
  second.command.client_submission_id = "aaaaaaaa-0000-4000-8000-000000000001";
  second.command.captured_at = "2026-11-04T12:00:00Z";
  third.command.client_submission_id = "aaaaaaaa-0000-4000-8000-000000000002";
  third.command.captured_at = "2026-11-04T11:00:00Z";

  for (const input of [first, second, third]) {
    const saved = await queueInBrowser(page, "enqueueSubmission", input);
    expect(saved.ok).toBe(true);
  }

  const otherPlayer = submission();
  otherPlayer.scope.playing_group_id = otherGroupId;
  otherPlayer.scope.scorer.round_entry_id = secondPlayerId;
  otherPlayer.assignment.id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  otherPlayer.assignment.round_entry_id = secondPlayerId;
  otherPlayer.active_round_entry_ids.reverse();
  otherPlayer.command.playing_group_id = otherGroupId;
  otherPlayer.command.client_submission_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
  const otherSaved = await queueInBrowser(page, "enqueueSubmission", otherPlayer);
  expect(otherSaved.ok).toBe(true);

  const conflictingScope = structuredClone(otherPlayer);
  conflictingScope.command.client_submission_id = first.command.client_submission_id.toUpperCase();
  const duplicate = await queueInBrowser(page, "enqueueSubmission", conflictingScope);

  const recovered = await queueInBrowser(page, "recoverPending", first.scope);
  const otherRecovered = await queueInBrowser(page, "recoverPending", otherPlayer.scope);

  expect(duplicate.ok).toBe(false);
  expect(duplicate.name).toBe("DuplicateSubmissionError");

  expect(recovered.value.map(({ command }) => command.client_submission_id)).toEqual([
    first.command.client_submission_id,
    second.command.client_submission_id,
    third.command.client_submission_id,
  ]);
  expect(otherRecovered.value.map(({ command }) => command.client_submission_id)).toEqual([
    otherPlayer.command.client_submission_id,
  ]);
});

test("accepts a reordered equivalent retry and preserves the original stored payload", async ({ page }) => {
  const input = submission();
  const saved = await queueInBrowser(page, "enqueueSubmission", input);
  expect(saved.ok).toBe(true);

  const retry = submission();
  retry.scope.event_id = retry.scope.event_id.toUpperCase();
  retry.scope.round_id = retry.scope.round_id.toUpperCase();
  retry.scope.playing_group_id = retry.scope.playing_group_id.toUpperCase();
  retry.scope.scorer.round_entry_id = retry.scope.scorer.round_entry_id.toUpperCase();
  retry.assignment.id = retry.assignment.id.toUpperCase();
  retry.assignment.round_entry_id = retry.assignment.round_entry_id.toUpperCase();
  retry.active_round_entry_ids = retry.active_round_entry_ids.map((id) => id.toUpperCase()).reverse();
  retry.command.client_submission_id = retry.command.client_submission_id.toUpperCase();
  retry.command.playing_group_id = retry.command.playing_group_id.toUpperCase();
  retry.command.round_hole_id = retry.command.round_hole_id.toUpperCase();
  retry.command.results = retry.command.results
    .map((result) => ({ ...result, round_entry_id: result.round_entry_id.toUpperCase() }))
    .reverse();
  retry.command.captured_at = "2026-11-04T14:37:45.123000+02:00";

  const duplicate = await queueInBrowser(page, "enqueueSubmission", retry);
  const recovered = await queueInBrowser(page, "recoverPending", input.scope);

  expect(duplicate.ok).toBe(true);
  expect(duplicate.value.sequence).toBe(saved.value.sequence);
  expect(duplicate.value.command).toEqual(input.command);
  expect(duplicate.value.metadata.active_round_entry_ids).toEqual(input.active_round_entry_ids);
  expect(recovered.value).toHaveLength(1);
  expect(recovered.value[0].command).toEqual(input.command);
});

test("atomically accepts only one concurrent write for a global submission ID", async ({ page }) => {
  const first = submission();
  const second = submission();
  second.scope.playing_group_id = otherGroupId;
  second.scope.scorer.round_entry_id = secondPlayerId;
  second.assignment.id = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  second.assignment.round_entry_id = secondPlayerId;
  second.command.playing_group_id = otherGroupId;
  second.command.client_submission_id = first.command.client_submission_id.toUpperCase();

  const results = await Promise.all([
    queueInBrowser(page, "enqueueSubmission", first),
    queueInBrowser(page, "enqueueSubmission", second),
  ]);
  const accepted = results.filter(({ ok }) => ok);
  const rejected = results.filter(({ ok }) => !ok);
  const firstRecovered = await queueInBrowser(page, "recoverPending", first.scope);
  const secondRecovered = await queueInBrowser(page, "recoverPending", second.scope);

  expect(accepted).toHaveLength(1);
  expect(rejected).toHaveLength(1);
  expect(rejected[0].name).toBe("DuplicateSubmissionError");
  expect(firstRecovered.value.length + secondRecovered.value.length).toBe(1);
});

test("rejects same-ID retries when scoring semantics or captured identity changes", async ({ page }) => {
  const input = submission();
  const saved = await queueInBrowser(page, "enqueueSubmission", input);
  expect(saved.ok).toBe(true);

  const changes = [
    ["strokes", (changed) => { changed.command.results[0].gross_strokes += 1; }],
    ["outcome", (changed) => {
      const pickedUp = changed.command.results.find(({ outcome }) => outcome === "picked_up");
      pickedUp.outcome = "holed_out";
      pickedUp.gross_strokes = 6;
      delete pickedUp.strokes_taken;
    }],
    ["revision", (changed) => { changed.command.expected_group_score_revision += 1; }],
    ["assignment identity", (changed) => { changed.assignment.id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"; }],
    ["assignment version", (changed) => {
      changed.assignment.assignment_version += 1;
      changed.command.role_assignment_version += 1;
    }],
    ["actor", (changed) => {
      changed.scope.scorer.round_entry_id = secondPlayerId;
      changed.assignment.id = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
      changed.assignment.round_entry_id = secondPlayerId;
    }],
    ["capture time", (changed) => { changed.command.captured_at = "2026-11-04T12:37:46.123Z"; }],
  ];

  for (const [label, change] of changes) {
    const changed = structuredClone(input);
    change(changed);
    const duplicate = await queueInBrowser(page, "enqueueSubmission", changed);

    expect(duplicate.ok, label).toBe(false);
    expect(duplicate.name, label).toBe("DuplicateSubmissionError");
  }

  const recovered = await queueInBrowser(page, "recoverPending", input.scope);
  expect(recovered.value).toHaveLength(1);
  expect(recovered.value[0].command).toEqual(input.command);
});

test("treats an exact repeated submission as already persisted", async ({ page }) => {
  const input = submission();
  const first = await queueInBrowser(page, "enqueueSubmission", input);
  const repeated = await queueInBrowser(page, "enqueueSubmission", input);
  const recovered = await queueInBrowser(page, "recoverPending", input.scope);

  expect(first.ok).toBe(true);
  expect(repeated.ok).toBe(true);
  expect(repeated.value.sequence).toBe(first.value.sequence);
  expect(recovered.value).toHaveLength(1);
});

test("rejects unavailable IndexedDB without reporting a saved command", async ({ page }) => {
  const result = await queueInBrowser(page, "enqueueSubmission", submission(), { factory: null });

  expect(result.ok).toBe(false);
  expect(result.name).toBe("IndexedDBUnavailableError");
});

test("does not partially persist when the IndexedDB transaction aborts", async ({ page }) => {
  const firstInput = submission();
  const first = await queueInBrowser(page, "enqueueSubmission", firstInput);
  expect(first.ok).toBe(true);

  await page.evaluate(async (scopeKey) => {
    const { openScoringDatabase, SCORING_STORE_NAMES } = await import("/scoring/indexed_db.js");
    const db = await openScoringDatabase();
    const transaction = db.transaction(SCORING_STORE_NAMES.sequences, "readwrite");
    transaction.objectStore(SCORING_STORE_NAMES.sequences).put({ scope_key: scopeKey, last_sequence: 0 });
    await new Promise((resolve, reject) => {
      transaction.oncomplete = resolve;
      transaction.onabort = () => reject(transaction.error);
      transaction.onerror = () => reject(transaction.error);
    });
    db.close();
  }, first.value.scope_key);

  const secondInput = submission();
  secondInput.command.client_submission_id = "aaaaaaaa-0000-4000-8000-000000000003";
  const failedWrite = await queueInBrowser(page, "enqueueSubmission", secondInput);
  const recovered = await queueInBrowser(page, "recoverPending", firstInput.scope);

  expect(failedWrite.ok).toBe(false);
  expect(failedWrite.name).toBe("ConstraintError");
  expect(recovered.ok).toBe(true);
  expect(recovered.value.map(({ command }) => command.client_submission_id)).toEqual([
    firstInput.command.client_submission_id,
  ]);
});

test("stores no player credentials or hidden Mystery data", async ({ page }) => {
  const input = submission();
  const saved = await queueInBrowser(page, "enqueueSubmission", input);
  expect(saved.ok).toBe(true);

  const serializedRecord = JSON.stringify(saved.value).toLowerCase();
  expect(serializedRecord).not.toMatch(/access_token|session|mystery|contribution|secret/);
});

test("closes database connections before a schema upgrade", async ({ page }) => {
  const result = await page.evaluate(async () => {
    const { SCORING_DATABASE_NAME, openScoringDatabase } = await import("/scoring/indexed_db.js");
    const db = await openScoringDatabase();
    const request = indexedDB.open(SCORING_DATABASE_NAME, db.version + 1);
    const upgraded = await new Promise((resolve, reject) => {
      request.onupgradeneeded = () => request.result.createObjectStore("upgrade_probe");
      request.onsuccess = () => resolve(true);
      request.onerror = () => reject(request.error);
      request.onblocked = () => reject(new Error("schema upgrade blocked"));
    });
    request.result.close();
    return upgraded;
  });

  expect(result).toBe(true);
});

test("schema upgrade preserves pending version-one commands", async ({ page }) => {
  const name = "gls-36-legacy-pending-commands";
  const first = submission();
  const second = submission();
  second.scope.scorer.round_entry_id = secondPlayerId;
  second.assignment.id = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  second.assignment.round_entry_id = secondPlayerId;
  second.command.client_submission_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

  expect(await seedVersionOneDatabase(page, name, [first, second])).toBe(1);

  const result = await page.evaluate(async ({ name }) => {
    const { openScoringDatabase, SCORING_STORE_NAMES } = await import("/scoring/indexed_db.js");
    const db = await openScoringDatabase({ name });
    const pending = db.transaction(SCORING_STORE_NAMES.pending, "readonly").objectStore(
      SCORING_STORE_NAMES.pending,
    );
    const hasUniqueSubmissionIndex = pending.indexNames.contains("by_submission_id") &&
      pending.index("by_submission_id").unique;
    const version = db.version;
    db.close();
    return { version, hasUniqueSubmissionIndex };
  }, { name });

  const firstRecovered = await queueInBrowser(page, "recoverPending", first.scope, { name });
  const secondRecovered = await queueInBrowser(page, "recoverPending", second.scope, { name });

  expect(result).toEqual({ version: 2, hasUniqueSubmissionIndex: true });
  expect(firstRecovered.value).toHaveLength(1);
  expect(firstRecovered.value[0].command).toEqual(first.command);
  expect(secondRecovered.value).toHaveLength(1);
  expect(secondRecovered.value[0].command).toEqual(second.command);
});

test("schema upgrade fails visibly and preserves conflicting version-one records", async ({ page }) => {
  const name = "gls-36-legacy-conflicting-submission-ids";
  const first = submission();
  const second = submission();
  second.scope.playing_group_id = otherGroupId;
  second.scope.scorer.round_entry_id = secondPlayerId;
  second.assignment.id = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  second.assignment.round_entry_id = secondPlayerId;
  second.active_round_entry_ids.reverse();
  second.command.playing_group_id = otherGroupId;
  second.command.client_submission_id = first.command.client_submission_id.toUpperCase();

  expect(await seedVersionOneDatabase(page, name, [first, second])).toBe(1);

  const result = await page.evaluate(async ({ name }) => {
    const { openScoringDatabase, SCORING_STORE_NAMES } = await import("/scoring/indexed_db.js");
    let errorName;
    try {
      await openScoringDatabase({ name });
    } catch (error) {
      errorName = error.name;
    }

    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open(name, 1);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    const transaction = db.transaction(SCORING_STORE_NAMES.pending, "readonly");
    const request = transaction.objectStore(SCORING_STORE_NAMES.pending).getAll();
    let records;
    request.onsuccess = () => { records = request.result; };
    await new Promise((resolve, reject) => {
      transaction.oncomplete = resolve;
      transaction.onabort = () => reject(transaction.error);
      transaction.onerror = () => reject(transaction.error);
    });
    const version = db.version;
    db.close();
    return { errorName, version, records };
  }, { name });

  expect(result.errorName).toBe("DuplicateSubmissionError");
  expect(result.version).toBe(1);
  expect(result.records).toHaveLength(2);
  expect(result.records.map(({ command }) => command)).toEqual([first.command, second.command]);
  expect(result.records.every(({ submission_id_key }) => submission_id_key === undefined)).toBe(true);
});

test("surfaces a storage quota error without reporting the command as saved", async ({ page }) => {
  const input = submission();
  const failedWrite = await page.evaluate(async (command) => {
    const { enqueueSubmission } = await import("/scoring/queue.js");
    const quotaFailure = {
      open() {
        throw new DOMException("Storage quota exceeded", "QuotaExceededError");
      },
    };
    try {
      await enqueueSubmission(command, { factory: quotaFailure });
      return { ok: true };
    } catch (error) {
      return { ok: false, name: error.name };
    }
  }, input);

  expect(failedWrite.ok).toBe(false);
  expect(failedWrite.name).toBe("QuotaExceededError");
  const recovered = await queueInBrowser(page, "recoverPending", input.scope);
  expect(recovered.value).toHaveLength(0);
});

test("does not skip validation before IndexedDB persistence", async ({ page }) => {
  const result = await page.evaluate(async () => {
    const { persistValidatedRecord } = await import("/scoring/indexed_db.js");
    try {
      await persistValidatedRecord({ state: "EMPTY" });
      return { ok: true };
    } catch (error) {
      return { ok: false, name: error.name };
    }
  });

  expect(result.ok).toBe(false);
  expect(result.name).toBe("InvalidLifecycleTransitionError");
});

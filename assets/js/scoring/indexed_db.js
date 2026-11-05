import {
  canonicalSubmissionPayload,
  InvalidLifecycleTransitionError,
  serializeSubmission,
} from "./submission_serializer.js";

export const SCORING_DATABASE_NAME = "golf_scoring_pending_commands";
export const SCORING_STORE_NAMES = Object.freeze({
  pending: "pending_commands",
  sequences: "scope_sequences",
});

const DATABASE_VERSION = 2;
const ORDER_INDEX = "by_scope_order";
const SUBMISSION_ID_INDEX = "by_submission_id";
const SUBMISSION_ID_KEY = "submission_id_key";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO_TIMESTAMP_PARTS =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|([+-])(\d{2}):(\d{2}))$/;

export class IndexedDBUnavailableError extends Error {
  constructor() {
    super("IndexedDB is unavailable in this browser context");
    this.name = "IndexedDBUnavailableError";
  }
}

export class IndexedDBUpgradeBlockedError extends Error {
  constructor() {
    super("IndexedDB schema upgrade is blocked by another open connection");
    this.name = "IndexedDBUpgradeBlockedError";
  }
}

export class DuplicateSubmissionError extends Error {
  constructor(message = "client_submission_id is already stored with a different command") {
    super(message);
    this.name = "DuplicateSubmissionError";
  }
}

export class InvalidStoredRecordError extends Error {
  constructor(message) {
    super(message);
    this.name = "InvalidStoredRecordError";
  }
}

export function openScoringDatabase(options = {}) {
  const factory = Object.hasOwn(options, "factory") ? options.factory : globalThis.indexedDB;
  const name = options.name || SCORING_DATABASE_NAME;
  if (!factory || typeof factory.open !== "function") {
    return Promise.reject(new IndexedDBUnavailableError());
  }

  return new Promise((resolve, reject) => {
    let settled = false;
    let upgradeError;
    let request;

    const fail = (error) => {
      if (settled) return;
      settled = true;
      reject(error);
    };

    const abortUpgrade = (error) => {
      upgradeError = error;
      try {
        request.transaction.abort();
      } catch (_abortError) {
        // The version-change transaction already aborted.
      }
    };

    try {
      request = factory.open(name, DATABASE_VERSION);
    } catch (error) {
      fail(error);
      return;
    }

    request.onupgradeneeded = (event) => {
      try {
        const db = request.result;
        const previousVersion = event.oldVersion;
        let pendingStore;
        if (db.objectStoreNames.contains(SCORING_STORE_NAMES.pending)) {
          pendingStore = request.transaction.objectStore(SCORING_STORE_NAMES.pending);
        } else {
          pendingStore = db.createObjectStore(SCORING_STORE_NAMES.pending, { keyPath: "record_key" });
        }
        if (!pendingStore.indexNames.contains(ORDER_INDEX)) {
          pendingStore.createIndex(ORDER_INDEX, ["scope_key", "sequence"], { unique: true });
        }
        if (!db.objectStoreNames.contains(SCORING_STORE_NAMES.sequences)) {
          db.createObjectStore(SCORING_STORE_NAMES.sequences, { keyPath: "scope_key" });
        }
        if (previousVersion < DATABASE_VERSION) {
          const ensureUniqueSubmissionIndex = () => {
            if (!pendingStore.indexNames.contains(SUBMISSION_ID_INDEX)) {
              pendingStore.createIndex(SUBMISSION_ID_INDEX, SUBMISSION_ID_KEY, { unique: true });
            }
          };
          if (previousVersion > 0) {
            // Preflight so legacy collisions fail explicitly before any index backfill begins.
            migrateLegacySubmissionIds(pendingStore, ensureUniqueSubmissionIndex, abortUpgrade);
          } else {
            ensureUniqueSubmissionIndex();
          }
        }
      } catch (error) {
        abortUpgrade(error);
      }
    };

    request.onblocked = () => fail(new IndexedDBUpgradeBlockedError());
    request.onerror = () => fail(upgradeError || request.error || new Error("IndexedDB open failed"));
    request.onsuccess = () => {
      const db = request.result;
      if (settled) {
        db.close();
        return;
      }
      db.onversionchange = () => db.close();
      settled = true;
      resolve(db);
    };
  });
}

function migrateLegacySubmissionIds(pendingStore, ensureUniqueSubmissionIndex, abortUpgrade) {
  const submissionIds = new Set();
  const scanRequest = pendingStore.openCursor();
  scanRequest.onerror = (event) => {
    abortUpgrade(event.target?.error || new InvalidStoredRecordError("Could not read legacy pending commands"));
  };
  scanRequest.onsuccess = () => {
    const cursor = scanRequest.result;
    if (cursor) {
      const submissionId = cursor.value?.command?.client_submission_id;
      if (typeof submissionId !== "string" || !UUID.test(submissionId)) {
        abortUpgrade(new InvalidStoredRecordError("Legacy pending command has an invalid submission ID"));
        return;
      }
      const submissionIdKey = submissionId.toLowerCase();
      if (submissionIds.has(submissionIdKey)) {
        abortUpgrade(new DuplicateSubmissionError("Legacy pending commands contain duplicate submission IDs"));
        return;
      }
      submissionIds.add(submissionIdKey);
      cursor.continue();
      return;
    }

    try {
      ensureUniqueSubmissionIndex();
      backfillLegacySubmissionIds(pendingStore, abortUpgrade);
    } catch (error) {
      abortUpgrade(error);
    }
  };
}

function backfillLegacySubmissionIds(pendingStore, abortUpgrade) {
  const cursorRequest = pendingStore.openCursor();
  cursorRequest.onerror = (event) => {
    abortUpgrade(event.target?.error || new InvalidStoredRecordError("Could not backfill legacy submission IDs"));
  };
  cursorRequest.onsuccess = () => {
    const cursor = cursorRequest.result;
    if (!cursor) return;

    const submissionId = cursor.value?.command?.client_submission_id;
    try {
      const updateRequest = cursor.update({
        ...cursor.value,
        [SUBMISSION_ID_KEY]: submissionId.toLowerCase(),
      });
      updateRequest.onerror = (event) => {
        const error = event.target?.error || updateRequest.error;
        abortUpgrade(
          error?.name === "ConstraintError"
            ? new DuplicateSubmissionError("Legacy pending commands contain duplicate submission IDs")
            : error || new InvalidStoredRecordError("Could not index a legacy pending command"),
        );
      };
      cursor.continue();
    } catch (error) {
      abortUpgrade(error);
    }
  };
}

export async function persistValidatedRecord(record, options = {}) {
  assertValidatedRecord(record);
  const db = await openScoringDatabase(options);
  try {
    return await persistInTransaction(db, record);
  } finally {
    db.close();
  }
}

export async function readPendingRecords(scopeKey, options = {}) {
  if (typeof scopeKey !== "string" || scopeKey.length === 0) {
    throw new InvalidStoredRecordError("A scoring scope key is required to recover pending commands");
  }
  const db = await openScoringDatabase(options);
  try {
    return await readInTransaction(db, scopeKey);
  } finally {
    db.close();
  }
}

export async function acknowledgePendingRecord(record, receipt, options = {}) {
  if (
    record?.state !== "RECOVERED" ||
    typeof record.record_key !== "string" ||
    typeof record.scope_key !== "string" ||
    !Number.isSafeInteger(record.sequence) ||
    record.sequence < 1 ||
    typeof record.command?.client_submission_id !== "string" ||
    !validAuthoritativeReceipt(record, receipt)
  ) {
    return false;
  }

  const db = await openScoringDatabase(options);
  try {
    return await acknowledgeInTransaction(db, record);
  } finally {
    db.close();
  }
}

export async function readConflictStop(scopeKey, options = {}) {
  if (typeof scopeKey !== "string" || scopeKey.length === 0) {
    throw new InvalidStoredRecordError("A scoring scope key is required to read its conflict state");
  }

  const db = await openScoringDatabase(options);
  try {
    return await readConflictStopInTransaction(db, scopeKey);
  } finally {
    db.close();
  }
}

export async function persistConflictStop(scopeKey, conflict, options = {}) {
  const candidate = validateConflictStop(conflict);
  if (typeof scopeKey !== "string" || scopeKey.length === 0) {
    throw new InvalidStoredRecordError("A scoring scope key is required to persist its conflict state");
  }

  const db = await openScoringDatabase(options);
  try {
    return await persistConflictStopInTransaction(db, scopeKey, candidate);
  } finally {
    db.close();
  }
}

export async function clearConflictStop(scopeKey, expectedConflict, options = {}) {
  const expected = validateConflictStop(expectedConflict);
  if (typeof scopeKey !== "string" || scopeKey.length === 0) {
    throw new InvalidStoredRecordError("A scoring scope key is required to clear its conflict state");
  }

  const db = await openScoringDatabase(options);
  try {
    return await clearConflictStopInTransaction(db, scopeKey, expected);
  } finally {
    db.close();
  }
}

function assertValidatedRecord(record) {
  if (!record || record.state !== "VALIDATED") {
    throw new InvalidLifecycleTransitionError(record?.state || "EMPTY", "PERSISTED");
  }
  const validated = serializeSubmission({
    scope: record.scope,
    assignment: record.metadata?.captured_assignment,
    active_round_entry_ids: record.metadata?.active_round_entry_ids,
    command: record.command,
  });
  const expectedFields = [
    "state",
    "scope",
    "scope_key",
    "metadata",
    "command",
  ];
  if (
    Object.keys(record).length !== expectedFields.length ||
    Object.keys(record).some((key) => !expectedFields.includes(key)) ||
    validated.scope_key !== record.scope_key ||
    JSON.stringify(validated.metadata) !== JSON.stringify(record.metadata) ||
    JSON.stringify(validated.command) !== JSON.stringify(record.command)
  ) {
    throw new InvalidStoredRecordError("Only a validated whole-hole command can be persisted");
  }
}

function persistInTransaction(db, record) {
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(
      [SCORING_STORE_NAMES.pending, SCORING_STORE_NAMES.sequences],
      "readwrite",
    );
    const pending = transaction.objectStore(SCORING_STORE_NAMES.pending);
    const sequences = transaction.objectStore(SCORING_STORE_NAMES.sequences);
    const recordKey = recordKeyFor(record.scope_key, record.command.client_submission_id);
    let result;
    let transactionError;

    const abortWith = (error) => {
      transactionError = error;
      try {
        transaction.abort();
      } catch (_abortError) {
        // The transaction already aborted.
      }
    };

    const submissionIdKey = record.command.client_submission_id.toLowerCase();
    const existingRequest = pending.index(SUBMISSION_ID_INDEX).get(submissionIdKey);
    existingRequest.onsuccess = () => {
      const existing = existingRequest.result;
      if (existing) {
        if (existing.state !== "PERSISTED") {
          abortWith(new InvalidStoredRecordError("Stored command has an invalid lifecycle state"));
          return;
        }
        if (existing[SUBMISSION_ID_KEY] !== submissionIdKey) {
          abortWith(new InvalidStoredRecordError("Stored submission ID index does not match its command"));
          return;
        }
        if (existing.scope_key !== record.scope_key) {
          abortWith(new DuplicateSubmissionError("client_submission_id is already stored in another scoring scope"));
          return;
        }
        try {
          if (canonicalPayloadForRecord(existing) !== canonicalPayloadForRecord(record)) {
            abortWith(new DuplicateSubmissionError());
            return;
          }
        } catch (error) {
          abortWith(new InvalidStoredRecordError("Stored command failed duplicate integrity validation"));
          return;
        }
        result = existing;
        return;
      }

      const sequenceRequest = sequences.get(record.scope_key);
      sequenceRequest.onsuccess = () => {
        const lastSequence = sequenceRequest.result?.last_sequence ?? 0;
        if (!Number.isSafeInteger(lastSequence) || lastSequence < 0) {
          abortWith(new InvalidStoredRecordError("Stored queue sequence is invalid"));
          return;
        }
        const sequence = lastSequence + 1;
        if (!Number.isSafeInteger(sequence)) {
          abortWith(new InvalidStoredRecordError("Scoring queue sequence is exhausted"));
          return;
        }

        result = {
          ...record,
          state: "PERSISTED",
          [SUBMISSION_ID_KEY]: submissionIdKey,
          sequence,
          record_key: recordKey,
        };
        sequences.put({
          ...(sequenceRequest.result || {}),
          scope_key: record.scope_key,
          last_sequence: sequence,
        });
        pending.add(result);
      };
    };

    transaction.onerror = (event) => {
      transactionError ||= event.target?.error || transaction.error;
    };
    transaction.onabort = () => {
      reject(transactionError || transaction.error || new Error("IndexedDB write transaction aborted"));
    };
    transaction.oncomplete = () => {
      if (!result) {
        reject(new Error("IndexedDB completed without persisting a command"));
        return;
      }
      resolve(result);
    };
  });
}

function canonicalPayloadForRecord(record) {
  return canonicalSubmissionPayload({
    scope: record.scope,
    assignment: record.metadata?.captured_assignment,
    active_round_entry_ids: record.metadata?.active_round_entry_ids,
    command: record.command,
  });
}

function validAuthoritativeReceipt(record, receipt) {
  try {
    const { command, scope, metadata } = record;
    const assignment = metadata.captured_assignment;
    const payload = receipt?.submitted_payload;

    if (
      !receipt ||
      typeof receipt !== "object" ||
      Array.isArray(receipt) ||
      typeof receipt.id !== "string" ||
      !UUID.test(receipt.id) ||
      !sameId(receipt.client_submission_id, command.client_submission_id) ||
      !sameId(receipt.round_id, scope.round_id) ||
      !sameId(receipt.playing_group_id, command.playing_group_id) ||
      !sameId(receipt.round_hole_id, command.round_hole_id) ||
      receipt.expected_group_score_revision !== command.expected_group_score_revision ||
      !sameId(receipt.group_role_assignment_id, assignment.id) ||
      receipt.role_assignment_version !== command.role_assignment_version ||
      !sameId(receipt.submitted_by_round_entry_id, scope.scorer.round_entry_id) ||
      !sameTimestamp(receipt.captured_at, command.captured_at) ||
      !validFingerprint(receipt.payload_fingerprint) ||
      (receipt.source !== undefined && receipt.source !== "normal") ||
      !payload ||
      typeof payload !== "object" ||
      Array.isArray(payload) ||
      !sameId(payload.playing_group_id, command.playing_group_id) ||
      !sameId(payload.round_hole_id, command.round_hole_id) ||
      payload.expected_group_score_revision !== command.expected_group_score_revision ||
      payload.role_assignment_version !== command.role_assignment_version ||
      !sameTimestamp(payload.captured_at, command.captured_at) ||
      payload.actor?.type !== "player" ||
      !sameId(payload.actor.round_entry_id, scope.scorer.round_entry_id) ||
      payload.actor.role_assignment_version !== command.role_assignment_version ||
      !Array.isArray(payload.results) ||
      !payload.results.every((result) => result && typeof result === "object" && !Array.isArray(result))
    ) {
      return false;
    }

    const expectedResults = command.results
      .map((result) => ({
        round_entry_id: result.round_entry_id.toLowerCase(),
        outcome: result.outcome,
        gross_strokes: result.gross_strokes,
        strokes_taken: result.strokes_taken ?? null,
      }))
      .sort((left, right) => compareIds(left.round_entry_id, right.round_entry_id));
    const receivedResults = payload.results
      .map((result) => ({
        round_entry_id: typeof result.round_entry_id === "string"
          ? result.round_entry_id.toLowerCase()
          : result.round_entry_id,
        outcome: result.outcome,
        gross_strokes: result.gross_strokes,
        strokes_taken: result.strokes_taken ?? null,
      }))
      .sort((left, right) => compareIds(left.round_entry_id, right.round_entry_id));

    return JSON.stringify(receivedResults) === JSON.stringify(expectedResults);
  } catch (_error) {
    return false;
  }
}

function validFingerprint(value) {
  return (
    (typeof value === "string" &&
      (/^[0-9a-f]{64}$/i.test(value) || /^[A-Za-z0-9+/]{43}=$/.test(value))) ||
    (value instanceof ArrayBuffer && value.byteLength === 32) ||
    (value instanceof Uint8Array && value.byteLength === 32)
  );
}

function sameId(left, right) {
  return typeof left === "string" &&
    typeof right === "string" &&
    left.toLowerCase() === right.toLowerCase();
}

function sameTimestamp(left, right) {
  const canonicalLeft = canonicalTimestamp(left);
  const canonicalRight = canonicalTimestamp(right);
  return canonicalLeft !== null && canonicalLeft === canonicalRight;
}

function canonicalTimestamp(value) {
  if (typeof value !== "string" || !Number.isFinite(Date.parse(value))) return null;
  const match = ISO_TIMESTAMP_PARTS.exec(value);
  if (!match) return null;

  const [, year, month, day, hour, minute, second, fraction, zone, sign, offsetHours, offsetMinutes] = match;
  if (
    Number(hour) > 23 ||
    Number(minute) > 59 ||
    Number(second) > 59 ||
    Number(offsetHours || 0) > 23 ||
    Number(offsetMinutes || 0) > 59
  ) {
    return null;
  }

  const localSecond = Date.UTC(
    Number(year),
    Number(month) - 1,
    Number(day),
    Number(hour),
    Number(minute),
    Number(second),
  ) / 1000;
  const date = new Date(Date.UTC(Number(year), Number(month) - 1, Number(day)));
  if (
    date.getUTCFullYear() !== Number(year) ||
    date.getUTCMonth() !== Number(month) - 1 ||
    date.getUTCDate() !== Number(day)
  ) {
    return null;
  }

  const offset = zone === "Z"
    ? 0
    : (Number(offsetHours) * 60 + Number(offsetMinutes)) * (sign === "+" ? 1 : -1);
  const microseconds = (fraction || "").slice(0, 6).padEnd(6, "0");
  return `${localSecond - offset * 60}:${microseconds}`;
}

function compareIds(left, right) {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

function readInTransaction(db, scopeKey) {
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(SCORING_STORE_NAMES.pending, "readonly");
    const index = transaction.objectStore(SCORING_STORE_NAMES.pending).index(ORDER_INDEX);
    const range = IDBKeyRange.bound([scopeKey, 0], [scopeKey, Number.MAX_SAFE_INTEGER]);
    const request = index.getAll(range);
    let records;
    let transactionError;

    request.onsuccess = () => {
      records = request.result;
    };
    request.onerror = (event) => {
      transactionError = event.target?.error || request.error;
    };
    transaction.onerror = (event) => {
      transactionError ||= event.target?.error || transaction.error;
    };
    transaction.onabort = () => {
      reject(transactionError || transaction.error || new Error("IndexedDB read transaction aborted"));
    };
    transaction.oncomplete = () => resolve(records || []);
  });
}

function acknowledgeInTransaction(db, record) {
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(SCORING_STORE_NAMES.pending, "readwrite");
    const pending = transaction.objectStore(SCORING_STORE_NAMES.pending);
    const request = pending.get(record.record_key);
    let acknowledged = false;
    let transactionError;

    request.onsuccess = () => {
      const stored = request.result;
      if (
        !stored ||
        stored.state !== "PERSISTED" ||
        stored.record_key !== record.record_key ||
        stored.scope_key !== record.scope_key ||
        stored.sequence !== record.sequence ||
        stored.submission_id_key !== record.command.client_submission_id.toLowerCase() ||
        JSON.stringify(stored.scope) !== JSON.stringify(record.scope) ||
        JSON.stringify(stored.metadata) !== JSON.stringify(record.metadata) ||
        JSON.stringify(stored.command) !== JSON.stringify(record.command)
      ) {
        return;
      }

      pending.delete(record.record_key);
      acknowledged = true;
    };
    request.onerror = (event) => {
      transactionError = event.target?.error || request.error;
    };
    transaction.onerror = (event) => {
      transactionError ||= event.target?.error || transaction.error;
    };
    transaction.onabort = () => {
      reject(transactionError || transaction.error || new Error("IndexedDB acknowledgement transaction aborted"));
    };
    transaction.oncomplete = () => resolve(acknowledged);
  });
}

function readConflictStopInTransaction(db, scopeKey) {
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(SCORING_STORE_NAMES.sequences, "readonly");
    const request = transaction.objectStore(SCORING_STORE_NAMES.sequences).get(scopeKey);
    let conflict;
    let transactionError;

    request.onsuccess = () => {
      const value = request.result?.conflict_stop;
      if (value !== undefined) {
        try {
          conflict = validateConflictStop(value);
        } catch (error) {
          transactionError = error;
          try {
            transaction.abort();
          } catch (_abortError) {
            // The read transaction already completed or aborted.
          }
        }
      }
    };
    request.onerror = (event) => {
      transactionError = event.target?.error || request.error;
    };
    transaction.onerror = (event) => {
      transactionError ||= event.target?.error || transaction.error;
    };
    transaction.onabort = () => {
      reject(transactionError || transaction.error || new Error("IndexedDB conflict read transaction aborted"));
    };
    transaction.oncomplete = () => resolve(conflict || null);
  });
}

function persistConflictStopInTransaction(db, scopeKey, candidate) {
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(SCORING_STORE_NAMES.sequences, "readwrite");
    const store = transaction.objectStore(SCORING_STORE_NAMES.sequences);
    const request = store.get(scopeKey);
    let result;
    let transactionError;

    request.onsuccess = () => {
      const sequenceRecord = request.result;
      if (
        !sequenceRecord ||
        sequenceRecord.scope_key !== scopeKey ||
        !Number.isSafeInteger(sequenceRecord.last_sequence) ||
        sequenceRecord.last_sequence < candidate.sequence
      ) {
        transactionError = new InvalidStoredRecordError("Conflict stop does not match a stored queue sequence");
        try {
          transaction.abort();
        } catch (_abortError) {
          // The transaction already completed or aborted.
        }
        return;
      }

      if (sequenceRecord.conflict_stop !== undefined) {
        try {
          result = validateConflictStop(sequenceRecord.conflict_stop);
        } catch (error) {
          transactionError = error;
          try {
            transaction.abort();
          } catch (_abortError) {
            // The transaction already completed or aborted.
          }
        }
        return;
      }

      result = candidate;
      store.put({ ...sequenceRecord, conflict_stop: candidate });
    };
    request.onerror = (event) => {
      transactionError = event.target?.error || request.error;
    };
    transaction.onerror = (event) => {
      transactionError ||= event.target?.error || transaction.error;
    };
    transaction.onabort = () => {
      reject(transactionError || transaction.error || new Error("IndexedDB conflict write transaction aborted"));
    };
    transaction.oncomplete = () => resolve(result);
  });
}

function clearConflictStopInTransaction(db, scopeKey, expected) {
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(SCORING_STORE_NAMES.sequences, "readwrite");
    const store = transaction.objectStore(SCORING_STORE_NAMES.sequences);
    const request = store.get(scopeKey);
    let cleared = false;
    let transactionError;

    request.onsuccess = () => {
      const sequenceRecord = request.result;
      if (
        !sequenceRecord ||
        sequenceRecord.scope_key !== scopeKey ||
        sequenceRecord.conflict_stop === undefined
      ) {
        return;
      }

      let current;
      try {
        current = validateConflictStop(sequenceRecord.conflict_stop);
      } catch (error) {
        transactionError = error;
        try {
          transaction.abort();
        } catch (_abortError) {
          // The transaction already completed or aborted.
        }
        return;
      }

      if (!current || !sameConflictStop(current, expected)) return;

      const updated = { ...sequenceRecord };
      delete updated.conflict_stop;
      store.put(updated);
      cleared = true;
    };
    request.onerror = (event) => {
      transactionError = event.target?.error || request.error;
    };
    transaction.onerror = (event) => {
      transactionError ||= event.target?.error || transaction.error;
    };
    transaction.onabort = () => {
      reject(transactionError || transaction.error || new Error("IndexedDB conflict clear transaction aborted"));
    };
    transaction.oncomplete = () => resolve(cleared);
  });
}

function validateConflictStop(value) {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    !UUID.test(value.submission_id || "") ||
    !Number.isSafeInteger(value.sequence) ||
    value.sequence < 1 ||
    typeof value.reason !== "string" ||
    value.reason.length === 0 ||
    Object.keys(value).some((key) => !["submission_id", "sequence", "reason"].includes(key))
  ) {
    throw new InvalidStoredRecordError("Stored scoring conflict state is invalid");
  }

  return {
    submission_id: value.submission_id,
    sequence: value.sequence,
    reason: value.reason,
  };
}

function sameConflictStop(left, right) {
  return (
    left.submission_id.toLowerCase() === right.submission_id.toLowerCase() &&
    left.sequence === right.sequence &&
    left.reason === right.reason
  );
}

function recordKeyFor(scopeKey, submissionId) {
  return JSON.stringify([scopeKey, submissionId.toLowerCase()]);
}

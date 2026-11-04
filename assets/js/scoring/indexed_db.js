import {
  InvalidLifecycleTransitionError,
  serializeSubmission,
} from "./submission_serializer.js";

export const SCORING_DATABASE_NAME = "golf_scoring_pending_commands";
export const SCORING_STORE_NAMES = Object.freeze({
  pending: "pending_commands",
  sequences: "scope_sequences",
});

const DATABASE_VERSION = 1;
const ORDER_INDEX = "by_scope_order";

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
  constructor() {
    super("client_submission_id is already stored with a different command");
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

    try {
      request = factory.open(name, DATABASE_VERSION);
    } catch (error) {
      fail(error);
      return;
    }

    request.onupgradeneeded = () => {
      try {
        const db = request.result;
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
      } catch (error) {
        upgradeError = error;
        request.transaction.abort();
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

    const existingRequest = pending.get(recordKey);
    existingRequest.onsuccess = () => {
      const existing = existingRequest.result;
      if (existing) {
        if (
          JSON.stringify(existing.command) !== JSON.stringify(record.command) ||
          JSON.stringify(existing.metadata) !== JSON.stringify(record.metadata)
        ) {
          abortWith(new DuplicateSubmissionError());
          return;
        }
        if (existing.state !== "PERSISTED") {
          abortWith(new InvalidStoredRecordError("Stored command has an invalid lifecycle state"));
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
          sequence,
          record_key: recordKey,
        };
        sequences.put({ scope_key: record.scope_key, last_sequence: sequence });
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

function recordKeyFor(scopeKey, submissionId) {
  return JSON.stringify([scopeKey, submissionId.toLowerCase()]);
}

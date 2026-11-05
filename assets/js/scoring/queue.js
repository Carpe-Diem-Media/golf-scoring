import {
  DuplicateSubmissionError,
  InvalidStoredRecordError,
  acknowledgePendingRecord,
  clearConflictStop as clearConflictStopRecord,
  persistConflictStop as persistConflictStopRecord,
  persistValidatedRecord,
  readConflictStop as readConflictStopRecord,
  readPendingRecords,
} from "./indexed_db.js";
import {
  InvalidLifecycleTransitionError,
  scopeKeyFor,
  serializeSubmission,
} from "./submission_serializer.js";

const STORED_RECORD_FIELDS = [
  "state",
  "scope",
  "scope_key",
  "metadata",
  "command",
  "submission_id_key",
  "sequence",
  "record_key",
];
const STORED_METADATA_FIELDS = ["captured_assignment", "active_round_entry_ids"];

export { DuplicateSubmissionError };

export async function enqueueSubmission(input, options = {}) {
  const validated = serializeSubmission(input);
  return persistValidatedRecord(validated, options);
}

export async function recoverPending(scope, options = {}) {
  const scopeKey = scopeKeyFor(scope);
  const storedRecords = await readPendingRecords(scopeKey, options);
  return storedRecords.map((record) => recoverRecord(record, scopeKey));
}

export async function acknowledgeSubmission(record, receipt, options = {}) {
  return acknowledgePendingRecord(record, receipt, options);
}

export async function persistConflictStop(record, reason, options = {}) {
  if (
    record?.state !== "RECOVERED" ||
    typeof record.scope_key !== "string" ||
    !Number.isSafeInteger(record.sequence) ||
    record.sequence < 1 ||
    typeof record.command?.client_submission_id !== "string"
  ) {
    throw new InvalidStoredRecordError("A recovered queue record is required to stop replay");
  }

  const safeReason = typeof reason === "string" && /^[a-zA-Z0-9_:-]{1,128}$/.test(reason)
    ? reason
    : "server_rejected";
  return persistConflictStopRecord(
    record.scope_key,
    {
      submission_id: record.command.client_submission_id,
      sequence: record.sequence,
      reason: safeReason,
    },
    options,
  );
}

export async function readConflictStop(scope, options = {}) {
  return readConflictStopRecord(scopeKeyFor(scope), options);
}

export async function clearConflictStop(scope, expectedConflict, options = {}) {
  return clearConflictStopRecord(scopeKeyFor(scope), expectedConflict, options);
}

function recoverRecord(record, requestedScopeKey) {
  if (!hasOnlyKeys(record, STORED_RECORD_FIELDS) || record.state !== "PERSISTED") {
    throw new InvalidLifecycleTransitionError(record?.state || "EMPTY", "RECOVERED");
  }
  if (!hasOnlyKeys(record.metadata, STORED_METADATA_FIELDS)) {
    throw new InvalidStoredRecordError("Stored queue metadata contains unsupported fields");
  }
  if (!Number.isSafeInteger(record.sequence) || record.sequence < 1) {
    throw new InvalidStoredRecordError("Stored queue sequence is invalid");
  }
  if (record.submission_id_key !== record.command.client_submission_id.toLowerCase()) {
    throw new InvalidStoredRecordError("Stored submission ID key does not match its command");
  }

  const validated = serializeSubmission({
    scope: record.scope,
    assignment: record.metadata.captured_assignment,
    active_round_entry_ids: record.metadata.active_round_entry_ids,
    command: record.command,
  });
  const expectedRecordKey = JSON.stringify([
    record.scope_key,
    record.command.client_submission_id.toLowerCase(),
  ]);
  if (
    record.scope_key !== requestedScopeKey ||
    validated.scope_key !== record.scope_key ||
    JSON.stringify(validated.command) !== JSON.stringify(record.command) ||
    expectedRecordKey !== record.record_key
  ) {
    throw new InvalidStoredRecordError("Stored scoring command failed integrity checks");
  }

  return { ...record, state: "RECOVERED" };
}

function hasOnlyKeys(value, allowed) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  return Object.keys(value).every((key) => allowed.includes(key));
}

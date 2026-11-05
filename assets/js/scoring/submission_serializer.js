const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;
const ISO_TIMESTAMP_PARTS = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|([+-])(\d{2}):(\d{2}))$/;

export class SubmissionSerializationError extends Error {
  constructor(message) {
    super(message);
    this.name = "SubmissionSerializationError";
  }
}

export class InvalidLifecycleTransitionError extends Error {
  constructor(from, to) {
    super(`Cannot transition scoring command from ${from} to ${to}`);
    this.name = "InvalidLifecycleTransitionError";
  }
}

export function serializeSubmission(input) {
  assertKeys(
    input,
    ["state", "scope", "assignment", "active_round_entry_ids", "command"],
    ["scope", "assignment", "active_round_entry_ids", "command"],
    "submission",
  );
  if (input.state !== undefined && input.state !== "EMPTY") {
    throw new InvalidLifecycleTransitionError(input.state, "VALIDATED");
  }

  const scope = serializeScope(input.scope);
  const assignment = serializeAssignment(input.assignment, scope);
  const activeRoundEntryIds = serializeRoster(input.active_round_entry_ids);
  const command = serializeCommand(input.command, scope, assignment, activeRoundEntryIds);

  return {
    state: "VALIDATED",
    scope,
    scope_key: scopeKeyFor(scope),
    metadata: {
      captured_assignment: assignment,
      active_round_entry_ids: activeRoundEntryIds,
    },
    command,
  };
}

export function canonicalSubmissionPayload(input) {
  const validated = serializeSubmission(input);
  const assignment = validated.metadata.captured_assignment;
  const activeRoundEntryIds = validated.metadata.active_round_entry_ids
    .map((id) => id.toLowerCase())
    .sort();
  const results = validated.command.results
    .map((result) => {
      const canonical = {
        round_entry_id: result.round_entry_id.toLowerCase(),
        outcome: result.outcome,
        gross_strokes: result.gross_strokes,
      };
      if (Object.hasOwn(result, "strokes_taken")) canonical.strokes_taken = result.strokes_taken;
      return canonical;
    })
    .sort((left, right) => compareStrings(left.round_entry_id, right.round_entry_id));

  return JSON.stringify({
    scope_key: validated.scope_key,
    captured_assignment: {
      id: assignment.id.toLowerCase(),
      round_entry_id: assignment.round_entry_id.toLowerCase(),
      assignment_version: assignment.assignment_version,
    },
    active_round_entry_ids: activeRoundEntryIds,
    command: {
      client_submission_id: validated.command.client_submission_id.toLowerCase(),
      playing_group_id: validated.command.playing_group_id.toLowerCase(),
      round_hole_id: validated.command.round_hole_id.toLowerCase(),
      expected_group_score_revision: validated.command.expected_group_score_revision,
      role_assignment_version: validated.command.role_assignment_version,
      captured_at: canonicalTimestamp(validated.command.captured_at),
      results,
    },
  });
}

export function scopeKeyFor(value) {
  const scope = serializeScope(value);
  return JSON.stringify([
    scope.event_id.toLowerCase(),
    scope.round_id.toLowerCase(),
    scope.playing_group_id.toLowerCase(),
    scope.scorer.type,
    scope.scorer.round_entry_id.toLowerCase(),
  ]);
}

function serializeScope(value) {
  assertKeys(
    value,
    ["event_id", "round_id", "playing_group_id", "scorer"],
    ["event_id", "round_id", "playing_group_id", "scorer"],
    "scoring scope",
  );
  assertUuid(value.event_id, "event_id");
  assertUuid(value.round_id, "round_id");
  assertUuid(value.playing_group_id, "playing_group_id");
  assertKeys(value.scorer, ["type", "round_entry_id"], ["type", "round_entry_id"], "scorer scope");
  if (value.scorer.type !== "player") {
    throw new SubmissionSerializationError("Scorer scope must identify a player round entry");
  }
  assertUuid(value.scorer.round_entry_id, "scorer round_entry_id");

  return {
    event_id: value.event_id,
    round_id: value.round_id,
    playing_group_id: value.playing_group_id,
    scorer: {
      type: value.scorer.type,
      round_entry_id: value.scorer.round_entry_id,
    },
  };
}

function serializeAssignment(value, scope) {
  assertKeys(
    value,
    ["id", "round_entry_id", "assignment_version"],
    ["id", "round_entry_id", "assignment_version"],
    "captured assignment",
  );
  assertUuid(value.id, "assignment id");
  assertUuid(value.round_entry_id, "assignment round_entry_id");
  assertInteger(value.assignment_version, "assignment_version", 1);
  if (value.round_entry_id.toLowerCase() !== scope.scorer.round_entry_id.toLowerCase()) {
    throw new SubmissionSerializationError("Captured assignment does not belong to the scorer");
  }

  return {
    id: value.id,
    round_entry_id: value.round_entry_id,
    assignment_version: value.assignment_version,
  };
}

function serializeRoster(value) {
  if (!Array.isArray(value) || value.length < 2 || value.length > 4) {
    throw new SubmissionSerializationError("A scoring group must have 2 to 4 active players");
  }
  const ids = value.map((id) => {
    assertUuid(id, "active round_entry_id");
    return id;
  });
  const canonicalIds = ids.map((id) => id.toLowerCase());
  if (new Set(canonicalIds).size !== ids.length) {
    throw new SubmissionSerializationError("Active player identities must be unique");
  }
  return ids;
}

function serializeCommand(value, scope, assignment, activeRoundEntryIds) {
  const fields = [
    "client_submission_id",
    "playing_group_id",
    "round_hole_id",
    "expected_group_score_revision",
    "role_assignment_version",
    "captured_at",
    "results",
  ];
  assertKeys(value, fields, fields, "SubmitGroupHole command");
  assertUuid(value.client_submission_id, "client_submission_id");
  assertUuid(value.playing_group_id, "playing_group_id");
  assertUuid(value.round_hole_id, "round_hole_id");
  assertInteger(value.expected_group_score_revision, "expected_group_score_revision", 0);
  assertInteger(value.role_assignment_version, "role_assignment_version", 1);
  if (value.playing_group_id.toLowerCase() !== scope.playing_group_id.toLowerCase()) {
    throw new SubmissionSerializationError("Command group does not match its scoring scope");
  }
  if (value.role_assignment_version !== assignment.assignment_version) {
    throw new SubmissionSerializationError("Command assignment version does not match captured assignment");
  }
  assertTimestamp(value.captured_at);
  if (!Array.isArray(value.results) || value.results.length < 2 || value.results.length > 4) {
    throw new SubmissionSerializationError("A whole-hole command requires outcomes for 2 to 4 players");
  }

  const results = value.results.map(serializeResult);
  const resultIds = results.map(({ round_entry_id }) => round_entry_id.toLowerCase());
  const expectedIds = activeRoundEntryIds.map((id) => id.toLowerCase());
  if (new Set(resultIds).size !== results.length) {
    throw new SubmissionSerializationError("A player may appear only once in a hole command");
  }
  if (
    resultIds.length !== expectedIds.length ||
    expectedIds.some((id) => !resultIds.includes(id))
  ) {
    throw new SubmissionSerializationError("Hole outcomes must cover every active player exactly once");
  }
  if (!resultIds.includes(scope.scorer.round_entry_id.toLowerCase())) {
    throw new SubmissionSerializationError("Scorer must have an outcome in the hole command");
  }

  return {
    client_submission_id: value.client_submission_id,
    playing_group_id: value.playing_group_id,
    round_hole_id: value.round_hole_id,
    expected_group_score_revision: value.expected_group_score_revision,
    role_assignment_version: value.role_assignment_version,
    captured_at: value.captured_at,
    results,
  };
}

function serializeResult(value) {
  assertKeys(
    value,
    ["round_entry_id", "outcome", "gross_strokes", "strokes_taken"],
    ["round_entry_id", "outcome", "gross_strokes"],
    "player outcome",
  );
  assertUuid(value.round_entry_id, "result round_entry_id");
  if (value.outcome !== "holed_out" && value.outcome !== "picked_up") {
    throw new SubmissionSerializationError("Player outcome must be holed_out or picked_up");
  }

  if (value.outcome === "holed_out") {
    assertInteger(value.gross_strokes, "gross_strokes", 1);
    if (Object.hasOwn(value, "strokes_taken")) assertInteger(value.strokes_taken, "strokes_taken", 0);
  } else {
    if (value.gross_strokes !== null) {
      throw new SubmissionSerializationError("Picked-up outcomes must not include gross strokes");
    }
    if (!Object.hasOwn(value, "strokes_taken")) {
      throw new SubmissionSerializationError("Picked-up outcomes require strokes_taken");
    }
    assertInteger(value.strokes_taken, "strokes_taken", 0);
  }

  const result = {
    round_entry_id: value.round_entry_id,
    outcome: value.outcome,
    gross_strokes: value.gross_strokes,
  };
  if (Object.hasOwn(value, "strokes_taken")) result.strokes_taken = value.strokes_taken;
  return result;
}

function assertKeys(value, allowed, required, label) {
  if (!isPlainRecord(value)) throw new SubmissionSerializationError(`${label} must be an object`);
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) throw new SubmissionSerializationError(`${label} contains unsupported field ${key}`);
  }
  for (const key of required) {
    if (!Object.hasOwn(value, key)) throw new SubmissionSerializationError(`${label} is missing ${key}`);
  }
}

function assertUuid(value, label) {
  if (typeof value !== "string" || !UUID.test(value)) {
    throw new SubmissionSerializationError(`${label} must be a UUID`);
  }
}

function assertInteger(value, label, minimum) {
  if (!Number.isSafeInteger(value) || value < minimum) {
    throw new SubmissionSerializationError(`${label} must be an integer greater than or equal to ${minimum}`);
  }
}

function assertTimestamp(value) {
  if (typeof value !== "string" || !ISO_TIMESTAMP.test(value) || !Number.isFinite(Date.parse(value))) {
    throw new SubmissionSerializationError("captured_at must be an ISO 8601 timestamp");
  }
  const [, year, month, day] = /^(\d{4})-(\d{2})-(\d{2})/.exec(value);
  const date = new Date(Date.UTC(Number(year), Number(month) - 1, Number(day)));
  if (
    date.getUTCFullYear() !== Number(year) ||
    date.getUTCMonth() !== Number(month) - 1 ||
    date.getUTCDate() !== Number(day)
  ) {
    throw new SubmissionSerializationError("captured_at must contain a valid calendar date");
  }
}

function isPlainRecord(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function compareStrings(left, right) {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

function canonicalTimestamp(value) {
  const [, year, month, day, hour, minute, second, fraction, zone, sign, offsetHours, offsetMinutes] =
    ISO_TIMESTAMP_PARTS.exec(value);
  const localSecond = Date.UTC(
    Number(year),
    Number(month) - 1,
    Number(day),
    Number(hour),
    Number(minute),
    Number(second),
  ) / 1000;
  const offset = zone === "Z"
    ? 0
    : (Number(offsetHours) * 60 + Number(offsetMinutes)) * (sign === "+" ? 1 : -1);
  const microseconds = (fraction || "").slice(0, 6).padEnd(6, "0");

  return `${localSecond - offset * 60}:${microseconds}`;
}

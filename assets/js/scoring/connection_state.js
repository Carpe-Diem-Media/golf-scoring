import {
  acknowledgeSubmission,
  enqueueSubmission,
  persistConflictStop,
  recoverPending,
} from "./queue.js";
import {
  clearReplayMarkersForRecovery,
  persistReplayIntent,
  readReplayMarkers,
} from "./indexed_db.js";
import { scopeKeyFor } from "./submission_serializer.js";

export const CONNECTION_STATES = Object.freeze({
  offline: "OFFLINE",
  pending: "PENDING",
  replaying: "REPLAYING",
  caughtUp: "CAUGHT_UP",
  conflictStop: "CONFLICT_STOP",
  recovery: "RECOVERY",
});

/**
 * The transport returns accepted only with a SubmitGroupHole receipt, returns rejected for an
 * explicit server error, and rejects its promise when the network result is uncertain.
 * Recovery authorization must come from a fresh server check for the exact pending assignment.
 */
export function createConnectionState(options) {
  if (!options || typeof options.transport !== "function") {
    throw new TypeError("A scoring submission transport is required");
  }

  const scope = options.scope;
  const scopeKey = scopeKeyFor(scope);
  const databaseOptions = options.databaseOptions || {};
  const replaySessionId = globalThis.crypto?.randomUUID?.() || null;
  const isOnline = options.isOnline || (() => globalThis.navigator?.onLine !== false);
  const lockManager = Object.hasOwn(options, "lockManager")
    ? options.lockManager
    : globalThis.navigator?.locks;
  const lockName = replayLockName(scope);
  let state = CONNECTION_STATES.offline;
  let conflict;

  async function persistSubmission(input) {
    if (scopeKeyFor(input?.scope) !== scopeKey) {
      throw new Error("A scoring controller can persist commands for its own scope only");
    }

    const record = await enqueueSubmission(input, databaseOptions);
    if (state !== CONNECTION_STATES.conflictStop && state !== CONNECTION_STATES.recovery) {
      state = CONNECTION_STATES.pending;
    }
    return record;
  }

  async function refresh() {
    if (state === CONNECTION_STATES.conflictStop || state === CONNECTION_STATES.recovery) {
      return state;
    }

    const markers = await readReplayMarkers(scopeKey, databaseOptions);
    if (markers.conflict_stop) {
      conflict = markers.conflict_stop;
      state = CONNECTION_STATES.conflictStop;
      return state;
    }
    if (markers.replay_intent && markers.replay_intent.session_id !== replaySessionId) {
      conflict = unresolvedIntentConflict(markers.replay_intent);
      state = CONNECTION_STATES.conflictStop;
      return state;
    }

    const pending = await recoverPending(scope, databaseOptions);
    state = pending.length
      ? CONNECTION_STATES.pending
      : isOnline()
        ? CONNECTION_STATES.caughtUp
        : CONNECTION_STATES.offline;
    return state;
  }

  async function replay() {
    try {
      await refresh();
    } catch (_error) {
      state = CONNECTION_STATES.pending;
      return state;
    }
    if (state === CONNECTION_STATES.conflictStop) return state;
    if (!replaySessionId) {
      state = CONNECTION_STATES.pending;
      return state;
    }

    let initialPending;
    try {
      initialPending = await recoverPending(scope, databaseOptions);
    } catch (_error) {
      state = CONNECTION_STATES.pending;
      return state;
    }
    if (initialPending.length === 0) return state;
    if (!isOnline()) {
      state = CONNECTION_STATES.pending;
      return state;
    }

    if (!lockManager || typeof lockManager.request !== "function") {
      state = CONNECTION_STATES.pending;
      return state;
    }

    try {
      return await lockManager.request(
        lockName,
        { mode: "exclusive", ifAvailable: true },
        async (lock) => {
          if (!lock) {
            state = CONNECTION_STATES.pending;
            return state;
          }

          while (true) {
            const pending = await recoverPending(scope, databaseOptions);
            if (pending.length === 0) {
              state = CONNECTION_STATES.caughtUp;
              return state;
            }
            const markers = await readReplayMarkers(scopeKey, databaseOptions);
            if (markers.conflict_stop) {
              conflict = markers.conflict_stop;
              state = CONNECTION_STATES.conflictStop;
              return state;
            }
            if (markers.replay_intent && (
              markers.replay_intent.session_id !== replaySessionId ||
              !samePendingCommand(markers.replay_intent, pending[0])
            )) {
              conflict = unresolvedIntentConflict(markers.replay_intent);
              state = CONNECTION_STATES.conflictStop;
              return state;
            }
            if (!isOnline()) {
              state = CONNECTION_STATES.pending;
              return state;
            }

            const record = pending[0];
            const command = structuredClone(record.command);
            const context = {
              scope: structuredClone(record.scope),
              scope_key: record.scope_key,
              assignment: structuredClone(record.metadata.captured_assignment),
              active_round_entry_ids: structuredClone(record.metadata.active_round_entry_ids),
              sequence: record.sequence,
            };
            const replayIntent = markers.replay_intent || {
              submission_id: record.command.client_submission_id,
              sequence: record.sequence,
              session_id: replaySessionId,
            };

            let intentPersisted;
            try {
              intentPersisted = await persistReplayIntent(scopeKey, replayIntent, databaseOptions);
            } catch (_error) {
              state = CONNECTION_STATES.pending;
              return state;
            }
            if (!intentPersisted) {
              let latestMarkers;
              try {
                latestMarkers = await readReplayMarkers(scopeKey, databaseOptions);
              } catch (_error) {
                state = CONNECTION_STATES.pending;
                return state;
              }
              if (latestMarkers.conflict_stop) {
                conflict = latestMarkers.conflict_stop;
                state = CONNECTION_STATES.conflictStop;
                return state;
              }
              if (latestMarkers.replay_intent) {
                conflict = unresolvedIntentConflict(latestMarkers.replay_intent);
                state = CONNECTION_STATES.conflictStop;
                return state;
              }
              state = CONNECTION_STATES.pending;
              return state;
            }

            state = CONNECTION_STATES.replaying;
            let response;
            try {
              response = await options.transport(command, context);
            } catch (_error) {
              state = CONNECTION_STATES.pending;
              return state;
            }

            if (response?.status === "rejected") {
              try {
                conflict = await persistConflictStop(record, response.reason, databaseOptions);
              } catch (_error) {
                conflict = {
                  submission_id: record.command.client_submission_id,
                  sequence: record.sequence,
                  reason: typeof response.reason === "string" ? response.reason : "server_rejected",
                };
              }
              state = CONNECTION_STATES.conflictStop;
              return state;
            }

            if (response?.status !== "accepted") {
              state = CONNECTION_STATES.pending;
              return state;
            }

            let acknowledged;
            try {
              acknowledged = await acknowledgeSubmission(record, response.receipt, {
                ...databaseOptions,
                replayIntent,
              });
            } catch (_error) {
              state = CONNECTION_STATES.pending;
              return state;
            }
            if (!acknowledged) {
              state = CONNECTION_STATES.pending;
              return state;
            }
          }
        },
      );
    } catch (_error) {
      if (state === CONNECTION_STATES.replaying) state = CONNECTION_STATES.pending;
      return state;
    }
  }

  async function recover({ authorize } = {}) {
    if (state !== CONNECTION_STATES.conflictStop) await refresh();
    if (state !== CONNECTION_STATES.conflictStop || typeof authorize !== "function") return state;

    let markers;
    try {
      markers = await readReplayMarkers(scopeKey, databaseOptions);
    } catch (_error) {
      return state;
    }

    if (markers.conflict_stop && markers.replay_intent && !sameConflictCommand(markers.conflict_stop, markers.replay_intent)) {
      return state;
    }
    const stopped = markers.conflict_stop || conflict || (
      markers.replay_intent && unresolvedIntentConflict(markers.replay_intent)
    );
    if (!stopped) return state;
    if (markers.replay_intent && !sameConflictCommand(stopped, markers.replay_intent)) return state;

    let pending;
    try {
      pending = await recoverPending(scope, databaseOptions);
    } catch (_error) {
      return state;
    }
    const record = pending.find((item) =>
      item.sequence === stopped.sequence &&
      sameId(item.command.client_submission_id, stopped.submission_id)
    );
    if (!record) return state;

    let authorization;
    try {
      authorization = await authorize({
        scope: structuredClone(scope),
        scope_key: scopeKey,
        conflict: { ...stopped },
        assignment: structuredClone(record.metadata.captured_assignment),
      });
    } catch (_error) {
      return state;
    }

    if (!validRecoveryAuthorization(authorization, scopeKey, stopped, record)) return state;

    let cleared;
    try {
      cleared = await clearReplayMarkersForRecovery(
        scopeKey,
        markers.conflict_stop,
        markers.replay_intent,
        databaseOptions,
      );
    } catch (_error) {
      return state;
    }
    if (!cleared) return state;

    conflict = undefined;
    state = CONNECTION_STATES.recovery;
    return state;
  }

  return {
    get state() {
      return state;
    },
    get conflict() {
      return conflict && { ...conflict };
    },
    persistSubmission,
    refresh,
    replay,
    recover,
  };
}

function validRecoveryAuthorization(authorization, scopeKey, conflict, record) {
  const assignment = record.metadata.captured_assignment;
  return (
    authorization?.status === "authorized" &&
    authorization.scope_key === scopeKey &&
    sameId(authorization.submission_id, conflict.submission_id) &&
    sameId(authorization.assignment_id, assignment.id) &&
    authorization.assignment_version === assignment.assignment_version
  );
}

function sameId(left, right) {
  return typeof left === "string" &&
    typeof right === "string" &&
    left.toLowerCase() === right.toLowerCase();
}

function replayLockName(scope) {
  return `golf-scoring-replay:${JSON.stringify([
    scope.event_id.toLowerCase(),
    scope.round_id.toLowerCase(),
    scope.playing_group_id.toLowerCase(),
  ])}`;
}

function samePendingCommand(intent, record) {
  return intent.sequence === record.sequence &&
    sameId(intent.submission_id, record.command.client_submission_id);
}

function sameConflictCommand(conflict, intent) {
  return conflict.sequence === intent.sequence &&
    sameId(conflict.submission_id, intent.submission_id);
}

function unresolvedIntentConflict(intent) {
  return {
    submission_id: intent.submission_id,
    sequence: intent.sequence,
    reason: "replay_intent_unresolved",
  };
}

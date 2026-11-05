import { CONNECTION_STATES, createConnectionState } from "../scoring/connection_state.js";
import { persistConflictStop, recoverPending } from "../scoring/queue.js";

const FORM_SELECTOR = "#scorecard-entry-form";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const ScoringQueue = {
  mounted() {
    this.form = null;
    this.submitListener = (event) => this.submitHole(event);
    this.offlineChangeListener = (event) => {
      if (!this.hasAuthorizedConnection()) event.stopPropagation();
    };
    this.refreshElements();
    this.destroyedQueue = false;
    this.replayingQueue = false;
    this.replayPromise = null;
    this.pendingCount = 0;
    this.nextRevision = 0;
    this.serverRevision = 0;
    this.initializingQueue = true;

    this.onlineListener = () => this.replayPending();
    this.offlineListener = () => this.renderStatus();
    window.addEventListener("online", this.onlineListener);
    window.addEventListener("offline", this.offlineListener);

    this.setControlsDisabled(true);

    this.ready = this.restoreQueue();
  },

  updated() {
    if (this.destroyedQueue || !this.projectionRoot) return;
    this.refreshElements();
    if (!this.initializingQueue) {
      this.setControlsDisabled(
        this.replayingQueue || this.controller?.state === CONNECTION_STATES.conflictStop,
      );
    }

    try {
      const projection = readProjection(this.projectionRoot);
      if (projection.revision === this.serverRevision) return;
      this.projection = projection;
      this.serverRevision = projection.revision;

      if (!this.replayPromise) {
        void this.syncAfterServerUpdate();
      }
    } catch (_error) {
      this.showAttention("The scorecard data changed. Refresh this scorecard before continuing.");
    }
  },

  disconnected() {
    this.renderStatus();
  },

  reconnected() {
    this.replayPending();
  },

  destroyed() {
    this.destroyedQueue = true;
    if (this.form && this.submitListener) {
      this.form.removeEventListener("submit", this.submitListener);
    }
    if (this.form && this.offlineChangeListener) {
      this.form.removeEventListener("input", this.offlineChangeListener);
      this.form.removeEventListener("change", this.offlineChangeListener);
    }
    if (this.onlineListener) window.removeEventListener("online", this.onlineListener);
    if (this.offlineListener) window.removeEventListener("offline", this.offlineListener);
  },

  refreshElements() {
    this.statusRoot = this.el;
    this.projectionRoot = this.el;
    this.lifecycle = this.el.dataset.scorecardLifecycle;
    const nextForm = this.el.querySelector(FORM_SELECTOR);

    if (nextForm !== this.form) {
      if (this.form && this.submitListener) {
        this.form.removeEventListener("submit", this.submitListener);
      }
      this.form = nextForm;
      if (this.form && this.submitListener) {
        this.form.addEventListener("submit", this.submitListener);
      }
      if (this.form && this.offlineChangeListener) {
        this.form.addEventListener("input", this.offlineChangeListener);
        this.form.addEventListener("change", this.offlineChangeListener);
      }
    }

    this.submitButton = this.form?.querySelector("#submit-group-hole");
    this.feedback = this.statusRoot.querySelector("#scorecard-feedback");
  },

  async restoreQueue() {
    try {
      this.projection = readProjection(this.projectionRoot);
      this.serverRevision = this.projection.revision;
      this.nextRevision = this.serverRevision;
      this.controller = createConnectionState({
        scope: this.projection.scope,
        isOnline: () => globalThis.navigator?.onLine !== false,
        transport: (command) => this.submitToLiveView(command),
      });

      await this.controller.refresh();
      const pending = await recoverPending(this.projection.scope);
      this.pendingCount = pending.length;

      if (await this.resumeUnacknowledgedCommand(pending)) {
        const remaining = await recoverPending(this.projection.scope);
        this.pendingCount = remaining.length;
        await this.recalculateNextRevision(remaining);
        this.renderCurrentHole();
        this.initializingQueue = false;
        this.renderStatus();
        await this.replayPending();
        return;
      }

      await this.recalculateNextRevision(pending);

      this.renderCurrentHole();
      this.initializingQueue = false;
      this.setControlsDisabled(this.controller.state === CONNECTION_STATES.conflictStop);
      this.renderStatus();

      if (this.controller.state !== CONNECTION_STATES.conflictStop) {
        await this.replayPending();
      }
    } catch (_error) {
      this.initializingQueue = false;
      this.showAttention("This browser could not verify its saved scores. Keep this page open and try again.");
    }
  },

  async syncAfterServerUpdate() {
    try {
      const pending = await recoverPending(this.projection.scope);
      this.pendingCount = pending.length;

      if (await this.resumeUnacknowledgedCommand(pending)) {
        const remaining = await recoverPending(this.projection.scope);
        this.pendingCount = remaining.length;
        await this.recalculateNextRevision(remaining);
        this.renderCurrentHole();
        this.renderStatus();
        await this.replayPending();
        return;
      }

      await this.recalculateNextRevision(pending, { preserveCurrent: true });

      this.renderCurrentHole();
      this.renderStatus();
      if (this.controller.state !== CONNECTION_STATES.conflictStop) {
        this.setControlsDisabled(false);
      }
    } catch (_error) {
      this.showAttention("This browser could not verify its saved scores. Keep this page open and try again.");
    }
  },

  async resumeUnacknowledgedCommand(pending) {
    if (this.controller.state !== CONNECTION_STATES.conflictStop) return false;

    const conflict = this.controller.conflict;
    if (conflict?.reason !== "replay_intent_unresolved") return true;

    const record = pending[0];
    if (!this.isRecoverableCommand(record, conflict) || !this.hasAuthorizedConnection()) return true;

    await this.controller.recover({
      authorize: async ({ scope_key, assignment, conflict: unresolved }) => {
        const response = await this.pushEvent("resolve_queued_hole", { command: record.command });
        const receipt = response?.receipt;

        if (response?.status !== "resolved" || !this.matchesAuthorizedReceipt(receipt, record)) {
          return null;
        }

        return {
          status: "authorized",
          scope_key,
          submission_id: unresolved.submission_id,
          assignment_id: assignment.id,
          assignment_version: assignment.assignment_version,
          receipt,
        };
      },
    });

    return true;
  },

  async recalculateNextRevision(pending, { preserveCurrent = false } = {}) {
    if (this.controller.state === CONNECTION_STATES.conflictStop) return false;

    if (!this.isContiguous(pending, this.serverRevision)) {
      await persistConflictStop(pending[0], "local_progression_mismatch");
      await this.controller.refresh();
      return false;
    }

    const nextRevision = this.serverRevision + pending.length;
    this.nextRevision = preserveCurrent
      ? Math.max(this.nextRevision, nextRevision)
      : nextRevision;
    return true;
  },

  isRecoverableCommand(record, conflict) {
    if (!record || !this.projection || this.projection.route.length !== 18) return false;

    const command = record.command;
    const assignment = record.metadata?.captured_assignment;
    const scope = record.scope;
    const routeHole = this.projection.route[command.expected_group_score_revision];

    return (
      Number.isSafeInteger(command.expected_group_score_revision) &&
      command.expected_group_score_revision >= 0 &&
      command.expected_group_score_revision < 18 &&
      sameId(command.round_hole_id, routeHole?.id) &&
      sameId(command.client_submission_id, conflict.submission_id) &&
      record.sequence === conflict.sequence &&
      sameId(command.playing_group_id, this.projection.scope.playing_group_id) &&
      sameId(scope?.event_id, this.projection.scope.event_id) &&
      sameId(scope?.round_id, this.projection.scope.round_id) &&
      sameId(scope?.playing_group_id, this.projection.scope.playing_group_id) &&
      sameId(scope?.scorer?.round_entry_id, this.projection.scope.scorer.round_entry_id) &&
      sameId(assignment?.id, this.projection.assignment.id) &&
      sameId(assignment?.round_entry_id, this.projection.assignment.round_entry_id) &&
      assignment?.assignment_version === this.projection.assignment.assignment_version &&
      command.role_assignment_version === this.projection.assignment.assignment_version
    );
  },

  matchesAuthorizedReceipt(receipt, record) {
    const command = record.command;
    const scope = record.scope;
    const assignment = record.metadata.captured_assignment;
    const payload = receipt?.submitted_payload;
    const actor = payload?.actor;

    return (
      receipt?.client_submission_id === command.client_submission_id &&
      receipt.round_id === scope.round_id &&
      receipt.playing_group_id === scope.playing_group_id &&
      receipt.round_hole_id === command.round_hole_id &&
      receipt.expected_group_score_revision === command.expected_group_score_revision &&
      receipt.group_role_assignment_id === assignment.id &&
      receipt.role_assignment_version === assignment.assignment_version &&
      receipt.submitted_by_round_entry_id === scope.scorer.round_entry_id &&
      receipt.source === "normal" &&
      timestampsMatch(receipt.captured_at, command.captured_at) &&
      typeof receipt.payload_fingerprint === "string" &&
      payload?.playing_group_id === command.playing_group_id &&
      payload.round_hole_id === command.round_hole_id &&
      payload.expected_group_score_revision === command.expected_group_score_revision &&
      payload.role_assignment_version === command.role_assignment_version &&
      timestampsMatch(payload.captured_at, command.captured_at) &&
      actor?.type === "player" &&
      actor.round_entry_id === scope.scorer.round_entry_id &&
      actor.role_assignment_version === command.role_assignment_version &&
      sameResultPayload(payload.results, command.results)
    );
  },

  hasAuthorizedConnection() {
    return (
      globalThis.navigator?.onLine !== false &&
      this.liveSocket?.isConnected() === true
    );
  },

  isContiguous(records, revision) {
    return records.every((record, index) => {
      const expectedRevision = revision + index;
      const routeHole = this.projection.route[expectedRevision];
      return (
        record.command.expected_group_score_revision === expectedRevision &&
        routeHole?.id?.toLowerCase() === record.command.round_hole_id.toLowerCase()
      );
    });
  },

  async submitHole(event) {
    event.preventDefault();
    event.stopPropagation();
    if (this.initializingQueue || this.replayingQueue || this.controller?.state === CONNECTION_STATES.conflictStop) {
      return;
    }

    let command;
    try {
      command = commandFromForm(this.form, this.projection, this.nextRevision);
    } catch (_error) {
      this.setFeedback("Complete every golfer's result before submitting.");
      return;
    }

    this.setControlsDisabled(true);
    try {
      await this.controller.persistSubmission({
        scope: this.projection.scope,
        assignment: this.projection.assignment,
        active_round_entry_ids: this.projection.active_round_entry_ids,
        command,
      });

      this.nextRevision += 1;
      this.pendingCount += 1;
      this.setFeedback("");
      this.renderCurrentHole();
      this.renderStatus();
      this.setControlsDisabled(false);

      await this.replayPending();
    } catch (_error) {
      this.showAttention("This hole was not saved on this device. Keep the scorecard open and try again.");
      this.setControlsDisabled(false);
    }
  },

  async submitToLiveView(command) {
    if (
      globalThis.navigator?.onLine === false ||
      !this.liveSocket ||
      !this.liveSocket.isConnected()
    ) {
      throw new Error("The authorized scorecard connection is unavailable");
    }

    return this.pushEvent("submit_queued_hole", { command });
  },

  replayPending() {
    if (this.replayPromise || this.destroyedQueue || !this.controller) {
      return this.replayPromise || Promise.resolve();
    }
    if (globalThis.navigator?.onLine === false || !this.liveSocket?.isConnected()) {
      this.controller.refresh().then(() => this.renderStatus()).catch(() => this.renderStatus());
      return Promise.resolve();
    }

    this.replayPromise = Promise.resolve().then(async () => {
      this.replayingQueue = true;
      this.setControlsDisabled(true);
      this.renderStatus();

      try {
        await this.controller.replay();
        await nextPaint();
        const latest = readProjection(this.projectionRoot);
        if (latest.revision > this.serverRevision) {
          this.projection = latest;
          this.serverRevision = latest.revision;
        }

        const pending = await recoverPending(this.projection.scope);
        this.pendingCount = pending.length;
        if (pending.length === 0) {
          this.nextRevision = Math.max(this.nextRevision, this.serverRevision);
        }
        this.renderCurrentHole();
      } catch (_error) {
        this.pendingCount = await recoverPending(this.projection.scope).then((records) => records.length).catch(() => this.pendingCount);
      } finally {
        this.replayingQueue = false;
        this.replayPromise = null;
        this.renderStatus();
        this.setControlsDisabled(this.controller.state === CONNECTION_STATES.conflictStop);
      }
    });

    return this.replayPromise;
  },

  renderCurrentHole() {
    const hole = this.projection.route[this.nextRevision];
    const currentHole = this.projectionRoot.querySelector("#current-hole");
    if (!hole) {
      if (currentHole) currentHole.textContent = "All holes queued for sync";
      if (this.submitButton) this.submitButton.disabled = true;
      return;
    }

    if (currentHole) currentHole.textContent = `Hole ${hole.display_hole_number}`;
    if (!this.form) return;
    this.setNamedValue("scorecard[expected_group_score_revision]", this.nextRevision);
    this.setNamedValue("scorecard[round_hole_id]", hole.id);
    this.setNamedValue("scorecard[client_submission_id]", globalThis.crypto.randomUUID());
    this.setNamedValue("scorecard[captured_at]", new Date().toISOString());

    hole.players.forEach((fact, index) => {
      const player = this.form.querySelector(`[data-scorecard-entry-id="${cssEscape(fact.round_entry_id)}"]`);
      if (!player) return;

      setText(player.querySelector(`#scorecard-par-${index}`), `Par ${fact.par}`);
      setText(player.querySelector(`#scorecard-stroke-index-${index}`), fact.stroke_index);
      setText(
        player.querySelector(`#scorecard-distance-${index}`),
        fact.distance_m == null ? "Not recorded" : `${fact.distance_m} m`,
      );
      setText(player.querySelector(`#scorecard-handicap-strokes-${index}`), fact.handicap_strokes_label);

      const resultPrefix = `scorecard[results][${fact.round_entry_id}]`;
      const outcome = this.form.elements.namedItem(`${resultPrefix}[outcome]`);
      const gross = this.form.elements.namedItem(`${resultPrefix}[gross_strokes]`);
      const strokesTaken = this.form.elements.namedItem(`${resultPrefix}[strokes_taken]`);
      if (outcome) outcome.value = "";
      if (gross) {
        gross.value = "";
        gross.disabled = false;
      }
      if (strokesTaken) strokesTaken.value = "";
    });

    this.form.querySelectorAll("[data-scorecard-preview]").forEach((preview) => preview.remove());
    if (globalThis.navigator?.onLine === false || !this.liveSocket?.isConnected()) {
      this.addOfflinePickupOptions();
    }
    this.updateProgress();
    if (this.submitButton) this.submitButton.disabled = false;
  },

  addOfflinePickupOptions() {
    this.form.querySelectorAll('select[name$="[outcome]"]').forEach((select) => {
      if (Array.from(select.options).some((option) => option.value === "picked_up")) return;
      const option = document.createElement("option");
      option.value = "picked_up";
      option.textContent = "Picked up, no points";
      select.append(option);
    });
  },

  updateProgress() {
    if (!this.form) return;

    setText(
      this.projectionRoot.querySelector("#completed-holes-label"),
      `${this.serverRevision} of 18 holes complete`,
    );
    const progress = this.projectionRoot.querySelector("#holes-complete-progress");
    if (progress) progress.value = this.serverRevision;
    setText(this.projectionRoot.querySelector("#holes-remaining"), `${Math.max(18 - this.nextRevision, 0)} remaining`);
  },

  async renderStatus() {
    if (!this.statusRoot) return;
    const label = this.statusRoot.querySelector("#scoring-sync-label");
    const count = this.statusRoot.querySelector("#scoring-pending-count");
    const state = this.controller?.state;
    const conflict = state === CONNECTION_STATES.conflictStop;
    const online = globalThis.navigator?.onLine !== false && this.liveSocket?.isConnected();

    if (conflict) {
      setText(label, "Attention required");
    } else if (this.pendingCount > 0 || state === CONNECTION_STATES.pending || state === CONNECTION_STATES.replaying) {
      setText(label, "Pending sync");
    } else {
      setText(label, online ? "Saved" : "Offline");
    }

    setText(count, `${this.pendingCount} pending`);
    if (count) count.hidden = this.pendingCount === 0;
    if (conflict) {
      this.setControlsDisabled(true);
      this.setFeedback("Attention required. These scores need a current server check before more can be entered.");
    }
  },

  setControlsDisabled(disabled) {
    if (!this.form) return;
    this.form.querySelectorAll("input, select, button").forEach((control) => {
      if (disabled) {
        if (!control.hasAttribute("data-queue-previously-disabled")) {
          control.dataset.queuePreviouslyDisabled = String(control.disabled);
        }
        control.disabled = true;
      } else if (control.hasAttribute("data-queue-previously-disabled")) {
        control.disabled = control.dataset.queuePreviouslyDisabled === "true";
        delete control.dataset.queuePreviouslyDisabled;
      }
    });
    if (this.submitButton && !disabled) {
      this.submitButton.disabled = this.nextRevision >= this.projection.route.length;
    }
  },

  setNamedValue(name, value) {
    const field = this.form.elements.namedItem(name);
    if (field) field.value = String(value);
  },

  setFeedback(message) {
    if (this.feedback) {
      this.feedback.textContent = message;
      this.feedback.hidden = message === "";
    }
  },

  showAttention(message) {
    this.pendingCount = Math.max(this.pendingCount, 0);
    const label = this.statusRoot?.querySelector("#scoring-sync-label");
    setText(label, "Attention required");
    this.setFeedback(message);
    this.setControlsDisabled(true);
  },
};

function readProjection(form) {
  const projection = JSON.parse(form.dataset.scoringQueueProjection || "null");
  if (
    !projection ||
    !Number.isSafeInteger(projection.revision) ||
    projection.revision < 0 ||
    !Array.isArray(projection.route) ||
    !Array.isArray(projection.active_round_entry_ids) ||
    projection.active_round_entry_ids.length < 2 ||
    projection.active_round_entry_ids.length > 4 ||
    !UUID.test(projection.scope?.event_id || "") ||
    !UUID.test(projection.scope?.round_id || "") ||
    !UUID.test(projection.scope?.playing_group_id || "") ||
    !UUID.test(projection.scope?.scorer?.round_entry_id || "") ||
    !UUID.test(projection.assignment?.id || "") ||
    !UUID.test(projection.assignment?.round_entry_id || "") ||
    !Number.isSafeInteger(projection.assignment?.assignment_version) ||
    projection.assignment.assignment_version < 1
  ) {
    throw new Error("The authorized scorecard projection is invalid");
  }
  return projection;
}

function commandFromForm(form, projection, revision) {
  const hole = projection.route[revision];
  if (!hole) throw new Error("The group route is complete");

  const results = projection.active_round_entry_ids.map((roundEntryId) => {
    const prefix = `scorecard[results][${roundEntryId}]`;
    const outcome = form.elements.namedItem(`${prefix}[outcome]`)?.value;
    const grossValue = form.elements.namedItem(`${prefix}[gross_strokes]`)?.value;
    const strokesTakenValue = form.elements.namedItem(`${prefix}[strokes_taken]`)?.value;

    if (outcome === "holed_out") {
      return {
        round_entry_id: roundEntryId,
        outcome,
        gross_strokes: parseScore(grossValue, 1),
      };
    }

    if (outcome === "picked_up") {
      return {
        round_entry_id: roundEntryId,
        outcome,
        gross_strokes: null,
        strokes_taken: parseScore(strokesTakenValue, 0),
      };
    }

    throw new Error("A complete group result is required");
  });

  return {
    client_submission_id: form.elements.namedItem("scorecard[client_submission_id]")?.value,
    playing_group_id: projection.scope.playing_group_id,
    round_hole_id: hole.id,
    expected_group_score_revision: revision,
    role_assignment_version: projection.assignment.assignment_version,
    captured_at: form.elements.namedItem("scorecard[captured_at]")?.value,
    results,
  };
}

function parseScore(value, minimum) {
  if (typeof value !== "string" || !/^\d+$/.test(value.trim())) {
    throw new Error("A whole stroke count is required");
  }
  const parsed = Number(value.trim());
  if (!Number.isSafeInteger(parsed) || parsed < minimum) {
    throw new Error("A whole stroke count is required");
  }
  return parsed;
}

function setText(element, value) {
  if (element) element.textContent = String(value);
}

function sameId(left, right) {
  return typeof left === "string" &&
    typeof right === "string" &&
    left.toLowerCase() === right.toLowerCase();
}

function sameResultPayload(received, expected) {
  if (!Array.isArray(received) || !Array.isArray(expected) || received.length !== expected.length) {
    return false;
  }

  const normalize = (results) => results
    .map((result) => ({
      round_entry_id: typeof result?.round_entry_id === "string"
        ? result.round_entry_id.toLowerCase()
        : result?.round_entry_id,
      outcome: result?.outcome,
      gross_strokes: result?.gross_strokes ?? null,
      strokes_taken: result?.strokes_taken ?? null,
    }))
    .sort((left, right) => left.round_entry_id.localeCompare(right.round_entry_id));

  return JSON.stringify(normalize(received)) === JSON.stringify(normalize(expected));
}

function timestampsMatch(left, right) {
  return typeof left === "string" &&
    typeof right === "string" &&
    Number.isFinite(Date.parse(left)) &&
    Date.parse(left) === Date.parse(right);
}

function cssEscape(value) {
  return globalThis.CSS?.escape ? CSS.escape(value) : value.replace(/[^a-zA-Z0-9_-]/g, "\\$&");
}

function nextPaint() {
  return new Promise((resolve) => requestAnimationFrame(() => resolve()));
}

export default ScoringQueue;

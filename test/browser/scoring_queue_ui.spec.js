import { expect, test } from "@playwright/test";

const ids = {
  event: "11111111-1111-4111-8111-111111111111",
  round: "22222222-2222-4222-8222-222222222222",
  group: "33333333-3333-4333-8333-333333333333",
  scorer: "44444444-4444-4444-8444-444444444444",
  assignment: "55555555-5555-4555-8555-555555555555",
  player: "66666666-6666-4666-8666-666666666666",
  holes: [
    "77777777-7777-4777-8777-777777777777",
    "88888888-8888-4888-8888-888888888888",
    "99999999-9999-4999-8999-999999999999",
  ],
};

function projection() {
  return {
    scope: {
      event_id: ids.event,
      round_id: ids.round,
      playing_group_id: ids.group,
      scorer: { type: "player", round_entry_id: ids.scorer },
    },
    assignment: {
      id: ids.assignment,
      round_entry_id: ids.scorer,
      assignment_version: 3,
    },
    active_round_entry_ids: [ids.scorer, ids.player],
    revision: 0,
    route: ids.holes.map((id, index) => ({
      id,
      display_hole_number: [14, 15, 16][index],
      players: [ids.scorer, ids.player].map((roundEntryId) => ({
        round_entry_id: roundEntryId,
        par: 4,
        stroke_index: index + 1,
        distance_m: 350 + index,
        handicap_strokes_label: "1 stroke received",
      })),
    })),
  };
}

function completedProjection() {
  const current = projection();
  const route = Array.from({ length: 18 }, (_, index) => ({
    id: current.route[index]?.id || `00000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
    display_hole_number: index + 1,
    players: current.active_round_entry_ids.map((roundEntryId) => ({
      round_entry_id: roundEntryId,
      par: 4,
      stroke_index: index + 1,
      distance_m: 350 + index,
      handicap_strokes_label: "1 stroke received",
    })),
  }));

  return { ...current, revision: 18, route };
}

function scorecardFixture() {
  return `
    <section id="group-scorecard" data-scorecard-lifecycle="scoring_active" data-scoring-queue-projection='${JSON.stringify(projection())}'>
      <header>
        <h2 id="current-hole">Hole 14</h2>
        <span id="completed-holes-label">0 of 18 holes complete</span>
        <progress id="holes-complete-progress" value="0" max="18"></progress>
        <p id="holes-remaining">18 remaining</p>
      </header>
      <form id="scorecard-entry-form">
      <input name="scorecard[expected_group_score_revision]" value="0">
      <input name="scorecard[round_hole_id]" value="${ids.holes[0]}">
      <input name="scorecard[client_submission_id]" value="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">
      <input name="scorecard[captured_at]" value="2026-11-05T08:00:00.000Z">
      <p id="scoring-sync-status" role="status" aria-live="polite">
        <span id="scoring-sync-label">Checking sync</span>
        <span id="scoring-pending-count" hidden>0</span>
      </p>
      <article data-scorecard-entry-id="${ids.scorer}">
        <p id="scorecard-par-0">Par 4</p>
        <p id="scorecard-stroke-index-0">1</p>
        <p id="scorecard-distance-0">350 m</p>
        <p id="scorecard-handicap-strokes-0">1 stroke received</p>
        <select name="scorecard[results][${ids.scorer}][outcome]"><option value="">Choose result</option><option value="holed_out">Holed out</option></select>
        <input name="scorecard[results][${ids.scorer}][gross_strokes]">
        <input name="scorecard[results][${ids.scorer}][strokes_taken]">
      </article>
      <article data-scorecard-entry-id="${ids.player}">
        <p id="scorecard-par-1">Par 4</p>
        <p id="scorecard-stroke-index-1">1</p>
        <p id="scorecard-distance-1">350 m</p>
        <p id="scorecard-handicap-strokes-1">1 stroke received</p>
        <select name="scorecard[results][${ids.player}][outcome]"><option value="">Choose result</option><option value="holed_out">Holed out</option></select>
        <input name="scorecard[results][${ids.player}][gross_strokes]">
        <input name="scorecard[results][${ids.player}][strokes_taken]">
      </article>
      <p id="scorecard-feedback"></p>
      <button id="submit-group-hole" type="submit">Save hole for group</button>
      </form>
    </section>`;
}

function completedScorecardFixture(completeProjection) {
  return `
    <section id="group-scorecard" data-scorecard-lifecycle="group_play_complete" data-scoring-queue-projection='${JSON.stringify(completeProjection)}'>
      <section id="group-play-complete">
        <h2>Group play complete</h2>
        <p id="scoring-sync-status" role="status" aria-live="polite">
          <span id="scoring-sync-label">Checking sync</span>
          <span id="scoring-pending-count" hidden>0 pending</span>
        </p>
        <p id="scorecard-feedback" hidden></p>
      </section>
    </section>`;
}

async function mountScorecard(page, responseMode = "accepted") {
  await page.addInitScript(() => {
    window.__testOnline = localStorage.getItem("__test_online") !== "false";
    const nativeOnLine = Object.getOwnPropertyDescriptor(Navigator.prototype, "onLine").get;
    Object.defineProperty(navigator, "onLine", {
      configurable: true,
      get: () => window.__testOnline && nativeOnLine.call(navigator),
    });
    window.__setTestOnline = (online) => {
      window.__testOnline = online;
      localStorage.setItem("__test_online", String(online));
      window.dispatchEvent(new Event(online ? "online" : "offline"));
    };
    window.__transportCalls = [];
    window.__makeReceipt = (command) => ({
      id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      client_submission_id: command.client_submission_id,
      round_id: "22222222-2222-4222-8222-222222222222",
      playing_group_id: command.playing_group_id,
      round_hole_id: command.round_hole_id,
      expected_group_score_revision: command.expected_group_score_revision,
      group_role_assignment_id: "55555555-5555-4555-8555-555555555555",
      role_assignment_version: command.role_assignment_version,
      submitted_by_round_entry_id: "44444444-4444-4444-8444-444444444444",
      captured_at: command.captured_at,
      payload_fingerprint: "a".repeat(64),
      source: "normal",
      submitted_payload: {
        playing_group_id: command.playing_group_id,
        round_hole_id: command.round_hole_id,
        expected_group_score_revision: command.expected_group_score_revision,
        role_assignment_version: command.role_assignment_version,
        captured_at: command.captured_at,
        actor: {
          type: "player",
          round_entry_id: "44444444-4444-4444-8444-444444444444",
          role_assignment_version: command.role_assignment_version,
        },
        results: command.results,
      },
    });
  });
  await page.goto("http://127.0.0.1:4173/");
  await page.setContent(scorecardFixture());
  await page.evaluate(async (mode) => {
    const { ScoringQueue } = await import("/hooks/scoring_queue.js");
    window.__transportCalls = [];
    const root = document.querySelector("#group-scorecard");
    const hook = Object.assign({
      el: root,
      liveSocket: { isConnected: () => navigator.onLine },
      async pushEvent(event, payload) {
        window.__transportCalls.push({ event, command: structuredClone(payload.command) });
        if (mode === "reject") {
          return { status: "rejected", reason: "stale_authority" };
        }
        return {
          status: "accepted",
          receipt: window.__makeReceipt(payload.command),
        };
      },
    }, ScoringQueue);
    window.__scorecardHook = hook;
    await hook.mounted();
    await hook.ready;
  }, responseMode);
}

test("queues holes through a real outage, restores after reload, then replays in order", async ({ page, context }) => {
  await mountScorecard(page);
  await context.setOffline(true);

  for (const entryId of [ids.scorer, ids.player]) {
    await page.locator(`[name="scorecard[results][${entryId}][outcome]"]`).selectOption("holed_out");
    await page.locator(`[name="scorecard[results][${entryId}][gross_strokes]"]`).fill("4");
  }
  await page.locator("#submit-group-hole").click();
  await expect(page.locator("#scoring-sync-label")).toHaveText("Pending sync");
  await expect(page.locator("#scoring-pending-count")).toHaveText("1 pending");
  await expect(page.locator("#current-hole")).toHaveText("Hole 15");
  await expect(page.locator('[name="scorecard[expected_group_score_revision]"]')).toHaveValue("1");
  await expect(page.locator('[name="scorecard[round_hole_id]"]')).toHaveValue(ids.holes[1]);
  await expect(page.locator("#scorecard-par-0")).toHaveText("Par 4");

  for (const entryId of [ids.scorer, ids.player]) {
    await page.locator(`[name="scorecard[results][${entryId}][outcome]"]`).selectOption("holed_out");
    await page.locator(`[name="scorecard[results][${entryId}][gross_strokes]"]`).fill("5");
  }
  await page.locator("#submit-group-hole").click();
  await expect(page.locator("#scoring-pending-count")).toHaveText("2 pending");
  await expect(page.locator("#current-hole")).toHaveText("Hole 16");
  expect(await page.evaluate(() => window.__transportCalls)).toHaveLength(0);

  const storedBeforeReload = await page.evaluate(async (scope) => {
    const { recoverPending } = await import("/scoring/queue.js");
    return recoverPending(scope);
  }, projection().scope);
  expect(storedBeforeReload).toHaveLength(2);
  expect(storedBeforeReload.map(({ command }) => [
    command.expected_group_score_revision,
    command.round_hole_id,
  ])).toEqual([
    [0, ids.holes[0]],
    [1, ids.holes[1]],
  ]);
  expect(storedBeforeReload.map(({ command }) => command.captured_at)).toEqual([
    expect.any(String),
    expect.any(String),
  ]);
  expect(JSON.stringify(storedBeforeReload)).not.toContain("mystery");
  await page.evaluate(() => window.__scorecardHook.destroyed());
  await page.evaluate(() => window.__setTestOnline(false));
  await context.setOffline(false);
  await page.reload();
  await page.setContent(scorecardFixture());
  await page.evaluate(async () => {
    const { ScoringQueue } = await import("/hooks/scoring_queue.js");
    const root = document.querySelector("#group-scorecard");
    const hook = Object.assign({
      el: root,
      liveSocket: { isConnected: () => navigator.onLine },
      async pushEvent(event, payload) {
        window.__transportCalls.push({ event, command: structuredClone(payload.command) });
        return { status: "accepted", receipt: window.__makeReceipt(payload.command) };
      },
    }, ScoringQueue);
    window.__scorecardHook = hook;
    await hook.mounted();
    await hook.ready;
  });
  await expect(page.locator("#scoring-pending-count")).toHaveText("2 pending");
  await expect(page.locator("#current-hole")).toHaveText("Hole 16");
  await expect(page.locator("#scoring-sync-label")).toHaveText("Pending sync");

  await page.evaluate(() => window.__setTestOnline(true));
  await expect(page.locator("#scoring-sync-label")).toHaveText("Saved", { timeout: 5000 });
  const calls = await page.evaluate(() => window.__transportCalls);
  expect(calls.map(({ event }) => event)).toEqual(["submit_queued_hole", "submit_queued_hole"]);
  expect(calls.map(({ command }) => command.expected_group_score_revision)).toEqual([0, 1]);
  expect(calls.map(({ command }) => command.round_hole_id)).toEqual(ids.holes.slice(0, 2));
  await expect(page.locator("#scoring-pending-count")).toHaveText("0 pending");
});

test("stops on a server conflict and does not resume after reload", async ({ page, context }) => {
  await mountScorecard(page, "reject");
  await context.setOffline(true);
  for (const entryId of [ids.scorer, ids.player]) {
    await page.locator(`[name="scorecard[results][${entryId}][outcome]"]`).selectOption("holed_out");
    await page.locator(`[name="scorecard[results][${entryId}][gross_strokes]"]`).fill("4");
  }
  await page.locator("#submit-group-hole").click();
  await expect(page.locator("#scoring-sync-label")).toHaveText("Pending sync");

  await context.setOffline(false);
  await expect(page.locator("#scoring-sync-label")).toHaveText("Attention required", { timeout: 5000 });
  await expect(page.locator("#scoring-pending-count")).toHaveText("1 pending");
  expect(await page.evaluate(() => window.__transportCalls)).toHaveLength(1);

  await page.evaluate(() => window.__scorecardHook.destroyed());
  await page.reload();
  await page.setContent(scorecardFixture());
  await page.evaluate(async () => {
    const { ScoringQueue } = await import("/hooks/scoring_queue.js");
    const root = document.querySelector("#group-scorecard");
    const hook = Object.assign({
      el: root,
      liveSocket: { isConnected: () => navigator.onLine },
      async pushEvent(event, payload) {
        window.__transportCalls.push({ event, command: structuredClone(payload.command) });
        return { status: "accepted", receipt: window.__makeReceipt(payload.command) };
      },
    }, ScoringQueue);
    window.__scorecardHook = hook;
    await hook.mounted();
    await hook.ready;
  });

  await expect(page.locator("#scoring-sync-label")).toHaveText("Attention required");
  expect(await page.evaluate(() => window.__transportCalls)).toHaveLength(0);
  await expect(page.locator("#submit-group-hole")).toBeDisabled();
});

test("shows an unresolved command on the completed scorecard", async ({ page }) => {
  const completeProjection = { ...projection(), revision: 3 };
  await page.goto("http://127.0.0.1:4173/");
  await page.setContent(completedScorecardFixture(completeProjection));
  await page.evaluate(async (authorizedProjection) => {
    const { enqueueSubmission } = await import("/scoring/queue.js");
    const { ScoringQueue } = await import("/hooks/scoring_queue.js");
    const command = {
      client_submission_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      playing_group_id: authorizedProjection.scope.playing_group_id,
      round_hole_id: authorizedProjection.route[2].id,
      expected_group_score_revision: 2,
      role_assignment_version: authorizedProjection.assignment.assignment_version,
      captured_at: "2026-11-05T08:00:00.000Z",
      results: authorizedProjection.active_round_entry_ids.map((round_entry_id) => ({
        round_entry_id,
        outcome: "holed_out",
        gross_strokes: 4,
      })),
    };
    await enqueueSubmission({
      scope: authorizedProjection.scope,
      assignment: authorizedProjection.assignment,
      active_round_entry_ids: authorizedProjection.active_round_entry_ids,
      command,
    });

    window.__transportCalls = [];
    const hook = Object.assign({
      el: document.querySelector("#group-scorecard"),
      liveSocket: { isConnected: () => navigator.onLine },
      async pushEvent(event) {
        window.__transportCalls.push(event);
        throw new Error("a completed scorecard must stop this stale command");
      },
    }, ScoringQueue);
    window.__scorecardHook = hook;
    await hook.mounted();
    await hook.ready;
  }, completeProjection);

  await expect(page.locator("#scoring-sync-label")).toHaveText("Attention required");
  await expect(page.locator("#scoring-pending-count")).toHaveText("1 pending");
  await expect(page.locator("#scorecard-feedback")).toHaveText(/current server check/);
  expect(await page.evaluate(() => window.__transportCalls)).toHaveLength(0);
});

test("reconciles an accepted final-hole command after its acknowledgement is lost", async ({ page }) => {
  const completeProjection = completedProjection();
  await page.goto("http://127.0.0.1:4173/");
  await page.setContent(completedScorecardFixture(completeProjection));
  await page.evaluate(async (authorizedProjection) => {
    const { enqueueSubmission, recoverPending } = await import("/scoring/queue.js");
    const { persistReplayIntent } = await import("/scoring/indexed_db.js");
    const { ScoringQueue } = await import("/hooks/scoring_queue.js");
    const command = {
      client_submission_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      playing_group_id: authorizedProjection.scope.playing_group_id,
      round_hole_id: authorizedProjection.route[17].id,
      expected_group_score_revision: 17,
      role_assignment_version: authorizedProjection.assignment.assignment_version,
      captured_at: "2026-11-05T08:00:00.000Z",
      results: authorizedProjection.active_round_entry_ids.map((round_entry_id) => ({
        round_entry_id,
        outcome: "holed_out",
        gross_strokes: 4,
      })),
    };
    window.__makeReceipt = (candidate) => ({
      id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      client_submission_id: candidate.client_submission_id,
      round_id: authorizedProjection.scope.round_id,
      playing_group_id: candidate.playing_group_id,
      round_hole_id: candidate.round_hole_id,
      expected_group_score_revision: candidate.expected_group_score_revision,
      group_role_assignment_id: authorizedProjection.assignment.id,
      role_assignment_version: candidate.role_assignment_version,
      submitted_by_round_entry_id: authorizedProjection.scope.scorer.round_entry_id,
      captured_at: candidate.captured_at,
      payload_fingerprint: "a".repeat(64),
      source: "normal",
      submitted_payload: {
        playing_group_id: candidate.playing_group_id,
        round_hole_id: candidate.round_hole_id,
        expected_group_score_revision: candidate.expected_group_score_revision,
        role_assignment_version: candidate.role_assignment_version,
        captured_at: candidate.captured_at,
        actor: {
          type: "player",
          round_entry_id: authorizedProjection.scope.scorer.round_entry_id,
          role_assignment_version: candidate.role_assignment_version,
        },
        results: candidate.results,
      },
    });

    await enqueueSubmission({
      scope: authorizedProjection.scope,
      assignment: authorizedProjection.assignment,
      active_round_entry_ids: authorizedProjection.active_round_entry_ids,
      command,
    });
    const [record] = await recoverPending(authorizedProjection.scope);
    await persistReplayIntent(record.scope_key, {
      submission_id: command.client_submission_id,
      sequence: record.sequence,
      session_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
    });

    window.__transportCalls = [];
    const hook = Object.assign({
      el: document.querySelector("#group-scorecard"),
      liveSocket: { isConnected: () => navigator.onLine },
      async pushEvent(event, payload) {
        window.__transportCalls.push({ event, command: structuredClone(payload.command) });
        return { status: "accepted", receipt: window.__makeReceipt(payload.command) };
      },
    }, ScoringQueue);
    window.__scorecardHook = hook;
    await hook.mounted();
    await hook.ready;
  }, completeProjection);

  await expect(page.locator("#scoring-sync-label")).toHaveText("Saved");
  await expect(page.locator("#scoring-pending-count")).toHaveText("0 pending");
  expect(await page.evaluate(() => window.__transportCalls.map(({ command }) => command.client_submission_id))).toEqual([
    "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  ]);
  const pending = await page.evaluate(async (scope) => {
    const { recoverPending } = await import("/scoring/queue.js");
    return recoverPending(scope);
  }, completeProjection.scope);
  expect(pending).toHaveLength(0);
});

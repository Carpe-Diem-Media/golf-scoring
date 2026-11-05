import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { chromium, expect, test } from "@playwright/test";

const eventId = "11111111-1111-4111-8111-111111111111";
const roundId = "22222222-2222-4222-8222-222222222222";
const groupId = "33333333-3333-4333-8333-333333333333";
const scorerId = "44444444-4444-4444-8444-444444444444";
const assignmentId = "55555555-5555-4555-8555-555555555555";
const secondPlayerId = "66666666-6666-4666-8666-666666666666";
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

async function recover(page, scope) {
  return page.evaluate(async (scoringScope) => {
    const { recoverPending } = await import("/scoring/queue.js");
    return recoverPending(scoringScope);
  }, scope);
}

test("recovers after reload and browser restart with the same persistent profile", async () => {
  const userDataDir = await mkdtemp(join(tmpdir(), "gls-36-indexeddb-profile-"));
  const input = submission();
  let firstContext;
  let restartedContext;

  try {
    firstContext = await chromium.launchPersistentContext(userDataDir, { headless: true });
    let page = await firstContext.newPage();
    await page.goto("http://127.0.0.1:4173/");

    const saved = await page.evaluate(async (command) => {
      const { enqueueSubmission } = await import("/scoring/queue.js");
      return enqueueSubmission(command);
    }, input);
    expect(saved.state).toBe("PERSISTED");

    await page.reload();
    const afterReload = await recover(page, input.scope);
    expect(afterReload).toHaveLength(1);
    expect(afterReload[0].command).toEqual(input.command);

    await firstContext.close();
    firstContext = undefined;

    restartedContext = await chromium.launchPersistentContext(userDataDir, { headless: true });
    page = await restartedContext.newPage();
    await page.goto("http://127.0.0.1:4173/");

    const afterRestart = await recover(page, input.scope);
    expect(afterRestart).toHaveLength(1);
    expect(afterRestart[0].state).toBe("RECOVERED");
    expect(afterRestart[0].command).toEqual(input.command);
    expect(afterRestart[0].command.client_submission_id).toBe(submissionId);
    expect(afterRestart[0].command.captured_at).toBe(input.command.captured_at);

    const stillPending = await recover(page, input.scope);
    expect(stillPending).toHaveLength(1);
  } finally {
    if (firstContext) await firstContext.close();
    if (restartedContext) await restartedContext.close();
    await rm(userDataDir, { recursive: true, force: true });
  }
});

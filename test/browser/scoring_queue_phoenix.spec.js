import { expect, test } from "@playwright/test";

const fixture = process.env.GLS37_BROWSER_FIXTURE
  ? JSON.parse(process.env.GLS37_BROWSER_FIXTURE)
  : null;

test("an authenticated LiveView reconciles a lost final-hole acknowledgement", async ({ page, context }) => {
  test.skip(!fixture || fixture.scenario !== "final_hole", "The Phoenix integration runner supplies an authenticated final-hole fixture");

  await context.addCookies([{
    name: "_golf_scoring_key",
    value: fixture.session_cookie,
    domain: "localhost",
    path: "/",
    httpOnly: true,
    secure: false,
    sameSite: "Lax",
  }]);

  let submissionRef = null;
  let droppedAcceptedReply = false;
  let resolveAcceptedReply;
  const acceptedReply = new Promise((resolve) => { resolveAcceptedReply = resolve; });

  await page.routeWebSocket(/\/live\/websocket/, (socket) => {
    const server = socket.connectToServer();

    socket.onMessage((message) => {
      const frame = JSON.parse(String(message));
      const [, ref, , event, payload] = frame;
      if (event === "event" && payload?.type === "hook" && payload.event === "submit_queued_hole") {
        submissionRef = ref;
      }
      server.send(message);
    });

    server.onMessage((message) => {
      const frame = JSON.parse(String(message));
      const [, ref, , event, payload] = frame;
      const response = payload?.response?.diff?.r;
      if (
        !droppedAcceptedReply &&
        submissionRef !== null &&
        ref === submissionRef &&
        event === "phx_reply" &&
        response?.status === "accepted"
      ) {
        droppedAcceptedReply = true;
        resolveAcceptedReply(response);
        return;
      }
      socket.send(message);
    });
  });

  await page.goto(fixture.base_url + fixture.scorecard_path);
  await expect(page.locator("#current-hole")).toHaveText("Hole 18");
  await expect(page.locator("#scoring-sync-label")).toHaveText("Saved");

  await context.setOffline(true);
  for (const entryId of fixture.round_entry_ids) {
    await page.locator("[name=\"scorecard[results][" + entryId + "][outcome]\"]").selectOption("holed_out");
    await page.locator("[name=\"scorecard[results][" + entryId + "][gross_strokes]\"]").fill("4");
  }
  await page.locator("#submit-group-hole").click();
  await expect(page.locator("#scoring-sync-label")).toHaveText("Pending sync");
  await expect(page.locator("#scoring-pending-count")).toHaveText("1 pending");
  await expect(page.locator("#current-hole")).toHaveText("All holes queued for sync");

  await context.setOffline(false);
  await page.waitForFunction(() => navigator.onLine);
  const response = await Promise.race([
    acceptedReply,
    new Promise((_, reject) => setTimeout(() => reject(new Error("LiveView did not accept the final hole")), 10000)),
  ]);
  expect(response.status).toBe("accepted");
  expect(droppedAcceptedReply).toBe(true);

  await page.reload();
  await expect(page.locator("#group-play-complete")).toBeVisible();
  await expect(page.locator("#scoring-sync-label")).toHaveText("Saved", { timeout: 10000 });
  await expect(page.locator("#scoring-pending-count")).toHaveText("0 pending");
});

test("an authenticated LiveView reconciles an accepted non-final hole after its reply is lost", async ({ page, context }) => {
  test.skip(
    !fixture || !["accepted_hole_1", "accepted_hole_4"].includes(fixture.scenario),
    "The Phoenix integration runner supplies an authenticated non-final-hole fixture",
  );

  await addSessionCookie(context);

  const traffic = await captureQueueTraffic(context, { dropFirstAcceptedReply: true });
  const currentHoleNumber = fixture.current_hole_number || 1;
  await queueHoleOffline(page, context, currentHoleNumber);
  const [storedId] = await pendingSubmissionIds(page);

  expect(storedId).toBeTruthy();
  await reconnectAndSubmit(page, context, traffic);
  await expect.poll(() => traffic.submissionIds.length).toBe(1);
  await expect.poll(() => traffic.replies.filter(({ event }) => event === "submit_queued_hole").length).toBe(1);
  expect(traffic.replies.find(({ event }) => event === "submit_queued_hole").response.status).toBe("accepted");

  await page.reload();
  await expect(page.locator("#current-hole")).toHaveText(`Hole ${currentHoleNumber + 1}`);
  await expect.poll(() => traffic.resolvedIds.length).toBe(1);
  await expect.poll(() => traffic.replies.filter(({ event }) => event === "resolve_queued_hole").length).toBe(1);
  await expect(page.locator("#scoring-sync-label")).toHaveText("Saved", { timeout: 10000 });
  await expect(page.locator("#scoring-pending-count")).toHaveText("0 pending");

  expect(traffic.resolvedIds).toEqual([storedId]);
  expect(traffic.replies.find(({ event }) => event === "resolve_queued_hole").response.status).toBe("resolved");
  expect(traffic.submissionIds).toEqual([storedId]);
  expect(await pendingSubmissionIds(page)).toEqual([]);
});

test("an unaccepted Hole 1 command remains pending without a server write", async ({ page, context }) => {
  test.skip(!fixture || fixture.scenario !== "unaccepted_hole_1", "The Phoenix integration runner supplies an unaccepted Hole 1 fixture");

  await addSessionCookie(context);

  const traffic = await captureQueueTraffic(context, { dropFirstSubmission: true });
  await queueHoleOffline(page, context, 1);
  const [storedId] = await pendingSubmissionIds(page);

  await reconnectAndSubmit(page, context, traffic);
  await expect.poll(() => traffic.submissionIds.length).toBe(1);
  await page.reload();

  await expect(page.locator("#current-hole")).toHaveText("Hole 1");
  await expect.poll(() => traffic.resolvedIds.length).toBe(1);
  await expect.poll(() => traffic.replies.filter(({ event }) => event === "resolve_queued_hole").length).toBe(1);
  await expect(page.locator("#scoring-sync-label")).toHaveText("Attention required", { timeout: 10000 });
  await expect(page.locator("#scoring-pending-count")).toHaveText("1 pending");

  expect(traffic.resolvedIds).toEqual([storedId]);
  expect(traffic.replies.find(({ event }) => event === "resolve_queued_hole").response).toEqual({ status: "rejected", reason: "receipt_not_found" });
  expect(traffic.submissionIds).toEqual([storedId]);
  expect(await pendingSubmissionIds(page)).toEqual([storedId]);
});

test("an authenticated browser stops an accepted command after scorer handover", async ({ page, context }) => {
  test.skip(!fixture || fixture.scenario !== "scorer_handover", "The Phoenix integration runner supplies a scorer-handover fixture");

  await addSessionCookie(context);

  const traffic = await captureQueueTraffic(context, { dropFirstAcceptedReply: true });
  await queueHoleOffline(page, context, 1);
  const [storedId] = await pendingSubmissionIds(page);

  await reconnectAndSubmit(page, context, traffic);
  await expect.poll(() => traffic.submissionIds.length).toBe(1);
  await expect.poll(() => traffic.replies.filter(({ event }) => event === "submit_queued_hole").length).toBe(1);
  expect(traffic.replies.find(({ event }) => event === "submit_queued_hole").response.status).toBe("accepted");

  const handover = await context.request.post(fixture.handover_url);
  expect(handover.status()).toBe(200);

  await page.evaluate(async () => {
    const root = document.querySelector("#group-scorecard");
    const hook = window.liveSocket.main.getHook(root);
    hook.destroyed();
    hook.mounted();
    await hook.ready;
  });

  await expect.poll(() => traffic.resolvedIds.length).toBe(1);
  await expect.poll(() => traffic.replies.filter(({ event }) => event === "resolve_queued_hole").length).toBe(1);
  await expect(page.locator("#scoring-sync-label")).toHaveText("Attention required");
  await expect(page.locator("#scoring-pending-count")).toHaveText("1 pending");

  expect(traffic.resolvedIds).toEqual([storedId]);
  expect(traffic.replies.find(({ event }) => event === "resolve_queued_hole").response).toEqual({
    status: "rejected",
    reason: "stale_authority",
  });
  expect(traffic.submissionIds).toEqual([storedId]);
  expect(await pendingSubmissionIds(page)).toEqual([storedId]);
});

test("an authenticated browser retains a command when its resolved receipt does not match", async ({ page, context }) => {
  test.skip(!fixture || fixture.scenario !== "receipt_mismatch", "The Phoenix integration runner supplies a receipt-mismatch fixture");

  await addSessionCookie(context);

  const traffic = await captureQueueTraffic(context, {
    dropFirstAcceptedReply: true,
    mismatchFirstResolutionReceipt: true,
  });
  await queueHoleOffline(page, context, 1);
  const [storedId] = await pendingSubmissionIds(page);

  await reconnectAndSubmit(page, context, traffic);
  await expect.poll(() => traffic.submissionIds.length).toBe(1);
  await expect.poll(() => traffic.replies.filter(({ event }) => event === "submit_queued_hole").length).toBe(1);
  expect(traffic.replies.find(({ event }) => event === "submit_queued_hole").response.status).toBe("accepted");

  await page.reload();
  await expect.poll(() => traffic.resolvedIds.length).toBe(1);
  await expect.poll(() => traffic.replies.filter(({ event }) => event === "resolve_queued_hole").length).toBe(1);
  await expect(page.locator("#scoring-sync-label")).toHaveText("Attention required");
  await expect(page.locator("#scoring-pending-count")).toHaveText("1 pending");

  const resolvedReply = traffic.replies.find(({ event }) => event === "resolve_queued_hole").response;
  expect(resolvedReply.status).toBe("resolved");
  expect(resolvedReply.receipt.client_submission_id).not.toBe(storedId);
  expect(traffic.resolvedIds).toEqual([storedId]);
  expect(traffic.submissionIds).toEqual([storedId]);
  expect(await pendingSubmissionIds(page)).toEqual([storedId]);
});

test("an accepted command with a changed local payload remains stopped", async ({ page, context }) => {
  test.skip(!fixture || fixture.scenario !== "payload_mismatch", "The Phoenix integration runner supplies a payload-mismatch fixture");

  await addSessionCookie(context);

  const traffic = await captureQueueTraffic(context, { dropFirstAcceptedReply: true });
  await queueHoleOffline(page, context, 1);
  const [storedId] = await pendingSubmissionIds(page);

  await reconnectAndSubmit(page, context, traffic);
  await expect.poll(() => traffic.submissionIds.length).toBe(1);
  await expect.poll(() => traffic.replies.filter(({ event }) => event === "submit_queued_hole").length).toBe(1);
  expect(traffic.replies.find(({ event }) => event === "submit_queued_hole").response.status).toBe("accepted");
  await changeStoredGrossStrokes(page, 5);
  await page.reload();

  await expect(page.locator("#current-hole")).toHaveText("Hole 2");
  await expect.poll(() => traffic.resolvedIds.length).toBe(1);
  await expect.poll(() => traffic.replies.filter(({ event }) => event === "resolve_queued_hole").length).toBe(1);
  await expect(page.locator("#scoring-sync-label")).toHaveText("Attention required", { timeout: 10000 });
  await expect(page.locator("#scoring-pending-count")).toHaveText("1 pending");

  expect(traffic.resolvedIds).toEqual([storedId]);
  expect(traffic.replies.find(({ event }) => event === "resolve_queued_hole").response.status).toBe("rejected");
  expect(traffic.submissionIds).toEqual([storedId]);
  expect(await pendingSubmissionIds(page)).toEqual([storedId]);
  expect((await pendingCommands(page))[0].results[0].gross_strokes).toBe(5);
});

async function addSessionCookie(context) {
  await context.addCookies([{
    name: "_golf_scoring_key",
    value: fixture.session_cookie,
    domain: "localhost",
    path: "/",
    httpOnly: true,
    secure: false,
    sameSite: "Lax",
  }]);
}

async function queueHoleOffline(page, context, holeNumber) {
  await page.goto(fixture.base_url + fixture.scorecard_path);
  await expect(page.locator("#current-hole")).toHaveText(`Hole ${holeNumber}`);
  await expect(page.locator("#scoring-sync-label")).toHaveText("Saved");
  await context.setOffline(true);
  await page.waitForFunction(() => !navigator.onLine);

  for (const entryId of fixture.round_entry_ids) {
    await page.locator(`[name="scorecard[results][${entryId}][outcome]"]`).selectOption("holed_out");
    await page.locator(`[name="scorecard[results][${entryId}][gross_strokes]"]`).fill("4");
  }

  await page.locator("#submit-group-hole").click();
  await expect(page.locator("#scoring-sync-label")).toHaveText("Pending sync");
  await expect(page.locator("#scoring-pending-count")).toHaveText("1 pending");
  await expect(page.locator("#current-hole")).toHaveText(`Hole ${holeNumber + 1}`);
}

async function reconnectAndSubmit(page, context, traffic) {
  await context.setOffline(false);
  await page.waitForFunction(() => navigator.onLine);

  if (!(await waitForCondition(() => traffic.submissionIds.length > 0, 1000))) {
    await page.reload();
  }
}

async function waitForCondition(condition, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (!condition() && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return condition();
}

async function captureQueueTraffic(context, {
  dropFirstAcceptedReply = false,
  dropFirstSubmission = false,
  mismatchFirstResolutionReceipt = false,
} = {}) {
  let firstSubmissionRef = null;
  let droppedAcceptedReply = false;
  let droppedFirstSubmission = false;
  let mismatchedResolutionReceipt = false;
  const submissionIds = [];
  const resolvedIds = [];
  const eventByRef = new Map();
  const replies = [];

  await context.routeWebSocket(/\/live\/websocket/, (socket) => {
    const server = socket.connectToServer();

    socket.onMessage((message) => {
      const frame = JSON.parse(String(message));
      const [, ref, , event, payload] = frame;
      if (event === "event" && payload?.type === "hook") {
        const command = payload.value?.command || payload.payload?.command || payload.command;
        eventByRef.set(ref, payload.event);

        if (payload.event === "submit_queued_hole") {
          submissionIds.push(command?.client_submission_id);
          if (submissionIds.length === 1) {
            firstSubmissionRef = ref;
            if (dropFirstSubmission && !droppedFirstSubmission) {
              droppedFirstSubmission = true;
              return;
            }
          }
        }

        if (payload.event === "resolve_queued_hole") {
          resolvedIds.push(command?.client_submission_id);
        }
      }

      server.send(message);
    });

    server.onMessage((message) => {
      const frame = JSON.parse(String(message));
      const [, ref, , event, payload] = frame;
      const response = payload?.response?.diff?.r;
      let forwardedMessage = message;
      if (
        mismatchFirstResolutionReceipt &&
        !mismatchedResolutionReceipt &&
        eventByRef.get(ref) === "resolve_queued_hole" &&
        event === "phx_reply" &&
        response?.status === "resolved"
      ) {
        response.receipt.client_submission_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
        mismatchedResolutionReceipt = true;
        forwardedMessage = JSON.stringify(frame);
      }
      if (event === "phx_reply" && eventByRef.has(ref)) {
        replies.push({ event: eventByRef.get(ref), response });
      }
      if (
        dropFirstAcceptedReply &&
        !droppedAcceptedReply &&
        firstSubmissionRef !== null &&
        ref === firstSubmissionRef &&
        event === "phx_reply" &&
        response?.status === "accepted"
      ) {
        droppedAcceptedReply = true;
        return;
      }

      socket.send(forwardedMessage);
    });
  });

  return { submissionIds, resolvedIds, replies };
}

async function pendingCommands(page) {
  return page.evaluate(async () => {
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open("golf_scoring_pending_commands", 2);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error("IndexedDB open failed"));
    });
    try {
      const records = await new Promise((resolve, reject) => {
        const request = db.transaction("pending_commands", "readonly")
          .objectStore("pending_commands")
          .getAll();
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error || new Error("IndexedDB request failed"));
      });
      return records.map(({ command }) => command);
    } finally {
      db.close();
    }
  });
}

async function pendingSubmissionIds(page) {
  const commands = await pendingCommands(page);
  return commands.map(({ client_submission_id }) => client_submission_id);
}

async function changeStoredGrossStrokes(page, grossStrokes) {
  await page.evaluate(async (value) => {
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open("golf_scoring_pending_commands", 2);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error("IndexedDB open failed"));
    });
    try {
      const transaction = db.transaction("pending_commands", "readwrite");
      const store = transaction.objectStore("pending_commands");
      const request = store.getAll();
      request.onsuccess = () => {
        const record = request.result[0];
        record.command.results[0].gross_strokes = value;
        store.put(record);
      };
      await new Promise((resolve, reject) => {
        transaction.oncomplete = resolve;
        transaction.onabort = () => reject(transaction.error || new Error("IndexedDB mutation aborted"));
        transaction.onerror = () => reject(transaction.error || new Error("IndexedDB mutation failed"));
      });
    } finally {
      db.close();
    }
  }, grossStrokes);
}

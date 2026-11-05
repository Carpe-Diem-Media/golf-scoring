import { expect, test } from "@playwright/test";

const fixture = process.env.GLS37_BROWSER_FIXTURE
  ? JSON.parse(process.env.GLS37_BROWSER_FIXTURE)
  : null;

test.skip(!fixture, "The Phoenix integration runner supplies an authenticated test fixture");

test("an authenticated LiveView reconciles a lost final-hole acknowledgement", async ({ page, context }) => {
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

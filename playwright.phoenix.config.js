import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: ["test/browser/scoring_queue_phoenix.spec.js"],
  testIgnore: ["**/.worktrees/**"],
  outputDir: "/tmp/golf-scoring-phoenix-playwright-results",
  workers: 1,
  reporter: "line",
  use: {
    browserName: "chromium",
    headless: true,
  },
});

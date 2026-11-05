import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: ["**/assets/test/**/*.test.js", "**/test/browser/**/*.spec.js"],
  testIgnore: ["**/.worktrees/**"],
  outputDir: "/tmp/golf-scoring-playwright-results",
  workers: 1,
  reporter: "line",
  use: {
    browserName: "chromium",
    baseURL: "http://127.0.0.1:4173",
    headless: true,
  },
  webServer: {
    command: "python3 -m http.server 4173 --bind 127.0.0.1 --directory assets/js",
    url: "http://127.0.0.1:4173/",
    reuseExistingServer: false,
  },
});

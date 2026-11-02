# GLS-78 Hallmark governance (Master Gate)

## Skill

Followed `~/.agents/skills/hallmark/SKILL.md`.

## Owner waiver

**None.** No Master Gate / owner authority was provided for `assets/css/app.css` stamp FAIL 20, render-tier skip, or agent self-waivers.

## Environment (not application dependencies)

- `puppeteer-core` installed **globally** via npm (`npm install -g puppeteer-core@24`); **not** added to `mix.exs` / `assets/package.json`.
- Chrome: `/usr/bin/google-chrome-stable`
- Dev server: `PORT=4102 devcore-project run dev -- mix phx.server`

## Affected targets (GLS-78 UI correction)

```text
lib/golf_scoring_web/components/app_shell.ex
lib/golf_scoring_web/player/access_denied_live.ex
lib/golf_scoring_web/player/home_live.ex
```

HEEx-in-`.ex` is not parsed by sloplint file tier (0 CSS/HTML/JSX files); render proof uses `--url` for routes that mount GLS-78 shell chrome.

**Do not** include legacy `assets/css/app.css` in the gate (stamp FAIL 20 on pre-existing bundle; modifying global CSS is out of scope without owner authority).

## Documented sloplint command

```bash
cd .worktrees/ux-role-aware-app-shell
node ~/.agents/skills/hallmark/scripts/sloplint.mjs \
  lib/golf_scoring_web/components/app_shell.ex \
  lib/golf_scoring_web/player/access_denied_live.ex \
  --genre modern-minimal --scope app --render \
  --url http://127.0.0.1:4102/player/access-denied
```

Recorded output: `.hallmark/gls-78/sloplint-affected-render.txt`

## Result: **BLOCKED** (render tier runs; gate does not pass)

With render tier executing (screenshots under `.hallmark/shots/`):

- **FAIL 26a** on `http://127.0.0.1:4102/player/access-denied`: keyboard focus lands on Tidewave toolbar `div#tidewave-toolbar` and `body` without a detectable focus ring (dev HTML injects `https://tidewave.ai/tc/toolbar.js` via Tidewave plug/meta). Fixing that requires unrelated dev-toolbar / layout work or a prod-like serve without Tidewave injection—not authorized on this ticket.

Including `--url http://127.0.0.1:4102/admin/sign-in` additionally fails **26a** and **76** on legacy Ash Authentication chrome (unrelated to GLS-78 AppShell).

## Audit

Substantial UI correction audit remains a **manual design read** of AppShell/player guest shell (no passing `--render` gate to attach). Prior `--before` URL-only sloplint was clean on file tier but did not satisfy render governance.

## Browser verification (non-Hallmark)

Prior thread: staff mobile drawer `aria-expanded`, player access-denied guest shell (preview on 4102).

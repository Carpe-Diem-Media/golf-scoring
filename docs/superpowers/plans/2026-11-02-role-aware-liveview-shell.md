# Role-aware LiveView application shell (2026-11-02)

## Route map

| Journey | Route | Guard | LiveView / Controller |
|---------|-------|-------|------------------------|
| Staff sign-in | `/admin/sign-in` | browser | AshAuthentication |
| Staff home | `/admin` | require_staff + admin_staff session | DashboardLive |
| Event course setup | `/admin/events/:event_id/course-setup` | require_staff | CourseSetupLive |
| Round setup | `/admin/events/:event_id/rounds/:round_id/setup` | require_staff | RoundSetupLive |
| Group assignment | `/admin/events/:event_id/rounds/:round_id/groups` | require_staff | GroupAssignmentLive |
| Player token exchange | `/player/access?token=` | browser | AccessController |
| Player home | `/player` | require_player_access + `:player` live_session on_mount | HomeLive |
| Player denied | `/player/access-denied` | browser | AccessDeniedLive |

## Session boundaries

- **Staff**: `load_from_session` → `set_actor(:staffuser)` → `RequireStaff` on `/admin` LiveViews.
- **Player HTTP**: `RequirePlayerAccess` plug loads grant via `PlayerAccessGrantGuard.load_grant_for_session/1`.
- **Player LiveView**: `GolfScoringWeb.Player.LiveMount.on_mount/4` revalidates the same grant on mount and reconnect; no URL params for identity.

## Component / file map

| File | Responsibility |
|------|----------------|
| `components/app_shell.ex` | Staff and player shells, nav, breadcrumbs, landmarks |
| `components/layouts.ex` | Outer `Layouts.app` — flash + neutral document frame (no Phoenix starter) |
| `player/live_mount.ex` | LiveView grant revalidation |
| `player/home_live.ex` | Mobile-first player landing |
| `player/access_denied_live.ex` | Invalid / missing player session UX |
| Admin LiveViews | Wrap content in `<AppShell.staff>`; preserve domain events |

## Implementation order

1. Plan + failing tests (staff shell landmarks, player redirect/mount, access denied).
2. `Layouts.app` + `AppShell`.
3. Player LiveMount, router, AccessController redirect, AccessDeniedLive, HomeLive.
4. Integrate four admin LiveViews + dashboard event links.
5. Hallmark sloplint + audit, precommit, draft PR.

## Role-aware navigation

- **SYSTEM_ADMIN**: presentation only via `StaffUser.system_admin` on dashboard (existing `can_create_event?`).
- **Event-scoped routes**: unchanged `ActiveEventRole` checks in each LiveView mount; shell shows event links only when `event_id` / `round_id` assigns are provided by the LiveView.
- No new authorization subsystem; no `authorize?: false` for role discovery.

## Placeholders (unavailable)

Player nav entries for scorecard, leaderboard, results — disabled with copy, no business actions.

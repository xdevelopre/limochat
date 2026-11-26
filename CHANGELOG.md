# Changelog — Limo Chat 2.04.1

## 2.04 — Module loader and device sessions
- Reworked the `limo-v2.js` loader to resolve from the published page URL, share one in-flight import promise, verify `window.LimoV2`, and show actionable retry diagnostics.
- Replaced the previous logo artwork with a clean, flat lime-and-white SVG mark without a black matte or border. Updated favicon and PWA icons.
- Added a device-session list in Settings with browser/OS label, first registration, last activity, IP (when the Edge Function is deployed), and app-level session revocation.
- Corrected Realtime subscription filtering so all signed-in devices for the same user receive revocation updates.
- Added device-session heartbeat and an additive Supabase migration.
- Added a Supabase Edge Function source that records the request IP from trusted platform headers; it never accepts an IP supplied in the JSON body.


## 2.04.2
- Replaced unsupported bottom-navigation Apps icon with Font Awesome Free `fa-table-cells-large`.
- Improved database schema error reporting to show the actual PostgREST/PostgreSQL code and server message rather than a generic notice.

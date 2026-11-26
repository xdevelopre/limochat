# Test report — Limo Chat 2.04.1

## Static checks
`node test-static.mjs` completed with **26 passed, 0 failed**. Checks cover duplicate HTML IDs, local file references, inline module syntax, `limo-v2.js` syntax, manifest JSON, module-loader and bridge ordering, session settings, per-user Realtime subscription, device heartbeat, SQL RPC/RLS markers, revoked-session non-resurrection, Edge Function JWT/IP/CORS handling, vector logo references, and additive migration safety.

## Not tested against live services
- SQL execution against the user's actual Supabase database.
- Live Auth, RLS, Realtime publication and Storage behavior.
- Edge Function deployment and IP header availability.
- Two-device end-to-end session revocation on real browsers.
- Full browser runtime against the live Supabase project.

## Reproduce
Extract the ZIP, run `node test-static.mjs` from its root. Apply the SQL only after backing up the existing project and confirming migrations 2.0–2.03 are already installed.


## 2.04.2 regression checks
- JavaScript module syntax: passed (Node.js --check).
- Apps navigation icon class replacement: passed (source inspection).
- Database schema error diagnostic path: passed (source inspection).
- Live Supabase message insertion: NOT TESTED; requires the project's authenticated session and live database.

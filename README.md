# Limo Chat 2.04.1

GitHub Pages PWA backed by the existing Supabase Auth, PostgreSQL, Realtime and Storage project. This package is an additive update to the supplied 2.03 source. All files are at the ZIP root; the ZIP uses ZIP_STORED (no compression).

## Files

- `index.html`: application shell and Supabase client.
- `limo-v2.js`: feature module.
- `logo.svg`, `favicon.svg`, `icon-192.png`, `icon-512.png`: new clean lime/white brand assets (no black JPEG background).
- `limochat-v2.04-migration.sql`: additive session-registry migration.
- `limo-session-manager.ts`: optional Supabase Edge Function source for trusted client-IP capture.

## Deploy

1. Back up Supabase database and Storage configuration.
2. Confirm migrations 2.0, 2.01, 2.02 and 2.03 are already applied.
3. Review and run `limochat-v2.04-migration.sql` in the existing Supabase project's SQL Editor.
4. (Recommended for IP display) Deploy `limo-session-manager.ts` as the Edge Function `limo-session-manager`; see `SETUP-SUPABASE.md`. Never put the service-role key in frontend files.
5. Publish every ZIP-root file to the root of the GitHub Pages repository. Keep the exact filename `limo-v2.js` (case-sensitive).
6. Clear the site's old service worker/cache once by reloading after deployment; the worker cache was version-bumped to 2.04.

## Module loader fix

The main page now creates one shared `window.LimoV2Ready` promise after the Supabase bridge is initialized. Settings pages await the same import, use a URL relative to `index.html`, and show the precise import error and resolved module URL if loading fails. Confirm that `https://<owner>.github.io/<repo>/limo-v2.js` returns JavaScript with HTTP 200.

## Device sessions

The app stores a per-tab device-session registry row. The UI lists browser/OS label, IP when the Edge Function is deployed, created/last-seen timestamps, and app-level revoke status. A remote open app tab receives a Realtime revoke event and signs out locally. This is app-level session termination, not guaranteed immediate revocation of the Supabase Auth refresh token at the Auth server. The public Supabase JS API does not expose a safe per-device admin token-revocation operation. For strict token revocation, a separately reviewed server-side Auth session-management service is required.

## Test status

Static syntax, markup, asset, SQL-shape and package checks are documented in `TEST-REPORT.md`. No SQL was executed against the live Supabase project and no GitHub deployment was performed. Realtime and Edge Function behavior require deployment and two real signed-in devices to verify.

# Supabase setup — Limo Chat 2.04

## Migration order

Run only `limochat-v2.04-migration.sql` after confirming the existing 2.0 base schema and 2.01, 2.02, 2.03 migrations have already been applied. Back up first. The migration is additive and does not drop or truncate existing user/chat/message data.

## Session registry

The migration creates `public.limo_device_sessions`, owner-only SELECT RLS, and two owner-checked RPCs:

- `limo_register_device_session(uuid,text,text)` registers the current app tab/device.
- `limo_revoke_device_session(uuid)` marks one of the current user's app sessions revoked.

The table is added to `supabase_realtime` where that publication exists. If your project reports that publication is unavailable, enable Realtime for `limo_device_sessions` in Supabase Dashboard.

## Trusted IP capture (recommended)

The browser cannot reliably discover its public IP without a network service. Deploy the included Edge Function source:

1. In your Supabase project create a function named `limo-session-manager`.
2. Put the contents of `limo-session-manager.ts` in `supabase/functions/limo-session-manager/index.ts` in a Supabase CLI project, then deploy it (`supabase functions deploy limo-session-manager`).
3. Ensure the function environment has `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`. Supabase supplies project secrets; if required, configure them in Edge Function secrets.
4. Do not expose `SUPABASE_SERVICE_ROLE_KEY` to GitHub Pages or commit it into the repository.
5. Test by signing in from two separate devices and check `ip_address` in `public.limo_device_sessions`.

The Edge Function CORS policy is restricted to `https://xdevelopre.github.io`; update the allowlist only if your published origin changes.

If the Edge Function is not deployed, the app falls back to the authenticated SQL RPC. Device names and timestamps work, but IP displays as unavailable.

## Security semantics / limitations

The session list is an app-managed device registry. Revoking a row sends a Realtime event to other open app clients, which then call local sign-out. This does not revoke that device's Supabase Auth refresh token at the Auth server, and cannot force a fully offline browser to sign out until it reconnects. Do not describe it as complete Auth token revocation. Individual Auth token revocation requires a separately designed trusted backend and verified Supabase Auth session-management API.

## Verification

Run these checks after migration:

```sql
select version, applied_at from public.limo_schema_migrations order by applied_at;
select id, device_label, ip_address, created_at, last_seen_at, revoked_at
from public.limo_device_sessions where user_id = auth.uid();
```

The second query is intended to run in an authenticated SQL context or through the app; SQL Editor usually runs as a privileged role and `auth.uid()` may be null.


## 2.04 device sessions
1. Back up the existing Supabase project.
2. Run `limochat-v2.04-migration.sql` only after migrations 2.0 through 2.03 have already been applied.
3. For IP recording, deploy `limo-session-manager.ts` as `supabase/functions/limo-session-manager/index.ts` using the Supabase CLI. Configure Edge Function secrets `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` in the Supabase dashboard/CLI. The service-role key must never be copied into GitHub files.
4. Restrict the Edge Function CORS `Access-Control-Allow-Origin` to `https://xdevelopre.github.io` (and your own preview origin, if needed) before production.
5. Confirm the `limo_device_sessions` table is enabled in the `supabase_realtime` publication. The migration attempts to add it; verify in Dashboard → Database → Publications.
6. Publish all root files to the GitHub Pages root. Keep `index.html`, `limo-v2.js`, `logo.svg`, `favicon.svg`, `manifest.json`, and `sw.js` together at the same level.
7. Open the app over HTTPS, sign in on two devices, inspect Settings → Sessions, and revoke one device. Test that its open app tab signs out.

IP may remain unavailable when the hosting/proxy does not forward a trusted IP header. The session list is an app-level registry, not complete Supabase Auth session revocation.

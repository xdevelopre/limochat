# Features — Limo Chat 2.04.1

- Existing 2.03 chat, groups, channels, premium, admin and PWA code is retained as the base.
- Feature module loader: one shared import promise, URL resolved against `document.baseURI`, API verification and diagnostic errors. The app must be served over HTTPS (GitHub Pages), not opened as `file://`.
- Brand: flat lime/white vector logo, favicon and PWA icons; no black image matte.
- Settings → Sessions: lists app-registered devices, device/browser label, IP when server Edge Function is deployed, created time and last activity. Users can revoke an app session; open app tabs/devices are notified over Supabase Realtime and sign out locally.
- Device IP collection is optional and requires deploying `limo-session-manager.ts` as the Supabase Edge Function `limo-session-manager`. Without it, IP is shown as unavailable.

## Explicit limitations
- This is an app-level device registry, not a complete Supabase Auth session administration console. Revoking a row signs out the matching open app instance through Realtime; it does not revoke every Auth refresh token or block arbitrary direct API calls from a previously issued token.
- Static tests do not prove the live Supabase schema, RLS, Realtime publication, Edge Function deployment, or browser runtime.

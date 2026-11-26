# Security notes — Limo Chat 2.04

- No Supabase service-role key is embedded in frontend files. `SUPABASE_SERVICE_ROLE_KEY` is read only from Supabase Edge Function secrets.
- The Edge Function validates the caller JWT with `auth.getUser()` before registering a device session. It derives IP from platform forwarding headers and ignores any client-supplied IP field.
- The session table has RLS enabled; authenticated users can read only rows where `user_id = auth.uid()`. Inserts and updates are exposed through owner-checked SECURITY DEFINER RPCs.
- Realtime is used to notify open app instances that their app session was revoked. This is not equivalent to revoking the Supabase Auth refresh token. A user with a still-valid token may continue making direct API requests until that token expires or is revoked by a separate Auth administration mechanism.
- IP addresses are sensitive personal data. Disclose collection in the privacy notice, restrict access, define a retention period, and comply with applicable law. Do not use wildcard CORS in production without restricting allowed origins to the published app.
- Keep database backups before applying the additive migration.

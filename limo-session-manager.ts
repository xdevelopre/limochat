// Supabase Edge Function: limo-session-manager
// Deploy as supabase/functions/limo-session-manager/index.ts.
// Configure SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY as Edge secrets.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
const ALLOWED_ORIGIN = 'https://xdevelopre.github.io';
const corsHeaders = { 'Access-Control-Allow-Origin': ALLOWED_ORIGIN, 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Vary': 'Origin' };
Deno.serve(async (req) => {
  if (req.headers.get('Origin') && req.headers.get('Origin') !== ALLOWED_ORIGIN) return new Response('Origin not allowed', { status: 403 });
  const origin = req.headers.get('Origin');
  if (origin && origin !== allowedOrigin) return new Response('Origin not allowed', { status: 403, headers: corsHeaders });
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  try {
    const authHeader = req.headers.get('Authorization') || '';
    if (!authHeader.startsWith('Bearer ')) return json({ error: 'Unauthorized' }, 401);
    const url = Deno.env.get('SUPABASE_URL');
    const anon = Deno.env.get('SUPABASE_ANON_KEY');
    const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!url || !anon || !service) return json({ error: 'Server configuration missing' }, 500);
    const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } });
    const { data: { user }, error: userError } = await userClient.auth.getUser();
    if (userError || !user) return json({ error: 'Unauthorized' }, 401);
    const body = await req.json();
    if (body.action !== 'register') return json({ error: 'Unsupported action' }, 400);
    const sessionId = String(body.session_id || '');
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
    if (!uuid.test(sessionId)) return json({ error: 'Invalid session id' }, 400);
    // Read only platform-provided forwarding headers; never accept IP from request JSON.
    const forwarded = req.headers.get('cf-connecting-ip') || req.headers.get('x-real-ip') || '';
    const ip = forwarded.split(',')[0].trim();
    // The owner-checked RPC is the only path allowed to create/reactivate a device session.
    // It refuses to resurrect a row that has already been revoked.
    const { error: registerError } = await userClient.rpc('limo_register_device_session', {
      p_session_id: sessionId,
      p_device_label: String(body.device_label || 'دستگاه ناشناس').slice(0, 120),
      p_user_agent: String(body.user_agent || req.headers.get('user-agent') || '').slice(0, 500),
    });
    if (registerError) return json({ error: registerError.message }, 403);
    // Owner-checked SQL RPC is the atomic gate; it refuses to revive revoked sessions.
    const { error: registerError } = await userClient.rpc('limo_register_device_session', {
      p_session_id: sessionId,
      p_device_label: String(body.device_label || 'دستگاه ناشناس').slice(0, 120),
      p_user_agent: String(body.user_agent || req.headers.get('user-agent') || '').slice(0, 500),
    });
    if (registerError) return json({ error: registerError.message }, 403);
    const admin = createClient(url, service, { auth: { persistSession: false } });
    if (ip) {
      const { error: ipError } = await admin.from('limo_device_sessions')
        .update({ ip_address: ip })
        .eq('id', sessionId).eq('user_id', user.id).is('revoked_at', null);
      if (ipError) throw ipError;
    }
    return json({ ok: true, ip_recorded: Boolean(ip) });
  } catch (error) {
    console.error('limo-session-manager:', error);
    return json({ error: error instanceof Error ? error.message : 'Internal error' }, 500);
  }
});

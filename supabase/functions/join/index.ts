// Checks a world invite code before an account is made (spec 14.4 and 14.21). The account itself is made by
// Supabase Auth's sign-up, which emails a 6-digit code to confirm the address; founding the airline is a separate
// step in the app (public.found_airline), which checks the invite code again. Until 14.21 this function created a
// confirmed account itself, so joining never depended on email.
// Deployed with verify_jwt off: callers have no account yet. SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are
// provided by the platform and never leave the function.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return reply(405, { error: 'Use POST' });
  let input: { invite?: string };
  try { input = await req.json(); } catch { return reply(400, { error: 'Send the invite code' }); }
  const invite = String(input.invite ?? '').trim().toLowerCase();
  if (!invite || invite.length > 64) return reply(400, { error: 'That invite code is not valid' });

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: w, error: we } = await admin.from('world_secrets').select('world_id, worlds!inner(status)')
    .eq('invite_code', invite).neq('worlds.status', 'ended').maybeSingle();
  if (we) return reply(500, { error: 'Could not check the invite code. Try again.' });
  if (!w) return reply(400, { error: 'That invite code is not valid' });
  return reply(200, { ok: true });
});

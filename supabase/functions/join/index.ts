// Creates a player account from an invite code. The account is confirmed at once, so joining never depends on
// email delivery (spec section 14: "Email and password plus a world invite code"). Founding the airline is a
// separate step in the app (public.found_airline), which checks the invite code again.
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
  let input: { email?: string; password?: string; invite?: string };
  try { input = await req.json(); } catch { return reply(400, { error: 'Send email, password and invite' }); }
  const email = String(input.email ?? '').trim().toLowerCase();
  const password = String(input.password ?? '');
  const invite = String(input.invite ?? '').trim().toLowerCase();

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: w, error: we } = await admin.from('world_secrets').select('world_id, worlds!inner(status)')
    .eq('invite_code', invite).neq('worlds.status', 'ended').maybeSingle();
  if (we) return reply(500, { error: 'Could not check the invite code. Try again.' });
  if (!w) return reply(400, { error: 'That invite code is not valid' });
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || email.length > 200) return reply(400, { error: 'Enter a valid email address' });
  if (password.length < 8 || password.length > 72) return reply(400, { error: 'Password must be 8 to 72 characters' });

  const { error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (error) {
    if (/already|registered|exists/i.test(error.message)) return reply(400, { error: 'An account with this email already exists. Sign in instead.' });
    return reply(400, { error: error.message });
  }
  return reply(200, { ok: true });
});

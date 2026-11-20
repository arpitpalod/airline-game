import { createClient } from '@supabase/supabase-js';

export const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL as string;
export const INVITE_KEY = 'airline-game-invite';
export const SUPABASE_KEY = import.meta.env.VITE_SUPABASE_ANON_KEY as string;

export const supabase = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, storageKey: 'airline-game-auth' },
});

// Reads: throw on error so React Query shows it.
export async function rows<T>(q: PromiseLike<{ data: unknown; error: { message: string } | null }>): Promise<T[]> {
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  return (data ?? []) as T[];
}

// Player actions are server functions; their error text is written for players.
export async function call<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(cleanError(error.message));
  return data as T;
}

function cleanError(m: string) {
  if (/JWT|token/i.test(m)) return 'Your sign-in has expired. Sign in again.';
  if (/Failed to fetch|NetworkError|Load failed/i.test(m)) return 'Could not reach the game server. Check your connection.';
  return m;
}

// Joining checks the invite code with the join function first; the account is then made by Supabase Auth's sign-up,
// which emails a 6-digit code to confirm the address (spec 14.21).
export async function checkInvite(invite: string) {
  let res: Response;
  try {
    res = await fetch(`${SUPABASE_URL}/functions/v1/join`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', apikey: SUPABASE_KEY },
      body: JSON.stringify({ invite }),
    });
  } catch {
    throw new Error('Could not reach the game server. Check your connection.');
  }
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || 'Could not check the invite code');
}

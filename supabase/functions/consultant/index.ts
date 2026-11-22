// The Claude consultant (spec 14.25, migration 0030). A player asks for a report on their own airline:
//  1. consultant_start runs as the player (their sign-in token): it checks the limits, charges the fee in game money and
//     hands back the model, the playbook and the model's prices.
//  2. The reply goes back at once with the report id; the report is written in the background (EdgeRuntime.waitUntil)
//     and the app polls consultant_reports.
//  3. Claude reads the airline's data through consultant_data (service role: the airline's own books and public market
//     data, never another airline's private data or any text a player wrote), in at most max_turns turns, then calls
//     submit_report. The report is checked and saved with consultant_finish; any failure refunds the fee.
// Actions in a report never run here: the player taps "Do it" in the app, which calls the usual public function.
// Deployed with verify_jwt on. ANTHROPIC_API_KEY is a Supabase secret; SUPABASE_URL, SUPABASE_ANON_KEY and
// SUPABASE_SERVICE_ROLE_KEY are provided by the platform. None of them is ever returned or logged.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

// Supabase's runtime keeps the function alive for background work; elsewhere (the local test) the promise just runs.
const later = (p: Promise<unknown>) =>
  (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime?.waitUntil(p);
const CLAUDE_URL = Deno.env.get('CONSULTANT_CLAUDE_URL') ?? 'https://api.anthropic.com/v1/messages';   // local test: a stub

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

// The function stops at 150 seconds on the Free plan: ask for the report by 85 s, give up on Claude at 140 s.
const FORCE_AT_MS = 85_000, GIVE_UP_AT_MS = 140_000, MAX_RESULT_CHARS = 40_000;

const LOOKUPS = ['overview', 'routes', 'route_weeks', 'fleet', 'market', 'what_works_where', 'ops_preview'] as const;
const ACTIONS: Record<string, string[]> = {     // each action the consultant may suggest, and the fields it needs
  set_strategy: ['route_id', 'strategy'],
  set_rotation: ['aircraft_id', 'route_id', 'round_trips_a_week'],
  open_route: ['from', 'to'],
  close_route: ['route_id'],
  set_sell_where: ['route_id', 'where'],
  return_aircraft: ['aircraft_id'],
  set_hedge: ['share'],
  set_usd_hedge: ['share'],
  set_maint_plan: ['plan'],
  set_op_style: ['style'],
  set_marketing: ['inr_day'],
  borrow: ['amount_inr'],
  repay: ['amount_inr'],
};
const TAGS = ['Certain', 'Likely', 'Guessing'];

const tools = [
  { name: 'overview', description: 'The airline: cash, debt, credit line, brand, on-time, last 28 days of revenue and costs by line, load, the last 4 quarters, its fleet-wide strategies, cost per seat-km of the industry, shocks now, fuel price and the rupee.', input_schema: { type: 'object', properties: {} } },
  { name: 'routes', description: 'Every open route of the airline, worst first: last 28 days of seats, passengers, load, turned away, revenue, flying and aircraft cost, result, average fare, its way of selling, share of the market\'s seats, and each rival\'s fare, round trips and seats.', input_schema: { type: 'object', properties: {} } },
  { name: 'route_weeks', description: 'One of the airline\'s routes week by week: 6 flown weeks and 8 on sale (seats, sold, fares now, turned away).', input_schema: { type: 'object', properties: { route_id: { type: 'string' } }, required: ['route_id'] } },
  { name: 'fleet', description: 'Every aircraft: type, base, status, arrival week, age, seats, routes and round trips, block hours last week against its flying day, result last week.', input_schema: { type: 'object', properties: {} } },
  { name: 'market', description: 'A market between two airports (IATA codes): distance, reference fare, the airlines flying it with fares and seats, and the airline\'s own route studies of it.', input_schema: { type: 'object', properties: { a: { type: 'string' }, b: { type: 'string' } }, required: ['a', 'b'] } },
  { name: 'what_works_where', description: 'Every route in the world over 13 flown weeks, by kind of sector and market shape: load, fare and revenue per seat against the reference fare for each way of selling.', input_schema: { type: 'object', properties: {} } },
  { name: 'ops_preview', description: 'What each fuel hedge, dollar hedge, maintenance strategy and operating style would cost or save this airline.', input_schema: { type: 'object', properties: {} } },
  {
    name: 'submit_report',
    description: 'Hand in the finished report. Call once, at the end.',
    input_schema: {
      type: 'object',
      properties: {
        summary: { type: 'string', description: 'Two or three plain sentences: how the airline is doing and the one thing that matters most.' },
        problems: {
          type: 'array', minItems: 1, maxItems: 3,
          items: { type: 'object', required: ['title', 'evidence', 'tag'], properties: {
            title: { type: 'string', description: 'The problem in a few words' },
            evidence: { type: 'string', description: 'The numbers from the look-ups that show it, and why it matters' },
            tag: { type: 'string', enum: TAGS } } },
        },
        actions: {
          type: 'array', maxItems: 3,
          items: { type: 'object', required: ['title', 'fn', 'why', 'effect', 'risk', 'tag'], properties: {
            title: { type: 'string', description: 'What to do, in a few words' },
            fn: { type: 'string', enum: Object.keys(ACTIONS) },
            route_id: { type: 'string' }, aircraft_id: { type: 'string' },
            strategy: { type: 'string', enum: ['fill', 'balanced', 'top', 'follow'] },
            round_trips_a_week: { type: 'integer', minimum: 0, maximum: 70 },
            from: { type: 'string', description: 'IATA code' }, to: { type: 'string', description: 'IATA code' },
            where: { type: 'string', enum: ['india', 'both', 'abroad'] },
            share: { type: 'number', enum: [0, 0.25, 0.5, 0.75] },
            plan: { type: 'string', enum: ['payg', 'contract', 'hangar', 'lean'] },
            style: { type: 'string', enum: ['saver', 'standard', 'quick', 'punctual'] },
            inr_day: { type: 'number', minimum: 0 }, amount_inr: { type: 'number', minimum: 0 },
            why: { type: 'string' },
            effect: { type: 'string', description: 'What it should change, in rupees a week, as a range' },
            risk: { type: 'string', description: 'What could go wrong' },
            tag: { type: 'string', enum: TAGS } } },
        },
        missing: { type: 'string', description: 'Data that was missing, and the route study or wait that would answer it' },
      },
      required: ['summary', 'problems', 'actions'],
    },
  },
];

type Usage = { input_tokens?: number; output_tokens?: number; cache_creation_input_tokens?: number; cache_read_input_tokens?: number };
type Block = { type: string; id?: string; name?: string; input?: Record<string, unknown>; text?: string };
type Start = { report_id: string; model: string; playbook: string; max_turns: number;
               usd_mtok: { in: number; cache_write: number; cache_read: number; out: number } };

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return reply(405, { error: 'Use POST' });
  const auth = req.headers.get('Authorization') ?? '';
  let input: { airline_id?: string };
  try { input = await req.json(); } catch { return reply(400, { error: 'Send the airline' }); }
  const airline = String(input.airline_id ?? '');
  if (!/^[0-9a-f-]{36}$/i.test(airline)) return reply(400, { error: 'Send the airline' });
  if (!Deno.env.get('ANTHROPIC_API_KEY')) return reply(503, { error: 'The consultant is not set up yet' });

  const url = Deno.env.get('SUPABASE_URL')!;
  const asPlayer = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: auth } }, auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await asPlayer.rpc('consultant_start', { p_airline: airline });
  if (error) return reply(400, { error: error.message });
  const start = data as Start;
  const server = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false, autoRefreshToken: false } });
  later(write(server, start));
  return reply(202, { report_id: start.report_id });
});

async function write(db: SupabaseClient, s: Start) {
  const t0 = Date.now();
  const used = { in: 0, cw: 0, cr: 0, out: 0 };
  const cost = () => (used.in * s.usd_mtok.in + used.cw * s.usd_mtok.cache_write + used.cr * s.usd_mtok.cache_read + used.out * s.usd_mtok.out) / 1e6;
  const finish = (ok: boolean, report: unknown, err: string | null) => db.rpc('consultant_finish', {
    p_report: s.report_id, p_ok: ok, p_report_json: report, p_tokens_in: used.in + used.cw, p_tokens_cached: used.cr,
    p_tokens_out: used.out, p_cost_usd: Number(cost().toFixed(4)), p_error: err,
  });
  const seen = new Set<string>();            // every id the consultant was shown: actions may only use these
  const looked: string[] = [];
  const messages: { role: string; content: unknown }[] = [{
    role: 'user',
    content: `Write this week's report for the airline. You have at most ${s.max_turns} turns; call several look-ups in one turn where you can. Start with overview and routes, then look deeper where the problems are, then call submit_report.`,
  }];
  try {
    for (let turn = 0; turn < s.max_turns; turn++) {
      const force = turn === s.max_turns - 1 || Date.now() - t0 > FORCE_AT_MS;
      const res = await claude(s, messages, force, GIVE_UP_AT_MS - (Date.now() - t0));
      const u = res.usage as Usage;
      used.in += u.input_tokens ?? 0; used.cw += u.cache_creation_input_tokens ?? 0;
      used.cr += u.cache_read_input_tokens ?? 0; used.out += u.output_tokens ?? 0;
      const blocks = res.content as Block[];
      const done = blocks.find((b) => b.type === 'tool_use' && b.name === 'submit_report');
      if (done) {
        const report = check(done.input ?? {}, seen);
        await finish(true, { ...report, turns: turn + 1, looked_up: looked, seconds: Math.round((Date.now() - t0) / 1000) }, null);
        return;
      }
      messages.push({ role: 'assistant', content: blocks });
      const calls = blocks.filter((b) => b.type === 'tool_use');
      if (calls.length === 0) { messages.push({ role: 'user', content: 'Now call submit_report.' }); continue; }
      const results = await Promise.all(calls.map(async (c) => {
        let out: string;
        if (!(LOOKUPS as readonly string[]).includes(c.name ?? '')) out = JSON.stringify({ error: 'Unknown look-up' });
        else {
          looked.push(c.name!);
          const { data, error } = await db.rpc('consultant_data', { p_report: s.report_id, p_tool: c.name, p_args: c.input ?? {} });
          out = error ? JSON.stringify({ error: 'That look-up failed' }) : JSON.stringify(data);
          for (const m of out.matchAll(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g)) seen.add(m[0]);
          for (const m of out.matchAll(/"(?:from|to|a|b)":"([A-Z]{3})"/g)) seen.add(m[1]);
          if (out.length > MAX_RESULT_CHARS) out = out.slice(0, MAX_RESULT_CHARS) + ' …(cut: too long)';
        }
        return { type: 'tool_result', tool_use_id: c.id, content: out };
      }));
      // cache everything up to here, so the next turn reads it from the cache
      (results[results.length - 1] as Record<string, unknown>).cache_control = { type: 'ephemeral' };
      messages.push({ role: 'user', content: results });
    }
    await finish(false, null, 'No report after the most turns');
  } catch (e) {
    await finish(false, null, (e as Error).message.slice(0, 300));
  }
}

async function claude(s: Start, messages: unknown[], force: boolean, msLeft: number) {
  if (msLeft < 5_000) throw new Error('Out of time');
  // only the latest tool results keep a cache mark (the API allows four)
  for (const m of messages.slice(0, -1) as { content: unknown }[])
    if (Array.isArray(m.content)) for (const b of m.content as Record<string, unknown>[]) delete b.cache_control;
  const body = JSON.stringify({
    model: s.model, max_tokens: 4096,
    system: [{ type: 'text', text: s.playbook, cache_control: { type: 'ephemeral' } }],
    tools, tool_choice: force ? { type: 'tool', name: 'submit_report' } : { type: 'auto' },
    messages,
  });
  for (let attempt = 0; ; attempt++) {
    const r = await fetch(CLAUDE_URL, {
      method: 'POST', body, signal: AbortSignal.timeout(Math.max(1_000, msLeft - 2_000)),
      headers: { 'x-api-key': Deno.env.get('ANTHROPIC_API_KEY')!, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    });
    if (r.ok) return await r.json();
    const busy = r.status === 429 || r.status === 529 || r.status >= 500;
    if (busy && attempt === 0 && msLeft > 30_000) { await new Promise((ok) => setTimeout(ok, 3_000)); continue; }
    const j = await r.json().catch(() => ({}));
    throw new Error(`Claude answered ${r.status}${j?.error?.type ? ` (${j.error.type})` : ''}`);
  }
}

// Keep only what the app can show and run: 3 problems, up to 3 actions with the fields their function needs and ids the
// consultant was actually shown. Anything else is dropped, never trusted.
function check(x: Record<string, unknown>, seen: Set<string>) {
  const str = (v: unknown, n = 1200) => (typeof v === 'string' ? v.slice(0, n) : '');
  const tag = (v: unknown) => (TAGS.includes(v as string) ? v as string : 'Guessing');
  const problems = (Array.isArray(x.problems) ? x.problems : []).slice(0, 3).map((p: Record<string, unknown>) =>
    ({ title: str(p.title, 120), evidence: str(p.evidence), tag: tag(p.tag) })).filter((p) => p.title);
  const actions = (Array.isArray(x.actions) ? x.actions : []).slice(0, 3).flatMap((a: Record<string, unknown>) => {
    const fn = String(a.fn ?? ''), need = ACTIONS[fn];
    if (!need) return [];
    const args: Record<string, unknown> = {};
    for (const k of need) {
      let v = a[k];
      if (v === undefined || v === null || v === '') return [];
      if (k === 'from' || k === 'to') v = String(v).toUpperCase();
      if ((k === 'route_id' || k === 'aircraft_id') && !seen.has(String(v))) return [];
      args[k] = v;
    }
    return [{ title: str(a.title, 120), fn, args, why: str(a.why), effect: str(a.effect, 300), risk: str(a.risk, 600), tag: tag(a.tag) }];
  });
  if (problems.length === 0) throw new Error('The report had no problems in it');
  return { summary: str(x.summary, 800), problems, actions, missing: str(x.missing, 600) || null };
}

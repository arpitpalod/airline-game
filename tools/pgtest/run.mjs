// Local migration test: runs every migration in an in-memory Postgres, then the checks.
// Usage: node run.mjs ../../supabase/migrations [--perf]
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
import { checks2a } from './checks_2a.mjs';
import { checks2b } from './checks_2b.mjs';
import { checks2c } from './checks_2c.mjs';
import { checks2d } from './checks_2d.mjs';
import { checks3 } from './checks_3.mjs';
import { checks4 } from './checks_4.mjs';
import { checks5 } from './checks_5.mjs';
import { checks6 } from './checks_6.mjs';
import { checks7 } from './checks_7.mjs';
import { checks8 } from './checks_8.mjs';
import { checks9 } from './checks_9.mjs';
import { checks10 } from './checks_10.mjs';
import { checks11 } from './checks_11.mjs';
import { checks12 } from './checks_12.mjs';
import { checks13 } from './checks_13.mjs';
import { checks14 } from './checks_14.mjs';
import { checks15 } from './checks_15.mjs';
import { checks16 } from './checks_16.mjs';
import { checks17 } from './checks_17.mjs';

const dir = process.argv[2];
const db = new PGlite();
// Stand-ins for Supabase's roles and auth schema. auth.uid() reads the request claims, as Supabase's does.
await db.exec(`
  create role anon; create role authenticated; create role service_role;
  create schema auth;
  create table auth.users (id uuid primary key);
  create function auth.uid() returns uuid language sql stable as $$
    select (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid $$;
  grant usage on schema auth to authenticated, anon;
`);
for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.sql')).sort()) {
  const t0 = Date.now();
  try { await db.exec(fs.readFileSync(`${dir}/${f}`, 'utf8')); console.log('ok', f, Date.now() - t0, 'ms'); }
  catch (e) { console.log('FAIL', f, e.message); process.exit(1); }
}

// Migration 0018 opens a fresh Test World. The older checks expect World 1 alone: note what 0018 made, then remove it.
const freshTestWorld = (await db.query(`select w.status, w.speed::float, w.prelaunch_weeks, w.pilots, w.max_airlines, s.invite_code
  from public.worlds w join public.world_secrets s on s.world_id = w.id where w.name = 'Test World'`)).rows[0];
await db.exec(`delete from public.worlds where name = 'Test World'`);
// The checks written before migration 0013 expect the flat pilot cost per aircraft: their worlds run without pilots.
await db.exec(`update public.worlds set pilots = false; alter table public.worlds alter column pilots set default false;`);
// The checks written before migration 0018 run without a pre-launch: airlines fly from day 1.
await db.exec(`update public.worlds set prelaunch_weeks = 0; alter table public.worlds alter column prelaunch_weeks set default 0;
  update public.airlines set first_flight_day = 1;`);
// and with the game values they were written for; checks_8 puts back the values 0018 set
const weekParams = (await db.query(`select key, num::float from public.game_params where key in ('wet_lead_days', 'season_start_month', 'tick_max_days')`)).rows;
await db.exec(`update public.game_params set num = case key when 'wet_lead_days' then 13 when 'season_start_month' then 4 else 30 end
  where key in ('wet_lead_days', 'season_start_month', 'tick_max_days');
  alter table public.airlines disable trigger airlines_first_flight; alter table public.aircraft disable trigger aircraft_week_start;`);
// The checks written before migration 0019 run in worlds with daily fares (no selling ahead); checks_9 makes its own.
await db.exec(`update public.worlds set selling = false; alter table public.worlds alter column selling set default false;`);
// ... and with computer-run airlines that neither fight nor explore (0021); checks_11 switches them on
await db.exec(`update public.bot_airlines set aggression = 0; update public.game_params set num = 0 where key = 'bot_explore_prob';
  create table public.bot_strategy_mix_0021 as select * from public.bot_strategy_mix;
  delete from public.bot_strategy_mix;
  insert into public.bot_strategy_mix select code, case code when 'SRW' then 'top' when 'KOL' then 'fill' when 'BLB' then 'follow' else 'balanced' end, 1
    from public.bot_airlines;`);   // one way each, as in 0020
// The checks written before migration 0022 run with one growth rate, no festivals or events, and a world start that leaves
// the first week to the scheduler; checks_12 puts them back.
await db.exec(`update public.game_params set num = case key when 'growth_year_intl' then (select num from public.game_params where key = 'growth_year') else 0 end
    where key in ('growth_year_intl', 'start_first_week');
  create table public.demand_events_0022 as select * from public.demand_events;
  delete from public.demand_events;`);
// The checks written before migration 0025 run with currency swings as before and fights at the 0024 fares; checks_15 puts
// the 0025 values back.
const z5Params = (await db.query(`select key, num::float from public.game_params where key in ('event_fx_prob_day', 'bot_fight_random')`)).rows;
await db.exec(`update public.game_params set num = case key when 'event_fx_prob_day' then 0.003 else 0 end
  where key in ('event_fx_prob_day', 'bot_fight_random');`);
// The checks written before migration 0024 run with the old disruption rates and the old computer-run airlines (one route per
// aircraft, no cost floor, fights that fill every seat) and fares that ignore fuel; checks_14 puts the 0024 values back.
const y1Params = (await db.query(`select key, num::float from public.game_params where key in ('ground_prob_day', 'event_fuel_prob_day',
  'event_engine_prob_day', 'bot_drop_min_days', 'bot_plan', 'bot_sell_floor_lf', 'bot_fight_follow', 'fuel_pass')`)).rows;
await db.exec(`update public.game_params set num = case key when 'ground_prob_day' then 0.004 when 'event_fuel_prob_day' then 0.004
    when 'event_engine_prob_day' then 0.002 when 'bot_drop_min_days' then 364 else 0 end
  where key in ('ground_prob_day', 'event_fuel_prob_day', 'event_engine_prob_day', 'bot_drop_min_days', 'bot_plan',
                'bot_sell_floor_lf', 'bot_fight_follow', 'fuel_pass');`);

let failed = 0;
const t = {
  db, freshTestWorld, weekParams, y1Params, z5Params,
  q: async (s, p) => (await db.query(s, p)).rows,
  one: async (s, p) => Object.values((await db.query(s, p)).rows[0])[0],
  ok(name, cond, detail = '') { if (!cond) failed++; console.log(cond ? '  pass' : '  FAIL', name, detail); },
  async fails(name, sql, re) {
    try { await db.query(sql); failed++; console.log('  FAIL', name, '(no error)'); }
    catch (e) { const hit = re.test(e.message); if (!hit) failed++; console.log(hit ? '  pass' : '  FAIL', name, hit ? '' : e.message); }
  },
  as: (uid) => db.query(`select set_config('request.jwt.claims', $1, false)`,
    [uid ? JSON.stringify({ sub: uid, role: 'authenticated' }) : '']),
};

await checks2a(t);
await checks2b(t, process.argv.includes('--perf'));
await checks2c(t);
await checks2d(t);
await checks3(t);
await checks4(t);
await checks5(t);
await checks6(t);
await checks7(t);
await checks8(t);
await checks9(t);
await checks10(t);
await checks11(t);
await checks12(t);
await checks13(t);
await checks14(t);
await checks15(t);
await checks16(t);
await checks17(t);
console.log(failed ? `\n${failed} CHECK(S) FAILED` : '\nall checks passed');
process.exit(failed ? 1 : 0);

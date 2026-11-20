// Admin: invite link, start, pause and resume. For profiles marked is_admin, and for the founder of a world founded by a
// player (0027: invite, pause, pace, turns and places; not the start, disruptions or the game-wide cards). The server
// checks this again.
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { call, rows, supabase } from '../lib/api';
import { useGame, useStrategies, useWorldAirlines } from '../lib/data';
import type { Strategy } from '../lib/types';
import { clock, inPrelaunch } from '../lib/game';
import { currentWeek, num, realTime, weekHours, weekLabel } from '../lib/format';
import { useToast } from '../components/toast';
import { Badge, Button, Empty, Field, Kpi, PageHeader, Sheet, Stepper } from '../components/ui';
import { TurnControl } from './Worlds';

export function Admin() {
  const { profile, world, uid } = useGame();
  const airlines = useWorldAirlines();
  const admin = !!profile?.is_admin;
  const founder = world.founder_id != null && world.founder_id === uid;
  const toast = useToast();
  const qc = useQueryClient();
  const [confirm, setConfirm] = useState<'start' | 'pause' | 'resume' | null>(null);
  const [busy, setBusy] = useState(false);
  const invite = useQuery({ queryKey: ['admin', world.id, 'invite'], enabled: admin || founder, queryFn: () => call<string>('admin_world_invite', { p_world: world.id }) });

  if (!admin && !founder) return <Empty title="Admins only" />;
  const players = (airlines.data ?? []).filter((a) => !a.is_ai);
  const link = invite.data ? `${location.origin}${location.pathname}#/join?code=${invite.data}` : '';
  const c = clock(world);

  async function act(fn: string, ok: string) {
    setBusy(true);
    try {
      await call(fn, { p_world: world.id });
      toast(ok);
      await qc.invalidateQueries({ queryKey: ['world', world.id] });
      setConfirm(null);
    } catch (e) { toast((e as Error).message, 'error'); } finally { setBusy(false); }
  }

  return (
    <div className="stack-lg">
      <PageHeader title={admin ? 'Admin' : 'Your world'} sub={founder ? `${world.name} · you founded it` : world.name} />
      <div className="grid4-d">
        <Kpi label="Status" value={world.status} note={world.status === 'running' && inPrelaunch(world) ? 'pre-launch' : `a week in ${weekHours(world.speed)}`} />
        <Kpi label="Game week" value={currentWeek(world)} note={weekLabel(currentWeek(world), world.start_date).split(' · ')[1]} />
        <Kpi label="Players" value={`${players.length} / ${world.max_airlines}`} />
        <Kpi label="Demand scale" value={num(world.demand_scale, 2)} note="about players / 50" />
      </div>
      <div className="split-even">
        <div className="card stack">
          <h2>Invite colleagues</h2>
          <p className="small muted">Anyone with this link can create an account and found an airline in {world.name}.</p>
          {invite.error ? <div className="card bad small">{(invite.error as Error).message}</div> : (
            <div className="card tight num small" style={{ wordBreak: 'break-all' }}>{link || 'Loading…'}</div>
          )}
          <div className="row">
            <Button disabled={!link} onClick={async () => { await navigator.clipboard.writeText(link); toast('Invite link copied'); }}>Copy link</Button>
            {'share' in navigator && <Button kind="secondary" disabled={!link} onClick={() => navigator.share({ title: 'Join my airline game', text: `Run an airline against us. Invite code ${invite.data}.`, url: link }).catch(() => {})}>Share</Button>}
          </div>
          {invite.data && <p className="tiny muted">Invite code: <span className="num strong">{invite.data}</span></p>}
        </div>
        <div className="card stack">
          <h2>Clock</h2>
          {world.status === 'setup' && world.min_players != null && (
            <p className="small muted">It starts by itself once {world.min_players} players have joined ({players.length} so far){world.join_deadline ? `, or closes on ${new Date(world.join_deadline).toLocaleDateString()} if not` : ''}.</p>
          )}
          {world.status === 'setup' && admin && <>
            <p className="small muted">Starting fills the lessor pool, starts the clock and plays the first week at once, so the computer-run airlines and seats on sale appear straight away. First comes the pre-launch: {world.prelaunch_weeks} weeks in {realTime(world.prelaunch_minutes * 60)}, with nothing flying. First flights are in week {world.prelaunch_weeks + 1}; after that a game week takes {weekHours(world.speed)}. Check the places first: they can only go up after the start.</p>
            <Button onClick={() => setConfirm('start')}>Start the world</Button>
          </>}
          {world.status === 'running' && <>
            <p className="small muted">Running{inPrelaunch(world) ? ', in the pre-launch' : ''}. This week's results in about {c.nextInSec != null ? realTime(c.nextInSec) : '–'}.</p>
            <Button kind="secondary" onClick={() => setConfirm('pause')}>Pause</Button>
          </>}
          {world.status === 'paused' && <Button onClick={() => setConfirm('resume')}>Resume</Button>}
          {world.status === 'ended' && <Badge>Season over</Badge>}
          {world.status !== 'ended' && <SpeedControl />}
          {world.status !== 'ended' && <TurnControl world={world} onDone={() => qc.invalidateQueries({ queryKey: ['world', world.id] })} />}
          {world.status !== 'ended' && <PlacesControl />}
        </div>
      </div>
      {admin && <DisruptionsAdmin />}
      {admin && <StrategiesAdmin />}
      {admin && <BotsAdmin />}
      {confirm && (
        <Sheet title={confirm === 'start' ? 'Start the world?' : confirm === 'pause' ? 'Pause the world?' : 'Resume the world?'} onClose={() => setConfirm(null)}>
          <div className="stack">
            <p className="small">{confirm === 'start' ? `${players.length} players have joined. Players can still join after the start.` : confirm === 'pause' ? 'No game weeks are processed while paused, and players cannot act.' : 'Game weeks start again from where they stopped.'}</p>
            <Button block busy={busy} onClick={() => act(confirm === 'start' ? 'admin_start_world' : confirm === 'pause' ? 'admin_pause_world' : 'admin_resume_world',
              confirm === 'start' ? 'The world has started' : confirm === 'pause' ? 'Paused' : 'Resumed')}>
              {confirm === 'start' ? 'Start' : confirm === 'pause' ? 'Pause' : 'Resume'}
            </Button>
          </div>
        </Sheet>
      )}
    </div>
  );
}

const WEEK_HOURS = [0.5, 1, 2, 3, 4, 6, 8, 12, 24];

// ---------- Disruptions, this world only (migration 0025) ----------
// Each event: how often (a chance a day; per aircraft for groundings), how big and how long. Values the admin has not set
// follow the game's defaults ("Real"). Players are not told.
type DKey = string;
const EVENTS: { id: string; name: string; what: string; prob: DKey; size?: { lo: DKey; hi: DKey; label: string; pct: 'over1' | 'share' };
  len: { lo: DKey; hi: DKey; unit: 'days' | 'weeks' } }[] = [
  { id: 'ground', name: 'Aircraft groundings', what: 'A technical fault grounds one aircraft; without a spare at its base, its flights are cancelled.',
    prob: 'ground_prob_day', len: { lo: 'ground_days_min', hi: 'ground_days_max', unit: 'days' } },
  { id: 'fuel', name: 'Fuel shocks', what: 'Jet fuel jumps for some weeks. Hedged fuel is protected.', prob: 'event_fuel_prob_day',
    size: { lo: 'event_fuel_mult_min', hi: 'event_fuel_mult_max', label: 'Fuel up by', pct: 'over1' }, len: { lo: 'event_fuel_days_min', hi: 'event_fuel_days_max', unit: 'weeks' } },
  { id: 'fx', name: 'Currency swings', what: 'The rupee weakens for some months: leases, maintenance and aircraft loans cost more.', prob: 'event_fx_prob_day',
    size: { lo: 'event_fx_mult_min', hi: 'event_fx_mult_max', label: 'Rupee weaker by', pct: 'over1' }, len: { lo: 'event_fx_days_min', hi: 'event_fx_days_max', unit: 'weeks' } },
  { id: 'engine', name: 'Engine events', what: 'Inspections ground part of one aircraft type across the world.', prob: 'event_engine_prob_day',
    size: { lo: 'event_engine_share_min', hi: 'event_engine_share_max', label: 'Share of the type', pct: 'share' }, len: { lo: 'event_engine_days_min', hi: 'event_engine_days_max', unit: 'weeks' } },
];
const D_KEYS = EVENTS.flatMap((e) => [e.prob, e.len.lo, e.len.hi, ...(e.size ? [e.size.lo, e.size.hi] : [])]);
const PER_YEAR = [0, 0.2, 0.5, 1, 2, 4, 6, 12];
const often = (y: number, perAircraft: boolean) => {
  const tail = perAircraft ? ' per aircraft' : '';
  if (y <= 0) return 'Never';
  if (y >= 11.5) return `About once a month${tail}`;
  if (y >= 1.5) return `About ${Math.round(y)} times a year${tail}`;
  if (y >= 0.9) return `About once a year${tail}`;
  return `About once in ${Math.round((1 / y) * 10) / 10} years${tail}`;
};

function DisruptionsAdmin() {
  const { world, ref } = useGame();
  const toast = useToast();
  const qc = useQueryClient();
  const own = useQuery({ queryKey: ['admin', world.id, 'world_params'],
    queryFn: () => rows<{ key: string; num: number }>(supabase.from('world_params').select('key,num').eq('world_id', world.id)) });
  const [draft, setDraft] = useState<Record<string, number> | null>(null);
  const [busy, setBusy] = useState(false);
  if (!own.data) return null;
  const def = (k: string) => Number(ref.param[k] ?? 0);
  const saved: Record<string, number> = Object.fromEntries(D_KEYS.map((k) => [k, Number(own.data!.find((r) => r.key === k)?.num ?? def(k))]));
  const v = draft ?? saved;
  const set = (k: string, x: number) => setDraft({ ...v, [k]: x });
  const preset = (m: number | null) => setDraft(Object.fromEntries(D_KEYS.map((k) => {
    const isProb = EVENTS.some((e) => e.prob === k);
    return [k, m == null || !isProb ? def(k) : Math.min(12 / 364, def(k) * m)];
  })));
  const changed = D_KEYS.some((k) => Math.abs(v[k] - saved[k]) > 1e-9);
  const isPreset = (m: number) => D_KEYS.every((k) => Math.abs(v[k] - (EVENTS.some((e) => e.prob === k) ? Math.min(12 / 364, def(k) * m) : def(k))) < 1e-9);
  const label = isPreset(1) ? 'Real' : isPreset(0.5) ? 'Calm' : isPreset(2) ? 'Rough' : 'Custom';
  const days = (k: string, unit: 'days' | 'weeks') => (unit === 'weeks' ? Math.round(v[k] / 7) : Math.round(v[k]));
  const fromUnit = (x: number, unit: 'days' | 'weeks') => (unit === 'weeks' ? x * 7 : x);
  const pctOf = (x: number, kind: 'over1' | 'share') => Math.round((kind === 'over1' ? x - 1 : x) * 100);
  const fromPct = (x: number, kind: 'over1' | 'share') => (kind === 'over1' ? 1 + x / 100 : x / 100);
  return (
    <div className="card stack">
      <div className="card-title" style={{ marginBottom: 0 }}><h2>Disruptions</h2><span className="small muted">{world.name} only · players are not told</span></div>
      <div className="row wrap" role="group" aria-label="Disruption presets">
        <Button size="sm" kind="secondary" onClick={() => preset(0.5)}>Calm</Button>
        <Button size="sm" kind="secondary" onClick={() => preset(null)}>Real</Button>
        <Button size="sm" kind="secondary" onClick={() => preset(2)}>Rough</Button>
        <Badge>{label}</Badge>
      </div>
      <p className="tiny muted">Real is close to Indian airlines today: about 1% of flights cancelled, and a fuel shock, a currency swing and an engine event each about once in three years. Calm halves how often they come; Rough doubles it. At most once a month; one shock of each kind at a time.</p>
      {EVENTS.map((e) => {
        const y = v[e.prob] * 364;
        const opts = [...new Set([...PER_YEAR, Math.round(def(e.prob) * 364 * 1000) / 1000, Math.round(y * 1000) / 1000])].sort((a, b) => a - b);
        return (
          <div key={e.id} className="stack" style={{ gap: 6, borderTop: '1px solid var(--line)', paddingTop: 10 }}>
            <div className="strong">{e.name}</div>
            <div className="tiny muted">{e.what}</div>
            <Field label="How often">
              <select className="input" aria-label={`${e.name}: how often`} value={Math.round(y * 1000) / 1000}
                onChange={(ev) => set(e.prob, Number(ev.target.value) / 364)}>
                {opts.map((o) => <option key={o} value={o}>{often(o, e.id === 'ground')}{Math.abs(o - def(e.prob) * 364) < 0.001 ? ' · Real' : ''}</option>)}
              </select>
            </Field>
            <div className="grid2">
              {e.size && <Field label={`${e.size.label} (%)`}>
                <div className="row" style={{ gap: 6 }}>
                  <input className="input num" inputMode="numeric" aria-label={`${e.name}: lowest size`} value={pctOf(v[e.size.lo], e.size.pct)}
                    onChange={(ev) => set(e.size!.lo, fromPct(Number(ev.target.value), e.size!.pct))} />
                  <span className="small muted">to</span>
                  <input className="input num" inputMode="numeric" aria-label={`${e.name}: highest size`} value={pctOf(v[e.size.hi], e.size.pct)}
                    onChange={(ev) => set(e.size!.hi, fromPct(Number(ev.target.value), e.size!.pct))} />
                </div>
              </Field>}
              <Field label={`Lasts (${e.len.unit})`}>
                <div className="row" style={{ gap: 6 }}>
                  <input className="input num" inputMode="numeric" aria-label={`${e.name}: shortest`} value={days(e.len.lo, e.len.unit)}
                    onChange={(ev) => set(e.len.lo, fromUnit(Number(ev.target.value), e.len.unit))} />
                  <span className="small muted">to</span>
                  <input className="input num" inputMode="numeric" aria-label={`${e.name}: longest`} value={days(e.len.hi, e.len.unit)}
                    onChange={(ev) => set(e.len.hi, fromUnit(Number(ev.target.value), e.len.unit))} />
                </div>
              </Field>
            </div>
          </div>
        );
      })}
      <div className="row wrap">
        <Button disabled={!changed} busy={busy} onClick={async () => {
          setBusy(true);
          try {
            // values equal to the game's default are cleared, so the world follows the default if it changes
            await call('admin_set_disruptions', { p_world: world.id,
              p_values: Object.fromEntries(D_KEYS.map((k) => [k, Math.abs(v[k] - def(k)) < 1e-9 ? null : v[k]])) });
            toast(`Disruptions saved for ${world.name}. They apply from the next game day.`);
            setDraft(null);
            await qc.invalidateQueries({ queryKey: ['admin', world.id, 'world_params'] });
          } catch (er) { toast((er as Error).message, 'error'); } finally { setBusy(false); }
        }}>Save disruptions</Button>
        {changed && <Button kind="secondary" onClick={() => setDraft(null)}>Undo</Button>}
      </div>
    </div>
  );
}

function SpeedControl() {
  const { world } = useGame();
  const toast = useToast();
  const qc = useQueryClient();
  const now = Math.round((168 / world.speed) * 100) / 100;
  const [hours, setHours] = useState(now);
  const [busy, setBusy] = useState(false);
  const label = (h: number) => (h < 1 ? `${Math.round(h * 60)} minutes` : h === 1 ? '1 hour' : `${h} hours`);
  const weeksLeft = Math.max(0, Math.floor(world.season_days / 7) - currentWeek(world) + 1);
  return (
    <div className="stack" style={{ marginTop: 8 }}>
      <div className="divider" />
      <Field label="One game week takes">
        <select className="input" value={hours} onChange={(e) => setHours(Number(e.target.value))}>
          {[...new Set([...WEEK_HOURS, now])].sort((a, b) => a - b).map((h) => <option key={h} value={h}>{label(h)}{h === now ? ' (now)' : ''}</option>)}
        </select>
      </Field>
      <p className="tiny muted">
        The {num(weeksLeft)} weeks left in the season then take about {realTime(weeksLeft * hours * 3600)}. A quarter (13 weeks) takes {realTime(13 * hours * 3600)}.
        {' '}The pre-launch is not affected: its weeks always pass in {realTime(world.prelaunch_minutes * 60)}.
      </p>
      <Button kind="secondary" disabled={hours === now} busy={busy} onClick={async () => {
        setBusy(true);
        try {
          await call('admin_set_week_hours', { p_world: world.id, p_hours: hours });
          toast(`A game week now takes ${label(hours)}`);
          await qc.invalidateQueries({ queryKey: ['world', world.id] });
        } catch (e) { toast((e as Error).message, 'error'); } finally { setBusy(false); }
      }}>Change the clock</Button>
    </div>
  );
}

// Principle 7: places set demand (places / 50) and every scarce pool together.
function PlacesControl() {
  const { world } = useGame();
  const toast = useToast();
  const qc = useQueryClient();
  const [places, setPlaces] = useState(world.max_airlines);
  const [busy, setBusy] = useState(false);
  const min = world.status === 'setup' ? 2 : world.max_airlines;
  return (
    <div className="stack" style={{ marginTop: 8 }}>
      <div className="divider" />
      <div className="field">
        <label>Places for players · {places}</label>
        <Stepper label="places" value={places} step={1} min={min} max={200} onChange={setPlaces} />
      </div>
      <p className="tiny muted">
        Set this to the number of colleagues expected. Travellers, aircraft in the lessor pool, delivery slots, pilots and airport capacity all
        {' '}scale with it, so the game is as tight with 10 players as with 100. When the world is full, nobody else can join.
        {world.status !== 'setup' && ' Once the world has started, places can only go up; the computer-run airlines keep their size.'}
      </p>
      <Button kind="secondary" disabled={places === world.max_airlines} busy={busy} onClick={async () => {
        setBusy(true);
        try {
          await call('admin_set_places', { p_world: world.id, p_places: places });
          toast(`The world now has ${places} places`);
          await qc.invalidateQueries({ queryKey: ['world', world.id] });
        } catch (e) { toast((e as Error).message, 'error'); } finally { setBusy(false); }
      }}>Change places</Button>
    </div>
  );
}

// The four selling strategies (all worlds). Fares are multiples of the reference fare (business: of the business
// reference); the engine moves them by "step" a week when sales run more than "band" ahead of or behind the target load.
const STRAT_FIELDS: { k: keyof Strategy; label: string }[] = [
  { k: 'target_lf', label: 'Target load' }, { k: 'early_mult', label: 'Fare 26 wk out' }, { k: 'late_mult', label: 'Fare in the week' },
  { k: 'biz_early_mult', label: 'Business 26 wk out' }, { k: 'biz_late_mult', label: 'Business in the week' },
  { k: 'min_mult', label: 'Lowest' }, { k: 'max_mult', label: 'Highest' }, { k: 'step', label: 'Step a week' },
  { k: 'band', label: 'Band' }, { k: 'follow_gap', label: 'Follow gap' }, { k: 'overbook', label: 'Overbooking' },
];
function StrategiesAdmin() {
  const st = useStrategies();
  const toast = useToast();
  const qc = useQueryClient();
  const [edit, setEdit] = useState<Record<string, Record<string, string>>>({});
  const [busy, setBusy] = useState<string | null>(null);
  if (!st.data) return null;
  return (
    <div className="card flush">
      <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>Selling strategies</h2><span className="small muted">all worlds</span></div>
      <p className="tiny muted" style={{ padding: '0 16px' }}>Fares are multiples of the reference fare. Each week the engine moves a flight week's fares by the step when sales run more than the band ahead of or behind the target load. Changes count from the next week of selling.</p>
      <div className="scroll-x">
        <table className="table">
          <thead><tr><th>Strategy</th>{STRAT_FIELDS.map((f) => <th key={f.k} className="r">{f.label}</th>)}<th /></tr></thead>
          <tbody>
            {st.data.map((x) => {
              const e = edit[x.key] ?? {};
              const dirty = Object.keys(e).length > 0;
              return (
                <tr key={x.key}>
                  <td className="strong">{x.name}</td>
                  {STRAT_FIELDS.map((f) => (
                    <td key={f.k} className="r">
                      <input className="input num" style={{ width: 72, height: 32 }} inputMode="decimal" aria-label={`${x.name} ${f.label}`}
                        value={e[f.k] ?? String(x[f.k])} onChange={(ev) => setEdit({ ...edit, [x.key]: { ...e, [f.k]: ev.target.value } })} />
                    </td>
                  ))}
                  <td><Button size="sm" kind="secondary" disabled={!dirty} busy={busy === x.key} onClick={async () => {
                    setBusy(x.key);
                    try {
                      await call('admin_set_strategy', { p_key: x.key, p_values: Object.fromEntries(Object.entries(e).map(([k, v]) => [k, Number(v)])) });
                      toast(`${x.name} saved`);
                      setEdit({ ...edit, [x.key]: {} });
                      await qc.invalidateQueries({ queryKey: ['strategies'] });
                    } catch (er) { toast((er as Error).message, 'error'); } finally { setBusy(null); }
                  }}>Save</Button></td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// The computer-run airlines (all worlds): how likely each fights a player who enters its market, the mix of ways of
// selling its new routes start from, and the game values for how they review and fight (migration 0021).
interface BotRow { code: string; name: string; aggression: number }
interface MixRow { code: string; strategy: string; weight: number }
const BOT_PARAMS: { k: string; label: string }[] = [
  { k: 'bot_review_weeks', label: 'Review every (weeks)' }, { k: 'bot_explore_prob', label: 'Chance to try another way' },
  { k: 'bot_switch_gain', label: 'Switch when better by' }, { k: 'bot_fight_weeks', label: 'Fight lasts (weeks)' },
  { k: 'bot_follow_cut', label: 'Follow a player cut of' }, { k: 'bot_fight_margin', label: 'Fight margin over cost' },
  { k: 'bot_fight_skew', label: 'Fight skew (aggressive go lower)' },
];
const MIX_KEYS = ['fill', 'balanced', 'top', 'follow'];
function BotsAdmin() {
  const { ref } = useGame();
  const toast = useToast();
  const qc = useQueryClient();
  const bots = useQuery({ queryKey: ['bots'], queryFn: () => rows<BotRow>(supabase.from('bot_airlines').select('code,name,aggression').order('sort')) });
  const mix = useQuery({ queryKey: ['bot_mix'], queryFn: () => rows<MixRow>(supabase.from('bot_strategy_mix').select('*')) });
  const [edit, setEdit] = useState<Record<string, Record<string, string>>>({});
  const [pv, setPv] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  if (!bots.data || !mix.data) return null;
  const w = (code: string, k: string) => String(mix.data!.find((m) => m.code === code && m.strategy === k)?.weight ?? 0);
  const save = async (key: string, fn: () => Promise<unknown>, msg: string) => {
    setBusy(key);
    try { await fn(); toast(msg); await qc.invalidateQueries({ queryKey: ['bots'] }); await qc.invalidateQueries({ queryKey: ['bot_mix'] }); }
    catch (er) { toast((er as Error).message, 'error'); } finally { setBusy(null); }
  };
  return (
    <div className="card flush">
      <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>Computer-run airlines</h2><span className="small muted">all worlds</span></div>
      <p className="tiny muted" style={{ padding: '0 16px' }}>Aggression is the chance an airline fights a player who starts flying one of its markets. A fight prices, for some weeks, at a point drawn between the airline's profitable lowest fare (its cost at 80% full plus the fight margin) and the player's fare; aggressive airlines draw lower. New routes draw their way of selling from the mix; every few weeks each route moves to what works better on routes like it, or tries another way at random.</p>
      <div className="scroll-x">
        <table className="table">
          <thead><tr><th>Airline</th><th className="r">Aggression</th>{MIX_KEYS.map((k) => <th key={k} className="r">{k === 'fill' ? 'Fill' : k === 'top' ? 'Top' : k === 'follow' ? 'Follow' : 'Balanced'}</th>)}<th /></tr></thead>
          <tbody>
            {bots.data.map((b) => {
              const e = edit[b.code] ?? {};
              const val = (k: string, d: string) => e[k] ?? d;
              return (
                <tr key={b.code}>
                  <td className="strong">{b.name}</td>
                  <td className="r"><input className="input num" style={{ width: 64, height: 32 }} inputMode="decimal" aria-label={`${b.name} aggression`}
                    value={val('aggression', String(b.aggression))} onChange={(ev) => setEdit({ ...edit, [b.code]: { ...e, aggression: ev.target.value } })} /></td>
                  {MIX_KEYS.map((k) => (
                    <td key={k} className="r"><input className="input num" style={{ width: 56, height: 32 }} inputMode="decimal" aria-label={`${b.name} ${k} weight`}
                      value={val(k, w(b.code, k))} onChange={(ev) => setEdit({ ...edit, [b.code]: { ...e, [k]: ev.target.value } })} /></td>
                  ))}
                  <td><Button size="sm" kind="secondary" disabled={!Object.keys(e).length} busy={busy === b.code} onClick={() => save(b.code, async () => {
                    await call('admin_set_bot', { p_code: b.code, p_aggression: Number(val('aggression', String(b.aggression))),
                      p_mix: Object.fromEntries(MIX_KEYS.map((k) => [k, Number(val(k, w(b.code, k)))])) });
                    setEdit({ ...edit, [b.code]: {} });
                  }, `${b.name} saved`)}>Save</Button></td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <div className="stack" style={{ padding: '0 16px 14px' }}>
        <div className="grid3">
          {BOT_PARAMS.map((p) => (
            <Field key={p.k} label={p.label}>
              <input className="input num" inputMode="decimal" value={pv[p.k] ?? String(ref.param[p.k] ?? '')} onChange={(ev) => setPv({ ...pv, [p.k]: ev.target.value })} />
            </Field>
          ))}
        </div>
        <Button kind="secondary" disabled={!Object.keys(pv).length} busy={busy === 'params'} onClick={() => save('params', async () => {
          for (const [k, v] of Object.entries(pv)) await call('admin_set_param', { p_key: k, p_num: Number(v) });
          setPv({});
          await qc.invalidateQueries({ queryKey: ['ref'] });
        }, 'Saved. Reload to see the new values everywhere.')}>Save these values</Button>
      </div>
    </div>
  );
}

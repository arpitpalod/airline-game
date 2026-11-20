// Worlds (migration 0027): your worlds, worlds founded by players that wait for players, founding your own, and
// joining with an invite code. A world's rules are fixed for its season, except pace and places.
import { useQuery } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { call, rows, supabase } from '../lib/api';
import { useFounderStatus, useGame, useWorldList, useWorldOptions } from '../lib/data';
import { currentWeek, inr, num, plural, realTime, weekHours } from '../lib/format';
import type { FounderStatus, World, WorldOption, WorldSetting } from '../lib/types';
import { useToast } from '../components/toast';
import { Badge, Button, Field, Icon, Loading, PageHeader, Sheet, Stepper } from '../components/ui';

const SETTING_NAME: Record<WorldSetting, string> = {
  region: 'Home region', pace: 'Pace', turn: 'Turns', places: 'Places', money: 'Starting money', banks: 'Banks',
  growth: 'Demand growth', seats: 'Seats between countries', shocks: 'Shocks', bots: 'Computer-run airlines',
};

/** A world's rules as short labels: pace, turns and places from the world itself (they can change), the rest as founded. */
export function ruleChips(w: World, options: WorldOption[]) {
  const label = (s: WorldSetting) => options.find((o) => o.setting === s && o.option === w.rules[s])?.label;
  return [
    label('region') ?? 'India',
    `A week in ${weekHours(w.speed)}`,
    w.turn_mode === 'ready' ? 'When all are ready' : 'On the clock',
    `${w.max_airlines} places`,
    label('money') && `${label('money')} to start`,
    label('banks') && `${label('banks')} banks`,
    label('growth') && `${label('growth')} growth`,
    label('seats') && `Seats abroad: ${label('seats')}`,
    label('shocks') && `${label('shocks')} shocks`,
    label('bots') && `Rivals: ${label('bots')}`,
  ].filter(Boolean) as string[];
}

const statusText = (w: World) =>
  w.status === 'setup' ? 'Not started' : w.status === 'running' ? `Running · week ${currentWeek(w)}` : w.status === 'paused' ? 'Paused' : w.closed_at ? 'Closed' : 'Season over';

const daysLeft = (iso: string | null) => (iso ? Math.max(0, Math.ceil((new Date(iso).getTime() - Date.now()) / 86_400_000)) : null);

export function Worlds() {
  const { uid, myAirlines, airline, switchAirline, startJoin } = useGame();
  const list = useWorldList();
  const options = useWorldOptions();
  const lic = useFounderStatus();
  const nav = useNavigate();
  const toast = useToast();
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const opts = options.data ?? [];
  const entries = list.data ?? [];
  const mineIds = new Set(myAirlines.map((a) => a.world_id));
  const waiting = entries.filter((e) => e.world.status === 'setup' && e.world.founder_id && !mineIds.has(e.world.id));
  const founders = useQuery({
    queryKey: ['profiles', waiting.map((e) => e.world.founder_id).join(',')], enabled: waiting.length > 0,
    queryFn: async () => Object.fromEntries((await rows<{ user_id: string; display_name: string }>(
      supabase.from('profiles').select('user_id,display_name').in('user_id', waiting.map((e) => e.world.founder_id!)))).map((p) => [p.user_id, p.display_name])),
  });

  async function join(w: World) {
    setBusy(w.id);
    try { startJoin(await call<string>('world_join_code', { p_world: w.id }), w.id); }
    catch (e) { toast((e as Error).message, 'error'); } finally { setBusy(null); }
  }

  return (
    <div className="stack-lg">
      <PageHeader title="Worlds" sub="One account, an airline in each world you join" />
      <section className="stack">
        <h2>Your worlds</h2>
        <div className="card flush">
          <div className="list">
            {myAirlines.map((a) => {
              const w = entries.find((e) => e.world.id === a.world_id)?.world;
              return (
                <div key={a.id} className={`item link ${a.id === airline.id ? 'me' : ''}`} role="button"
                  onClick={() => { switchAirline(a.id); nav('/'); }}>
                  <div className="grow">
                    <div className="row" style={{ gap: 8 }}><span className="strong">{w?.name ?? '…'}</span>
                      {w && <Badge tone={w.status === 'running' ? 'good' : w.status === 'setup' ? 'info' : 'neutral'}>{statusText(w)}</Badge>}
                      {w?.founder_id === uid && <Badge tone="accent">Yours</Badge>}</div>
                    <div className="small muted">{a.name} ({a.code})</div>
                    {w && <div className="tiny muted">{ruleChips(w, opts).slice(0, 4).join(' · ')}</div>}
                  </div>
                  {a.id === airline.id ? <Badge>Playing</Badge> : <Icon name="right" />}
                </div>
              );
            })}
          </div>
        </div>
      </section>

      <section className="stack">
        <h2>Worlds waiting for players</h2>
        {list.isLoading ? <Loading h={90} /> : waiting.length === 0 ? (
          <div className="card small muted">None right now. Found one, or ask a colleague for an invite link.</div>
        ) : waiting.map(({ world: w, players }) => {
          const need = w.min_players ?? 1;
          const left = daysLeft(w.join_deadline);
          return (
            <div key={w.id} className="card stack">
              <div className="row">
                <div className="grow">
                  <h3>{w.name}</h3>
                  <div className="small muted">
                    {w.founder_id === uid ? 'Founded by you' : `Founded by ${founders.data?.[w.founder_id!] ?? 'a player'}`}
                    {` · starts when ${need} join`}{left != null ? ` · closes in ${plural(left, 'day')} if not` : ''}
                  </div>
                </div>
                <Badge tone="info">{players} of {need} joined</Badge>
              </div>
              <div className="row wrap" style={{ gap: 6 }}>{ruleChips(w, opts).map((c) => <Badge key={c}>{c}</Badge>)}</div>
              <p className="tiny muted">Fixed for the season, except pace and places, which the founder can change.</p>
              <div><Button busy={busy === w.id} onClick={() => join(w)}>Join with an airline</Button></div>
            </div>
          );
        })}
      </section>

      <section className="stack">
        <h2>Run your own world</h2>
        <div className="card flush"><div className="list">
          <div className="item link" role="button" onClick={() => nav('/worlds/new')}>
            <div className="grow">
              <div className="strong">Found a world</div>
              <div className="small muted">{lic.data ? licenceLine(lic.data) : 'Checking…'}</div>
            </div>
            <Icon name="right" />
          </div>
        </div></div>
      </section>

      <section className="card stack">
        <h2>Have an invite code?</h2>
        <div className="row">
          <input className="input grow" placeholder="Invite code" value={code} autoCapitalize="none" onChange={(e) => setCode(e.target.value)} />
          <Button disabled={code.trim().length < 4} onClick={() => startJoin(code.trim().toLowerCase())}>Enter it</Button>
        </div>
      </section>
    </div>
  );
}

function licenceLine(l: FounderStatus) {
  if (l.live_world) return `You run ${l.live_world}: one world at a time`;
  if (l.ok) return 'Earned in play: you may found one';
  if (l.admin) return 'As an admin you may found one at any time';
  if (l.quarters < l.need_quarters) return `Earned in play: ${plural(l.need_quarters - l.quarters, 'more quarter')} running an airline to go`;
  const bad = l.last.filter((q) => q.op_profit <= 0).length;
  return `Earned in play: ${plural(bad, 'more profitable quarter')} to go`;
}

// ---------- Found a world ----------

const STEP1: WorldSetting[] = ['region', 'pace', 'turn', 'places'];
const STEP2: WorldSetting[] = ['money', 'banks', 'growth', 'seats', 'shocks', 'bots'];

export function NewWorld() {
  const { ref, startJoin } = useGame();
  const lic = useFounderStatus();
  const options = useWorldOptions();
  const nav = useNavigate();
  const toast = useToast();
  const [step, setStep] = useState(1);
  const [name, setName] = useState('');
  const [pick, setPick] = useState<Partial<Record<WorldSetting, string>>>({});
  const [minPlayers, setMinPlayers] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [made, setMade] = useState<{ world_id: string; invite: string } | null>(null);
  const opts = options.data ?? [];
  const bySetting = useMemo(() => {
    const m: Partial<Record<WorldSetting, WorldOption[]>> = {};
    for (const o of opts) (m[o.setting] ??= []).push(o);
    return m;
  }, [opts]);
  const chosen = (s: WorldSetting) => pick[s] ?? bySetting[s]?.find((o) => o.is_default)?.option;
  const l = lic.data;
  const may = !!l && (l.ok || l.admin);
  const places = Number(bySetting.places?.find((o) => o.option === chosen('places'))?.vals.places ?? 25);
  const need = Math.min(places, minPlayers ?? ref.param.world_min_players ?? 6);
  const link = made ? `${location.origin}${location.pathname}#/join?code=${made.invite}` : '';

  async function create() {
    setBusy(true);
    try {
      const rules: Record<string, unknown> = Object.fromEntries([...STEP1, ...STEP2].map((s) => [s, chosen(s)]));
      if (l?.admin && minPlayers != null) rules.min_players = need;
      setMade(await call<{ world_id: string; invite: string }>('create_world', { p_name: name.trim(), p_rules: rules }));
    } catch (e) { toast((e as Error).message, 'error'); } finally { setBusy(false); }
  }

  const group = (s: WorldSetting) => (
    <Field key={s} label={SETTING_NAME[s]}>
      <div className={s === 'region' ? 'grid2' : 'choices'} role="radiogroup" aria-label={SETTING_NAME[s]}>
        {(bySetting[s] ?? []).map((o) => (
          <button key={o.option} type="button" role="radio" aria-checked={chosen(s) === o.option} disabled={!o.available}
            className={`choice${chosen(s) === o.option ? ' on' : ''}`} style={o.available ? undefined : { opacity: 0.5, cursor: 'default' }}
            onClick={() => o.available && setPick({ ...pick, [s]: o.option })}>
            <div className="t">{o.label}{!o.available && <span className="tiny muted" style={{ fontWeight: 400 }}> · coming</span>}</div>
            {(o.available || s !== 'region') && <div className="d">{o.blurb}{moneyNote(s, o)}</div>}
          </button>
        ))}
      </div>
    </Field>
  );

  return (
    <div className="stack-lg">
      <PageHeader title="Found a world" sub="Earned by running an airline well, in any world" back="/worlds" />
      {!l ? <Loading h={120} /> : <Licence l={l} />}

      <div className="card stack">
        <div className="row">
          <h2 className="grow">{step === 1 ? '1 · The world' : '2 · The market'}</h2>
          <span className="small muted">Step {step} of 2</span>
        </div>
        {options.isLoading ? <Loading h={200} /> : step === 1 ? <>
          <Field label="World name" hint="3 to 40 characters. Players see it when they join.">
            <input className="input" value={name} maxLength={40} onChange={(e) => setName(e.target.value)} placeholder="e.g. Monsoon League" />
          </Field>
          {STEP1.map(group)}
          {l?.admin && (
            <div className="field">
              <label>Players to start · {need} (admins only)</label>
              <Stepper label="players to start" value={need} min={1} max={places} onChange={setMinPlayers} />
            </div>
          )}
          <Button block disabled={name.trim().length < 3} onClick={() => { setStep(2); window.scrollTo(0, 0); }}>Next: the market</Button>
        </> : <>
          {STEP2.map(group)}
          <div className="card tight small">
            The world starts by itself when {plural(need, 'player')} {need === 1 ? 'has' : 'have'} joined, you included. If that takes more than {plural(ref.param.world_join_days ?? 7, 'day')}, it closes and you can found another.
            {' '}Everything here is fixed for the season, except pace and places (places only upwards once started).
          </div>
          <div className="grid2">
            <Button kind="secondary" onClick={() => setStep(1)}>Back</Button>
            <Button busy={busy} disabled={!may || name.trim().length < 3} onClick={create}>Found {name.trim() || 'the world'}</Button>
          </div>
          {!may && <p className="tiny muted" style={{ textAlign: 'center' }}>{l ? licenceLine(l) : ''}</p>}
        </>}
      </div>

      {made && (
        <Sheet title={`${name.trim()} is founded`} onClose={() => nav('/worlds')}>
          <div className="stack">
            <p className="small">It starts once {plural(need, 'player')} {need === 1 ? 'has' : 'have'} joined. Share the link, and found your own airline in it: you play by the same rules as everyone.</p>
            <div className="card tight num small" style={{ wordBreak: 'break-all' }}>{link}</div>
            <div className="grid2">
              <Button kind="secondary" onClick={async () => { await navigator.clipboard.writeText(link); toast('Invite link copied'); }}>Copy link</Button>
              <Button onClick={() => startJoin(made.invite, made.world_id)}>Found my airline</Button>
            </div>
          </div>
        </Sheet>
      )}
    </div>
  );
}

const moneyNote = (s: WorldSetting, o: WorldOption) =>
  s === 'banks' ? ` Credit line ${inr(o.vals.credit_limit_inr)} at ${num(o.vals.interest_year * 100, 0)}%, ${num(o.vals.order_deposit_share * 100, 0)}% deposit on new aircraft.` : '';

function Licence({ l }: { l: FounderStatus }) {
  const qOk = l.quarters >= l.need_quarters;
  const profitOk = l.last.length >= l.need_profit_quarters && l.last.every((q) => q.op_profit > 0);
  return (
    <div className="card stack">
      <h2>What it takes</h2>
      {l.admin && <div className="card info small">As an admin you may found a world at any time.</div>}
      <div className="steps">
        <div className={`step ${qOk ? 'done' : ''}`}>
          <div className="n">{qOk ? '✓' : Math.min(l.quarters, l.need_quarters)}</div>
          <div className="small" style={{ paddingTop: 3 }}>
            <div className="strong">Run one airline for {l.need_quarters} game quarters</div>
            <div className="muted">{Math.min(l.quarters, l.need_quarters)} of {l.need_quarters} done{l.airline ? ` · ${l.airline} in ${l.world}` : ''}</div>
          </div>
        </div>
        <div className={`step ${profitOk ? 'done' : ''}`}>
          <div className="n">{profitOk ? '✓' : '!'}</div>
          <div className="small grow" style={{ paddingTop: 3 }}>
            <div className="strong">An operating profit in your last {l.need_profit_quarters} quarters</div>
            {l.last.map((q) => (
              <div key={q.quarter} className="row" style={{ justifyContent: 'space-between' }}>
                <span className="muted">Quarter {q.quarter}</span>
                <span className={q.op_profit > 0 ? 'good' : 'bad'}>{inr(q.op_profit, { sign: true })} · {q.op_profit > 0 ? 'Met' : 'Not yet'}</span>
              </div>
            ))}
          </div>
        </div>
        <div className={`step ${!l.live_world ? 'done' : ''}`}>
          <div className="n">{l.live_world ? '!' : '✓'}</div>
          <div className="small" style={{ paddingTop: 3 }}>
            <div className="strong">No other world of yours waiting or running</div>
            <div className="muted">{l.live_world ? `You run ${l.live_world}` : 'One world at a time per founder'}</div>
          </div>
        </div>
      </div>
      <div className="small muted">
        As a founder you set the rules before the start, invite players with the world's link, and are its admin: pause it, change its pace, turns and places, and share its invite code. You also play in it, by the same rules as everyone.
      </div>
    </div>
  );
}

/** For the Admin screen: a world's turns (clock or When all are ready), for its founder or an admin. */
export function TurnControl({ world, onDone }: { world: World; onDone: () => void }) {
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  const next = world.turn_mode === 'ready' ? 'clock' : 'ready';
  return (
    <div className="stack" style={{ marginTop: 8 }}>
      <div className="divider" />
      <div className="small"><span className="strong">Turns: </span>{world.turn_mode === 'ready'
        ? `when all are ready. The week moves as soon as every player taps Ready, and at the latest after ${realTime(168 / world.speed * 3600)}.`
        : 'on the clock. Weeks move on time, ready or not.'}</div>
      <Button kind="secondary" busy={busy} onClick={async () => {
        setBusy(true);
        try { await call('set_turn_mode', { p_world: world.id, p_mode: next }); toast(next === 'ready' ? 'Weeks now move when all are ready' : 'Weeks now move on the clock'); onDone(); }
        catch (e) { toast((e as Error).message, 'error'); } finally { setBusy(false); }
      }}>{next === 'ready' ? 'Move when all are ready' : 'Move on the clock'}</Button>
    </div>
  );
}

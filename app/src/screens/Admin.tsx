// Admin: invite link, start, pause and resume. Only for profiles marked is_admin; the server checks this again.
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { call } from '../lib/api';
import { useGame, useStrategies, useWorldAirlines } from '../lib/data';
import type { Strategy } from '../lib/types';
import { clock, inPrelaunch } from '../lib/game';
import { currentWeek, num, realTime, weekHours, weekLabel } from '../lib/format';
import { useToast } from '../components/toast';
import { Badge, Button, Empty, Field, Kpi, PageHeader, Sheet, Stepper } from '../components/ui';

export function Admin() {
  const { profile, world } = useGame();
  const airlines = useWorldAirlines();
  const toast = useToast();
  const qc = useQueryClient();
  const [confirm, setConfirm] = useState<'start' | 'pause' | 'resume' | null>(null);
  const [busy, setBusy] = useState(false);
  const invite = useQuery({ queryKey: ['admin', world.id, 'invite'], enabled: !!profile?.is_admin, queryFn: () => call<string>('admin_world_invite', { p_world: world.id }) });

  if (!profile?.is_admin) return <Empty title="Admins only" />;
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
      <PageHeader title="Admin" sub={world.name} />
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
          {world.status === 'setup' && <>
            <p className="small muted">Starting fills the lessor pool and starts the clock. First comes the pre-launch: {world.prelaunch_weeks} weeks in {realTime(world.prelaunch_minutes * 60)}, with nothing flying. First flights are in week {world.prelaunch_weeks + 1}; after that a game week takes {weekHours(world.speed)}. The computer-run airlines are set up on day 1. Check the places first: they can only go up after the start.</p>
            <Button onClick={() => setConfirm('start')}>Start the world</Button>
          </>}
          {world.status === 'running' && <>
            <p className="small muted">Running{inPrelaunch(world) ? ', in the pre-launch' : ''}. This week's results in about {c.nextInSec != null ? realTime(c.nextInSec) : '–'}.</p>
            <Button kind="secondary" onClick={() => setConfirm('pause')}>Pause</Button>
          </>}
          {world.status === 'paused' && <Button onClick={() => setConfirm('resume')}>Resume</Button>}
          {world.status === 'ended' && <Badge>Season over</Badge>}
          {world.status !== 'ended' && <SpeedControl />}
          {world.status !== 'ended' && <PlacesControl />}
        </div>
      </div>
      <StrategiesAdmin />
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

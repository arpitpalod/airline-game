// Revenue management for one route: the next six weeks of flights, the fare levels and how they sell, and results.
import { useMemo, useState } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import { call } from '../lib/api';
import {
  useDepartureLog, useDepartures, useEvents, useGame, useMarketFares, useMarketsFrom, useRivals, useRmCalendar, useRouteRm, useRoutes, useWhatIf,
  type RmCalendar,
} from '../lib/data';
import { pairKey } from '../lib/game';
import { inr, num, pct } from '../lib/format';
import {
  advice, booked, dateLabel, DOW, dow, festivalsOn, kRs, levelFare, MODE_HELP, MODE_LABEL, PACE_LABEL, PACE_TONE, paceOf, rmStats, sum,
  targetAt, TYPES,
} from '../lib/rm';
import type { Departure, Market, RmMode, RouteRm } from '../lib/types';
import { useAction } from '../components/toast';
import { Badge, Button, Empty, Kpi, Loading, PageHeader, Seg, Sheet, Stepper } from '../components/ui';

type Tab = 'calendar' | 'fares' | 'results';

export function Selling() {
  const { id } = useParams();
  const [sp, setSp] = useSearchParams();
  const { ref, world } = useGame();
  const net = useRoutes();
  const route = net.data?.routes.find((r) => r.id === id);
  const markets = useMarketsFrom(route ? [route.origin, route.dest] : []);
  const rm = useRouteRm(id);
  const deps = useDepartures(id);
  const cal = useRmCalendar();
  const tab = (sp.get('tab') as Tab) || 'calendar';

  if (net.isLoading || rm.isLoading) return <Loading h={300} />;
  if (!route || !rm.data) return <Empty title="This route is closed" />;
  const m = markets.data?.[pairKey(route.origin, route.dest)];
  const A = ref.airport[route.origin], B = ref.airport[route.dest];
  if (!world.rm) return <Empty title="Selling is simple in this world">This world sells one fare per cabin. Set it on the route page.</Empty>;

  return (
    <div className="stack-lg">
      <PageHeader back={`/route/${route.id}`} title={`Selling ${A.city} – ${B.city}`}
        sub={<>{MODE_LABEL[rm.data.mode]} · aiming for {pct(rm.data.target_lf)} full · flights go on sale {ref.param.rm_horizon ?? 42} days ahead</>} />
      <Seg block value={tab} onChange={(v) => setSp({ tab: v }, { replace: true })}
        options={[{ value: 'calendar', label: 'Next 6 weeks' }, { value: 'fares', label: 'Fares' }, { value: 'results', label: 'Results' }]} />
      {!m ? <Loading /> : tab === 'calendar' ? <CalendarTab rm={rm.data} deps={deps.data ?? []} m={m} cal={cal.data} routeId={route.id} base={route.fare_econ} />
        : tab === 'fares' ? <FaresTab rm={rm.data} base={route.fare_econ} baseB={route.fare_biz} m={m} routeId={route.id} />
          : <ResultsTab rm={rm.data} routeId={route.id} m={m} />}
    </div>
  );
}

// ---------- Next six weeks ----------

function CalendarTab({ rm, deps, m, cal, routeId, base }: { rm: RouteRm; deps: Departure[]; m: Market; cal: RmCalendar | undefined; routeId: string; base: number }) {
  const { ref, world } = useGame();
  const ev = useEvents();
  const [open, setOpen] = useState<number | null>(null);
  const sm = ref.param.season_start_month ?? 4;
  const today = world.game_day;
  const cityEv = (ev.data ?? []).filter((e) => e.kind === 'city_demand');
  const byDay = Object.fromEntries(deps.map((d) => [d.dep_day, d]));
  if (deps.length === 0) return <Empty title="Nothing on sale">Put an aircraft on this route and its flights go on sale for the next six weeks.</Empty>;
  const first = deps[0].dep_day, last = deps[deps.length - 1].dep_day;
  const start = first - dow(first);   // the Monday on or before the first date
  const cells: number[] = [];
  for (let d = start; d <= last; d++) cells.push(d);
  const week = deps.filter((d) => d.dep_day <= today + 7);
  const sold7 = sum(week.map(booked)), cap7 = sum(week.map((d) => d.cap_e + d.cap_b));
  const paces = deps.map((d) => paceOf(d, today, rm, m, ref, cal).pace);
  const n = (p: string) => paces.filter((x) => x === p).length;
  const evOn = (day: number) => [
    ...festivalsOn(day, sm, m.intl, cal).map((f) => f.name),
    ...cityEv.filter((e) => day >= e.starts_day && day <= (e.ends_day ?? e.starts_day) && [m.a, m.b].includes(String(e.payload.iata)))
      .map((e) => `${String(e.payload.name)} (${String(e.payload.iata)})`),
  ];
  const sel = open != null ? byDay[open] : null;

  return (
    <div className="stack-lg">
      <div className="grid4-d">
        <Kpi label="Next 7 days, sold" value={cap7 ? pct(sold7 / cap7) : '–'} note={`${num(2 * sold7)} seats both ways`} />
        <Kpi label="Selling fast" value={num(n('ahead') + n('full'))} note="dates ahead of your curve or sold out" />
        <Kpi label="Selling slowly" value={num(n('behind'))} note="dates behind your curve" tone={n('behind') > deps.length / 3 ? 'bad' : undefined} />
        <Kpi label="Cheapest on sale" value={inr(Math.min(...deps.map((d) => d.fare_e ?? Infinity).filter(isFinite)))} note="economy, any date" />
      </div>
      <div className="card stack">
        <div className="card-title" style={{ marginBottom: 0 }}><h2>Flights on sale</h2><span className="small muted">tap a date</span></div>
        <div className="cal">
          {DOW.map((d) => <div key={d} className="cal-h">{d}</div>)}
          {cells.map((day) => {
            const d = byDay[day];
            if (!d) return <div key={day} className="cal-c off">{day <= today ? '' : dateLabel(day, sm, false).split(' ')[0]}</div>;
            const p = paceOf(d, today, rm, m, ref, cal);
            const cap = d.cap_e + d.cap_b;
            return (
              <button key={day} className={`cal-c ${p.pace}`} onClick={() => setOpen(day)} aria-label={`${dateLabel(day, sm)}, ${PACE_LABEL[p.pace]}`}>
                <span className="cal-d">{dateLabel(day, sm, false).split(' ')[0]}{evOn(day).length > 0 && <i className="cal-ev" />}</span>
                <span className="cal-v">{cap ? pct(booked(d) / cap) : '–'}</span>
                <span className="cal-f">{d.fare_e != null ? kRs(d.fare_e) : 'full'}</span>
              </button>
            );
          })}
        </div>
        <div className="row wrap small" style={{ gap: 8 }}>
          {(['ahead', 'on', 'behind', 'full'] as const).map((p) => <Badge key={p} tone={PACE_TONE[p]}>{PACE_LABEL[p]}</Badge>)}
          <span className="tiny muted"><i className="cal-ev" style={{ position: 'static', display: 'inline-block' }} /> festival or city event</span>
        </div>
        <p className="tiny muted">Each date shows how full it is so far and the cheapest economy fare on sale. "Selling fast" means bookings run more than 8% (and at least 3% of the seats) ahead of the curve that ends at your target load; the target curve follows when each kind of traveller books (business travellers in the last week, families and budget travellers weeks ahead).</p>
      </div>
      {sel && <DateSheet d={sel} rm={rm} m={m} cal={cal} routeId={routeId} base={base} events={evOn(sel.dep_day)} onClose={() => setOpen(null)} />}
    </div>
  );
}

function DateSheet({ d, rm, m, cal, routeId, base, events, onClose }: {
  d: Departure; rm: RouteRm; m: Market; cal: RmCalendar | undefined; routeId: string; base: number; events: string[]; onClose: () => void;
}) {
  const { ref, world, airline } = useGame();
  const { run, busy } = useAction();
  const mf = useMarketFares(routeId);
  const log = useDepartureLog(routeId, 35);
  const rivals = useRivals([m.a, m.b]);
  const sm = ref.param.season_start_month ?? 4;
  const h = ref.param.rm_horizon ?? 42;
  const n = d.dep_day - world.game_day;
  const [minE, setMinE] = useState(d.min_e);
  const cap = d.cap_e + d.cap_b;
  const p = paceOf(d, world.game_day, rm, m, ref, cal);
  // typical: flown departures on the same weekday, last five weeks
  const same = (log.data ?? []).filter((l) => dow(l.dep_day) === dow(d.dep_day));
  const typical = Array.from({ length: h }, (_, i) => {
    const v = same.map((l) => l.curve[i]).filter((x): x is number => x != null);
    return v.length ? sum(v) / v.length : null;
  });
  const target = Array.from({ length: h }, (_, i) => targetAt(i, d.dep_day, d, rm, m, ref, cal));
  const names = Object.fromEntries((rivals.data?.[pairKey(m.a, m.b)] ?? []).map((x) => [x.route.airline_id, x.airline?.name ?? '—']));
  const others = (mf.data ?? []).filter((x) => x.dep_day === d.dep_day);
  const typeRows = TYPES.map((t, i) => ({ t, s: d.sav[i], f: d.flx[i] }));

  return (
    <Sheet title={`${dateLabel(d.dep_day, sm)} · day ${d.dep_day}`} onClose={onClose}>
      <div className="stack">
        <div className="row wrap" style={{ gap: 8 }}>
          <Badge tone={PACE_TONE[p.pace]}>{PACE_LABEL[p.pace]}</Badge>
          <span className="small muted">{n === 1 ? 'flies tomorrow' : `${n} days to go`} · {num(2 * booked(d))} of {num(2 * cap)} seats sold both ways</span>
        </div>
        {events.length > 0 && <div className="card info small">{events.join(' · ')}: more travellers than usual on this date.</div>}
        <div className="card tight">
          <BookingCurveChart actual={d.curve} target={target} typical={same.length ? typical : null} cap={cap} now={n} />
          <div className="row wrap tiny muted" style={{ gap: 12 }}>
            <span><i className="lg-k a" /> this flight</span><span><i className="lg-k t" /> target curve</span>
            {same.length > 0 && <span><i className="lg-k y" /> typical {DOW[dow(d.dep_day)]}</span>}
          </div>
        </div>
        <table className="table">
          <thead><tr><th>Booked so far</th><th className="r">Saver</th><th className="r">Flexi</th></tr></thead>
          <tbody>
            {typeRows.map((r) => <tr key={r.t}><td>{r.t}</td><td className="r">{num(2 * r.s)}</td><td className="r">{num(2 * r.f)}</td></tr>)}
            {d.cap_b > 0 && <tr><td>Business cabin</td><td className="r" colSpan={2}>{num(2 * d.bkb)}</td></tr>}
          </tbody>
        </table>
        <div className="card tight small stack" style={{ gap: 4 }}>
          <strong>On sale now</strong>
          <span>Economy: {d.lvl_e ? `level ${d.lvl_e}, ${inr(d.fare_e)}` : 'sold out'}{rm.flex != null && d.lvl_e ? ` (Flexi ${inr((d.fare_e ?? 0) + rm.flex * m.ref_fare)})` : ''}</span>
          {d.cap_b > 0 && <span>Business: {d.lvl_b ? `level ${d.lvl_b}, ${inr(d.fare_b)}` : 'sold out'}</span>}
          {others.filter((x) => x.airline_id !== airline.id).map((x) => (
            <span key={x.route_id} className="muted">{names[x.airline_id] ?? 'A rival'}: {x.fare_e != null ? inr(x.fare_e) : 'sold out'}</span>
          ))}
          {others.filter((x) => x.airline_id !== airline.id).length === 0 && <span className="muted">Nobody else sells this date.</span>}
        </div>
        <div className="field">
          <label>Cheapest economy level allowed on this date</label>
          <Stepper label="cheapest level" value={minE} min={1} max={6} onChange={setMinE}
            format={(v) => v === 1 ? 'Any level' : `Level ${v} and dearer · from ${inr(levelFare(base, rm.e_mult[v - 1]))}`} />
          <div className="hint">For a date you expect to be busy, such as a festival, keep cheap fares off it. Fences by days before departure still apply.</div>
        </div>
        <Button block disabled={minE === d.min_e} busy={busy === 'date'} onClick={() => run('date', () => call('set_rm_dates', {
          p_airline: airline.id, p_route: routeId, p_from: d.dep_day, p_to: d.dep_day, p_min_e: minE, p_min_b: d.min_b,
        }), minE === 1 ? 'Every level can sell on this date again' : `Only level ${minE} and dearer sell on this date`).then((r) => r !== undefined && onClose())}>Save</Button>
      </div>
    </Sheet>
  );
}

export function BookingCurveChart({ actual, target, typical, cap, now }: {
  actual: (number | null)[]; target: number[]; typical: (number | null)[] | null; cap: number; now?: number;
}) {
  const W = 420, H = 170, L = 36, R = 8, T = 10, B = 24;
  const h = target.length;
  const max = Math.max(cap * 1.05, ...target, ...actual.map((v) => v ?? 0), ...(typical ?? []).map((v) => v ?? 0), 1);
  const x = (n: number) => L + ((h - 1 - n) / (h - 1)) * (W - L - R);   // days before departure, far left to the day on the right
  const y = (v: number) => T + (1 - v / max) * (H - T - B);
  const path = (vals: (number | null)[]) => {
    let d = '', pen = false;
    for (let n = h - 1; n >= 0; n--) {
      const v = vals[n];
      if (v == null) { pen = false; continue; }
      d += `${pen ? 'L' : 'M'}${x(n).toFixed(1)},${y(v).toFixed(1)}`; pen = true;
    }
    return d;
  };
  return (
    <svg viewBox={`0 0 ${W} ${H}`} width="100%" role="img" aria-label="Bookings by days before departure">
      <line x1={L} x2={W - R} y1={y(cap)} y2={y(cap)} stroke="var(--line-strong)" strokeDasharray="2 3" />
      <text x={L + 2} y={y(cap) - 4} fontSize="10" fill="var(--muted)">seats</text>
      {[0, 0.5, 1].map((f) => <text key={f} x={L - 6} y={y(f * max) + 4} textAnchor="end" fontSize="10" fill="var(--muted)">{num(2 * f * max)}</text>)}
      {now != null && now > 0 && now < h && <rect x={x(now - 1)} y={T} width={W - R - x(now - 1)} height={H - T - B} fill="var(--bg)" />}
      <path d={path(target)} fill="none" stroke="var(--faint)" strokeWidth="2" strokeDasharray="5 4" />
      {typical && <path d={path(typical)} fill="none" stroke="#7A3FD1" strokeWidth="1.5" opacity="0.7" />}
      <path d={path(actual)} fill="none" stroke="var(--accent)" strokeWidth="2.5" strokeLinejoin="round" />
      <text x={L} y={H - 6} fontSize="11" fill="var(--muted)">{h - 1} days before</text>
      <text x={W - R} y={H - 6} textAnchor="end" fontSize="11" fill="var(--muted)">the day</text>
    </svg>
  );
}

// ---------- Fares and how they sell ----------

function FaresTab({ rm, base, baseB, m, routeId }: { rm: RouteRm; base: number; baseB: number | null; m: Market; routeId: string }) {
  const { ref, airline } = useGame();
  const { run, busy } = useAction();
  const wi = useWhatIf(routeId);
  const [e, setE] = useState<Partial<RouteRm>>({});
  const [lvl, setLvl] = useState<{ cabin: 'e' | 'b'; i: number } | null>(null);
  const [baseE, setBaseE] = useState<number | null>(null);
  const v: RouteRm = { ...rm, ...e };
  const set = (x: Partial<RouteRm>) => setE((o) => ({ ...o, ...x }));
  const dirty = Object.keys(e).length > 0;
  const be = baseE ?? base, bb = baseB ?? Math.round(m.ref_fare * (ref.param.biz_fare_mult ?? 3.5));
  const h = ref.param.rm_horizon ?? 42, obMax = ref.param.rm_ob_max ?? 0.15;
  const minF = Math.ceil(m.ref_fare * ref.param.fare_min_mult), maxF = Math.floor(m.ref_fare * ref.param.fare_max_mult);
  const flexRs = v.flex != null ? Math.round(v.flex * m.ref_fare) : null;

  return (
    <div className="split">
      <div className="stack-lg">
        <div className="card stack">
          <div className="card-title" style={{ marginBottom: 0 }}><h2>How this route sells</h2></div>
          <Seg block value={v.mode} onChange={(x) => set({ mode: x as RmMode })}
            options={(['curve', 'optimise', 'manual'] as RmMode[]).map((x) => ({ value: x, label: MODE_LABEL[x] }))} />
          <p className="small">{MODE_HELP[v.mode]}</p>
          <div className="field">
            <label>Target load at departure</label>
            <Stepper label="target load" value={Math.round(v.target_lf * 100)} step={1} min={50} max={110} onChange={(x) => set({ target_lf: x / 100 })} format={(x) => `${x}% full`} />
            {v.mode !== 'curve' && <div className="hint">Used for the target curve on the calendar.</div>}
          </div>
          {v.mode === 'curve' && (
            <div className="field">
              <label>How fast it reacts</label>
              <Seg value={String(v.pace)} onChange={(x) => set({ pace: +x })}
                options={[{ value: '1', label: 'Calm' }, { value: '2', label: 'Brisk' }, { value: '3', label: 'Jumpy' }]} />
              <div className="hint">Fare levels moved a day when a flight is off its curve. Jumpy reacts fast but swings fares around on small changes.</div>
            </div>
          )}
          {v.mode === 'optimise' && (
            <div className="field">
              <label>Forecast</label>
              <Stepper label="forecast" value={Math.round(v.outlook * 100)} step={5} min={70} max={130} onChange={(x) => set({ outlook: x / 100 })}
                format={(x) => x === 100 ? 'As expected' : x > 100 ? `Hopeful, +${x - 100}%` : `Cautious, ${x - 100}%`} />
              <div className="hint">A hopeful forecast holds out for dearer fares; a cautious one fills seats sooner.</div>
            </div>
          )}
          <div className="field">
            <label>Overbooking</label>
            <Stepper label="overbooking" value={Math.round(v.overbook * 100)} step={1} min={0} max={Math.round(obMax * 100)} onChange={(x) => set({ overbook: x / 100 })}
              format={(x) => x === 0 ? 'None' : `Sell ${x}% more seats than you have`} />
            <div className="hint">Some passengers never turn up (business travellers most). Overbooking fills their seats; when too many turn up, those left behind get their fare back plus twice the fare, at most ₹{num(ref.param.rm_deny_cap_inr ?? 10000)}, and your brand suffers.</div>
          </div>
        </div>

        <div className="card stack">
          <div className="card-title" style={{ marginBottom: 0 }}><h2>Economy fare levels</h2><span className="small muted">reference {inr(m.ref_fare)}</span></div>
          <div className="field">
            <label>Base fare · every level is a multiple of it</label>
            <Stepper label="base fare" value={be} step={100} min={minF} max={maxF} onChange={setBaseE} format={(x) => `${inr(x)} · ${(x / m.ref_fare).toFixed(2)}× reference`} />
          </div>
          <table className="table">
            <thead><tr><th>Level</th><th className="r">Fare</th><th className="r">Sells until</th>{v.mode === 'manual' && <th className="r">Seats</th>}</tr></thead>
            <tbody>
              {v.e_mult.map((mu, i) => (
                <tr key={i} className="link" onClick={() => setLvl({ cabin: 'e', i })}>
                  <td>{i + 1}</td><td className="r">{inr(levelFare(be, mu))}</td>
                  <td className="r">{v.e_close[i] === 0 ? 'the day' : `${v.e_close[i]} days before`}</td>
                  {v.mode === 'manual' && <td className="r">{i === 5 ? 'all' : `up to ${pct(v.e_limit[i])}`}</td>}
                </tr>
              ))}
            </tbody>
          </table>
          <p className="tiny muted">Travellers see the cheapest level still on sale. A level stops selling its set number of days before the flight{v.mode === 'manual' ? ', or once its share of seats is sold (counting the cheaper levels)' : ''}. Business travellers book late, so late fares are where they pay more. Tap a level to change it.</p>
          {baseE != null && baseE !== base && (
            <Button block busy={busy === 'base'} onClick={() => run('base', () => call('set_fares', { p_airline: airline.id, p_route: routeId, p_fare_econ: baseE, p_fare_biz: baseB }),
              'Base fare saved. Every level moves with it from the next game day.').then((r) => r !== undefined && setBaseE(null))}>Save base fare</Button>
          )}
        </div>

        <div className="card stack">
          <div className="card-title" style={{ marginBottom: 0 }}><h2>Flexi</h2>
            <Seg value={v.flex == null ? 'no' : 'yes'} onChange={(x) => set({ flex: x === 'no' ? null : rm.flex ?? (ref.param.rm_flex_default ?? 0.15) })}
              options={[{ value: 'yes', label: 'Sell' }, { value: 'no', label: 'Saver only' }]} /></div>
          {v.flex != null && flexRs != null && (
            <Stepper label="Flexi price" value={flexRs} step={50} min={Math.ceil(0.02 * m.ref_fare)} max={m.ref_fare} onChange={(x) => set({ flex: x / m.ref_fare })}
              format={(x) => `${inr(x)} more than Saver`} />
          )}
          <p className="small">A Flexi ticket can be changed and refunded. Business travellers value that at about {inr((ref.param.rm_flex_val_biz ?? 0.25) * m.ref_fare)} on this route, leisure travellers at {inr((ref.param.rm_flex_val_lei ?? 0.04) * m.ref_fare)}: priced between the two, it charges business travellers more without asking who they are. Flexi passengers miss more flights and get their fare back.</p>
        </div>

        {baseB != null && (
          <div className="card stack">
            <div className="card-title" style={{ marginBottom: 0 }}><h2>Business cabin levels</h2><span className="small muted">base {inr(bb)}</span></div>
            <table className="table">
              <thead><tr><th>Level</th><th className="r">Fare</th><th className="r">Sells until</th>{v.mode === 'manual' && <th className="r">Seats</th>}</tr></thead>
              <tbody>
                {v.b_mult.map((mu, i) => (
                  <tr key={i} className="link" onClick={() => setLvl({ cabin: 'b', i })}>
                    <td>{i + 1}</td><td className="r">{inr(levelFare(bb, mu))}</td>
                    <td className="r">{v.b_close[i] === 0 ? 'the day' : `${v.b_close[i]} days before`}</td>
                    {v.mode === 'manual' && <td className="r">{i === 2 ? 'all' : `up to ${pct(v.b_limit[i])}`}</td>}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <div className="stack-lg sticky-col">
        <div className="card stack">
          <div className="card-title" style={{ marginBottom: 0 }}><h2>Price and demand</h2></div>
          {wi.isLoading ? <Loading h={150} /> : (wi.data?.length ?? 0) < 3 ? <p className="small muted">Shown once flights are on sale.</p> : <WhatIfChart rows={wi.data!} now={base} />}
        </div>
        <Button block disabled={!dirty} busy={busy === 'rm'} onClick={() => run('rm', () => call('set_rm', { p_airline: airline.id, p_route: routeId, p_settings: e }),
          'Saved. It counts from the next game day.').then((r) => r !== undefined && setE({}))}>Save how this route sells</Button>
        <Button kind="ghost" block busy={busy === 'all'} onClick={() => run('all', () => call<number>('set_rm', {
          p_airline: airline.id, p_route: null,
          p_settings: { mode: v.mode, target_lf: v.target_lf, pace: v.pace, outlook: v.outlook, overbook: v.overbook, flex: v.flex },
        }), 'The way of selling, target, overbooking and Flexi now apply to all your routes')}>Use these settings on all my routes</Button>
        <p className="tiny muted">"All my routes" copies the way of selling, target load, overbooking and Flexi, not the fare levels.</p>
      </div>

      {lvl && <LevelSheet cabin={lvl.cabin} i={lvl.i} v={v} base={lvl.cabin === 'e' ? be : bb} h={h} onClose={() => setLvl(null)} onChange={set} />}
    </div>
  );
}

function LevelSheet({ cabin, i, v, base, h, onClose, onChange }: {
  cabin: 'e' | 'b'; i: number; v: RouteRm; base: number; h: number; onClose: () => void; onChange: (x: Partial<RouteRm>) => void;
}) {
  const mult = cabin === 'e' ? v.e_mult : v.b_mult, close = cabin === 'e' ? v.e_close : v.b_close, limit = cabin === 'e' ? v.e_limit : v.b_limit;
  const top = mult.length - 1;
  const lo = i > 0 ? mult[i - 1] * base + 10 : 0.3 * base, hi = i < top ? mult[i + 1] * base - 10 : 4 * base;
  const upd = (k: 'mult' | 'close' | 'limit', val: number) => {
    const arr = [...(k === 'mult' ? mult : k === 'close' ? close : limit)];
    arr[i] = val;
    onChange(cabin === 'e' ? { [`e_${k}`]: arr } as Partial<RouteRm> : { [`b_${k}`]: arr } as Partial<RouteRm>);
  };
  return (
    <Sheet title={`${cabin === 'e' ? 'Economy' : 'Business'} level ${i + 1}`} onClose={onClose}>
      <div className="stack">
        <div className="field">
          <label>Fare</label>
          <Stepper label="fare" value={levelFare(base, mult[i])} step={50} min={Math.ceil(lo / 10) * 10} max={Math.floor(hi / 10) * 10}
            onChange={(x) => upd('mult', Math.round((x / base) * 1000) / 1000)} format={(x) => `${inr(x)} · ${(x / base).toFixed(2)}× base`} />
          <div className="hint">Between level {i} and level {i + 2}{i === top ? ' (the dearest)' : ''}.</div>
        </div>
        {i < top && (
          <div className="field">
            <label>Sells until</label>
            <Stepper label="days before" value={close[i]} min={i < top ? close[i + 1] : 0} max={i > 0 ? close[i - 1] : h} onChange={(x) => upd('close', x)}
              format={(x) => x === 0 ? 'The day of the flight' : `${x} days before the flight`} />
            <div className="hint">Cheaper levels must stop selling no later than dearer ones.</div>
          </div>
        )}
        {v.mode === 'manual' && i < top && (
          <div className="field">
            <label>Seats it may sell, with the cheaper levels</label>
            <Stepper label="seat share" value={Math.round(limit[i] * 100)} min={i > 0 ? Math.round(limit[i - 1] * 100) : 0} max={100} onChange={(x) => upd('limit', x / 100)}
              format={(x) => `Up to ${x}% of seats`} />
          </div>
        )}
        <Button block onClick={onClose}>Done</Button>
        <p className="tiny muted">Changes are saved with "Save how this route sells".</p>
      </div>
    </Sheet>
  );
}

function WhatIfChart({ rows, now }: { rows: { fare: number; demand: number; pax: number; revenue: number }[]; now: number }) {
  const W = 420, H = 170, L = 8, R = 8, T = 16, B = 30;
  const maxR = Math.max(...rows.map((r) => Number(r.revenue)), 1);
  const best = rows.reduce((a, r) => (Number(r.revenue) > Number(a.revenue) ? r : a), rows[0]);
  const bw = (W - L - R) / rows.length;
  const cur = rows.reduce((a, r) => (Math.abs(r.fare - now) < Math.abs(a.fare - now) ? r : a), rows[0]);
  const capped = rows.filter((r) => Number(r.pax) < Number(r.demand) - 0.5);
  return (
    <div className="stack" style={{ gap: 6 }}>
      <svg viewBox={`0 0 ${W} ${H}`} width="100%" role="img" aria-label="Revenue a flight at each fare">
        {rows.map((r, i) => {
          const h = (Number(r.revenue) / maxR) * (H - T - B);
          return (
            <g key={r.fare}>
              <rect x={L + i * bw + bw * 0.12} width={bw * 0.76} y={H - B - h} height={Math.max(1, h)} rx="2"
                fill={r === best ? 'var(--accent)' : r === cur ? 'var(--accent-strong)' : 'var(--accent-soft)'} />
              {(i % 3 === 0 || r === best) && <text x={L + i * bw + bw / 2} y={H - B + 14} textAnchor="middle" fontSize="10" fill="var(--muted)">{kRs(r.fare)}</text>}
            </g>
          );
        })}
        <text x={L} y={11} fontSize="10" fill="var(--muted)">Revenue a flight, economy, by base fare</text>
      </svg>
      <p className="small">At a base fare of about {inr(best.fare)} an average flight on sale would earn most, {inr(Number(best.revenue))} each way, carrying {num(Number(best.pax))} of the {num(Number(best.demand))} who would want to fly{capped.length ? '; cheaper than that, there are more travellers than seats' : ''}. At your base fare of {inr(now)}: {inr(Number(cur.revenue))}.</p>
      <p className="tiny muted">If you sold the whole six weeks at one fare, against rivals' fares on sale now. Raising the fare loses travellers: how many depends on who flies the route (business travellers mind price least).</p>
    </div>
  );
}

// ---------- Results ----------

function ResultsTab({ rm, routeId, m }: { rm: RouteRm; routeId: string; m: Market }) {
  const log = useDepartureLog(routeId, 28);
  const st = useMemo(() => rmStats(log.data ?? []), [log.data]);
  if (log.isLoading) return <Loading h={200} />;
  if (st.n === 0) return <Empty title="No flights yet">Results appear the day after the first flight.</Empty>;
  const days = st.n;
  const perDay = (x: number) => (2 * x) / days;
  const tips = advice(st, rm);
  const totE = sum(st.byLevel);
  return (
    <div className="split">
      <div className="stack-lg">
        <div className="grid4-d">
          <Kpi label="Average fare" value={inr(st.fare)} note={st.fare ? `${(st.fare / m.ref_fare).toFixed(2)}× reference` : ''} />
          <Kpi label="Load" value={st.lf != null ? pct(st.lf) : '–'} note={`aiming for ${pct(rm.target_lf)}`} tone={st.lf != null && Math.abs(st.lf - rm.target_lf) < 0.05 ? 'good' : undefined} />
          <Kpi label="Turned away a day" value={num(perDay(st.turned))} note="wanted a seat on a sold-out flight (spill)" />
          <Kpi label="Empty seats a day" value={num(perDay(st.cap - st.pax))} note="flew empty (spoilage)" />
          <Kpi label="No-shows a day" value={num(perDay(st.noshow))} note="Saver fares kept, Flexi refunded" />
          <Kpi label="Could not board a day" value={num(perDay(st.denied))}
            note={<>{st.comp ? `${inr((2 * st.comp) / days)} a day in compensation` : 'overbooked flights: none'}{st.cancelled > 0.5 ? `; and ${num(perDay(st.cancelled))} a day refunded when a flight was cancelled` : ''}</>}
            tone={st.denied > 0.005 * st.pax ? 'bad' : undefined} />
        </div>
        {tips.length > 0 && (
          <div className="card info small stack" style={{ gap: 6 }}>
            <strong>What the numbers say</strong>
            {tips.map((t) => <span key={t}>{t}</span>)}
          </div>
        )}
      </div>
      <div className="stack-lg">
        <div className="card stack">
          <div className="card-title" style={{ marginBottom: 0 }}><h2>Economy seats by fare level</h2><span className="small muted">last {days} days</span></div>
          {st.byLevel.map((v, i) => (
            <div key={i} className="row" style={{ gap: 8 }}>
              <span className="small" style={{ width: 54 }}>Level {i + 1}</span>
              <div className="grow" style={{ background: 'var(--bg)', borderRadius: 6, height: 12 }}>
                <div style={{ width: `${totE ? (100 * v) / totE : 0}%`, background: 'var(--accent)', height: 12, borderRadius: 6 }} />
              </div>
              <span className="small r" style={{ width: 44 }}>{totE ? pct(v / totE) : '–'}</span>
            </div>
          ))}
        </div>
        <div className="card flush">
          <table className="table">
            <thead><tr><th>Who flew</th><th className="r">Saver</th><th className="r">Flexi</th></tr></thead>
            <tbody>
              {TYPES.map((t, i) => <tr key={t}><td>{t}</td><td className="r">{num(perDay(st.sav[i]))}</td><td className="r">{num(perDay(st.flx[i]))}</td></tr>)}
              {st.bkb > 0 && <tr><td>Business cabin</td><td className="r" colSpan={2}>{num(perDay(st.bkb))}</td></tr>}
            </tbody>
          </table>
          <p className="tiny muted" style={{ padding: '0 16px 14px' }}>Booked a day, both ways. You cannot ask a traveller why they fly; the fares they choose and when they book tell you.</p>
        </div>
      </div>
    </div>
  );
}

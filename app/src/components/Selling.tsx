// Selling ahead (migration 0019): how a route sells (its strategy), its seats on sale for the next 26 weeks, and what
// rivals did on its market. The engine sets every fare from the strategy; players choose the strategy only.
import { useMemo, useState } from 'react';
import { call } from '../lib/api';
import { useGame, useMarketsFrom, useMarketWatch, useRivals, useRoutePlans, useRoutes, useRouteWeeks, useSectorInsights, useStrategies, useWorldAirlines } from '../lib/data';
import { clock, pairKey } from '../lib/game';
import { BAND_LABEL, bandOf, practice, practiceInput, routeIndex, SHAPE_LABEL, shapeOf, verdict } from '../lib/insights';
import { currentWeek, inr, num, pct, realTime, weekLabel } from '../lib/format';
import type { MarketMove, Route, RouteWeek, StrategyKey } from '../lib/types';
import { useAction } from './toast';
import { Badge, Button, Loading } from './ui';

const sold = (w: RouteWeek) => w.bk_be + w.bk_l + w.bk_u + w.bk_b;
const seats = (w: RouteWeek) => w.seats_e + w.seats_b;

export function marketShape(n: number) {
  return n <= 1 ? 'Monopoly' : n === 2 ? 'Duopoly' : n <= 4 ? 'Oligopoly' : 'Crowded';
}

/** The route's strategy, the fares it gives now, and a line on no-shows here. */
export function StrategyCard({ route }: { route: Route }) {
  const { world, airline, ref } = useGame();
  const net = useRoutes();
  const markets = useMarketsFrom([route.origin, route.dest]);
  const rivals = useRivals([route.origin, route.dest]);
  const plans = useRoutePlans();
  const strategies = useStrategies();
  const weeks = useRouteWeeks(route.id);
  const { run, busy } = useAction();
  const [pick, setPick] = useState<StrategyKey | null>(null);
  const now = plans.data?.[route.id] ?? 'balanced';
  const chosen = pick ?? now;
  const wk = currentWeek(world);
  const on = (weeks.data ?? []).filter((w) => w.flown_e == null && w.week >= wk);
  const at = (n: number) => on.find((w) => w.week === wk + n)?.price_e;
  const flown = (weeks.data ?? []).filter((w) => w.flown_e != null);
  const booked = flown.reduce((s, w) => s + sold(w), 0);
  const noShows = flown.reduce((s, w) => s + (w.noshow ?? 0), 0);
  const denied = flown.reduce((s, w) => s + (w.denied ?? 0), 0);
  // what each way of selling would do on this route now: one practice flight week against today's rivals
  const m = markets.data?.[pairKey(route.origin, route.dest)];
  const expect = useMemo(() => {
    if (!m || !strategies.data || !rivals.data) return null;
    const input = practiceInput(m, rivals.data[pairKey(route.origin, route.dest)] ?? [], airline.id, world.demand_scale, world.game_day + 1, ref.param, 1, world.fare_index ?? 1);
    return Object.fromEntries(strategies.data.map((s) => [s.key, practice(s, input)]));
  }, [m, strategies.data, rivals.data, route.origin, route.dest, airline.id, world.demand_scale, world.game_day, ref.param]);
  const others = (net.data?.routes ?? []).filter((r) => r.id !== route.id && (plans.data?.[r.id] ?? 'balanced') !== chosen);
  const chosenName = strategies.data?.find((s) => s.key === chosen)?.name ?? chosen;
  const next = clock(world).nextInSec;
  const soon = next != null ? `, in about ${realTime(next)}` : '';
  return (
    <div className="card stack">
      <div className="card-title" style={{ marginBottom: 0 }}><h2>How it sells</h2></div>
      {!strategies.data || !plans.data ? <Loading h={80} /> : (
        <div className="choices" role="radiogroup" aria-label="How this route sells">
          {strategies.data.map((s) => (
            <button key={s.key} type="button" role="radio" aria-label={s.name} aria-checked={chosen === s.key} className={`choice${chosen === s.key ? ' on' : ''}`} onClick={() => setPick(s.key)}>
              <div className="t">{s.name}{now === s.key && <span className="tiny muted" style={{ fontWeight: 400 }}> · now</span>}</div>
              <div className="d">{s.blurb}</div>
            </button>
          ))}
        </div>
      )}
      {expect && strategies.data && (
        <div className="stack" style={{ gap: 4 }}>
          <div className="tiny muted">Expect on this route, for one flight week each way</div>
          <table className="table expect">
            <thead><tr><th>Way</th><th className="r">Seats sold</th><th className="r">Average fare</th><th className="r">Takings</th></tr></thead>
            <tbody>
              {strategies.data.map((s) => {
                const r = expect[s.key];
                return (
                  <tr key={s.key} className={chosen === s.key ? 'me' : ''}>
                    <td>{s.name}</td><td className="r num">{pct(r.load)}</td><td className="r num">{r.sold >= 1 ? inr(r.fare) : '–'}</td><td className="r num">{inr(r.revenue)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          <p className="tiny muted">A practice run against today's rivals and demand: economy only, no no-shows, no festivals. A guide, not a promise.</p>
        </div>
      )}
      <Button block disabled={chosen === now} busy={busy === 'plan'} onClick={() => run('plan', () => call('set_strategy', {
        p_airline: airline.id, p_route: route.id, p_strategy: chosen,
      }), `Saved. Fares switch to ${chosenName} when next week's selling starts${soon}.`).then(() => setPick(null))}>Sell this way</Button>
      {others.length > 0 && (
        <Button block kind="secondary" busy={busy === 'plan-all'} onClick={() => run('plan-all', async () => {
          for (const r of [...others, route]) await call('set_strategy', { p_airline: airline.id, p_route: r.id, p_strategy: chosen });
        }, `Saved. All your routes switch to ${chosenName} when next week's selling starts${soon}.`).then(() => setPick(null))}>Use {chosenName} on all my routes</Button>
      )}
      {on.length > 0 && (
        <div className="kv small">
          <span>Economy fare on sale for this week</span><span>{at(0) != null ? inr(at(0)!) : '–'}</span>
          <span>for 4 weeks ahead</span><span>{at(4) != null ? inr(at(4)!) : '–'}</span>
          <span>for 12 weeks ahead</span><span>{at(12) != null ? inr(at(12)!) : '–'}</span>
        </div>
      )}
      <p className="tiny muted">A change of strategy applies when the next week's selling starts: from then every flight still on sale is priced the new way. Tickets already sold keep their price. Fares move every week with how the flights sell and how close they are, and seats are sold a little beyond the cabin to cover passengers who do not turn up.</p>
      {booked > 0 && (
        <p className="tiny muted">On this route lately: {pct(noShows / booked, 1)} of bookings did not turn up{denied >= 0.5 ? `; ${num(Math.round(2 * denied))} could not board and were compensated or refunded` : ''}.</p>
      )}
    </div>
  );
}

/** How full each of the next 26 flight weeks already is. */
export function SeatsOnSale({ route }: { route: Route }) {
  const { world } = useGame();
  const weeks = useRouteWeeks(route.id);
  const wk = currentWeek(world);
  const [sel, setSel] = useState<number | null>(null);
  if (weeks.isLoading) return <div className="card"><Loading h={100} /></div>;
  const on = (weeks.data ?? []).filter((w) => w.flown_e == null && w.week >= wk).slice(0, 26);
  const firstWeek = Math.floor((route.first_flight_day - 1) / 7) + 1;
  const pick = on.find((w) => w.week === sel) ?? on[0];
  return (
    <div className="card stack">
      <div className="card-title" style={{ marginBottom: 0 }}><h2>Seats on sale</h2><span className="small muted">next 26 weeks</span></div>
      {on.length === 0 ? (
        <p className="small muted">Nothing on sale yet. Flights go on sale 26 weeks ahead once an aircraft is on the route{firstWeek > wk ? `; the first flight is in week ${firstWeek}` : ''}.</p>
      ) : (
        <>
          <div className="weeks-strip" aria-label="Share of seats sold for each flight week">
            {Array.from({ length: 26 }, (_, i) => wk + i).map((w) => {
              const x = on.find((y) => y.week === w);
              const f = x && seats(x) > 0 ? Math.min(1, sold(x) / seats(x)) : 0;
              return (
                <button key={w} type="button" className={`wk${f >= 0.98 ? ' full' : ''}${pick?.week === w ? ' sel' : ''}`} title={`Week ${w}: ${pct(f)} sold`}
                  onClick={() => x && setSel(w)} aria-label={`Week ${w}, ${pct(f)} sold`}>
                  <i style={{ height: `${Math.round(f * 100)}%` }} />
                </button>
              );
            })}
          </div>
          <div className="weeks-axis"><span>Week {wk}</span><span>Week {wk + 25}</span></div>
          {pick && (
            <div className="kv small">
              <span>{weekLabel(pick.week, world.start_date)}</span><span />
              <span>Sold, each way</span><span>{num(Math.round(sold(pick)))} of {num(seats(pick))} seats · {pct(seats(pick) ? sold(pick) / seats(pick) : 0)}</span>
              <span>Seats left</span><span>{num(Math.max(0, Math.round(seats(pick) - sold(pick))))}</span>
              <span>Sold in the latest week</span><span>{num(Math.round(pick.sold_wk))}</span>
              <span>Economy fare now</span><span>{pick.price_e != null ? inr(pick.price_e) : '–'}{pick.price_b != null ? ` · business ${inr(pick.price_b)}` : ''}</span>
            </div>
          )}
        </>
      )}
    </div>
  );
}

const moveText = (m: MarketMove) => {
  switch (m.kind) {
    case 'enter': return 'started flying here';
    case 'leave': return 'stopped flying here';
    case 'fare_up': return `raised fares, ${inr(m.old_value ?? 0)} → ${inr(m.new_value ?? 0)}`;
    case 'fare_down': return `cut fares, ${inr(m.old_value ?? 0)} → ${inr(m.new_value ?? 0)}`;
    case 'more_flights': return `added flights, ${num(m.old_value ?? 0)} → ${num(m.new_value ?? 0)} a week`;
    case 'fewer_flights': return `cut flights, ${num(m.old_value ?? 0)} → ${num(m.new_value ?? 0)} a week`;
  }
};

/** The market's shape and what rivals did lately, week by week. */
export function MarketMoves({ route, airlines }: { route: Route; airlines: number }) {
  const { airline } = useGame();
  const mw = useMarketWatch(route.origin, route.dest);
  const all = useWorldAirlines();
  const name = (id: string) => (id === airline.id ? 'You' : all.data?.find((a) => a.id === id)?.name ?? 'An airline');
  const moves = mw.data?.moves ?? [];
  return (
    <div style={{ padding: '0 16px 14px' }} className="stack">
      <div className="row" style={{ gap: 8 }}>
        <Badge tone={airlines <= 1 ? 'good' : airlines >= 5 ? 'warn' : 'info'}>{marketShape(airlines)}</Badge>
        <span className="small muted">{airlines <= 1 ? 'Nobody else flies it' : `${airlines} airlines fly it`}</span>
      </div>
      {moves.length > 0 && (
        <div className="stack" style={{ gap: 4 }}>
          <div className="tiny muted">Recent moves</div>
          {moves.slice(0, 8).map((m) => (
            <div key={m.id} className="small"><span className="faint num" style={{ display: 'inline-block', width: 52 }}>Wk {m.week}</span>{name(m.airline_id)} {moveText(m)}</div>
          ))}
        </div>
      )}
    </div>
  );
}

/** A cabin seen from above, one square a seat, six abreast: filled seats in the accent colour. */
function SeatMap({ seats, filled }: { seats: number; filled: number }) {
  const cap = 252;
  const n = Math.min(seats, cap);
  const f = seats > cap ? Math.round((filled / seats) * cap) : filled;
  const cells = [];
  let k = 0;
  for (let r = 0; r < Math.ceil(n / 6); r++) {
    for (let c = 0; c < 7; c++) {
      if (c === 3) { cells.push(<i key={`${r}-${c}`} className="aisle" />); continue; }
      const i = k++;
      cells.push(<i key={`${r}-${c}`} className={i >= n ? 'none' : i < f ? 'on' : ''} />);
    }
  }
  return <div className="seatmap" aria-hidden>{cells}</div>;
}

/** The last flown weeks in plain words: a typical flight of the latest week as a seat map with its story, then each week. */
export function LastFlights({ route }: { route: Route }) {
  const weeks = useRouteWeeks(route.id);
  const flown = (weeks.data ?? []).filter((w) => w.flown_e != null).sort((a, b) => b.week - a.week).slice(0, 6);
  if (!flown.length) return null;
  const w0 = flown[0];
  const v0 = verdict(w0);
  const tr = Math.max(1, w0.trips);
  const pf = { seats: Math.round(v0.seats / tr), flown: Math.round(v0.flown / tr), turned: Math.round(v0.turned / tr) };
  const empty = Math.max(0, pf.seats - pf.flown);
  const story = v0.kind === 'full'
    ? `Seats went cheap early, so about ${num(pf.turned)} travellers a flight found none left. Late travellers pay the most: higher fares earlier, such as Top fares, would have kept seats for them.`
    : v0.kind === 'empty'
      ? `Fares stayed high while the flights sold slowly, so about ${num(empty)} seats a flight flew empty. An empty seat earns nothing once the plane leaves: lower fares earlier, such as Fill every seat, would have filled some. So would fewer flights or a smaller aircraft.`
      : 'About right: few empty seats and few travellers turned away. A good flight sits between the two mistakes.';
  return (
    <div className="card stack">
      <div className="card-title" style={{ marginBottom: 0 }}><h2>Last flights</h2><span className="small muted">each way</span></div>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <span className="small strong">A typical flight in week {w0.week}</span>
        <Badge tone={v0.kind === 'full' ? 'warn' : v0.kind === 'empty' ? 'bad' : 'good'}>{v0.kind === 'full' ? 'Too full' : v0.kind === 'empty' ? 'Too empty' : 'About right'}</Badge>
      </div>
      <div className="row" style={{ gap: 16, alignItems: 'center' }}>
        <SeatMap seats={pf.seats} filled={pf.flown} />
        <div className="stack" style={{ gap: 8 }}>
          <div><div className="tiny muted">Seats filled</div><div className="kpi-s">{num(pf.flown)} of {num(pf.seats)}</div></div>
          <div><div className="tiny muted">Empty seats</div><div className="kpi-s">{num(empty)}</div></div>
          <div><div className="tiny muted">Turned away</div><div className="kpi-s">{num(pf.turned)}</div></div>
        </div>
      </div>
      <p className="small">{story}</p>
      <div className="tiny muted">Week by week</div>
      <div className="legend"><span><i style={{ background: 'var(--accent)' }} />flew</span><span><i style={{ background: 'var(--line-strong)' }} />seats empty</span><span><i style={{ background: 'var(--warn-ink)' }} />wanted a seat, none left</span></div>
      {flown.map((w) => {
        const v = verdict(w);
        const tot = Math.max(1, v.seats + v.turned);
        return (
          <div key={w.week} className="stack" style={{ gap: 4 }}>
            <div className="row" style={{ justifyContent: 'space-between' }}>
              <span className="small"><span className="faint num">Wk {w.week}</span> · {num(Math.round(v.flown))} flew of {num(v.seats)} seats</span>
              <Badge tone={v.kind === 'full' ? 'warn' : v.kind === 'empty' ? 'bad' : 'good'}>{v.kind === 'full' ? 'Too full' : v.kind === 'empty' ? 'Too empty' : 'About right'}</Badge>
            </div>
            <div className="fbar" aria-label={`${num(Math.round(v.flown))} flew, ${num(Math.round(v.empty))} seats empty, ${num(Math.round(v.turned))} turned away`}>
              <div className="f" style={{ width: `${(100 * v.flown) / tot}%` }} />
              <div className="e" style={{ width: `${(100 * v.empty) / tot}%` }} />
              <div className="t" style={{ width: `${(100 * v.turned) / tot}%` }} />
            </div>
          </div>
        );
      })}
    </div>
  );
}

/** How this route compares with routes like it in the world (What works where), by strategy. */
export function RouteAudit({ route, km, intl, refFare, airlines }: { route: Route; km: number; intl: boolean; refFare: number; airlines: number }) {
  const ins = useSectorInsights();
  const weeks = useRouteWeeks(route.id);
  const plans = useRoutePlans();
  const strategies = useStrategies();
  const band = bandOf({ km, intl });
  const shape = shapeOf(airlines);
  const cells = (ins.data ?? []).filter((x) => x.band === band && x.shape === shape).sort((a, b) => b.rev_index - a.rev_index);
  const mine = routeIndex((weeks.data ?? []).filter((w) => w.flown_e != null), refFare);
  const myStrat = plans.data?.[route.id] ?? 'balanced';
  const name = (k: string) => strategies.data?.find((s) => s.key === k)?.name ?? k;
  const best = cells[0];
  return (
    <div className="card stack">
      <div className="card-title" style={{ marginBottom: 0 }}><h2>How it compares</h2><span className="small muted">last 13 weeks</span></div>
      <p className="small muted">{BAND_LABEL[band]} routes where {shape === 'alone' ? 'one airline flies' : SHAPE_LABEL[shape].toLowerCase() + ' fly'}, across the world, by how they sell. Revenue per seat at this route's reference fare.</p>
      {cells.length === 0 ? <p className="small">Not enough routes like this yet: a way of selling shows once three routes use it.</p> : (
        <table className="table">
          <tbody>
            {cells.map((c) => (
              <tr key={c.strategy}>
                <td className={c === best ? 'cell-best' : ''}>{name(c.strategy)}<div className="tiny muted">{c.routes} routes</div></td>
                <td className="r">{inr(c.rev_index * refFare)} a seat</td>
                <td className="r muted">{pct(c.load)} full</td>
              </tr>
            ))}
            {mine && (
              <tr className="me"><td><strong>This route</strong><div className="tiny muted">{name(myStrat)}</div></td>
                <td className="r">{inr(mine.rev_index * refFare)} a seat</td><td className="r muted">{pct(mine.load)} full</td></tr>
            )}
          </tbody>
        </table>
      )}
      {best && mine && best.strategy !== myStrat && best.rev_index > mine.rev_index * 1.05 && (
        <p className="small">Routes like this earned {pct(best.rev_index / mine.rev_index - 1)} more per seat with {name(best.strategy)}. Worth a try.</p>
      )}
      <div className="row"><a className="small" href="#/insights">What works where</a><span className="faint">·</span><a className="small" href={`#/practice?route=${route.id}`}>Practise this route week by week</a></div>
    </div>
  );
}

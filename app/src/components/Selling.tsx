// Selling ahead (migration 0019): how a route sells (its strategy), its seats on sale for the next 26 weeks, and what
// rivals did on its market. The engine sets every fare from the strategy; players choose the strategy only.
import { useState } from 'react';
import { call } from '../lib/api';
import { useGame, useMarketWatch, useRoutePlans, useRouteWeeks, useStrategies, useWorldAirlines } from '../lib/data';
import { currentWeek, inr, num, pct, weekLabel } from '../lib/format';
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
  const { world, airline } = useGame();
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
      <Button block disabled={chosen === now} busy={busy === 'plan'} onClick={() => run('plan', () => call('set_strategy', {
        p_airline: airline.id, p_route: route.id, p_strategy: chosen,
      }), 'Saved. Fares follow it from this week.').then(() => setPick(null))}>Sell this way</Button>
      {on.length > 0 && (
        <div className="kv small">
          <span>Economy fare on sale for this week</span><span>{at(0) != null ? inr(at(0)!) : '–'}</span>
          <span>for 4 weeks ahead</span><span>{at(4) != null ? inr(at(4)!) : '–'}</span>
          <span>for 12 weeks ahead</span><span>{at(12) != null ? inr(at(12)!) : '–'}</span>
        </div>
      )}
      <p className="tiny muted">Fares move every week with how the flights are selling and how close they are. Seats are sold a little beyond the cabin to cover passengers who do not turn up.</p>
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
  const advance = 2 * on.reduce((s, w) => s + w.rev_e + w.rev_b, 0);
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
          <p className="tiny muted">Advance sales on this route: {inr(advance)}. The money is in your cash now; it counts as revenue when each flight flies.</p>
        </>
      )}
    </div>
  );
}

const moveText = (m: MarketMove) => {
  switch (m.kind) {
    case 'enter': return 'starts flying here';
    case 'leave': return 'stops flying here';
    case 'fare_up': return `raised fares, ${inr(m.old_value ?? 0)} → ${inr(m.new_value ?? 0)}`;
    case 'fare_down': return `cut fares, ${inr(m.old_value ?? 0)} → ${inr(m.new_value ?? 0)}`;
    case 'more_flights': return `adds flights, ${num(m.old_value ?? 0)} → ${num(m.new_value ?? 0)} a week`;
    case 'fewer_flights': return `cuts flights, ${num(m.old_value ?? 0)} → ${num(m.new_value ?? 0)} a week`;
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

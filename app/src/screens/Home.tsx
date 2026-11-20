// Home: what changed last week and the decisions waiting, each with a one-tap fix or a link to the screen that fixes it.
import { useState, type ReactNode } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { call, supabase } from '../lib/api';
import { useAirlineDaily, useAirlineRow, useAirlineWeeks, useBases, useDemandEvents, useFinance, useFleet, useGame, useMarketsFrom, useNews, usePilots, useRivals, useRouteDaily, useRoutePlans, useRoutes, useStrategies } from '../lib/data';
import { effectText, touches, upcomingEvents } from '../lib/events';
import { byWeek, routeStat, sumDaily } from '../lib/derive';
import { pairKey } from '../lib/game';
import { arrivalWeek, calDate, currentWeek, dateLabel, inr, num, pct, plural, weekLabel, weekOf, weeks } from '../lib/format';
import type { Route } from '../lib/types';
import { useOpsDecisions } from './Ops';
import { ProfitBars } from '../components/charts';
import { WorldClock } from '../components/Shell';
import { useAction } from '../components/toast';
import { Badge, Button, Icon, Kpi, Loading, Logo, Sheet } from '../components/ui';

interface Alert { key: string; tone: 'warn' | 'info' | 'bad'; title: string; body: ReactNode; to?: string; action?: { label: string; run: () => void; busy?: boolean } }

export function Home() {
  const { airline, world, ref } = useGame();
  const row = useAirlineRow().data ?? airline;
  const fin = useFinance();
  const fleet = useFleet();
  const net = useRoutes();
  const bases = useBases();
  const daily = useAirlineDaily(84);
  const aw = useAirlineWeeks();
  const advance = [...(aw.data ?? [])].sort((a, b) => b.week - a.week)[0]?.advance_inr ?? null;
  const rd = useRouteDaily();
  const news = useNews(12);
  const pilots = usePilots();
  const routes = net.data?.routes ?? [];
  const rots = net.data?.rotations ?? [];
  const endpoints = routes.flatMap((r) => [r.origin, r.dest]);
  const rivals = useRivals(endpoints);
  useMarketsFrom(bases.data?.map((b) => b.iata) ?? []);
  const { run, busy } = useAction();
  const nav = useNavigate();
  const [menu, setMenu] = useState(false);
  const opsDecisions = useOpsDecisions();

  const days = daily.data ?? [];
  const wk = byWeek(days);
  const week = sumDaily(days.filter((d) => d.game_day > world.game_day - 7));   // last week (time moves a week at a time)
  const from7 = world.game_day - 6;
  // the direction while it is still red: last week against the average week of the four before
  const before = sumDaily(days.filter((d) => d.game_day <= world.game_day - 7 && d.game_day > world.game_day - 35));
  const trend = week.days >= 7 && before.days >= 14 ? week.netProfit - before.netProfit / (before.days / 7) : null;
  const flyingIn = row.first_flight_day - (world.game_day + 1);                    // days until first flights; <= 0 when flying

  // ---------- Alerts ----------
  const alerts: Alert[] = [];
  const f = fin.data;
  if (f && f.insolvent_days > 0) {
    alerts.push({ key: 'insolvent', tone: 'bad', title: `Out of cash for ${f.insolvent_days} days`, to: '/money',
      body: `Cash is below zero and the credit line is used up. After ${weeks(ref.param.insolvency_days)} the airline goes into administration. Cut costs, return aircraft or sell differently.` });
  }
  if (world.pilots && pilots.data) {
    for (const fm of pilots.data.families) {
      const c = pilots.data.crews[fm.id];
      if (!c || c.need === 0) continue;
      const sc = c.need - c.captains, sf = c.need - c.fos;
      if (sc > 0 || sf > 0) {
        alerts.push({ key: `p${fm.id}`, tone: 'warn', to: '/fleet', title: `Short of ${fm.name} pilots`,
          body: `${[sc > 0 ? `${sc} captain${sc === 1 ? '' : 's'}` : '', sf > 0 ? `${sf} first officer${sf === 1 ? '' : 's'}` : ''].filter(Boolean).join(' and ')} short. Flights with nobody to fly them are cancelled until more join. Pilots are hired for you at market pay and join in 4 weeks.` });
      }
    }
  }
  const fl = fleet.data ?? [];
  const flying = new Set(rots.map((r) => r.aircraft_id));
  // An idle aircraft at the same base as a grounded one of its type covers that one's flights (spec 14.3).
  const covering = new Set<string>();
  for (const g of fl.filter((a) => a.status === 'grounded' && flying.has(a.id))) {
    const spare = fl.find((s) => s.id !== g.id && !covering.has(s.id) && s.type_id === g.type_id && s.base_iata === g.base_iata && s.status === 'active' && !flying.has(s.id));
    if (spare) covering.add(spare.id);
  }
  for (const ac of fl) {
    if (ac.status === 'grounded') {
      const spare = fl.find((s) => s.id !== ac.id && s.type_id === ac.type_id && s.base_iata === ac.base_iata && s.status === 'active' && !flying.has(s.id));
      alerts.push({ key: `g${ac.id}`, tone: spare ? 'info' : 'warn', to: `/aircraft/${ac.id}`,
        title: `${ac.reg} is grounded until week ${arrivalWeek(ac.available_day)}`,
        body: spare ? `${spare.reg} is idle at ${ac.base_iata} and covers its flights.` : 'Its flights are cancelled until then, which hurts punctuality and brand. An idle aircraft of the same type at the same base would cover them.' });
    } else if (ac.status === 'active' && !flying.has(ac.id) && !covering.has(ac.id)) {
      alerts.push(flyingIn > 0
        ? { key: `i${ac.id}`, tone: 'info', to: `/aircraft/${ac.id}`, title: `${ac.reg} has no route yet`,
            body: `Give it one before your first flights in week ${weekOf(row.first_flight_day)}. From then it costs ${ac.terms?.holding === 'wet' ? 'the wet-lease minimum' : 'rent'} every week, flying or not.` }
        : { key: `i${ac.id}`, tone: 'warn', to: `/aircraft/${ac.id}`, title: `${ac.reg} is not flying`,
            body: `It still costs ${ac.terms?.holding === 'wet' ? 'the wet-lease minimum' : 'rent'} every week. Give it a route.` });
    } else if (ac.status === 'delivering' && ac.available_day - world.game_day <= 14 && !flying.has(ac.id)) {
      alerts.push({ key: `d${ac.id}`, tone: 'info', to: `/aircraft/${ac.id}`, title: `${ac.reg} arrives in week ${arrivalWeek(ac.available_day)}`,
        body: 'Plan its routes now so it flies from the week it arrives.' });
    }
  }
  for (const r of routes) {
    const s = routeStat(rd.data ?? [], r.id, from7);
    const name = `${ref.airport[r.origin]?.city ?? r.origin}–${ref.airport[r.dest]?.city ?? r.dest}`;
    if (s.lf != null && s.lf >= 0.95 && s.days >= 2) {
      const fare = Math.round((r.fare_econ * 1.05) / 50) * 50;
      alerts.push({ key: `f${r.id}`, tone: 'warn', to: `/route/${r.id}`, title: `${name} is full`,
        body: `${pct(s.lf)} of seats sold last week and ${num(s.spill)} travellers turned away. ${world.selling ? 'Top fares would earn more from the same seats.' : 'A higher fare would earn more from the same seats.'}`,
        action: world.selling ? undefined : { label: `Raise fare 5% to ${inr(fare)}`, busy: busy === `f${r.id}`,
          run: () => run(`f${r.id}`, () => call('set_fares', { p_airline: airline.id, p_route: r.id, p_fare_econ: fare, p_fare_biz: r.fare_biz }), `Fare on ${name} is now ${inr(fare)} from this week`) } });
    } else if (s.lf != null && s.lf < 0.6 && s.days >= 3) {
      alerts.push({ key: `e${r.id}`, tone: 'warn', to: `/route/${r.id}`, title: `${name} is ${pct(s.lf)} full`,
        body: `Empty seats cost almost as much as full ones. Try ${world.selling ? 'Fill every seat' : 'a lower fare'}, fewer flights, or a smaller aircraft.` });
    }
    const theirs = (rivals.data?.[pairKey(r.origin, r.dest)] ?? []).filter((x) => x.route.airline_id !== airline.id && x.weekly > 0);
    const cheapest = theirs.sort((a, b) => a.route.fare_econ - b.route.fare_econ)[0];
    if (cheapest && cheapest.route.fare_econ < r.fare_econ * 0.9 && (s.lf ?? 1) < 0.8) {
      alerts.push({ key: `u${r.id}`, tone: 'info', to: `/route/${r.id}`, title: `${cheapest.airline?.name ?? 'A rival'} is cheaper on ${name}`,
        body: `${inr(cheapest.route.fare_econ)} against your ${inr(r.fare_econ)}. ${world.selling ? 'Follow the market matches rivals' : 'Match it'}, or hold if your flights are full enough.` });
    }
  }
  const wet = fl.filter((a) => a.terms?.holding === 'wet' && a.status === 'active');
  if (wet.length && world.game_day + 1 - row.first_flight_day > 28) {
    alerts.push({ key: 'wet', tone: 'info', to: '/market', title: `${wet.length === 1 ? wet[0].reg + ' is' : wet.length + ' aircraft are'} still on wet lease`,
      body: 'A wet lease costs about twice as much as an operating lease. Lease an aircraft from the pool and return the wet one when it arrives.' });
  }

  if (opsDecisions.length) {
    alerts.push({ key: 'ops', tone: 'info', to: '/ops', title: opsDecisions.length === 1 ? opsDecisions[0].title : `${opsDecisions.length} decisions in Ops`,
      body: opsDecisions.length === 1 ? 'A decision on how you run the airline. Open Ops to see what it changes in rupees.' : opsDecisions.map((d) => d.title).join(' · ') });
  }

  const started = routes.length > 0 && rots.length > 0 && days.some((d) => d.pax > 0);
  const loading = fleet.isLoading || net.isLoading || fin.isLoading;

  return (
    <div className="stack-lg">
      <div className="page-head" style={{ marginBottom: 0 }}>
        <Logo code={row.code} color={row.livery?.color} lg />
        <div className="grow">
          <h1>{row.name}</h1>
          <div className="sub">{weekLabel(currentWeek(world), world.start_date)}{row.status !== 'active' ? ' · in administration' : ''}</div>
        </div>
        <button className="back phone-only" aria-label="Menu" onClick={() => setMenu(true)}><Icon name="more" /></button>
      </div>

      <div className="grid4-d">
        <Kpi label="Cash" value={f ? inr(f.cash_inr) : '…'} note={[f && f.debt_inr > 0 ? `${inr(f.debt_inr)} borrowed` : 'No borrowing',
          world.selling && advance != null ? `advance sales ${inr(advance)}` : null].filter(Boolean).join(' · ')} />
        <Kpi label="Last week's profit" value={week.days ? inr(week.netProfit, { sign: true }) : '–'} tone={week.days ? (week.netProfit >= 0 ? 'good' : 'bad') : undefined}
          note={week.days ? (trend != null && Math.abs(trend) >= 5e5
            ? `${trend > 0 ? 'Up' : 'Down'} ${inr(Math.abs(trend))} on the 4 weeks before` : `${num(week.pax)} passengers`) : flyingIn > 0 ? `First flights in ${weeks(Math.ceil(flyingIn / 7) * 7)}` : 'No flights yet'} />
        <Kpi label="Seats sold, last week" value={week.ask > 0 ? pct(week.rpk / week.ask) : '–'} note="Healthy is 80 to 88%" />
        <Kpi label="On time · Brand" value={`${pct(row.otp)} · ${num(row.brand)}`} note="Brand drives demand" />
      </div>

      <div className="split">
        <div className="stack-lg">

          {flyingIn > 0 && <GetReady ffd={row.first_flight_day} weeksLeft={Math.ceil(flyingIn / 7)} />}
          {!started && flyingIn <= 0 && <GettingStarted hasRoute={routes.length > 0} hasRotation={rots.length > 0} />}

          <section className="stack">
            <h2>Needs your attention {alerts.length > 0 && <Badge tone="warn">{alerts.length}</Badge>}</h2>
            {loading ? <Loading h={90} /> : alerts.length === 0 ? (
              <div className="card small muted row"><Icon name="check" size={18} /> Nothing urgent. Check how your routes are selling.</div>
            ) : alerts.map((a) => (
              <div key={a.key} className={`card ${a.tone}`}>
                <div className="row" style={{ alignItems: 'flex-start' }}>
                  <div className="grow">
                    <h3>{a.title}</h3>
                    <p className="small" style={{ marginTop: 4 }}>{a.body}</p>
                  </div>
                </div>
                <div className="row wrap" style={{ marginTop: 10 }}>
                  {a.action && <Button size="sm" busy={a.action.busy} onClick={a.action.run}>{a.action.label}</Button>}
                  {a.to && <Button size="sm" kind="secondary" onClick={() => nav(a.to!)}>Open</Button>}
                </div>
              </div>
            ))}
          </section>
        </div>

        <div className="stack-lg">
          <ComingUp />
          <div className="card">
            <div className="card-title"><h2>Profit by week</h2><span className="small muted">after interest, last 12 weeks</span></div>
            {daily.isLoading ? <Loading /> : <ProfitBars points={wk.map((w) => ({ day: w.week, v: w.netProfit }))} />}
            {week.days > 0 && <p className="small muted" style={{ marginTop: 8 }}>Last week: {inr(week.revenue)} revenue, {inr(week.netProfit, { sign: true })} profit.</p>}
          </div>
          <div className="card flush">
            <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>News</h2><Link to="/ranks" className="small">Leaderboard</Link></div>
            <div className="list">
              {(news.data ?? []).slice(0, 8).map((n) => (
                <div key={n.id} className="item small" style={{ alignItems: 'flex-start' }}>
                  <span className="faint num" style={{ width: 58, flexShrink: 0 }}>Wk {weekOf(Math.max(n.game_day, 1))}</span>
                  <span className="grow">{n.body}</span>
                </div>
              ))}
              {news.data?.length === 0 && <div className="item small muted">No news yet.</div>}
            </div>
          </div>
        </div>
      </div>
      {menu && <MoreMenu onClose={() => setMenu(false)} />}
    </div>
  );
}

/** Before the first flights: what is ready and what still needs doing (the pre-launch checklist). */
function GetReady({ ffd, weeksLeft }: { ffd: number; weeksLeft: number }) {
  const { world, ref } = useGame();
  const net = useRoutes();
  const fleet = useFleet();
  const plans = useRoutePlans();
  const strategies = useStrategies();
  const pilots = usePilots();
  const nav = useNavigate();
  const routes = net.data?.routes ?? [];
  const rots = net.data?.rotations ?? [];
  const fl = (fleet.data ?? []).filter((a) => ['active', 'delivering', 'grounded', 'refit'].includes(a.status));
  const city = (i: string) => ref.airport[i]?.city ?? i;
  const rname = (r: Route) => `${city(r.origin)}–${city(r.dest)}`;
  const listOf = (xs: string[]) => (xs.length <= 3 ? xs.join(', ') : `${xs.slice(0, 3).join(', ')} and ${xs.length - 3} more`);
  const fw = weekOf(ffd);
  const items: { done: boolean; title: string; body: string; to: string }[] = [];

  const withAc = new Set(rots.map((r) => r.route_id));
  const bare = routes.filter((r) => !withAc.has(r.id));
  if (!routes.length) items.push({ done: false, title: 'No routes yet', to: '/network', body: 'Open a route from your base. It goes on sale at once, for flights up to 26 weeks ahead.' });
  else items.push({ done: bare.length === 0, to: '/network', title: `${plural(routes.length, 'route')} on sale`,
    body: bare.length ? `${listOf(bare.map(rname))} ${bare.length === 1 ? 'has' : 'have'} no aircraft yet, so nothing sells there.`
      : `${listOf(routes.map(rname))}: tickets sell for flights up to 26 weeks ahead.` });
  if (routes.length && plans.data && strategies.data) {
    const n: Record<string, number> = {};
    for (const r of routes) { const k = plans.data[r.id] ?? 'balanced'; n[k] = (n[k] ?? 0) + 1; }
    const used = strategies.data.filter((s) => n[s.key]);
    const mix = used.length === 1 ? `All on ${used[0].name}` : used.map((s) => `${s.name} on ${plural(n[s.key], 'route')}`).join(', ');
    items.push({ done: true, to: '/network', title: 'How they sell', body: `${mix}. Change it on each route's page.` });
  }
  const flying = new Set(rots.map((r) => r.aircraft_id));
  const issues: string[] = [];
  for (const a of fl) {
    if (a.status === 'grounded' && a.available_day > ffd)
      issues.push(`${a.reg} is grounded until week ${arrivalWeek(a.available_day)}: its flights before then are cancelled unless an idle aircraft of its type at ${a.base_iata} covers them.`);
    else if (a.available_day > ffd) issues.push(`${a.reg} arrives in week ${arrivalWeek(a.available_day)}, after your first flights.`);
    if (!flying.has(a.id)) issues.push(`${a.reg} has no route yet.`);
  }
  if (fl.length) items.push({ done: issues.length === 0, to: '/fleet', title: plural(fl.length, 'aircraft', 'aircraft'),
    body: issues.length ? issues.join(' ') : `All ready for week ${fw}, each with a route.` });
  if (world.pilots && pilots.data) {
    let sc = 0, sf = 0;
    for (const fm of pilots.data.families) {
      const c = pilots.data.crews[fm.id];
      if (!c || c.need === 0) continue;
      sc += Math.max(0, c.need - c.captains); sf += Math.max(0, c.need - c.fos);
    }
    items.push({ done: sc + sf === 0, to: '/fleet', title: 'Pilots',
      body: sc + sf === 0 ? 'A crew for every aircraft.' : `${[sc ? plural(sc, 'captain') : '', sf ? plural(sf, 'first officer') : ''].filter(Boolean).join(' and ')} short. They are hired for you at market pay and join in 4 weeks.` });
  }
  return (
    <div className="card info stack">
      <div>
        <h2>Pre-launch: {weeks(weeksLeft * 7)} to your first flights</h2>
        <p className="small" style={{ marginTop: 4 }}>Your first flights are on {dateLabel(ffd, world.start_date, true)}, week {fw}. Until then nothing flies and nothing is
          charged, but tickets already sell. Aircraft take weeks to arrive.</p>
      </div>
      <div className="checklist" aria-label="Get ready">
        {items.map((it) => (
          <button key={it.title} type="button" className={`check ${it.done ? 'done' : 'todo'}`} onClick={() => nav(it.to)}>
            <span className="m" aria-hidden>{it.done ? '✓' : '!'}</span>
            <span className="grow"><span className="t">{it.title}</span><span className="d">{it.body}</span></span>
          </button>
        ))}
      </div>
    </div>
  );
}

/** Festivals and events in the next 13 weeks, and how many of the player's routes each touches. */
function ComingUp() {
  const { world, ref } = useGame();
  const ev = useDemandEvents();
  const net = useRoutes();
  if (!ev.data?.length) return null;
  const day = world.game_day + 1;
  const list = upcomingEvents(ev.data, day, 13 * 7).slice(0, 5);
  const routes = net.data?.routes ?? [];
  return (
    <div className="card flush">
      <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>Coming up</h2><span className="small muted">next 13 weeks</span></div>
      <div className="list">
        {list.length === 0 && <div className="item small muted">No festivals or events in the next 13 weeks.</div>}
        {list.map(({ e, start, end }) => {
          const c = calDate(start, world.start_date);
          const mine = routes.filter((r) => touches(e, r.origin, r.dest, ref.airport)).length;
          return (
            <div key={`${e.id}-${start}`} className="item" style={{ alignItems: 'flex-start' }}>
              <div className="datebox"><span>{c.m}</span><b>{c.d}</b></div>
              <div className="grow">
                <div className="strong small">{e.name}{start <= day ? ' · now' : ''}</div>
                <div className="tiny muted">{dateLabel(start, world.start_date)} to {dateLabel(end, world.start_date)} · week {weekOf(start)}{end > start + 6 ? ` to ${weekOf(end)}` : ''}</div>
                <div className="small" style={{ marginTop: 2 }}>{e.note}</div>
                <div className="tiny muted">{effectText(e)}{mine ? ` · ${mine} of your routes` : ''}</div>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function GettingStarted({ hasRoute, hasRotation }: { hasRoute: boolean; hasRotation: boolean }) {
  const nav = useNavigate();
  const steps = [
    { done: hasRoute, t: 'Open your first route from your base', to: '/network' },
    { done: hasRotation, t: 'Put your aircraft on it: choose how many round trips a week', to: '/fleet' },
    { done: false, t: 'Come back after your first week of flying to see how full the flights were, then adjust how the route sells', to: '/network' },
  ];
  const next = steps.find((s) => !s.done)!;
  return (
    <div className="card accent stack">
      <div>
        <h2>Get flying</h2>
        <p className="small" style={{ marginTop: 4 }}>Three steps to your first passengers. Your wet-leased aircraft is yours from the start.</p>
      </div>
      <div className="steps">
        {steps.map((s, i) => (
          <div key={i} className={`step ${s.done ? 'done' : ''}`}>
            <div className="n">{s.done ? '✓' : i + 1}</div>
            <div className="t small" style={{ paddingTop: 3 }}>{s.t}</div>
          </div>
        ))}
      </div>
      <div><Button onClick={() => nav(next.to)}>{next === steps[0] ? 'Open a route' : next === steps[1] ? 'Go to fleet' : 'See my routes'}</Button></div>
    </div>
  );
}

function MoreMenu({ onClose }: { onClose: () => void }) {
  const { profile, myAirlines, airline, switchAirline } = useGame();
  const nav = useNavigate();
  const go = (to: string) => { onClose(); nav(to); };
  return (
    <Sheet title="More" onClose={onClose}>
      <div className="stack">
        <WorldClock />
        <div className="card flush">
          <div className="list">
            <div className="item link" onClick={() => go('/market')}><Icon name="market" /><span className="grow">Get aircraft</span><Icon name="right" /></div>
            <div className="item link" onClick={() => go('/ranks')}><Icon name="trophy" /><span className="grow">Leaderboard and news</span><Icon name="right" /></div>
            {profile?.is_admin && <div className="item link" onClick={() => go('/admin')}><Icon name="shield" /><span className="grow">Admin</span><Icon name="right" /></div>}
          </div>
        </div>
        {myAirlines.length > 0 && (
          <div className="field">
            <label>Airline</label>
            <select className="input" value={airline.id} onChange={(e) => { onClose(); switchAirline(e.target.value); }}>
              {myAirlines.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
              <option value="new">Join another world…</option>
            </select>
          </div>
        )}
        <p className="tiny muted">To use this like an app, add it to your home screen: in Safari tap Share, then Add to Home Screen.</p>
        <Button kind="secondary" block onClick={() => supabase.auth.signOut()}><Icon name="out" />Sign out</Button>
      </div>
    </Sheet>
  );
}

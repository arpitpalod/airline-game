// Home: what changed since yesterday and the decisions waiting, each with a one-tap fix or a link to the screen that fixes it.
import { useState, type ReactNode } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { call, supabase } from '../lib/api';
import { useAirlineDaily, useAirlineRow, useBases, useFinance, useFleet, useGame, useMarketsFrom, useNews, usePilots, useRivals, useRouteDaily, useRoutes } from '../lib/data';
import { dailyNetProfit, routeStat, sumDaily } from '../lib/derive';
import { pairKey } from '../lib/game';
import { dayLabel, inr, num, pct } from '../lib/format';
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
  const daily = useAirlineDaily(28);
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

  const days = daily.data ?? [];
  const last = days[days.length - 1];
  const yesterday = last ? sumDaily([last]) : null;
  const week = sumDaily(days.slice(-7));
  const from7 = world.game_day - 6;

  // ---------- Alerts ----------
  const alerts: Alert[] = [];
  const f = fin.data;
  if (f && f.insolvent_days > 0) {
    alerts.push({ key: 'insolvent', tone: 'bad', title: `Out of cash for ${f.insolvent_days} days`, to: '/money',
      body: `Cash is below zero and the credit line is used up. After ${ref.param.insolvency_days} days the airline goes into administration. Cut costs, return aircraft or raise fares.` });
  }
  if (world.pilots && pilots.data) {
    for (const fm of pilots.data.families) {
      const c = pilots.data.crews[fm.id];
      if (!c || c.need === 0) continue;
      const sc = c.need - c.captains, sf = c.need - c.fos;
      if (sc > 0 || sf > 0) {
        alerts.push({ key: `p${fm.id}`, tone: 'warn', to: '/pilots', title: `Short of ${fm.name} pilots`,
          body: `${[sc > 0 ? `${sc} captain${sc === 1 ? '' : 's'}` : '', sf > 0 ? `${sf} first officer${sf === 1 ? '' : 's'}` : ''].filter(Boolean).join(' and ')} short. Flights with nobody to fly them are cancelled until more join.` });
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
        title: `${ac.reg} is grounded until day ${ac.available_day}`,
        body: spare ? `${spare.reg} is idle at ${ac.base_iata} and covers its flights.` : 'Its flights are cancelled until then, which hurts punctuality and brand. An idle aircraft of the same type at the same base would cover them.' });
    } else if (ac.status === 'active' && !flying.has(ac.id) && !covering.has(ac.id)) {
      alerts.push({ key: `i${ac.id}`, tone: 'warn', to: `/aircraft/${ac.id}`, title: `${ac.reg} is not flying`,
        body: `It still costs ${ac.terms?.holding === 'wet' ? 'the wet-lease minimum' : 'rent'} every day. Give it a route.` });
    } else if (ac.status === 'delivering' && ac.available_day - world.game_day <= 14 && !flying.has(ac.id)) {
      alerts.push({ key: `d${ac.id}`, tone: 'info', to: `/aircraft/${ac.id}`, title: `${ac.reg} arrives on day ${ac.available_day}`,
        body: 'Plan its routes now so it flies from the day it arrives.' });
    }
  }
  for (const r of routes) {
    const s = routeStat(rd.data ?? [], r.id, from7);
    const name = `${ref.airport[r.origin]?.city ?? r.origin}–${ref.airport[r.dest]?.city ?? r.dest}`;
    if (s.lf != null && s.lf >= 0.95 && s.days >= 2) {
      const fare = Math.round((r.fare_econ * 1.05) / 50) * 50;
      alerts.push({ key: `f${r.id}`, tone: 'warn', to: `/route/${r.id}`, title: `${name} is full`,
        body: `${pct(s.lf)} of seats sold this week and ${num(s.spill)} travellers turned away. A higher fare would earn more from the same seats.`,
        action: { label: `Raise fare 5% to ${inr(fare)}`, busy: busy === `f${r.id}`,
          run: () => run(`f${r.id}`, () => call('set_fares', { p_airline: airline.id, p_route: r.id, p_fare_econ: fare, p_fare_biz: r.fare_biz }), `Fare on ${name} is now ${inr(fare)} from tomorrow`) } });
    } else if (s.lf != null && s.lf < 0.6 && s.days >= 3) {
      alerts.push({ key: `e${r.id}`, tone: 'warn', to: `/route/${r.id}`, title: `${name} is ${pct(s.lf)} full`,
        body: 'Empty seats cost almost as much as full ones. Try a lower fare, fewer flights, or a smaller aircraft.' });
    }
    const theirs = (rivals.data?.[pairKey(r.origin, r.dest)] ?? []).filter((x) => x.route.airline_id !== airline.id && x.weekly > 0);
    const cheapest = theirs.sort((a, b) => a.route.fare_econ - b.route.fare_econ)[0];
    if (cheapest && cheapest.route.fare_econ < r.fare_econ * 0.9 && (s.lf ?? 1) < 0.8) {
      alerts.push({ key: `u${r.id}`, tone: 'info', to: `/route/${r.id}`, title: `${cheapest.airline?.name ?? 'A rival'} is cheaper on ${name}`,
        body: `${inr(cheapest.route.fare_econ)} against your ${inr(r.fare_econ)}. Match it, or hold if your flights are full enough.` });
    }
  }
  const wet = fl.filter((a) => a.terms?.holding === 'wet' && a.status === 'active');
  if (wet.length && world.game_day > 30) {
    alerts.push({ key: 'wet', tone: 'info', to: '/market', title: `${wet.length === 1 ? wet[0].reg + ' is' : wet.length + ' aircraft are'} still on wet lease`,
      body: 'A wet lease costs about twice as much as an operating lease. Lease an aircraft from the pool and return the wet one when it arrives.' });
  }

  const started = routes.length > 0 && rots.length > 0 && days.some((d) => d.pax > 0);
  const loading = fleet.isLoading || net.isLoading || fin.isLoading;

  return (
    <div className="stack-lg">
      <div className="page-head" style={{ marginBottom: 0 }}>
        <Logo code={row.code} color={row.livery?.color} lg />
        <div className="grow">
          <h1>{row.name}</h1>
          <div className="sub">{dayLabel(Math.max(world.game_day, 1))}{row.status !== 'active' ? ' · in administration' : ''}</div>
        </div>
        <button className="back phone-only" aria-label="Menu" onClick={() => setMenu(true)}><Icon name="more" /></button>
      </div>

      <div className="grid4-d">
        <Kpi label="Cash" value={f ? inr(f.cash_inr) : '…'} note={f && f.debt_inr > 0 ? `${inr(f.debt_inr)} borrowed` : 'No borrowing'} />
        <Kpi label="Yesterday's profit" value={yesterday ? inr(dailyNetProfit(last!), { sign: true }) : '–'} tone={last ? (dailyNetProfit(last) >= 0 ? 'good' : 'bad') : undefined}
          note={yesterday ? `${num(yesterday.pax)} passengers` : 'No flights yet'} />
        <Kpi label="Seats sold, 7 days" value={week.ask > 0 ? pct(week.rpk / week.ask) : '–'} note="Healthy is 80 to 88%" />
        <Kpi label="On time · Brand" value={`${pct(row.otp)} · ${num(row.brand)}`} note="Brand drives demand" />
      </div>

      <div className="split">
        <div className="stack-lg">

          {!started && <GettingStarted hasRoute={routes.length > 0} hasRotation={rots.length > 0} />}

          <section className="stack">
            <h2>Needs your attention {alerts.length > 0 && <Badge tone="warn">{alerts.length}</Badge>}</h2>
            {loading ? <Loading h={90} /> : alerts.length === 0 ? (
              <div className="card small muted row"><Icon name="check" size={18} /> Nothing urgent. Check your routes for fares worth testing.</div>
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
          <div className="card">
            <div className="card-title"><h2>Profit by day</h2><span className="small muted">after interest, last 28 days</span></div>
            {daily.isLoading ? <Loading /> : <ProfitBars points={days.map((d) => ({ day: d.game_day, v: dailyNetProfit(d) }))} />}
            {week.days > 0 && <p className="small muted" style={{ marginTop: 8 }}>Last 7 days: {inr(week.revenue)} revenue, {inr(week.netProfit, { sign: true })} profit.</p>}
          </div>
          <div className="card flush">
            <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>News</h2><Link to="/ranks" className="small">Leaderboard</Link></div>
            <div className="list">
              {(news.data ?? []).slice(0, 8).map((n) => (
                <div key={n.id} className="item small" style={{ alignItems: 'flex-start' }}>
                  <span className="faint num" style={{ width: 52, flexShrink: 0 }}>Day {n.game_day}</span>
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

function GettingStarted({ hasRoute, hasRotation }: { hasRoute: boolean; hasRotation: boolean }) {
  const nav = useNavigate();
  const steps = [
    { done: hasRoute, t: 'Open your first route from your base', to: '/network' },
    { done: hasRotation, t: 'Put your aircraft on it: choose how many round trips a week', to: '/fleet' },
    { done: false, t: 'Come back after the next game day to see how full the flights were, then adjust the fare', to: '/network' },
  ];
  const next = steps.find((s) => !s.done)!;
  return (
    <div className="card accent stack">
      <div>
        <h2>Get flying</h2>
        <p className="small" style={{ marginTop: 4 }}>Three steps to your first passengers. Your wet-leased aircraft is ready.</p>
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
            <div className="item link" onClick={() => go('/pilots')}><Icon name="pilot" /><span className="grow">Pilots</span><Icon name="right" /></div>
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

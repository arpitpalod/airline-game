// Ops (migration 0023): what flying costs against the industry, the decisions worth a look this week, and the strategies
// for the whole fleet (fuel hedging, dollar hedging from 0026, maintenance, operating style). Every choice shows its cost or
// revenue before and after.
import { useMemo, useState, type ReactNode } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { call } from '../lib/api';
import { useAirlineDaily, useAirlineOps, useCostBenchmarks, useFleet, useGame, useMaintPlans, useOpStyles, useOpsPreview, useRoutes } from '../lib/data';
import { gameDate, inr, num, pct, plural, usd, weekOf } from '../lib/format';
import type { AirlineDaily, OpsPreview } from '../lib/types';
import { CrewCard } from '../components/PilotsCard';
import { useAction } from '../components/toast';
import { Badge, Button, Loading, PageHeader } from '../components/ui';

// ---------- cost lines ----------
const LINES: { key: string; name: string; color: string; lever: string; to?: string; usd?: boolean; of: (d: AirlineDaily) => number }[] = [
  { key: 'fuel', name: 'Fuel', color: '#0E7C70', lever: 'Fuel hedging · operating style', to: '/ops/fuel', of: (d) => d.c_fuel },
  { key: 'aircraft', name: 'Aircraft', color: '#4FA59A', lever: 'Lease or buy, in Get aircraft', to: '/market', usd: true, of: (d) => d.c_rent + d.c_depr },
  { key: 'maintenance', name: 'Maintenance', color: '#9AD0C7', lever: 'Maintenance strategy', to: '/ops/maintenance', usd: true, of: (d) => d.c_maint },
  { key: 'crew', name: 'Crew', color: '#1E5AA8', lever: 'Hired for you · operating style', to: '/ops/style', of: (d) => d.c_crew },
  { key: 'airports', name: 'Airports and slots', color: '#7FA7DD', lever: 'Set by your routes', to: '/network', of: (d) => d.c_airport + d.c_slots },
  { key: 'sales', name: 'Sales and service', color: '#F0A04B', lever: 'Extras and marketing', to: '/extras', of: (d) => d.c_dist + d.c_marketing },
  { key: 'office', name: 'Head office', color: '#98A2B3', lever: 'Fixed: spread over more seats as you grow', of: (d) => d.c_overhead },
];

const sum = (xs: AirlineDaily[], f: (d: AirlineDaily) => number) => xs.reduce((s, d) => s + f(d), 0);

/** 13 weeks of a bill (fuel, or dollar costs in rupees) under a hedged share h if prices move by s: the hedged part at
 *  today's price plus the premium. */
export const hedgeBill = (fuelWeek: number, h: number, s: number, premium: number) => 13 * fuelWeek * ((1 - h) * (1 + s) + h * (1 + premium));

export interface Decision { key: string; tone: 'warn' | 'info'; tag: string; title: string; body: ReactNode; to?: string; action?: { label: string; run: () => void; busy?: boolean }; alt?: string }

/** The few decisions worth a look this week: a fuel shock, a cheaper maintenance strategy, a run of groundings, schedules
 *  that no longer fit. Each comes with what it changes in rupees. */
export function useOpsDecisions(): Decision[] {
  const { world, airline, ref } = useGame();
  const pv = useOpsPreview();
  const plans = useMaintPlans();
  const styles = useOpStyles();
  const daily = useAirlineDaily(28);
  const { run, busy } = useAction();
  const p = pv.data;
  if (!p || !plans.data || !styles.data || world.status === 'ended') return [];
  const out: Decision[] = [];
  const step = Number(ref.param.hedge_step ?? 0.25), max = Number(ref.param.hedge_max ?? 0.75);
  const shock = world.fuel_walk ? world.fuel_inr_kg / world.fuel_walk - 1 : 0;
  const cur = p.styles.find((s) => s.key === p.style);
  if (shock >= 0.1 && p.hedge_share < max - 1e-9 && cur && cur.fuel_week > 0) {
    const next = Math.min(max, p.hedge_share + step);
    const b = (h: number, s: number) => inr(hedgeBill(cur.fuel_week, h, s, p.hedge_premium));
    out.push({ key: 'fuel', tone: 'warn', tag: 'Fuel', title: `Fuel is ${pct(shock)} above normal`,
      body: <>
        <p className="small">You hedge {pct(p.hedge_share)}. Hedging more now locks today's high price for 13 weeks, starting in 13 weeks: it pays if the shock lasts and costs if it ends.</p>
        <div className="kv small" style={{ marginTop: 6 }}>
          <span>13 weeks of fuel, if prices stay</span><span>{b(p.hedge_share, 0)} at {pct(p.hedge_share)} · {b(next, 0)} at {pct(next)}</span>
          <span>if they rise 20% more</span><span>{b(p.hedge_share, 0.2)} · {b(next, 0.2)}</span>
        </div>
      </>,
      action: { label: `Hedge ${pct(next)}`, busy: busy === 'd-hedge',
        run: () => run('d-hedge', () => call('set_hedge', { p_airline: airline.id, p_share: next }), `You now hedge ${pct(next)} of each week's fuel.`) },
      alt: `Keep ${pct(p.hedge_share)}` });
  }
  const now = p.plans.find((x) => x.key === p.plan);
  const better = p.plans.filter((x) => x.key !== p.plan && x.key !== 'lean' && now && x.cost_week < now.cost_week * 0.95
    && x.groundings_qtr <= now.groundings_qtr).sort((a, b) => a.cost_week - b.cost_week)[0];
  // 0026: the rupee well off Rs 90 and dollar costs to protect
  const fxRef = Number(p.usd?.ref ?? 90), weak = world.fx_inr_usd / fxRef - 1;
  const usdWeek = (p.usd?.week_usd ?? 0) * world.fx_inr_usd;
  if (p.usd && weak >= 0.05 && p.usd.share < p.usd.max - 1e-9 && usdWeek > 0) {
    const next = Math.min(p.usd.max, p.usd.share + p.usd.step);
    const b = (h: number, s: number) => inr(hedgeBill(usdWeek, h, s, p.usd.premium));
    out.push({ key: 'usd', tone: 'warn', tag: 'Currency', title: `The rupee is ${pct(weak)} weaker than ₹${fxRef}`,
      body: <>
        <p className="small">Your dollar costs (aircraft, maintenance, dollar loans) are about {inr(usdWeek)} a week, and you hedge {pct(p.usd.share)}. Hedging more locks today's rate for 13 weeks, starting in 13 weeks: it pays if the rupee weakens further and costs if it recovers.</p>
        <div className="kv small" style={{ marginTop: 6 }}>
          <span>13 weeks of dollars, if the rupee stays</span><span>{b(p.usd.share, 0)} at {pct(p.usd.share)} · {b(next, 0)} at {pct(next)}</span>
          <span>if it weakens 5% more</span><span>{b(p.usd.share, 0.05)} · {b(next, 0.05)}</span>
        </div>
      </>,
      action: { label: `Hedge ${pct(next)}`, busy: busy === 'd-usd',
        run: () => run('d-usd', () => call('set_usd_hedge', { p_airline: airline.id, p_share: next }), `You now hedge ${pct(next)} of each week's dollars.`) },
      alt: `Keep ${pct(p.usd.share)}` });
  }
  if (now && better && !p.plan_next && p.day >= p.locked_until) {
    const name = plans.data.find((x) => x.key === better.key)?.name ?? better.key;
    out.push({ key: 'maint', tone: 'info', tag: 'Maintenance', title: p.aircraft >= 40 && better.key === 'hangar' ? `Your fleet passed 40 aircraft` : `${name} would cost less`,
      body: <p className="small">{name} would cost about {inr(now.cost_week - better.cost_week)} a week less than {plans.data.find((x) => x.key === p.plan)?.name.toLowerCase()}
        {better.setup_inr > 0 ? `: ${inr(better.setup_inr)} to set up, open in ${better.setup_weeks} weeks` : ''}.</p>,
      to: '/ops/maintenance' });
  }
  const days = (daily.data ?? []).filter((d) => d.game_day > world.game_day - 28);
  const grounded = sum(days, (d) => d.groundings);
  const expected = (now?.groundings_qtr ?? 0) * (28 / 91);
  if (grounded >= 3 && grounded >= 1.5 * expected && p.plan !== 'contract') {
    out.push({ key: 'ground', tone: 'warn', tag: 'Maintenance', title: `${plural(grounded, 'grounding')} in 4 weeks`,
      body: <p className="small">More than your maintenance strategy should give. A flight-hour contract cuts groundings by 30%; an idle aircraft at the same base covers one.</p>,
      to: '/ops/maintenance' });
  }
  if (cur && cur.over > 0) {
    out.push({ key: 'over', tone: 'warn', tag: 'Operating style', title: `${plural(cur.over, 'aircraft', 'aircraft')} no longer fit their schedules`,
      body: <p className="small">With {styles.data.find((x) => x.key === p.style)?.name.toLowerCase()} turns they need more hours than they have, so they fly late. Trim their round trips, or change the style.</p>,
      to: '/fleet' });
  }
  return out;
}

export function Ops() {
  const { world, airline, ref } = useGame();
  const daily = useAirlineDaily(28);
  const bench = useCostBenchmarks();
  const ops = useAirlineOps();
  const plans = useMaintPlans();
  const styles = useOpStyles();
  const fleet = useFleet();
  const net = useRoutes();
  const decisions = useOpsDecisions();
  const [hidden, setHidden] = useState<string[]>([]);
  const nav = useNavigate();

  const days = (daily.data ?? []).filter((d) => d.game_day > world.game_day - 28);
  const ask = sum(days, (d) => d.ask);
  const mine = Object.fromEntries(LINES.map((l) => [l.key, ask > 0 ? sum(days, l.of) / ask : null]));
  const ind = Object.fromEntries((bench.data ?? []).map((b) => [b.line, Number(b.median_inr_ask)]));
  const total = ask > 0 ? LINES.reduce((s, l) => s + (mine[l.key] ?? 0), 0) : null;
  const indTotal = LINES.every((l) => ind[l.key] != null) ? LINES.reduce((s, l) => s + ind[l.key], 0) : null;
  const scale = Math.max(total ?? 0, indTotal ?? 0) || 1;
  const nAirlines = bench.data?.[0]?.airlines;

  const fl = fleet.data ?? [];
  const wet = fl.filter((a) => a.terms?.holding === 'wet').length;
  const flyingIds = new Set((net.data?.rotations ?? []).map((r) => r.aircraft_id));
  const lastWeek = days.filter((d) => d.game_day > world.game_day - 7);
  const hedgeWeek = sum(lastWeek, (d) => d.hedge_inr);
  const usdHedgeWeek = sum(lastWeek, (d) => d.usd_hedge_inr ?? 0);
  // 0026: the share of costs paid in dollars, and what the rupee's move against the reference rate added over 4 weeks
  const allCost = sum(days, (d) => LINES.reduce((s, l) => s + l.of(d), 0) + d.c_interest);
  const usdCost = sum(days, (d) => d.usd_cost_inr ?? 0);
  const fxEffect = sum(days, (d) => d.fx_effect_inr ?? 0);
  const qStart = (gameDate(world.game_day).quarter - 1) * 91 + (gameDate(world.game_day).year - 1) * 364;
  const groundQ = sum((daily.data ?? []).filter((d) => d.game_day > qStart), (d) => d.groundings);
  const o = ops.data;
  const planName = (k?: string | null) => plans.data?.find((x) => x.key === k)?.name ?? '–';
  const styleName = (k?: string | null) => styles.data?.find((x) => x.key === k)?.name ?? '–';
  const shown = decisions.filter((d) => !hidden.includes(d.key));

  return (
    <div className="stack-lg">
      <PageHeader title="Ops" sub={`${plural(fl.length, 'aircraft', 'aircraft')} · what flying costs, and how you run it`} />

      <section className="stack">
        <h2>Decisions this week {shown.length > 0 && <Badge tone="warn">{shown.length}</Badge>}</h2>
        {shown.length === 0 ? <div className="card small muted">Nothing needs a decision. Your strategies are below.</div> : shown.map((d) => (
          <div key={d.key} className={`card ${d.tone} stack`} style={{ gap: 6 }}>
            <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start' }}><h3>{d.title}</h3><Badge tone={d.tone}>{d.tag}</Badge></div>
            {d.body}
            <div className="row wrap">
              {d.action && <Button size="sm" busy={d.action.busy} onClick={d.action.run}>{d.action.label}</Button>}
              {d.alt && <Button size="sm" kind="secondary" onClick={() => setHidden([...hidden, d.key])}>{d.alt}</Button>}
              {d.to && <Button size="sm" kind="secondary" onClick={() => nav(d.to!)}>Open</Button>}
            </div>
          </div>
        ))}
      </section>

      <div className="split">
        <div className="stack-lg">
          <div className="card stack">
            <div className="card-title" style={{ marginBottom: 0 }}><h2>Cost per seat-km</h2><span className="small muted">last 4 weeks</span></div>
            {daily.isLoading ? <Loading h={120} /> : total == null ? (
              <p className="small muted">No flights yet. Once you fly, each cost line shows here against the industry.</p>
            ) : (
              <>
                <div className="row" style={{ gap: 20, alignItems: 'baseline' }}>
                  <div><div className="tiny muted">You</div><div className="kpi-s" style={{ fontSize: 24 }}>₹{total.toFixed(2)}</div></div>
                  {indTotal != null && <div><div className="tiny muted">Industry median</div><div className="kpi-s muted" style={{ fontSize: 24 }}>₹{indTotal.toFixed(2)}</div></div>}
                  {indTotal != null && <span className={`small strong ${total > indTotal ? 'bad-ink' : 'good'}`}>{pct(Math.abs(total / indTotal - 1))} {total > indTotal ? 'above' : 'below'}</span>}
                </div>
                <div className="cost-bars" aria-label="Cost per seat-km by line, you against the industry">
                  <span className="tiny muted">You</span>
                  <div className="cost-bar">{LINES.map((l) => <i key={l.key} style={{ width: `${(100 * (mine[l.key] ?? 0)) / scale}%`, background: l.color }} />)}</div>
                  {indTotal != null && <>
                    <span className="tiny muted">Industry</span>
                    <div className="cost-bar">{LINES.map((l) => <i key={l.key} style={{ width: `${(100 * (ind[l.key] ?? 0)) / scale}%`, background: l.color }} />)}</div>
                  </>}
                </div>
                <div className="list">
                  {LINES.map((l) => {
                    const v = mine[l.key] ?? 0, i = ind[l.key];
                    const d = i != null ? v - i : null;
                    const row = (
                      <>
                        <span className="swatch" style={{ background: l.color }} />
                        <span className="grow"><span className="strong small">{l.name}</span>{l.usd && <span className="usd-tag" title="Paid in dollars">$</span>}<span className="tiny muted" style={{ display: 'block' }}>{l.lever}</span></span>
                        <span className="small num">₹{v.toFixed(2)}</span>
                        <span className={`tiny strong num ${d == null ? 'muted' : d > 0.005 ? 'bad-ink' : 'good'}`} style={{ minWidth: 44, textAlign: 'right' }}>
                          {d == null ? '' : `${d > 0 ? '+' : d < 0 ? '−' : ''}${Math.abs(d).toFixed(2)}`}</span>
                      </>
                    );
                    return l.to ? <Link key={l.key} to={l.to} className="item link cost-line">{row}</Link> : <div key={l.key} className="item cost-line">{row}</div>;
                  })}
                </div>
                {usdCost > 0 && (
                  <Link to="/ops/dollars" className="fx-strip" aria-label="Currency: open dollar hedging">
                    <div className="fx-head"><span className="small strong">Currency</span><span className="small strong" style={{ color: 'var(--accent)' }}>Hedge ›</span></div>
                    <div><div className="tiny muted">Rupee</div><div className="strong num">₹{world.fx_inr_usd.toFixed(2)}</div><div className="tiny muted">a dollar</div></div>
                    <div><div className="tiny muted">In dollars</div><div className="strong num">{pct(usdCost / (allCost || 1))}</div><div className="tiny muted">of your costs</div></div>
                    <div><div className="tiny muted">Against ₹{Number(ref.param.fx_ref_inr_usd ?? 90)}</div>
                      <div className={`strong num ${fxEffect > 0.5 ? 'bad-ink' : fxEffect < -0.5 ? 'good' : ''}`}>{Math.abs(fxEffect) < 1 ? '±₹0' : `${fxEffect > 0 ? '+' : '−'}${inr(Math.abs(fxEffect))}`}</div>
                      <div className="tiny muted">{fxEffect >= 0 ? 'added' : 'saved'} in 4 weeks</div></div>
                    <div className="fx-foot tiny muted">Lines marked $ are paid in dollars; fares are in rupees. {o && o.usd_hedge_share > 0 ? `You hedge ${pct(o.usd_hedge_share)} of each week's dollars.` : 'No dollar hedge.'}</div>
                  </Link>
                )}
                {wet > 0 && <p className="tiny" style={{ margin: 0 }}>{wet === fl.length ? 'All your aircraft are' : `${plural(wet, 'aircraft', 'aircraft')} are`} wet-leased: their crew and maintenance are in the rent, so they count under Aircraft.</p>}
                <p className="tiny muted">Rupees per seat-km flown. {nAirlines ? `Industry: the median of ${nAirlines} airlines, refreshed weekly.` : 'The industry median shows at the end of a week once three airlines fly.'}</p>
              </>
            )}
          </div>
        </div>

        <div className="stack-lg">
          <div className="card flush">
            <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>Your strategies</h2><span className="small muted">for the whole fleet</span></div>
            {!o ? <Loading h={120} /> : (
              <div className="list">
                <Link to="/ops/fuel" className="item link">
                  <div className="grow"><div className="tiny muted">Fuel hedging</div><div className="strong">{o.hedge_share > 0 ? `${pct(o.hedge_share)} of each week's fuel` : 'No hedge'}</div></div>
                  <span className={`small ${hedgeWeek > 0 ? 'good' : hedgeWeek < 0 ? 'bad-ink' : 'muted'}`}>
                    {hedgeWeek > 0 ? `Saved ${inr(hedgeWeek)} last week` : hedgeWeek < 0 ? `Cost ${inr(-hedgeWeek)} last week` : 'No hedge result yet'}</span>
                </Link>
                <Link to="/ops/dollars" className="item link">
                  <div className="grow"><div className="tiny muted">Dollar hedging</div><div className="strong">{o.usd_hedge_share > 0 ? `${pct(o.usd_hedge_share)} of each week's dollars` : 'No hedge'}</div></div>
                  <span className={`small ${usdHedgeWeek > 0 ? 'good' : usdHedgeWeek < 0 ? 'bad-ink' : 'muted'}`}>
                    {usdHedgeWeek > 0 ? `Saved ${inr(usdHedgeWeek)} last week` : usdHedgeWeek < 0 ? `Cost ${inr(-usdHedgeWeek)} last week` : 'No hedge result yet'}</span>
                </Link>
                <Link to="/ops/maintenance" className="item link">
                  <div className="grow"><div className="tiny muted">Maintenance</div>
                    <div className="strong">{planName(o.maint_plan)}{o.maint_next ? ` → ${planName(o.maint_next)} from week ${weekOf(o.maint_next_day ?? 1)}` : ''}</div></div>
                  <span className="small muted">{plural(groundQ, 'grounding')} this quarter</span>
                </Link>
                <Link to="/ops/style" className="item link">
                  <div className="grow"><div className="tiny muted">Operating style</div><div className="strong">{styleName(o.op_style)}</div></div>
                  <span className="small muted">On time {pct(airline.otp)}</span>
                </Link>
              </div>
            )}
          </div>
          <CrewCard />
          <Link to="/fleet" className="card link row" style={{ justifyContent: 'space-between' }}>
            <span><span className="strong">Aircraft</span><span className="small muted" style={{ display: 'block' }}>
              {num(fl.filter((a) => a.status === 'active' && flyingIds.has(a.id)).length)} flying · {num(fl.filter((a) => a.status === 'grounded').length)} on the ground · {num(fl.filter((a) => a.status === 'delivering').length)} arriving</span></span>
            <span className="small strong" style={{ color: 'var(--accent)' }}>View all ›</span>
          </Link>
        </div>
      </div>
    </div>
  );
}

// ---------- the three strategy pages ----------
function Choices({ items, now, pick, onPick, label }: {
  items: { key: string; name: string; blurb: string; good_for: string }[]; now?: string; pick?: string; onPick: (k: string) => void; label: string;
}) {
  return (
    <div className="choices" role="radiogroup" aria-label={label}>
      {items.map((s) => (
        <button key={s.key} type="button" role="radio" aria-label={s.name} aria-checked={pick === s.key} className={`choice${pick === s.key ? ' on' : ''}`} onClick={() => onPick(s.key)}>
          <div className="t">{s.name}{now === s.key && <span className="tiny muted" style={{ fontWeight: 400 }}> · now</span>}</div>
          <div className="d">{s.blurb}</div>
          {s.good_for && <div className="d" style={{ color: 'var(--faint)' }}>{s.good_for}</div>}
        </button>
      ))}
    </div>
  );
}

function Expect({ title, items, note }: { title: ReactNode; items: { label: string; v: ReactNode; note?: ReactNode; tone?: 'good' | 'bad' }[]; note?: ReactNode }) {
  return (
    <div className="card stack" style={{ gap: 10 }}>
      <div className="small muted">{title}</div>
      <div className="grid2">
        {items.map((e) => (
          <div key={e.label}><div className="tiny muted">{e.label}</div><div className="kpi-s">{e.v}</div>
            {e.note && <div className={`tiny ${e.tone === 'good' ? 'good' : e.tone === 'bad' ? 'bad-ink' : 'muted'}`}>{e.note}</div>}</div>
        ))}
      </div>
      {note && <div className="tiny muted" style={{ borderTop: '1px solid var(--line)', paddingTop: 8 }}>{note}</div>}
    </div>
  );
}

const signed = (x: number) => (Math.abs(x) < 1 ? '±₹0' : `${x > 0 ? '+' : '−'}${inr(Math.abs(x))}`);

export function OpsFuel() {
  const { world, airline, ref } = useGame();
  const pv = useOpsPreview();
  const daily = useAirlineDaily(91);
  const { run, busy } = useAction();
  const [pick, setPick] = useState<number | null>(null);
  const p = pv.data;
  const step = Number(ref.param.hedge_step ?? 0.25), max = Number(ref.param.hedge_max ?? 0.75);
  const options = useMemo(() => Array.from({ length: Math.round(max / step) + 1 }, (_, i) => Math.round(i * step * 100) / 100), [step, max]);
  if (!p) return <div className="stack-lg"><PageHeader title="Fuel hedging" back="/ops" /><Loading /></div>;
  const share = pick ?? p.hedge_share;
  const cur = p.styles.find((s) => s.key === p.style);
  const fuelWeek = cur?.fuel_week ?? 0;
  const shock = world.fuel_walk ? world.fuel_inr_kg / world.fuel_walk - 1 : 0;
  const days = daily.data ?? [];
  const week = days.filter((d) => d.game_day > world.game_day - 7);
  const qStart = (gameDate(world.game_day).quarter - 1) * 91 + (gameDate(world.game_day).year - 1) * 364;
  const booked = p.hedges.filter((h) => h.share > 0);
  const wNow = weekOf(world.game_day + 1);
  const rows = [[-0.2, 'fall 20%', '#4FA59A'], [0, 'stay', 'var(--accent)'], [0.2, 'rise 20%', '#F0A04B']] as const;
  const bills = rows.map(([s]) => hedgeBill(fuelWeek, share, s, p.hedge_premium));
  const top = hedgeBill(fuelWeek, 0, 0.2, p.hedge_premium) || 1;
  const blurb = (h: number) => (h === 0 ? 'Pay the market price every week. Cheapest when fuel falls; shocks hit in full.'
    : h <= 0.25 ? 'Takes the edge off a shock.' : h <= 0.5 ? "Half of each week's fuel bought ahead: steadier costs." : 'Most of the bill fixed 13 weeks ahead. Costly if prices fall.');
  return (
    <div className="stack-lg">
      <PageHeader title="Fuel hedging" back="/ops" sub={`Buy part of each week's fuel ${p.hedge_lead_weeks} weeks ahead, at that week's price plus ${pct(p.hedge_premium)}. It evens out shocks, and costs a little when prices fall.`} />
      <div className="split">
        <div className="stack-lg">
          <div className="card stack" style={{ gap: 8 }}>
            <div className="row" style={{ justifyContent: 'space-between', alignItems: 'baseline' }}>
              <div><div className="tiny muted">Fuel this week</div><div className="kpi-s" style={{ fontSize: 22 }}>₹{world.fuel_inr_kg.toFixed(0)} a kg</div></div>
              <Badge tone={shock >= 0.1 ? 'warn' : shock <= -0.1 ? 'good' : 'neutral'}>{Math.abs(shock) < 0.02 ? 'normal' : `${pct(Math.abs(shock))} ${shock > 0 ? 'above' : 'below'} normal`}</Badge>
            </div>
            <div className="kv small">
              <span>Fuel charge in fares</span><span>{Math.abs((world.fare_index ?? 1) - 1) < 0.001 ? 'none' : `${(world.fare_index ?? 1) > 1 ? '+' : '−'}${pct(Math.abs((world.fare_index ?? 1) - 1), 1)} on every fare`}</span>
              <span>Already bought</span><span>{booked.length ? `weeks ${booked[0].week} to ${booked[booked.length - 1].week}` : 'nothing yet'}</span>
              {booked.length > 0 && <><span>at an average of</span><span>₹{(booked.reduce((s, h) => s + h.price, 0) / booked.length).toFixed(0)} a kg</span></>}
              <span>Hedge result last week</span><span className={sum(week, (d) => d.hedge_inr) >= 0 ? 'good' : 'bad-ink'}>{signed(sum(week, (d) => d.hedge_inr))}</span>
              <span>This quarter</span><span className={sum(days.filter((d) => d.game_day > qStart), (d) => d.hedge_inr) >= 0 ? 'good' : 'bad-ink'}>{signed(sum(days.filter((d) => d.game_day > qStart), (d) => d.hedge_inr))}</span>
            </div>
          </div>
          <h2>How much to hedge</h2>
          <Choices label="How much to hedge" now={String(p.hedge_share)} pick={String(share)} onPick={(k) => setPick(Number(k))}
            items={options.map((h) => ({ key: String(h), name: h === 0 ? 'None' : pct(h), blurb: blurb(h), good_for: '' }))} />
        </div>
        <div className="stack-lg">
          <div className="card stack" style={{ gap: 10 }}>
            <div className="small muted">Fuel for weeks {wNow + p.hedge_lead_weeks} to {wNow + p.hedge_lead_weeks + 12} (the weeks this choice buys) with <strong style={{ color: 'var(--ink)' }}>{share === 0 ? 'no hedge' : `${pct(share)} hedged`}</strong>, if prices then…</div>
            {fuelWeek === 0 ? <p className="small muted">No flights scheduled yet: put aircraft on routes to see your fuel bill.</p> : rows.map(([s, label, c], i) => (
              <div key={s} className="hedge-row">
                <span className="small">{label}</span>
                <div className="hedge-bar"><i style={{ width: `${(100 * bills[i]) / top}%`, background: c }} /></div>
                <span className="small strong num">{inr(bills[i])}</span>
              </div>
            ))}
            {fuelWeek > 0 && <div className="tiny muted">Best to worst case: <strong>{inr(bills[2] - bills[0])}</strong>. More hedging narrows it, for the {pct(p.hedge_premium)} premium.</div>}
          </div>
          <Button block disabled={share === p.hedge_share} busy={busy === 'hedge'} onClick={() => run('hedge', () => call('set_hedge', { p_airline: airline.id, p_share: share }),
            share === 0 ? 'No new hedges from next week. Hedges already bought run off.' : `Hedging ${pct(share)} from next week's purchase: fuel for week ${wNow + p.hedge_lead_weeks} on.`).then(() => setPick(null))}>Hedge this way</Button>
          <p className="tiny muted" style={{ textAlign: 'center' }}>Hedges already bought run off over {p.hedge_lead_weeks} weeks, so a change shows fully after {p.hedge_lead_weeks} weeks.
            Fares follow about a third of a change in fuel cost, a few weeks late: hedging protects the rest.</p>
        </div>
      </div>
    </div>
  );
}

export function OpsDollar() {
  const { world, airline } = useGame();
  const pv = useOpsPreview();
  const daily = useAirlineDaily(91);
  const { run, busy } = useAction();
  const [pick, setPick] = useState<number | null>(null);
  const p = pv.data;
  const u = p?.usd;
  const options = useMemo(() => (u ? Array.from({ length: Math.round(u.max / u.step) + 1 }, (_, i) => Math.round(i * u.step * 100) / 100) : []), [u]);
  if (!p || !u) return <div className="stack-lg"><PageHeader title="Dollar hedging" back="/ops" /><Loading /></div>;
  const share = pick ?? u.share;
  const fx = world.fx_inr_usd, weak = fx / u.ref - 1;
  const usdWeek = u.week_usd * fx;
  const days = daily.data ?? [];
  const week = days.filter((d) => d.game_day > world.game_day - 7);
  const qStart = (gameDate(world.game_day).quarter - 1) * 91 + (gameDate(world.game_day).year - 1) * 364;
  const quarter = days.filter((d) => d.game_day > qStart);
  const booked = u.bought.filter((h) => h.share > 0);
  const wNow = weekOf(world.game_day + 1);
  const rows = [[-0.05, 'gains 5%', '#4FA59A'], [0, 'stays', 'var(--accent)'], [0.05, 'loses 5%', '#F0A04B'], [0.1, 'loses 10%', '#D9644A']] as const;
  const bills = rows.map(([s]) => hedgeBill(usdWeek, share, s, u.premium));
  const top = hedgeBill(usdWeek, 0, 0.1, u.premium) || 1;
  const blurb = (h: number) => (h === 0 ? 'Buy dollars at the going rate every week. Cheapest when the rupee strengthens; a fall hits in full.'
    : h <= 0.25 ? 'Takes the edge off a fall.' : h <= 0.5 ? "Half of each week's dollars bought ahead: steadier costs." : 'Most of the dollar bill fixed 13 weeks ahead. Costly if the rupee recovers.');
  const res = (xs: typeof days) => sum(xs, (d) => d.usd_hedge_inr ?? 0);
  return (
    <div className="stack-lg">
      <PageHeader title="Dollar hedging" back="/ops" sub={`Aircraft rent, maintenance and dollar loans are paid in dollars; your fares are in rupees. Buy part of each week's dollars ${p.hedge_lead_weeks} weeks ahead, at that week's rate plus ${pct(u.premium)}.`} />
      <div className="split">
        <div className="stack-lg">
          <div className="card stack" style={{ gap: 8 }}>
            <div className="row" style={{ justifyContent: 'space-between', alignItems: 'baseline' }}>
              <div><div className="tiny muted">The rupee this week</div><div className="kpi-s" style={{ fontSize: 22 }}>₹{fx.toFixed(2)} a dollar</div></div>
              <Badge tone={weak >= 0.05 ? 'warn' : weak <= -0.05 ? 'good' : 'neutral'}>{Math.abs(weak) < 0.01 ? `about ₹${u.ref}` : `${pct(Math.abs(weak))} ${weak > 0 ? 'weaker' : 'stronger'} than ₹${u.ref}`}</Badge>
            </div>
            <div className="kv small">
              <span>Your dollar costs</span><span>{u.week_usd > 0 ? `${usd(u.week_usd)} a week (${inr(usdWeek)})` : 'none yet'}</span>
              <span>Already bought</span><span>{booked.length ? `weeks ${booked[0].week} to ${booked[booked.length - 1].week}` : 'nothing yet'}</span>
              {booked.length > 0 && <><span>at an average of</span><span>₹{(booked.reduce((s0, h) => s0 + h.rate, 0) / booked.length).toFixed(2)} a dollar</span></>}
              <span>Hedge result last week</span><span className={res(week) >= 0 ? 'good' : 'bad-ink'}>{signed(res(week))}</span>
              <span>This quarter</span><span className={res(quarter) >= 0 ? 'good' : 'bad-ink'}>{signed(res(quarter))}</span>
            </div>
          </div>
          <h2>How much to hedge</h2>
          <Choices label="How much of the dollars to hedge" now={String(u.share)} pick={String(share)} onPick={(k) => setPick(Number(k))}
            items={options.map((h) => ({ key: String(h), name: h === 0 ? 'None' : pct(h), blurb: blurb(h), good_for: '' }))} />
        </div>
        <div className="stack-lg">
          <div className="card stack" style={{ gap: 10 }}>
            <div className="small muted">Dollar costs for weeks {wNow + p.hedge_lead_weeks} to {wNow + p.hedge_lead_weeks + 12} (the weeks this choice buys), in rupees, with <strong style={{ color: 'var(--ink)' }}>{share === 0 ? 'no hedge' : `${pct(share)} hedged`}</strong>, if the rupee then…</div>
            {usdWeek === 0 ? <p className="small muted">No dollar costs yet: they start with your first aircraft.</p> : rows.map(([s, label, c], i) => (
              <div key={s} className="hedge-row">
                <span className="small">{label}</span>
                <div className="hedge-bar"><i style={{ width: `${(100 * bills[i]) / top}%`, background: c }} /></div>
                <span className="small strong num">{inr(bills[i])}</span>
              </div>
            ))}
            {usdWeek > 0 && <div className="tiny muted">Best to worst case: <strong>{inr(bills[3] - bills[0])}</strong>. More hedging narrows it, for the {pct(u.premium)} premium.</div>}
          </div>
          <Button block disabled={share === u.share} busy={busy === 'usd'} onClick={() => run('usd', () => call('set_usd_hedge', { p_airline: airline.id, p_share: share }),
            share === 0 ? 'No new dollar hedges from next week. Hedges already bought run off.' : `Hedging ${pct(share)} from next week's purchase: dollars for week ${wNow + p.hedge_lead_weeks} on.`).then(() => setPick(null))}>Hedge this way</Button>
          <p className="tiny muted" style={{ textAlign: 'center' }}>Hedges already bought run off over {p.hedge_lead_weeks} weeks, so a change shows fully after {p.hedge_lead_weeks} weeks.
            International routes that sell abroad take some fares in dollars, a natural hedge: see each route's How it sells.</p>
        </div>
      </div>
    </div>
  );
}

function costChart(p: OpsPreview) {
  // cost a week against fleet size, from this airline's cost per aircraft today
  const n = p.aircraft;
  const P = Object.fromEntries(p.plans.map((x) => [x.key, x]));
  if (n === 0 || !P.payg || !P.contract || !P.hangar || P.payg.cost_week <= 0) return null;
  const per = (k: string) => (P[k].cost_week - P[k].fixed_week) / n;
  const line = (k: string) => (m: number) => per(k) * m + P[k].fixed_week;
  const be = per('payg') > per('hangar') ? P.hangar.fixed_week / (per('payg') - per('hangar')) : null;
  const xMax = Math.max(100, Math.ceil((Math.max(n, be ?? 0) * 1.2) / 10) * 10);
  const yMax = Math.max(line('payg')(xMax), line('contract')(xMax), line('hangar')(xMax)) * 1.05 || 1;
  const X = (m: number) => 34 + (m / xMax) * 296, Y = (v: number) => 150 - (v / yMax) * 140;
  const seg = (k: string) => `${X(0)},${Y(line(k)(0))} ${X(xMax)},${Y(line(k)(xMax))}`;
  return (
    <svg viewBox="0 0 340 176" width="100%" role="img" aria-label={`Maintenance cost a week against fleet size${be ? `: an own hangar becomes cheaper from about ${Math.round(be)} aircraft` : ''}; you have ${n}`}>
      <line x1="34" y1="150" x2="330" y2="150" stroke="var(--line-strong)" />
      <text x="0" y={Y(yMax / 1.05) + 4} fontSize="10" fill="var(--muted)">{inr(yMax / 1.05)}</text>
      <line x1={X(n)} y1="10" x2={X(n)} y2="150" stroke="var(--ink)" strokeDasharray="3 3" />
      <text x={X(n) + 4} y="20" fontSize="10" fill="var(--ink)">You: {n}</text>
      <polyline points={seg('contract')} fill="none" stroke="#1E5AA8" strokeWidth="2.5" />
      <polyline points={seg('payg')} fill="none" stroke="#9AA3B2" strokeWidth="2.5" />
      <polyline points={seg('hangar')} fill="none" stroke="var(--accent)" strokeWidth="2.5" />
      {be != null && be < xMax && <><circle cx={X(be)} cy={Y(line('payg')(be))} r="4" fill="var(--card)" stroke="var(--accent)" strokeWidth="2" />
        <text x={X(be) - 30} y={Y(line('payg')(be)) + 18} fontSize="10" fill="var(--accent)">break-even: {Math.round(be)}</text></>}
      <text x="34" y="164" fontSize="10" fill="var(--muted)">0</text>
      <text x="306" y="164" fontSize="10" fill="var(--muted)">{xMax}</text>
      <text x="290" y="175" fontSize="10" fill="var(--muted)">aircraft</text>
    </svg>
  );
}

export function OpsMaint() {
  const { airline } = useGame();
  const pv = useOpsPreview();
  const plans = useMaintPlans();
  const { run, busy } = useAction();
  const [pick, setPick] = useState<string | null>(null);
  const p = pv.data;
  if (!p || !plans.data) return <div className="stack-lg"><PageHeader title="Maintenance strategy" back="/ops" /><Loading /></div>;
  const key = (pick ?? p.plan_next ?? p.plan) as string;
  const sel = p.plans.find((x) => x.key === key)!;
  const now = p.plans.find((x) => x.key === p.plan)!;
  const meta = plans.data.find((x) => x.key === key)!;
  const locked = p.day < p.locked_until && key !== p.plan;
  const pending = p.plan_next === key;
  const commit = sel.lock_weeks > 0 ? `Runs ${sel.lock_weeks} weeks once it takes effect.` : sel.setup_inr > 0 ? `${inr(sel.setup_inr)} to set up, paid now; opens ${sel.setup_weeks} weeks later.` : 'Change any time; it takes effect from next week.';
  return (
    <div className="stack-lg">
      <PageHeader title="Maintenance strategy" back="/ops" sub={p.aircraft === 0
        ? 'One way for the whole fleet. You have no aircraft of your own yet: wet-leased aircraft come with their own maintenance, so your strategy starts with the first aircraft you lease or buy.'
        : `One way for the whole fleet: ${plural(p.aircraft, 'aircraft', 'aircraft')} of your own, average age ${p.avg_age} years.`} />
      {p.plan_next && <div className="card info small">{plans.data.find((x) => x.key === p.plan_next)?.name} takes effect in week {weekOf(p.plan_next_day ?? 1)}.</div>}
      {p.day < p.locked_until && <div className="card small muted">Your {plans.data.find((x) => x.key === p.plan)?.name.toLowerCase()} runs until week {weekOf(p.locked_until)}.</div>}
      <div className="split">
        <div className="stack-lg">
          <Choices label="Maintenance strategy" now={p.plan} pick={key} onPick={setPick} items={plans.data} />
        </div>
        <div className="stack-lg">
          <Expect title={<>Expect for your fleet with <strong style={{ color: 'var(--ink)' }}>{meta.name}</strong></>} note={commit}
            items={[
              { label: 'Maintenance a week', v: inr(sel.cost_week), note: key === p.plan ? 'now' : signed(sel.cost_week - now.cost_week) + ' against now', tone: sel.cost_week < now.cost_week ? 'good' : sel.cost_week > now.cost_week ? 'bad' : undefined },
              { label: 'Groundings a quarter', v: sel.groundings_qtr.toFixed(1), note: `about ${Math.round(sel.days_qtr)} aircraft-days on the ground` },
              { label: 'On-time effect', v: sel.otp_delta === 0 ? '±0' : `${sel.otp_delta > 0 ? '+' : '−'}${Math.round(Math.abs(sel.otp_delta) * 100)} points` },
              { label: 'Ageing', v: meta.age_k === 0 ? 'Flat' : `+${pct(meta.age_k)} a year`, note: 'how bills grow as aircraft age' },
            ]} />
          {costChart(p) && <div className="card stack" style={{ gap: 6 }}>
            <div className="small strong">Cost a week by fleet size</div>
            {costChart(p)}
            <div className="legend"><span><i style={{ background: '#1E5AA8' }} />Flight-hour contract</span><span><i style={{ background: '#9AA3B2' }} />Pay as you go</span><span><i style={{ background: 'var(--accent)' }} />Own hangar</span></div>
            <div className="tiny muted">Costs only, at today's flying and ages; groundings come on top. Spare aircraft at the same base cover a grounding.</div>
          </div>}
          <Button block disabled={(key === p.plan && !p.plan_next) || pending || locked} busy={busy === 'maint'}
            onClick={() => run('maint', () => call<{ from_day: number | null }>('set_maint_plan', { p_airline: airline.id, p_plan: key }),
              (r) => r.from_day == null ? `Staying with ${meta.name.toLowerCase()}.` : `${meta.name} from week ${weekOf(r.from_day)}.`).then(() => setPick(null))}>
            {key === p.plan ? (p.plan_next ? `Stay with ${meta.name.toLowerCase()}` : 'Your strategy now') : pending ? 'On its way' : locked ? `Locked until week ${weekOf(p.locked_until)}`
              : sel.setup_inr > 0 ? `Set up ${meta.name.toLowerCase()} · ${inr(sel.setup_inr)}` : `Switch to ${meta.name.toLowerCase()}`}
          </Button>
        </div>
      </div>
    </div>
  );
}

export function OpsStyle() {
  const { airline } = useGame();
  const pv = useOpsPreview();
  const styles = useOpStyles();
  const { run, busy } = useAction();
  const [pick, setPick] = useState<string | null>(null);
  const p = pv.data;
  if (!p || !styles.data) return <div className="stack-lg"><PageHeader title="Operating style" back="/ops" /><Loading /></div>;
  const key = (pick ?? p.style) as string;
  const sel = p.styles.find((x) => x.key === key)!;
  const std = p.styles.find((x) => x.key === 'standard')!;
  const meta = styles.data.find((x) => x.key === key)!;
  const caveat = sel.over > 0 ? `${plural(sel.over, 'aircraft', 'aircraft')} would no longer fit their schedules: they fly late until you trim their round trips.`
    : key === 'quick' ? 'The extra round trips earn nothing until you add them to routes.'
    : key === 'saver' ? 'Flights land later, so on-time slips; business travellers notice most.' : key === 'punctual' ? 'Better punctuality lifts the brand, which brings travellers back.' : 'Nothing changes.';
  return (
    <div className="stack-lg">
      <PageHeader title="Operating style" back="/ops" sub="How fast your aircraft fly and how quickly they turn round, for the whole fleet." />
      <div className="split">
        <div className="stack-lg">
          <Choices label="Operating style" now={p.style} pick={key} onPick={setPick} items={styles.data} />
        </div>
        <div className="stack-lg">
          <Expect title={<>Expect for your fleet with <strong style={{ color: 'var(--ink)' }}>{meta.name}</strong>, at today's fuel price</>} note={caveat}
            items={[
              { label: 'Fuel a week', v: inr(sel.fuel_week), note: key === 'standard' ? `at ₹${p.fuel_price.toFixed(0)} a kg` : `${signed(sel.fuel_week - std.fuel_week)} against Standard`, tone: sel.fuel_week < std.fuel_week ? 'good' : sel.fuel_week > std.fuel_week ? 'bad' : undefined },
              { label: 'Round trips that fit', v: num(sel.trips_fit), note: `you fly ${num(sel.trips_week)} a week${sel.trips_fit !== std.trips_fit ? ` · ${sel.trips_fit > std.trips_fit ? '+' : '−'}${num(Math.abs(sel.trips_fit - std.trips_fit))} against Standard` : ''}` },
              { label: 'Other costs a week', v: sel.other_week ? signed(sel.other_week) : '±₹0', note: key === 'quick' ? 'crew allowance per quick turn' : key === 'saver' ? 'flying pay and maintenance by the hour' : 'nothing extra', tone: sel.other_week > 0 ? 'bad' : undefined },
              { label: 'On time', v: pct(sel.otp), note: sel.brand_delta ? `brand ${sel.brand_delta > 0 ? 'rises' : 'dips'}` : 'your punctuality' },
            ]} />
          <Button block disabled={key === p.style} busy={busy === 'style'}
            onClick={() => run('style', () => call<{ over: number }>('set_op_style', { p_airline: airline.id, p_style: key }),
              (r) => `${meta.name} from the next day flown.${r.over ? ` ${plural(r.over, 'aircraft', 'aircraft')} no longer fit their schedules.` : ''}`).then(() => setPick(null))}>
            {key === p.style ? 'Your style now' : 'Fly this way'}</Button>
          <p className="tiny muted" style={{ textAlign: 'center' }}>Pilot and cabin crew salaries are not affected.</p>
        </div>
      </div>
    </div>
  );
}

// Insights (step 3 of spec section 19): What works where, by kind of sector and market shape, with an audit of your own
// routes; and the practice flight, which plays one flight week under each way of selling.
import { useMemo, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useGame, useMarketsFrom, useRivals, useRoutes, useSectorInsights, useStrategies } from '../lib/data';
import { BAND_LABEL, bandOf, practice, practiceInput, SHAPE_LABEL, shapeOf, STRAT_SHORT, type Band, type PracticeResult, type Shape } from '../lib/insights';
import { inr, num, pct } from '../lib/format';
import { pairKey } from '../lib/game';
import type { StrategyKey } from '../lib/types';
import { Badge, Empty, Field, Loading, PageHeader, Seg } from '../components/ui';

const BANDS: Band[] = ['short', 'medium', 'long', 'intl'];
const SHAPES: Shape[] = ['alone', 'two', 'few', 'many'];
const KEYS: StrategyKey[] = ['fill', 'balanced', 'top', 'follow'];

export function Insights() {
  const loc = useLocation();
  const nav = useNavigate();
  const tab = loc.pathname === '/practice' ? 'practice' : 'where';
  return (
    <div className="stack-lg">
      <PageHeader title="Insights" sub="What sells where, and a practice flight" back />
      <Seg value={tab} block onChange={(v) => nav(v === 'practice' ? '/practice' : '/insights')}
        options={[{ value: 'where', label: 'What works where' }, { value: 'practice', label: 'Practice flight' }]} />
      {tab === 'where' ? <WhatWorksWhere /> : <Practice />}
    </div>
  );
}

function WhatWorksWhere() {
  const { airline } = useGame();
  const ins = useSectorInsights();
  const net = useRoutes();
  const routes = net.data?.routes ?? [];
  const markets = useMarketsFrom(routes.flatMap((r) => [r.origin, r.dest]));
  const rivals = useRivals(routes.flatMap((r) => [r.origin, r.dest]));
  const nav = useNavigate();
  if (ins.isLoading) return <Loading />;
  const cells = ins.data ?? [];
  const cell = (b: Band, s: Shape, k: StrategyKey) => cells.find((x) => x.band === b && x.shape === s && x.strategy === k);
  return (
    <div className="stack-lg">
      <p className="small muted">Every route in the world over the last 13 weeks, by kind of sector and how many airlines fly the market. Each figure is revenue per seat as a share of the route's reference fare; the best in each row is in green. A figure shows only when three or more routes sell that way, so no one airline's route can be read off it. It changes every week.</p>
      {cells.length === 0 ? <Empty title="Nothing yet">It fills in once routes have flown for a few weeks.</Empty> : BANDS.filter((b) => cells.some((x) => x.band === b)).map((b) => (
        <div key={b} className="card flush">
          <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>{BAND_LABEL[b]}</h2></div>
          <div className="scroll-x">
            <table className="table">
              <thead><tr><th>Market</th>{KEYS.map((k) => <th key={k} className="r">{STRAT_SHORT[k]}</th>)}</tr></thead>
              <tbody>
                {SHAPES.filter((s) => cells.some((x) => x.band === b && x.shape === s)).map((s) => {
                  const row = KEYS.map((k) => cell(b, s, k));
                  const best = Math.max(...row.map((c) => c?.rev_index ?? 0));
                  return (
                    <tr key={s}>
                      <td>{SHAPE_LABEL[s]}</td>
                      {row.map((c, i) => (
                        <td key={KEYS[i]} className={`r ${c && c.rev_index === best ? 'cell-best' : ''}`} title={c ? `${c.routes} routes, ${pct(c.load)} full` : 'Fewer than 3 routes'}>
                          {c ? pct(c.rev_index) : '–'}{c && <div className="tiny muted" style={{ fontWeight: 400 }}>{pct(c.load)} full</div>}
                        </td>
                      ))}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      ))}

      <div className="card flush">
        <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>Audit your routes</h2></div>
        {routes.length === 0 ? <p className="small muted" style={{ padding: '0 16px 14px' }}>Open a route first.</p> : (
          <div className="list">
            {routes.map((r) => {
              const m = markets.data?.[pairKey(r.origin, r.dest)];
              if (!m) return null;
              const n = (rivals.data?.[pairKey(r.origin, r.dest)] ?? []).filter((x) => x.weekly > 0 || x.route.airline_id === airline.id).length;
              const b = bandOf(m), s = shapeOf(n);
              const row = KEYS.map((k) => cell(b, s, k)).filter(Boolean);
              const best = row.sort((x, y) => y!.rev_index - x!.rev_index)[0];
              return (
                <div key={r.id} className="item link" onClick={() => nav(`/route/${r.id}`)}>
                  <div className="grow">
                    <div className="strong">{r.origin}–{r.dest}</div>
                    <div className="tiny muted">{BAND_LABEL[b]} · {SHAPE_LABEL[s].toLowerCase()}</div>
                  </div>
                  {best ? <Badge tone="good">Best here: {STRAT_SHORT[best.strategy]}</Badge> : <span className="tiny muted">Not enough routes like it</span>}
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}

function Practice() {
  const { ref, world, airline } = useGame();
  const strategies = useStrategies();
  const net = useRoutes();
  const routes = net.data?.routes ?? [];
  const ends = routes.flatMap((r) => [r.origin, r.dest]);
  const markets = useMarketsFrom(ends);
  const rivals = useRivals(ends);
  const loc = useLocation();
  const [rid, setRid] = useState<string>(() => new URLSearchParams(loc.search).get('route') ?? '');
  const [season, setSeason] = useState<'quiet' | 'normal' | 'busy'>('normal');
  const [show, setShow] = useState<StrategyKey>('balanced');
  const route = routes.find((r) => r.id === rid) ?? routes[0];
  const m = route ? markets.data?.[pairKey(route.origin, route.dest)] : undefined;

  const results = useMemo(() => {
    if (!route || !m || !strategies.data) return null;
    const input = practiceInput(m, rivals.data?.[pairKey(route.origin, route.dest)] ?? [], airline.id, world.demand_scale, world.game_day + 1, ref.param,
      season === 'busy' ? 1.2 : season === 'quiet' ? 0.85 : 1);
    return { input, out: strategies.data.map((s) => practice(s, input)).sort((a, b) => b.revenue - a.revenue) };
  }, [route, m, strategies.data, rivals.data, season, airline.id, world.demand_scale, world.game_day, ref.param]);

  if (net.isLoading || markets.isLoading) return <Loading />;
  if (!routes.length) return <Empty title="No routes yet">Open a route, then practise selling it here.</Empty>;
  const sel = results?.out.find((r) => r.key === show);
  const name = (k: string) => strategies.data?.find((s) => s.key === k)?.name ?? k;
  return (
    <div className="stack-lg">
      <p className="small muted">Plays one flight week on sale for 26 weeks, once for each way of selling, against your rivals holding their fares. Nothing is saved and nothing changes in the game. It leaves out business seats and no-shows, so treat it as a guide.</p>
      <div className="card stack">
        <Field label="Route">
          <select className="input" value={route?.id ?? ''} onChange={(e) => setRid(e.target.value)}>
            {routes.map((r) => <option key={r.id} value={r.id}>{ref.airport[r.origin]?.city ?? r.origin} – {ref.airport[r.dest]?.city ?? r.dest}</option>)}
          </select>
        </Field>
        <Field label="Which week">
          <Seg value={season} block onChange={setSeason} options={[{ value: 'quiet', label: 'Quiet' }, { value: 'normal', label: 'Normal' }, { value: 'busy', label: 'Busy' }]} />
        </Field>
        {results && <p className="tiny muted">{num(Math.round(results.input.seats))} seats each way · {results.input.rivalSeats ? `rivals ${num(Math.round(results.input.rivalSeats))} seats at about ${inr(results.input.rivalFare ?? 0)}` : 'no rivals'}</p>}
      </div>
      {results && (
        <div className="card flush">
          <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>How each way did</h2><span className="small muted">tap one to see its sale</span></div>
          <table className="table">
            <thead><tr><th>#</th><th>Selling</th><th className="r">Revenue</th><th className="r">Full</th><th className="r">Avg fare</th></tr></thead>
            <tbody>
              {results.out.map((r, i) => (
                <tr key={r.key} className={r.key === show ? 'me' : ''} onClick={() => setShow(r.key)} style={{ cursor: 'pointer' }}>
                  <td className="num">{i + 1}</td><td>{name(r.key)}</td><td className="r">{inr(r.revenue)}</td><td className="r">{pct(r.load)}</td><td className="r">{inr(r.fare)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {sel && <PracticeChart r={sel} seats={results!.input.seats} name={name(sel.key)} />}
    </div>
  );
}

function PracticeChart({ r, seats, name }: { r: PracticeResult; seats: number; name: string }) {
  const W = 340, H = 150, P = 6;
  let cum = 0;
  const pts = r.weeks.map((w) => ({ ...w, cum: (cum += w.booked) }));
  const maxFare = Math.max(...pts.map((p) => p.fare));
  const x = (i: number) => P + (i * (W - 2 * P)) / Math.max(1, pts.length - 1);
  const y = (v: number, max: number) => H - P - (v / max) * (H - 2 * P);
  return (
    <div className="card stack">
      <div className="card-title" style={{ marginBottom: 0 }}><h2>{name}: the sale week by week</h2></div>
      <svg viewBox={`0 0 ${W} ${H}`} width="100%" role="img" aria-label={`${name}: seats sold and fare over 26 weeks`}>
        <line x1={P} x2={W - P} y1={y(seats, seats)} y2={y(seats, seats)} stroke="var(--line-strong)" strokeDasharray="4 3" />
        <polyline fill="none" stroke="var(--accent)" strokeWidth="2.5" points={pts.map((p, i) => `${x(i)},${y(Math.min(p.cum, seats), seats)}`).join(' ')} />
        <polyline fill="none" stroke="var(--warn-ink)" strokeWidth="1.5" points={pts.map((p, i) => `${x(i)},${y(p.fare, maxFare * 1.1)}`).join(' ')} />
      </svg>
      <div className="legend"><span><i style={{ background: 'var(--accent)' }} />seats sold (dashed: all seats)</span><span><i style={{ background: 'var(--warn-ink)' }} />fare on sale</span></div>
      <div className="weeks-axis"><span>26 weeks before</span><span>the flight week</span></div>
      <p className="small">{num(Math.round(r.sold))} of {num(Math.round(seats))} seats sold at {inr(r.fare)} on average.{r.turned >= 1 ? ` ${num(Math.round(r.turned))} travellers wanted a seat after it sold out.` : ''}{r.empty >= 1 ? ` ${num(Math.round(r.empty))} seats flew empty.` : ''}</p>
    </div>
  );
}

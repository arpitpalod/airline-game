// Extras for the whole network: sell each one at a price (a multiple of its reference price) or include it free.
// Prices follow each route's reference fare, so one setting works from short hops to long haul.
import { useMemo, useState } from 'react';
import { call } from '../lib/api';
import { useAirlineDaily, useExtras, useGame, useMarketsFrom, useRoutes, type AncProduct } from '../lib/data';
import { pairKey } from '../lib/game';
import { inr, pct, signedPct } from '../lib/format';
import { useAction } from '../components/toast';
import { Button, Kpi, Loading, PageHeader, Seg, Stepper } from '../components/ui';

type Choice = { included: boolean; mult: number };

const HINT: Record<string, string> = {
  bag: 'Leisure and family travellers carry the most bags, so its price moves them most. Including one wins holiday and Gulf routes, but you pay handling on every bag.',
  seat: 'Costs you nothing to give away. Business travellers care most.',
  meal: 'Dear to include: travellers value a free meal less than it costs you.',
  priority: 'Cheap to include, and business travellers notice it.',
};

const SEGS = [['lei', 'Leisure'], ['bud', 'Budget and family'], ['biz', 'Business']] as const;
type Seg3 = Record<(typeof SEGS)[number][0], number>;

// What a choice does to the trip price each kind of traveller compares, in rupees on the sample route.
// Matches the engine: utility uses fare / reference + sum of w x reference share x (multiple - 1), or - w x reference share when free.
function feel(p: AncProduct, c: Choice, fare: number): Seg3 {
  const d = c.included ? -p.ref_share : p.ref_share * (c.mult - 1);
  return { lei: p.w_lei * d * fare, bud: p.w_bud * d * fare, biz: p.w_biz * d * fare };
}

function FeelLine({ f, verb }: { f: Seg3; verb: 'higher' | 'cut' }) {
  const parts = SEGS.filter(([k]) => Math.abs(f[k]) >= 1).map(([k, n]) => `${n.toLowerCase()} ${inr(Math.abs(f[k]))}`);
  if (!parts.length) return <p className="small">No effect on seat sales: this is the price travellers expect.</p>;
  return <p className="small">{verb === 'cut' ? 'Feels like a fare cut' : 'Your seats feel dearer'} to travellers: {parts.join(', ')}.</p>;
}

export function Extras() {
  const { ref, airline } = useGame();
  const ex = useExtras();
  const net = useRoutes();
  const markets = useMarketsFrom((net.data?.routes ?? []).flatMap((r) => [r.origin, r.dest]));
  const daily = useAirlineDaily(7);
  const { run, busy } = useAction();
  const [edit, setEdit] = useState<Record<string, Choice>>({});
  const k = ref.param.anc_k ?? 0.6;

  // prices are shown for the airline's first route, or a 1,000 km flight before it has one
  const sample = useMemo(() => {
    const r = net.data?.routes[0];
    const m = r && markets.data?.[pairKey(r.origin, r.dest)];
    if (r && m) return { fare: m.ref_fare, mine: r.fare_econ as number | null, label: `${ref.airport[r.origin]?.city}–${ref.airport[r.dest]?.city}` };
    return { fare: (ref.param.ref_fare_fixed ?? 2100) + (ref.param.ref_fare_per_km ?? 3.3) * 1000, mine: null, label: 'a 1,000 km flight' };
  }, [net.data, markets.data, ref]);

  if (ex.isLoading || !ex.data) return <Loading h={300} />;
  const choice = (p: AncProduct): Choice => edit[p.id] ?? { included: ex.data.mine[p.id]?.included ?? false, mult: ex.data.mine[p.id]?.price_mult ?? 1 };
  const dirty = Object.keys(edit).some((id) => {
    const c = edit[id]; const m = ex.data.mine[id];
    return c.included !== (m?.included ?? false) || Math.abs(c.mult - (m?.price_mult ?? 1)) > 1e-9;
  });
  const takeup = (p: AncProduct, m: number) => Math.min(1, p.takeup * Math.exp(-k * (m - 1)));
  let rev = 0, cost = 0;
  const tot: Seg3 = { lei: 0, bud: 0, biz: 0 };
  for (const p of ex.data.products) {
    const c = choice(p);
    const f = feel(p, c, sample.fare);
    for (const [s] of SEGS) tot[s] += f[s];
    if (c.included) cost += p.cost_share * p.inc_use;
    else rev += p.ref_share * c.mult * takeup(p, c.mult);
  }
  const days = daily.data ?? [];
  const pax = days.reduce((s, d) => s + d.pax, 0), anc = days.reduce((s, d) => s + d.rev_anc, 0);
  const base = sample.mine ?? sample.fare;

  return (
    <div className="stack-lg">
      <PageHeader back="/network" title="Extras" sub="Bag, seat, meal and priority boarding. One setting for all your routes; prices grow with each route's distance." />
      <div className="card stack">
        <div className="card-title" style={{ marginBottom: 0 }}><h2>What travellers compare on {sample.label}</h2></div>
        <p className="small">Travellers add the extras they need to the seat fare. Your economy fare {sample.mine != null ? `is ${inr(base)}` : `would be about ${inr(base)}`}; with these extras it feels like:</p>
        <table className="table">
          <thead><tr><th>Traveller</th><th className="r">Extras add</th><th className="r">Feels like</th></tr></thead>
          <tbody>
            {SEGS.map(([s, n]) => (
              <tr key={s}><td>{n}</td><td className="r">{inr(Math.round(tot[s]), { sign: true })}</td><td className="r"><strong>{inr(Math.round(base + tot[s]))}</strong></td></tr>
            ))}
          </tbody>
        </table>
        <p className="tiny muted">"Extras add" is the change against normal extras prices. At normal prices it is zero and only the seat fare matters. Rivals' fares are compared the same way.</p>
      </div>
      <div className="grid4-d">
        <Kpi label={`Extras earn, on ${sample.label}`} value={inr(rev * sample.fare)} note={`per economy passenger${cost ? `; free extras cost ${inr(cost * sample.fare)}` : ''}`} />
        <Kpi label="Extras earned, last 7 days" value={pax ? inr(anc / pax) : '–'} note={pax ? `per passenger, ${inr(anc)} in all` : 'No flights yet'} />
      </div>
      <div className="split">
        <div className="stack">
          {ex.data.products.map((p) => {
            const c = choice(p);
            const set = (x: Partial<Choice>) => setEdit((e) => ({ ...e, [p.id]: { ...c, ...x } }));
            const normal = p.ref_share * sample.fare;
            const price = normal * c.mult;
            const f = feel(p, c, sample.fare);
            const tu = takeup(p, c.mult);
            return (
              <div key={p.id} className="card stack">
                <div className="row between wrap">
                  <h2>{p.name}</h2>
                  <Seg value={c.included ? 'free' : 'sell'} onChange={(v) => set({ included: v === 'free' })}
                    options={[{ value: 'sell', label: 'Sell' }, { value: 'free', label: 'Include free' }]} />
                </div>
                {c.included ? (
                  <>
                    <p className="small">Free for everyone. About {Math.round(p.inc_use * 100)} in 100 passengers use it, costing you {inr(p.cost_share * p.inc_use * sample.fare)} a passenger.</p>
                    <FeelLine f={f} verb="cut" />
                  </>
                ) : (
                  <>
                    <Stepper label={`${p.name} price`} value={Math.round(c.mult * 100) / 100} step={0.05} min={ref.param.anc_mult_min ?? 0.25} max={ref.param.anc_mult_max ?? 3}
                      onChange={(v) => set({ mult: Math.round(v * 100) / 100 })} format={(v) => inr(normal * v)} />
                    <p className="tiny muted">{Math.abs(c.mult - 1) < 1e-9 ? `Normal price on ${sample.label}` : `${signedPct(c.mult - 1)} on the normal price of ${inr(normal)}`}</p>
                    <p className="small">About {Math.round(tu * 100)} in 100 economy passengers buy it at {inr(price)}: {inr(price * tu)} a passenger.</p>
                    <FeelLine f={f} verb="higher" />
                  </>
                )}
                <p className="tiny muted">{HINT[p.id]}</p>
              </div>
            );
          })}
        </div>
        <div className="stack-lg sticky-col">
          <div className="card info small stack" style={{ gap: 6 }}>
            <strong>How extras work</strong>
            <span>Each extra has a normal price that travellers expect, a fixed share of the route's reference fare. At the normal price it earns money and changes nothing else.</span>
            <span>Charge more and you earn more from each buyer, but fewer buy it, and your seats feel dearer to the travellers who need it, as if you had raised the fare.</span>
            <span>Include it free and your seats feel cheaper to those travellers, as if you had cut the fare, but you earn nothing from it and pay what it costs.</span>
            <span>Business-cabin passengers get everything included; their extras add {pct(ref.param.anc_biz_share ?? 0.08)} of the business fare.</span>
          </div>
          <Button block disabled={!dirty} busy={busy === 'extras'} onClick={() => run('extras', () => call('set_extras', {
            p_airline: airline.id, p_settings: Object.fromEntries(Object.entries(edit).map(([id, c]) => [id, { included: c.included, mult: c.mult }])),
          }), 'Extras saved. They count from the next game day.').then((r) => r !== undefined && setEdit({}))}>Save extras</Button>
          <p className="tiny muted">Rivals see your extras just like your fares.</p>
        </div>
      </div>
    </div>
  );
}

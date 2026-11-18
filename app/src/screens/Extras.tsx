// Extras for the whole network: sell each one at a price (a multiple of its reference price) or include it free.
// Prices follow each route's reference fare, so one setting works from short hops to long haul.
import { useMemo, useState } from 'react';
import { call } from '../lib/api';
import { useAirlineDaily, useExtras, useGame, useMarketsFrom, useRoutes, type AncProduct } from '../lib/data';
import { pairKey } from '../lib/game';
import { inr, num, pct, signedPct } from '../lib/format';
import { useAction } from '../components/toast';
import { Button, Kpi, Loading, PageHeader, Seg, Stepper } from '../components/ui';

type Choice = { included: boolean; mult: number };

const HINT: Record<string, string> = {
  bag: 'Leisure and family travellers carry the most bags. Including one wins them over on holiday and Gulf routes, but costs handling on every bag.',
  seat: 'Costs you nothing to give away; business travellers value it most.',
  meal: 'Expensive to include: most low-cost airlines sell it, full-service airlines include it.',
  priority: 'Cheap to include and business travellers notice it.',
};

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
    if (r && m) return { fare: m.ref_fare, label: `${ref.airport[r.origin]?.city}–${ref.airport[r.dest]?.city}` };
    return { fare: (ref.param.ref_fare_fixed ?? 2100) + (ref.param.ref_fare_per_km ?? 3.3) * 1000, label: 'a 1,000 km flight' };
  }, [net.data, markets.data, ref]);

  if (ex.isLoading || !ex.data) return <Loading h={300} />;
  const choice = (p: AncProduct): Choice => edit[p.id] ?? { included: ex.data.mine[p.id]?.included ?? false, mult: ex.data.mine[p.id]?.price_mult ?? 1 };
  const dirty = Object.keys(edit).some((id) => {
    const c = edit[id]; const m = ex.data.mine[id];
    return c.included !== (m?.included ?? false) || Math.abs(c.mult - (m?.price_mult ?? 1)) > 1e-9;
  });
  const takeup = (p: AncProduct, m: number) => Math.min(1, p.takeup * Math.exp(-k * (m - 1)));
  let rev = 0, cost = 0, dB = 0, dL = 0, dU = 0;
  for (const p of ex.data.products) {
    const c = choice(p);
    if (c.included) { cost += p.cost_share * p.inc_use; dB -= p.w_biz * p.ref_share; dL -= p.w_lei * p.ref_share; dU -= p.w_bud * p.ref_share; }
    else { rev += p.ref_share * c.mult * takeup(p, c.mult); dB += p.w_biz * p.ref_share * (c.mult - 1); dL += p.w_lei * p.ref_share * (c.mult - 1); dU += p.w_bud * p.ref_share * (c.mult - 1); }
  }
  const days = daily.data ?? [];
  const pax = days.reduce((s, d) => s + d.pax, 0), anc = days.reduce((s, d) => s + d.rev_anc, 0);

  return (
    <div className="stack-lg">
      <PageHeader back="/network" title="Extras" sub="One setting for your whole network. Prices follow each route's reference fare." />
      <div className="grid4-d">
        <Kpi label="Extras per passenger, last 7 days" value={pax ? inr(anc / pax) : '–'} note={pax ? `${inr(anc)} in all` : 'No flights yet'} />
        <Kpi label={`With these settings, on ${sample.label}`} value={inr(rev * sample.fare)} note={`revenue a passenger${cost ? `, ${inr(cost * sample.fare)} cost` : ''}`} />
        <Kpi label="Trip price leisure travellers see" value={signedPct(dL, 1)} note="of the reference fare, from extras" />
        <Kpi label="Business · budget travellers" value={`${signedPct(dB, 1)} · ${signedPct(dU, 1)}`} note="the same, by segment" />
      </div>
      <div className="split">
        <div className="stack">
          {ex.data.products.map((p) => {
            const c = choice(p);
            const set = (x: Partial<Choice>) => setEdit((e) => ({ ...e, [p.id]: { ...c, ...x } }));
            const price = p.ref_share * c.mult * sample.fare;
            return (
              <div key={p.id} className="card stack">
                <div className="row between wrap">
                  <h2>{p.name}</h2>
                  <Seg value={c.included ? 'free' : 'sell'} onChange={(v) => set({ included: v === 'free' })}
                    options={[{ value: 'sell', label: 'Sell' }, { value: 'free', label: 'Include free' }]} />
                </div>
                {c.included ? (
                  <p className="small">Free for everyone. About {pct(p.inc_use)} use it, costing about {inr(p.cost_share * p.inc_use * sample.fare)} a passenger on {sample.label}.</p>
                ) : (
                  <>
                    <Stepper label={`${p.name} price`} value={Math.round(c.mult * 100) / 100} step={0.05} min={ref.param.anc_mult_min ?? 0.25} max={ref.param.anc_mult_max ?? 3}
                      onChange={(v) => set({ mult: Math.round(v * 100) / 100 })} format={(v) => `${inr(p.ref_share * v * sample.fare)} · ${v.toFixed(2)}×`} />
                    <p className="small muted">About {pct(takeup(p, c.mult))} of economy travellers buy it at {inr(price)} on {sample.label}, earning {inr(price * takeup(p, c.mult))} a passenger. Reference price {inr(p.ref_share * sample.fare)}.</p>
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
            <span>Travellers judge the whole trip price. A dear extra earns more from those who buy it but makes your flights look dearer to everyone who needs it, so you sell fewer seats.</span>
            <span>Including an extra free makes your flights more attractive, like a fare cut, but you give up its revenue and pay its cost.</span>
            <span>Business-cabin passengers get everything included; their extras add {pct(ref.param.anc_biz_share ?? 0.08)} of the business fare.</span>
          </div>
          <Button block disabled={!dirty} busy={busy === 'extras'} onClick={() => run('extras', () => call('set_extras', {
            p_airline: airline.id, p_settings: Object.fromEntries(Object.entries(edit).map(([id, c]) => [id, { included: c.included, mult: c.mult }])),
          }), 'Extras saved. They count from the next game day.').then((r) => r !== undefined && setEdit({}))}>Save extras</Button>
          <p className="tiny muted">Rivals see your extras just like your fares. {num(ex.data.products.length)} extras are on offer for now.</p>
        </div>
      </div>
    </div>
  );
}

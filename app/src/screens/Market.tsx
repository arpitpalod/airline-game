// Getting aircraft: lease from the lessor pool, order new, or wet-lease. Scarcity sets the price; it never says no.
import { useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { call } from '../lib/api';
import { useAircraftMarket, useBases, useGame, usePool, useTxns } from '../lib/data';
import { ageYears, poolRentUsd } from '../lib/game';
import { inr, num, realSpan, usd } from '../lib/format';
import type { Aircraft } from '../lib/types';
import { useAction } from '../components/toast';
import { Badge, Button, Empty, Field, Loading, PageHeader, Seg, Sheet } from '../components/ui';

type Tab = 'lease' | 'order' | 'wet';

export function Market() {
  const { ref, world } = useGame();
  const [sp, setSp] = useSearchParams();
  const tab = (sp.get('tab') as Tab) || 'lease';
  const market = useAircraftMarket();
  const pool = usePool();
  const txns = useTxns();
  const nav = useNavigate();
  const [typeFilter, setTypeFilter] = useState<string>('A20N');
  const [leasing, setLeasing] = useState<Aircraft | null>(null);
  const [wet, setWet] = useState<string | null>(null);

  const leasedRecently = (txns.data ?? []).filter((x) => x.kind === 'lease' && x.game_day > world.game_day - 91).length;
  const left = Math.max(0, ref.param.pool_lease_max_qtr - leasedRecently);
  const quote = (id: string) => market.data?.find((q) => q.type_id === id);
  const poolOfType = useMemo(() => (pool.data ?? []).filter((a) => a.type_id === typeFilter), [pool.data, typeFilter]);
  // The pool can hold over a hundred aircraft of a type: group them by cabin and age, and offer the youngest of each group.
  const groups = useMemo(() => {
    const bands: [number, number, string][] = [[0, 3, 'Up to 3 years old'], [3, 6, '3 to 6 years old'], [6, 9, '6 to 9 years old'], [9, 99, 'Over 9 years old']];
    const q = quote(typeFilter);
    const out: Record<string, { key: string; label: string; n: number; pick: Aircraft; rent: number; age: number }> = {};
    for (const a of poolOfType) {
      const age = ageYears(a, world.game_day);
      const band = bands.find(([lo, hi]) => age >= lo && age < hi) ?? bands[3];
      const key = `${a.seats_biz}+${a.seats_econ}|${band[0]}`;
      const g = out[key];
      if (!g) out[key] = { key, label: band[2], n: 1, pick: a, rent: q ? poolRentUsd(ref.type[a.type_id], q.rent_mult, age) : 0, age };
      else { g.n++; if (age < g.age) { g.pick = a; g.age = age; g.rent = q ? poolRentUsd(ref.type[a.type_id], q.rent_mult, age) : 0; } }
    }
    return Object.values(out).sort((x, y) => x.age - y.age || x.pick.seats_econ - y.pick.seats_econ);
  }, [poolOfType, world.game_day, ref.type, typeFilter, market.data]);

  return (
    <div className="stack-lg">
      <PageHeader back="/fleet" title="Get aircraft" sub="Three ways, priced by how scarce aircraft are right now" />
      <Seg block value={tab} onChange={(v) => setSp({ tab: v })} options={[
        { value: 'lease', label: 'Lease' }, { value: 'order', label: 'Order new' }, { value: 'wet', label: 'Wet lease' },
      ]} />
      <div className="card info small">
        {tab === 'lease' && <>An operating lease from the lessor pool arrives in {realSpan(39, world.speed)} to {realSpan(91, world.speed)} and runs {num(ref.param.lease_term_days / 364, 0)} game years. Rent rises as the pool empties. You pay {ref.param.lease_deposit_months} months' rent as a deposit. You can take {left} more from the pool right now: lessors place at most {ref.param.pool_lease_max_qtr} with one airline in any 91 game days.</>}
        {tab === 'order' && <>A new aircraft is the cheapest to run but takes about {realSpan(ref.param.order_lead_min_days, world.speed)} to arrive. You pay 15% now and the rest on delivery: cash, an aircraft loan, or a sale and leaseback. You choose its cabin.</>}
        {tab === 'wet' && <>A wet lease comes with crew and maintenance and arrives in {ref.param.wet_lead_days ?? 13} game days ({realSpan(ref.param.wet_lead_days ?? 13, world.speed)}). It is the fastest way to add capacity and the most expensive: about twice an operating lease, billed for at least {ref.param.wet_min_hours_day} hours a day.</>}
      </div>

      {market.isLoading ? <Loading h={240} /> : tab === 'lease' ? (
        <div className="split">
          <div className="stack">
            <div className="chips">
              {ref.types.map((t) => {
                const q = quote(t.id);
                return <button key={t.id} className={`chip ${typeFilter === t.id ? 'on' : ''}`} onClick={() => setTypeFilter(t.id)}>{t.name} · {q?.pool_available ?? 0}</button>;
              })}
            </div>
            <div className="card flush">
              {pool.isLoading ? <div style={{ padding: 16 }}><Loading /></div> : poolOfType.length === 0 ? (
                <Empty title="None left in the pool">The lessors add a quarter of their target each quarter. Try another type, a new order, or a wet lease.</Empty>
              ) : (
                <div className="list">
                  {groups.map((g) => (
                    <div key={g.key} className="item link" onClick={() => setLeasing(g.pick)}>
                      <div className="grow">
                        <div className="strong">{g.label} <span className="muted" style={{ fontWeight: 400 }}>· {g.n} available</span></div>
                        <div className="tiny muted">{g.pick.seats_biz ? `${g.pick.seats_biz} business + ` : ''}{g.pick.seats_econ} economy · economy at {g.pick.econ_pitch} in</div>
                      </div>
                      <div className="right">
                        <div className="num strong">{usd(g.rent)}</div>
                        <div className="tiny muted">a month</div>
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>
          <TypeFacts typeId={typeFilter} />
        </div>
      ) : tab === 'order' ? (
        <div className="grid4-d" style={{ gridTemplateColumns: 'repeat(auto-fill, minmax(250px, 1fr))' }}>
          {ref.types.map((t) => {
            const q = quote(t.id)!;
            return (
              <div key={t.id} className="card stack">
                <div><h2>{t.name}</h2><div className="tiny muted">{t.role} · {t.ref_seats} standard seats · {num(t.range_km)} km</div></div>
                <div className="kv">
                  <span>Price</span><span>{usd(q.order_price_usd)}</span>
                  <span>Delivery</span><span>day {q.order_delivery_day}</span>
                  <span>Arrives in</span><span>{realSpan(q.order_delivery_day - world.game_day, world.speed)}</span>
                </div>
                <Button kind="secondary" onClick={() => nav(`/configure/${t.id}`)}>Choose cabin and order</Button>
              </div>
            );
          })}
        </div>
      ) : (
        <div className="grid4-d" style={{ gridTemplateColumns: 'repeat(auto-fill, minmax(250px, 1fr))' }}>
          {ref.types.map((t) => {
            const q = quote(t.id)!;
            return (
              <div key={t.id} className="card stack">
                <div><h2>{t.name}</h2><div className="tiny muted">{t.ref_seats} seats, standard cabin, with crew</div></div>
                <div className="kv">
                  <span>Rate</span><span>{usd(q.wet_usd_bh)} a block hour</span>
                  <span>Minimum a day</span><span>{inr(q.wet_usd_bh * ref.param.wet_min_hours_day * world.fx_inr_usd)}</span>
                  <span>Arrives</span><span>day {world.game_day + q.wet_lead_days}</span>
                </div>
                <Button kind="secondary" onClick={() => setWet(t.id)}>Wet-lease one</Button>
              </div>
            );
          })}
        </div>
      )}
      {leasing && <LeaseSheet ac={leasing} onClose={() => setLeasing(null)} left={left} />}
      {wet && <WetSheet typeId={wet} onClose={() => setWet(null)} />}
    </div>
  );
}

function TypeFacts({ typeId }: { typeId: string }) {
  const { ref, world } = useGame();
  const market = useAircraftMarket();
  const t = ref.type[typeId]; const q = market.data?.find((x) => x.type_id === typeId);
  if (!q) return null;
  return (
    <div className="card stack">
      <h2>{t.name}</h2>
      <div className="kv">
        <span>In the pool</span><span>{q.pool_available} of {q.pool_target}</span>
        <span>Rent now</span><span>{q.rent_mult > 1.001 ? `${num(q.rent_mult, 2)}× the base rent` : 'base rent'}</span>
        <span>Base rent, new</span><span>{usd(t.lease_usd_month)} a month</span>
        <span>Arrives</span><span>day {world.game_day + q.lease_lead_days}</span>
        <span>Standard cabin</span><span>{t.ref_seats} seats</span>
        <span>Range</span><span>{num(t.range_km)} km</span>
        <span>Runways</span><span>{['', 'any', 'not turboprop-only', 'widebody airports'][t.runway_class]}</span>
      </div>
      <p className="tiny muted">Older aircraft rent for less but burn more fuel, cost more to maintain and break down more often.</p>
    </div>
  );
}

function BasePicker({ typeId, value, onChange }: { typeId: string; value: string; onChange: (v: string) => void }) {
  const { ref } = useGame();
  const bases = useBases();
  const t = ref.type[typeId];
  const ok = (bases.data ?? []).filter((b) => (ref.airport[b.iata]?.runway_class ?? 0) >= t.runway_class);
  if (!ok.length) return <div className="card warn small">None of your bases can take a {t.name}.</div>;
  return (
    <Field label="Base it at">
      <select className="input" value={value || ok[0].iata} onChange={(e) => onChange(e.target.value)}>
        {ok.map((b) => <option key={b.iata} value={b.iata}>{ref.airport[b.iata]?.city} ({b.iata})</option>)}
      </select>
    </Field>
  );
}

function useDefaultBase(typeId: string) {
  const { ref } = useGame();
  const bases = useBases();
  return (bases.data ?? []).find((b) => (ref.airport[b.iata]?.runway_class ?? 0) >= ref.type[typeId].runway_class)?.iata ?? '';
}

function LeaseSheet({ ac, onClose, left }: { ac: Aircraft; onClose: () => void; left: number }) {
  const { ref, airline, world } = useGame();
  const market = useAircraftMarket();
  const { run, busy } = useAction();
  const nav = useNavigate();
  const def = useDefaultBase(ac.type_id);
  const [base, setBase] = useState('');
  const t = ref.type[ac.type_id]; const q = market.data!.find((x) => x.type_id === ac.type_id)!;
  const rent = poolRentUsd(t, q.rent_mult, ageYears(ac, world.game_day));
  return (
    <Sheet title={`Lease ${ac.reg}`} onClose={onClose}>
      <div className="stack">
        <div className="kv">
          <span>Aircraft</span><span>{t.name}, {num(ageYears(ac, world.game_day), 0)} years old</span>
          <span>Cabin</span><span>{ac.seats_biz ? `${ac.seats_biz} + ` : ''}{ac.seats_econ} seats</span>
          <span>Rent, about</span><span>{usd(rent)} a month</span>
          <span>Deposit, about</span><span>{inr(rent * ref.param.lease_deposit_months * world.fx_inr_usd)}</span>
          <span>Arrives</span><span>day {world.game_day + q.lease_lead_days}</span>
        </div>
        {left === 0 && <div className="card warn small">You have reached the pool limit of {ref.param.pool_lease_max_qtr} leases in 91 days. Order new or wet-lease instead.</div>}
        <BasePicker typeId={ac.type_id} value={base || def} onChange={setBase} />
        <Button block disabled={left === 0} busy={busy === 'lease'} onClick={() => run('lease', () => call<{ reg: string; arrives_day: number }>('lease_aircraft', {
          p_airline: airline.id, p_aircraft: ac.id, p_base: base || def,
        }), (r) => `${r.reg} leased. It arrives on day ${r.arrives_day}; you can plan its routes now.`).then((r) => r && nav('/fleet'))}>Lease it</Button>
      </div>
    </Sheet>
  );
}

function WetSheet({ typeId, onClose }: { typeId: string; onClose: () => void }) {
  const { ref, airline } = useGame();
  const { run, busy } = useAction();
  const nav = useNavigate();
  const def = useDefaultBase(typeId);
  const [base, setBase] = useState('');
  return (
    <Sheet title={`Wet-lease a ${ref.type[typeId].name}`} onClose={onClose}>
      <div className="stack">
        <p className="small">Use a wet lease to fill a gap while a leased or new aircraft is on its way, then end it. It cannot be refitted.</p>
        <BasePicker typeId={typeId} value={base || def} onChange={setBase} />
        <Button block busy={busy === 'wet'} onClick={() => run('wet', () => call<{ reg: string; arrives_day: number }>('wet_lease', {
          p_airline: airline.id, p_type: typeId, p_base: base || def,
        }), (r) => `${r.reg} arrives on day ${r.arrives_day}.`).then((r) => r && nav('/fleet'))}>Wet-lease it</Button>
        <Badge tone="warn">Costs about twice an operating lease</Badge>
      </div>
    </Sheet>
  );
}

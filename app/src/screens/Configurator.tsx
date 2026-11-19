// Cabin configurator: business rows and pitch, economy pitch. Used to refit an aircraft or to choose the cabin of a new order.
import { useState } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { call } from '../lib/api';
import { useAircraftMarket, useBases, useFleet, useGame, useLayout } from '../lib/data';
import { crewFor, layoutRows } from '../lib/game';
import { arrivalLabel, arrivalWeek, inr, num, pct, usd, weeks } from '../lib/format';
import { SeatMap } from '../components/SeatMap';
import { useAction } from '../components/toast';
import { Button, Empty, Field, Loading, PageHeader, Seg, Stepper } from '../components/ui';

export const DEFAULT_CABIN: Record<string, [number, number | null, number]> = {
  AT76: [0, null, 29], A20N: [0, null, 29], A21N: [0, null, 30], A21X: [3, 38, 30], A359: [9, 44, 31],
};

const comfortWord = (c: number) => (c < 0.2 ? 'Tight' : c < 0.5 ? 'Standard' : c < 0.8 ? 'Roomy' : 'Very roomy');

export function Configurator() {
  const { type: typeId } = useParams();
  const [sp] = useSearchParams();
  const { ref, airline, world } = useGame();
  const fleet = useFleet();
  const acId = sp.get('aircraft');
  const ac = acId ? fleet.data?.find((a) => a.id === acId) : undefined;
  const t = ref.type[typeId ?? ''];
  const def = DEFAULT_CABIN[typeId ?? ''] ?? [0, null, 29];
  const [bizRows, setBizRows] = useState<number | null>(null);
  const [bizPitch, setBizPitch] = useState<number | null>(null);
  const [econPitch, setEconPitch] = useState<number | null>(null);
  const br = bizRows ?? ac?.biz_rows ?? def[0];
  const bp = t?.biz_kind === 'lieflat' ? 44 : (bizPitch ?? ac?.biz_pitch ?? def[1] ?? 38);
  const ep = econPitch ?? ac?.econ_pitch ?? def[2];
  const lay = useLayout(typeId ?? '', br, br ? bp : null, ep);
  const { run, busy } = useAction();
  const nav = useNavigate();

  if (!t) return <Empty title="Unknown aircraft type" />;
  if (acId && fleet.isLoading) return <Loading h={300} />;
  const g = layoutRows(t, br, bp, ep);
  const L = lay.data;
  const maxBizRows = t.biz_kind === 'none' ? 0 : t.role === 'widebody' ? 15 : 8;
  const nextRowCrew = crewFor(g.seats + t.econ_abreast) > crewFor(g.seats);
  const changed = ac ? Math.abs((L?.seats_econ ?? g.seatsEcon) - ac.seats_econ) + Math.abs((L?.seats_biz ?? g.seatsBiz) - ac.seats_biz) : 0;
  const same = ac && br === ac.biz_rows && ep === ac.econ_pitch && (br === 0 || bp === (ac.biz_pitch ?? 44));
  const refitCost = ref.param.refit_fixed_inr + ref.param.refit_per_seat_inr * changed;

  return (
    <div className="stack-lg">
      <PageHeader back={ac ? `/aircraft/${ac.id}` : '/market'} title={ac ? `Change ${ac.reg}'s cabin` : `Choose a cabin: ${t.name}`}
        sub={`${t.name} · up to ${t.max_seats} seats · standard ${t.ref_seats}`} />
      <div className="split-side">
        <div className="card sticky-col">
          <SeatMap type={t} bizRows={br} bizPitch={bp} econPitch={ep} />
          <div className="row" style={{ justifyContent: 'center', gap: 16, marginTop: 10 }}>
            {t.biz_kind !== 'none' && <span className="row tiny"><span className="dot" style={{ background: '#7A3FD1' }} />Business {L?.seats_biz ?? g.seatsBiz}</span>}
            <span className="row tiny"><span className="dot" style={{ background: 'var(--accent)' }} />Economy {L?.seats_econ ?? g.seatsEcon}</span>
          </div>
        </div>
        <div className="stack-lg">
          <div className="grid2">
            <div className="card tight kpi"><div className="label">Seats</div><div className="value">{L?.seats ?? g.seats}</div><div className="note">{(L?.seats ?? g.seats) > t.ref_seats ? 'Denser than standard' : (L?.seats ?? g.seats) < t.ref_seats ? 'Roomier than standard' : 'Standard'}</div></div>
            <div className="card tight kpi"><div className="label">Cabin crew</div><div className="value">{L?.cabin_crew ?? crewFor(g.seats)}</div><div className="note">{nextRowCrew ? 'One more row needs another' : 'One per 50 seats'}</div></div>
            <div className="card tight kpi"><div className="label">Range, full</div><div className="value">{num(L?.range_km)} km</div><div className="note">More seats, more weight</div></div>
            <div className="card tight kpi"><div className="label">Turnaround</div><div className="value">{num(L?.min_turn_min)} min</div><div className="note">Comfort: {comfortWord(L?.comfort_econ ?? 0)}</div></div>
          </div>
          {L && !L.valid && <div className="card bad small">{L.reason}</div>}

          <div className="card stack">
            {t.biz_kind !== 'none' && (
              <Field label={`Business rows (${t.biz_abreast} seats each, ${t.biz_kind === 'lieflat' ? 'lie-flat' : 'recliners'})`}>
                <Stepper label="business rows" value={br} min={0} max={maxBizRows} onChange={setBizRows} format={(v) => (v ? `${v} rows · ${v * t.biz_abreast} seats` : 'None')} />
              </Field>
            )}
            {t.biz_kind === 'recliner' && (
              <Field label="Business pitch">
                <Stepper label="business pitch" value={bp} min={36} max={42} onChange={setBizPitch} format={(v) => (br ? `${v} in` : 'No business cabin')} disabled={!br} />
              </Field>
            )}
            <Field label="Economy pitch" hint="28 in is budget-tight, 34 in is generous.">
              <Stepper label="economy pitch" value={ep} min={28} max={34} onChange={setEconPitch} format={(v) => `${v} in`} />
            </Field>
          </div>

          <div className="card info small stack" style={{ gap: 6 }}>
            <strong>What this changes</strong>
            <span>More seats lower the cost of each seat and give you more to sell, but they shorten range and slow turnarounds.</span>
            <span>Tighter pitch lowers comfort, which travellers notice more on long flights.</span>
            <span>A business cabin only pays where many business travellers fly: busy domestic trunks and long haul.</span>
          </div>

          {ac ? (
            <div className="card stack">
              <div className="kv">
                <span>Seats changed</span><span>{changed}</span>
                <span>Cost</span><span>{inr(refitCost)}</span>
                <span>Time on the ground</span><span>{weeks(Math.max(7, Math.ceil(ref.param.refit_days / 7) * 7))}, back in week {arrivalWeek(world.game_day + 1 + ref.param.refit_days)}</span>
              </div>
              <Button block disabled={!!same || !L?.valid} busy={busy === 'refit'} onClick={() => run('refit', () => call<{ cost_inr: number; back_day: number }>('refit_aircraft', {
                p_airline: airline.id, p_aircraft: ac.id, p_biz_rows: br, p_biz_pitch: br ? bp : null, p_econ_pitch: ep,
              }), (r) => `Refit booked for ${inr(r.cost_inr)}. Back in week ${arrivalWeek(r.back_day)}.`).then((r) => r && nav(`/aircraft/${ac.id}`))}>
                {same ? 'This is the current cabin' : `Refit for ${inr(refitCost)}`}
              </Button>
            </div>
          ) : (
            <OrderBox typeId={t.id} br={br} bp={br ? bp : null} ep={ep} valid={!!L?.valid} />
          )}
        </div>
      </div>
    </div>
  );
}

function OrderBox({ typeId, br, bp, ep, valid }: { typeId: string; br: number; bp: number | null; ep: number; valid: boolean }) {
  const { ref, airline, world } = useGame();
  const bases = useBases();
  const market = useAircraftMarket();
  const t = ref.type[typeId];
  const q = market.data?.find((x) => x.type_id === typeId);
  const okBases = (bases.data ?? []).filter((b) => (ref.airport[b.iata]?.runway_class ?? 0) >= t.runway_class);
  const [base, setBase] = useState<string | null>(null);
  const [pay, setPay] = useState<'cash' | 'loan' | 'slb'>('loan');
  const [count, setCount] = useState(1);
  const { run, busy } = useAction();
  const nav = useNavigate();
  const b = base ?? okBases[0]?.iata ?? '';
  if (!q) return <Loading h={120} />;
  const priceInr = q.order_price_usd * world.fx_inr_usd;
  const dep = priceInr * (ref.param.order_deposit_share ?? 0.15);
  const wait = q.order_delivery_day - world.game_day;
  return (
    <div className="card stack">
      <h2>Order new</h2>
      <Field label="How many with this cabin">
        <Stepper label="aircraft to order" value={count} min={1} max={ref.param.bulk_max ?? 10} onChange={setCount} format={(v) => `${v} aircraft`} />
      </Field>
      <div className="kv">
        <span>Price each</span><span>{usd(q.order_price_usd)} ({inr(priceInr)})</span>
        <span>Deposit now</span><span>{inr(dep * count)}</span>
        <span>{count > 1 ? 'First delivery' : 'Delivery'}</span><span>{arrivalLabel(q.order_delivery_day, world.start_date)} · in {weeks(Math.max(7, Math.ceil(wait / 7) * 7))}</span>
      </div>
      {count > 1 && <p className="tiny muted">Each aircraft takes the next free delivery slot, so the later ones may arrive a little later. All are ordered or none is.</p>}
      <Field label="Pay the balance on delivery with">
        <Seg block value={pay} onChange={setPay} options={[{ value: 'loan', label: 'Loan' }, { value: 'cash', label: 'Cash' }, { value: 'slb', label: 'Leaseback' }]} />
      </Field>
      <p className="tiny muted">
        {pay === 'loan' && `An aircraft loan in dollars at ${pct(ref.param.loan_rate_year)} a year, repaid daily over ${ref.param.loan_years} years. You own the aircraft.`}
        {pay === 'cash' && 'Pay the full balance from cash on delivery. You own the aircraft and pay no interest. If cash is short that day, it becomes a sale and leaseback.'}
        {pay === 'slb' && `A lessor buys it on delivery and leases it back to you at ${pct(ref.param.slb_rent_mult)} of the usual rent. No big payment, but you never own it.`}
      </p>
      {okBases.length === 0 ? <div className="card warn small">None of your bases can take a {t.name}.</div> : (
        <Field label="Base it at">
          <select className="input" value={b} onChange={(e) => setBase(e.target.value)}>
            {okBases.map((x) => <option key={x.iata} value={x.iata}>{ref.airport[x.iata]?.city} ({x.iata})</option>)}
          </select>
        </Field>
      )}
      <Button block disabled={!valid || !b} busy={busy === 'order'} onClick={() => run('order', () => call<{ reg: string; arrives_day: number }[]>('order_aircraft_bulk', {
        p_airline: airline.id, p_type: typeId, p_base: b, p_count: count, p_biz_rows: br, p_biz_pitch: bp, p_econ_pitch: ep, p_pay: pay,
      }), (r) => r.length === 1 ? `${r[0].reg} ordered. It arrives on day ${r[0].arrives_day}.`
        : `${r.length} aircraft ordered. They arrive from day ${r[0].arrives_day} to day ${r[r.length - 1].arrives_day}.`).then((r) => r && nav('/fleet'))}>
        {count > 1 ? `Order ${count} for ${inr(dep * count)} deposit` : `Order for ${inr(dep)} deposit`}
      </Button>
      <p className="tiny muted">Every order joins one queue for this type, so a rush of orders lengthens everyone's wait.</p>
    </div>
  );
}

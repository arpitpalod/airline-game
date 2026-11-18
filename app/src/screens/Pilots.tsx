// Pilots: crews by fleet family against what the fleet needs, who is joining or leaving, the world market, and the four
// settings that drive hiring. The engine hires on its own every day; the player decides pay, spare pilots, cadets and
// whether to take foreign captains.
import { useState } from 'react';
import { call } from '../lib/api';
import { useEvents, useFinance, useGame, usePilots, type AirlinePilots, type PilotFamily, type PilotMove } from '../lib/data';
import { inr, num, signedPct } from '../lib/format';
import { useAction } from '../components/toast';
import { Badge, Button, Empty, Kpi, Loading, PageHeader, Seg, Stepper } from '../components/ui';

const sumMoves = (moves: PilotMove[], f: string, rank: 'c' | 'f', kinds: PilotMove['kind'][]) =>
  moves.filter((m) => m.family === f && m.rank === rank && kinds.includes(m.kind)).reduce((s, m) => s + m.n, 0);

function FamilyCard({ fam, crew, moves }: { fam: PilotFamily; crew: AirlinePilots; moves: PilotMove[] }) {
  const rows = [
    { rank: 'c' as const, label: 'Captains', have: crew.captains, joining: sumMoves(moves, fam.id, 'c', ['hire', 'expat', 'upgrade']),
      leaving: sumMoves(moves, fam.id, 'c', ['leave']) },
    { rank: 'f' as const, label: 'First officers', have: crew.fos, joining: sumMoves(moves, fam.id, 'f', ['hire', 'cadet']),
      leaving: sumMoves(moves, fam.id, 'f', ['leave']) + moves.filter((m) => m.family === fam.id && m.kind === 'upgrade').reduce((s, m) => s + m.n, 0) },
  ];
  const short = rows.map((r) => ({ ...r, short: Math.max(0, crew.need - r.have) }));
  const next = moves.filter((m) => m.family === fam.id && m.kind !== 'leave').slice(0, 4);
  const label: Record<PilotMove['kind'], string> = { hire: 'hired', expat: 'foreign', cadet: 'cadets', upgrade: 'promoted to captain', leave: 'leaving' };
  return (
    <div className="card flush">
      <div className="card-title" style={{ padding: '14px 16px 0' }}>
        <h2>{fam.name}</h2>
        {short.some((r) => r.short > 0) ? <Badge tone="warn">Short of pilots</Badge> : <Badge tone="good">Crewed</Badge>}
      </div>
      <div className="scroll-x">
        <table className="table">
          <thead><tr><th></th><th className="r">Have</th><th className="r">Need</th><th className="r">Joining</th><th className="r">Leaving</th></tr></thead>
          <tbody>
            {short.map((r) => (
              <tr key={r.rank}>
                <td>{r.label}{r.rank === 'c' && crew.expats > 0 && <div className="tiny muted">{crew.expats} foreign</div>}</td>
                <td className="r">{num(r.have)}</td>
                <td className="r">{num(crew.need)}</td>
                <td className="r">{r.joining ? `+${r.joining}` : '–'}</td>
                <td className="r">{r.leaving ? `−${r.leaving}` : '–'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div style={{ padding: '0 16px 14px' }} className="stack">
        {short.filter((r) => r.short > 0).map((r) => (
          <div key={r.rank} className="card warn small">Short of {r.short} {r.label.toLowerCase()}. Flights are cancelled when there is nobody to fly them.</div>
        ))}
        {next.length > 0 && (
          <p className="tiny muted">Next: {next.map((m) => `${m.n} ${label[m.kind]} on day ${m.due_day}`).join(' · ')}</p>
        )}
        {crew.need === 0 && crew.captains + crew.fos > 0 && <p className="tiny muted">No aircraft of this family needs crews. Pilots far above need are let go with 91 days of pay.</p>}
      </div>
    </div>
  );
}

export function Pilots() {
  const { world, ref, airline } = useGame();
  const pilots = usePilots();
  const fin = useFinance();
  const events = useEvents();
  const { run, busy } = useAction();
  const [pay, setPay] = useState<number | null>(null);
  const [buffer, setBuffer] = useState<number | null>(null);
  const [cadets, setCadets] = useState<number | null>(null);
  const [expats, setExpats] = useState<boolean | null>(null);

  if (!world.pilots) {
    return (
      <div className="stack-lg">
        <PageHeader back title="Pilots" />
        <Empty title="Pilots are not part of this world">Pilot costs are a fixed amount per aircraft here.</Empty>
      </div>
    );
  }
  if (pilots.isLoading || fin.isLoading || !pilots.data || !fin.data) return <Loading h={300} />;
  const { families, crews, moves, market } = pilots.data;
  const f = fin.data;
  const P = ref.param;
  const vPay = pay ?? f.pilot_pay, vBuf = buffer ?? f.pilot_buffer, vCad = cadets ?? f.pilot_cadets, vExp = expats ?? f.pilot_expats;
  const dirty = vPay !== f.pilot_pay || vBuf !== f.pilot_buffer || vCad !== f.pilot_cadets || vExp !== f.pilot_expats;

  const shown = families.filter((fm) => crews[fm.id] && (crews[fm.id].need > 0 || crews[fm.id].captains + crews[fm.id].fos > 0));
  const total = shown.reduce((s, fm) => s + crews[fm.id].captains + crews[fm.id].fos, 0);
  const need = shown.reduce((s, fm) => s + 2 * crews[fm.id].need, 0);
  const joining = moves.filter((m) => m.kind !== 'leave' && m.kind !== 'upgrade').reduce((s, m) => s + m.n, 0);
  const leaving = moves.filter((m) => m.kind === 'leave').reduce((s, m) => s + m.n, 0);
  const salary = shown.reduce((s, fm) => {
    const c = crews[fm.id], idx = market[fm.id]?.pay_index ?? 1;
    return s + idx * ((c.captains - c.expats) * fm.pay_c_inr_day * f.pilot_pay + c.expats * fm.pay_c_inr_day * P.pilot_expat_mult + c.fos * fm.pay_f_inr_day * f.pilot_pay);
  }, 0);
  const duty = (events.data ?? []).find((e) => e.kind === 'duty_rules');

  return (
    <div className="stack-lg">
      <PageHeader back title="Pilots" sub="Captains and first officers by fleet family" />
      <div className="grid4-d">
        <Kpi label="Pilots" value={num(total)} note={`${num(need)} needed for your fleet`} />
        <Kpi label="Joining" value={num(joining)} note="Hired, foreign and cadets on their way" />
        <Kpi label="Serving notice" value={num(leaving)} note="Resigned; they keep flying until they leave" />
        <Kpi label="Salaries a day" value={inr(salary)} note="Plus flying pay per block hour" />
      </div>
      {duty && duty.starts_day > world.game_day && (
        <div className="card warn small">Stricter duty-time rules start on day {duty.starts_day}: each pilot may fly about 10% fewer hours, so you will need about 11% more pilots.</div>
      )}

      <div className="split">
        <div className="stack-lg">
          {shown.length === 0 ? (
            <Empty title="No pilots yet">Wet-leased aircraft come with their own crew. Lease or order an aircraft and crews are hired for it automatically, to join 28 days later.</Empty>
          ) : shown.map((fm) => <FamilyCard key={fm.id} fam={fm} crew={crews[fm.id]} moves={moves} />)}

          <div className="card flush">
            <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>Pilot market</h2><span className="small muted">looking for work in this world</span></div>
            <div className="scroll-x">
              <table className="table">
                <thead><tr><th>Fleet</th><th className="r">Captains</th><th className="r">First officers</th><th className="r">Market pay</th></tr></thead>
                <tbody>
                  {families.map((fm) => {
                    const m = market[fm.id];
                    return (
                      <tr key={fm.id}>
                        <td>{fm.name}</td>
                        <td className="r">{m ? num(Math.floor(m.captains)) : '–'}</td>
                        <td className="r">{m ? num(Math.floor(m.fos)) : '–'}</td>
                        <td className="r">{m ? (Math.abs(m.pay_index - 1) < 0.005 ? 'Normal' : `${signedPct(m.pay_index - 1, 0)}`) : '–'}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            <p className="tiny muted" style={{ padding: '0 16px 14px' }}>{Object.keys(market).length === 0 ? 'The market opens on the first game day. ' : ''}Airlines paying the most get first pick each day. When captains run short, market pay rises for everyone.</p>
          </div>
        </div>

        <div className="stack-lg">
          <div className="card stack">
            <div className="card-title" style={{ marginBottom: 0 }}><h2>Hiring</h2></div>
            <p className="small muted">Crews are hired every day to cover the aircraft you fly and those arriving within {P.pilot_plan_days} days: from the market first, then by promoting your own first officers ({P.pilot_upgrade_days} days), then foreign captains if you allow them.</p>
            <div className="field">
              <label>Pay against the market · {vPay.toFixed(2)}×</label>
              <Stepper label="pilot pay" value={vPay} step={0.05} min={P.pilot_pay_min} max={P.pilot_pay_max} onChange={(v) => setPay(Math.round(v * 100) / 100)} format={(v) => `${v.toFixed(2)}×`} />
              <p className="tiny muted">Below 1× saves money but pilots resign more, and more again if a rival pays more. Captains serve {P.pilot_notice_c} days of notice, first officers {P.pilot_notice_f}.</p>
            </div>
            <div className="field">
              <label>Spare pilots · {Math.round(vBuf * 100)}% above need</label>
              <Stepper label="spare pilots" value={vBuf} step={0.05} min={0} max={P.pilot_buffer_max} onChange={(v) => setBuffer(Math.round(v * 100) / 100)} format={(v) => `${Math.round(v * 100)}%`} />
              <p className="tiny muted">Spares cost salaries every day and cover resignations, growth and stricter rules without cancelling flights.</p>
            </div>
            <div className="field">
              <label>Cadets a quarter · {vCad}</label>
              <Stepper label="cadets" value={vCad} step={5} min={0} max={P.pilot_cadets_max_qtr} onChange={setCadets} />
              <p className="tiny muted">{inr(P.pilot_cadet_inr)} each; first officers after {P.pilot_cadet_days} days. They don't depend on the market.{vCad > 0 ? ` About ${inr(vCad * P.pilot_cadet_inr)} a quarter.` : ''}</p>
            </div>
            <div className="field">
              <label>Foreign captains</label>
              <Seg value={vExp ? 'on' : 'off'} onChange={(v) => setExpats(v === 'on')}
                options={[{ value: 'off', label: 'Not allowed' }, { value: 'on', label: 'Allowed' }]} />
              <p className="tiny muted">When the market has no captains: they join in {P.pilot_expat_days} days at {P.pilot_expat_mult}× market pay.</p>
            </div>
            <Button block disabled={!dirty} busy={busy === 'save'} onClick={() => run('save', () => call('set_pilot_policy', {
              p_airline: airline.id, p_pay: vPay, p_buffer: vBuf, p_cadets: vCad, p_expats: vExp,
            }), 'Pilot settings saved').then(() => { setPay(null); setBuffer(null); setCadets(null); setExpats(null); })}>Save pilot settings</Button>
          </div>
        </div>
      </div>
    </div>
  );
}

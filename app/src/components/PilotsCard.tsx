// Pilots as one lever: two numbers (crews against need, salaries a week) and two settings (pay against the market, spare
// pilots). Hiring, promotions and foreign captains as the last resort all run on their own.
import { useState } from 'react';
import { call } from '../lib/api';
import { useFinance, useGame, usePilots } from '../lib/data';
import { inr, num, weeks } from '../lib/format';
import { useAction } from './toast';
import { Badge, Button, Sheet, Stepper } from './ui';

export function usePilotSummary() {
  const { ref } = useGame();
  const pilots = usePilots();
  const fin = useFinance();
  if (!pilots.data || !fin.data) return null;
  const { families, crews, market } = pilots.data;
  let have = 0, need = 0, salary = 0, shortC = 0, shortF = 0;
  for (const fm of families) {
    const c = crews[fm.id];
    if (!c) continue;
    const idx = market[fm.id]?.pay_index ?? 1;
    have += c.captains + c.fos; need += 2 * c.need;
    shortC += Math.max(0, c.need - c.captains); shortF += Math.max(0, c.need - c.fos);
    salary += idx * ((c.captains - c.expats) * fm.pay_c_inr_day * fin.data.pilot_pay + c.expats * fm.pay_c_inr_day * ref.param.pilot_expat_mult
      + c.fos * fm.pay_f_inr_day * fin.data.pilot_pay);
  }
  return { have, need, salary, shortC, shortF, pay: fin.data.pilot_pay, buffer: fin.data.pilot_buffer };
}

export function PilotsCard() {
  const { world } = useGame();
  const s = usePilotSummary();
  const [open, setOpen] = useState(false);
  if (!world.pilots || !s) return null;
  const short = s.shortC + s.shortF;
  return (
    <div className="card tight">
      <div className="row wrap" style={{ alignItems: 'center' }}>
        <div className="grow">
          <div className="row" style={{ gap: 8, alignItems: 'center' }}>
            <strong>Pilots</strong>
            {s.need === 0 ? <Badge>None needed yet</Badge> : short > 0 ? <Badge tone="warn">Short by {short}</Badge> : <Badge tone="good">Crewed</Badge>}
          </div>
          <div className="small muted">{s.need === 0 && s.have === 0 ? 'Wet-leased aircraft bring their own crew. Lease or order one and crews are hired for it.'
            : `${num(s.have)} of ${num(s.need)} needed · ${inr(s.salary * 7)} a week · pay ${s.pay.toFixed(2)}× market, ${Math.round(s.buffer * 100)}% spare`}</div>
        </div>
        <Button size="sm" kind="secondary" onClick={() => setOpen(true)}>Adjust pilots</Button>
      </div>
      {open && <PilotSheet pay={s.pay} buffer={s.buffer} onClose={() => setOpen(false)} />}
    </div>
  );
}

function PilotSheet({ pay, buffer, onClose }: { pay: number; buffer: number; onClose: () => void }) {
  const { ref, airline } = useGame();
  const P = ref.param;
  const { run, busy } = useAction();
  const [vPay, setPay] = useState(pay);
  const [vBuf, setBuf] = useState(buffer);
  return (
    <Sheet title="Pilots" onClose={onClose}>
      <div className="stack">
        <p className="small muted">Crews are hired on their own for the aircraft you fly and those arriving soon, and join 4 weeks later. When the market runs out of captains, first officers are promoted and then foreign captains hired at {P.pilot_expat_mult}× pay.</p>
        <div className="field">
          <label>Pay against the market · {vPay.toFixed(2)}×</label>
          <Stepper label="pilot pay" value={vPay} step={0.05} min={P.pilot_pay_min} max={P.pilot_pay_max} onChange={(v) => setPay(Math.round(v * 100) / 100)} format={(v) => `${v.toFixed(2)}×`} />
          <p className="tiny muted">Pay less and pilots resign, faster if a rival pays more; they leave after {weeks(P.pilot_notice_c)}' notice (captains). Pay more and you keep them and hire first.</p>
        </div>
        <div className="field">
          <label>Spare pilots · {Math.round(vBuf * 100)}% above need</label>
          <Stepper label="spare pilots" value={vBuf} step={0.05} min={0} max={P.pilot_buffer_max} onChange={(v) => setBuf(Math.round(v * 100) / 100)} format={(v) => `${Math.round(v * 100)}%`} />
          <p className="tiny muted">Spares cost salaries every week; without them, resignations, growth or stricter duty rules cancel flights.</p>
        </div>
        <Button block disabled={vPay === pay && vBuf === buffer} busy={busy === 'save'} onClick={() => run('save', () => call('set_pilot_policy', {
          p_airline: airline.id, p_pay: vPay, p_buffer: vBuf, p_cadets: 0, p_expats: true,
        }), 'Pilot settings saved').then((r) => r !== undefined && onClose())}>Save pilot settings</Button>
      </div>
    </Sheet>
  );
}

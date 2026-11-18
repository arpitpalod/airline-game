// Money: cash and the credit line, marketing spend, profit and loss, and one-off payments.
import { useState } from 'react';
import { call } from '../lib/api';
import { useAirlineDaily, useAirlineRow, useFinance, useGame, useQuarterlies, useTxns } from '../lib/data';
import { COST_LINES, sumDaily } from '../lib/derive';
import { inr, num, pct } from '../lib/format';
import type { AirlineDaily } from '../lib/types';
import { ProfitBars } from '../components/charts';
import { useAction } from '../components/toast';
import { Button, Field, Kpi, Loading, PageHeader, Seg, Stepper } from '../components/ui';
import { dailyNetProfit } from '../lib/derive';

type Period = '1' | '7' | '28';

export function Money() {
  const { ref, airline } = useGame();
  const row = useAirlineRow().data ?? airline;
  const fin = useFinance();
  const daily = useAirlineDaily(28);
  const txns = useTxns();
  const q = useQuarterlies();
  const { run, busy } = useAction();
  const [period, setPeriod] = useState<Period>('7');
  const [amount, setAmount] = useState('10');
  const [mkt, setMkt] = useState<number | null>(null);
  const f = fin.data;
  const days = daily.data ?? [];
  const sel = days.slice(-Number(period));
  const s = sumDaily(sel);
  const line = (k: keyof AirlineDaily) => sel.reduce((a, d) => a + (d[k] as number), 0);
  const mktLakh = mkt ?? Math.round(row.marketing_inr_day / 1e5);
  const mine = (q.data ?? []).filter((x) => x.airline_id === airline.id).slice(0, 4);
  const amt = Math.round(Number(amount) * 1e7);

  return (
    <div className="stack-lg">
      <PageHeader title="Money" sub="Cash, borrowing and results" />
      <div className="grid4-d">
        <Kpi label="Cash" value={f ? inr(f.cash_inr) : '…'} tone={f && f.cash_inr < 0 ? 'bad' : undefined} />
        <Kpi label="Borrowed" value={f ? inr(f.debt_inr) : '…'} note={`at ${pct(ref.param.interest_year)} a year`} />
        <Kpi label="Credit left" value={f ? inr(f.credit_limit_inr - f.debt_inr) : '…'} note={f ? `of ${inr(f.credit_limit_inr)}` : ''} />
        <Kpi label="Seats sold" value={s.ask ? pct(s.rpk / s.ask) : '–'} note={`last ${period === '1' ? 'day' : `${period} days`}`} />
      </div>

      <div className="split">
        <div className="stack-lg">
          <div className="card stack">
            <div className="card-title" style={{ marginBottom: 0 }}>
              <h2>Profit and loss</h2>
              <Seg value={period} onChange={setPeriod} options={[{ value: '1', label: 'Day' }, { value: '7', label: '7 days' }, { value: '28', label: '28 days' }]} />
            </div>
            {daily.isLoading ? <Loading /> : sel.length === 0 ? <p className="small muted">Results appear after the first game day with flights.</p> : (
              <table className="table">
                <tbody>
                  <tr><td>Tickets</td><td className="r">{inr(line('rev_ticket'))}</td></tr>
                  <tr><td>Extras (bags, seats, food)</td><td className="r">{inr(line('rev_anc'))}</td></tr>
                  <tr><td className="strong">Revenue</td><td className="r strong">{inr(s.revenue)}</td></tr>
                  {COST_LINES.map((c) => { const v = line(c.key); return v ? <tr key={c.key}><td className="muted">{c.label}</td><td className="r muted">−{inr(v).replace('−', '')}</td></tr> : null; })}
                  <tr><td className="strong">Operating profit</td><td className={`r strong ${s.opProfit >= 0 ? 'good' : 'bad'}`}>{inr(s.opProfit, { sign: true })} · {s.revenue ? pct(s.opProfit / s.revenue) : '–'}</td></tr>
                  <tr><td className="muted">Interest</td><td className="r muted">{line('c_interest') ? `−${inr(line('c_interest'))}` : inr(0)}</td></tr>
                  <tr><td className="strong">Profit after interest</td><td className={`r strong ${s.netProfit >= 0 ? 'good' : 'bad'}`}>{inr(s.netProfit, { sign: true })}</td></tr>
                </tbody>
              </table>
            )}
            {s.ask > 0 && (
              <div className="grid3">
                <div><div className="tiny muted">Revenue per seat-km</div><div className="num strong">₹{num(s.revenue / s.ask, 2)}</div></div>
                <div><div className="tiny muted">Cost per seat-km</div><div className="num strong">₹{num(s.opCost / s.ask, 2)}</div></div>
                <div><div className="tiny muted">Passengers</div><div className="num strong">{num(s.pax)}</div></div>
              </div>
            )}
          </div>
          <div className="card">
            <div className="card-title"><h2>Profit by day</h2></div>
            <ProfitBars points={days.map((d) => ({ day: d.game_day, v: dailyNetProfit(d) }))} />
          </div>
        </div>

        <div className="stack-lg">
          <div className="card stack">
            <h2>Credit line</h2>
            <p className="small muted">Actions need cash in hand, so borrow before a big payment. A daily shortfall is drawn from the credit line automatically. If cash stays below zero with the line used up for {ref.param.insolvency_days} days, the airline goes into administration.</p>
            <Field label="Amount (₹ crore)">
              <input className="input num" type="number" inputMode="decimal" min={0} value={amount} onChange={(e) => setAmount(e.target.value)} />
            </Field>
            <div className="grid2">
              <Button busy={busy === 'borrow'} disabled={!amt} onClick={() => run('borrow', () => call('borrow', { p_airline: airline.id, p_amount: amt }), `Borrowed ${inr(amt)}`)}>Borrow</Button>
              <Button kind="secondary" busy={busy === 'repay'} disabled={!amt} onClick={() => run('repay', () => call('repay', { p_airline: airline.id, p_amount: amt }), `Repaid ${inr(amt)}`)}>Repay</Button>
            </div>
          </div>
          <div className="card stack">
            <h2>Marketing</h2>
            <p className="small muted">Marketing lifts your brand, and brand brings passengers. It works best measured against how many passengers you carry: about ₹100 a day per daily passenger buys most of the effect.</p>
            <Stepper label="marketing a day" value={mktLakh} step={1} min={0} max={Math.round(ref.param.marketing_max_inr_day / 1e5)} onChange={setMkt}
              format={(v) => (v ? `${inr(v * 1e5)} a day` : 'None')} />
            <Button kind="secondary" disabled={mkt == null || mkt * 1e5 === row.marketing_inr_day} busy={busy === 'mkt'}
              onClick={() => run('mkt', () => call('set_marketing', { p_airline: airline.id, p_inr_day: mktLakh * 1e5 }), 'Marketing spend saved').then(() => setMkt(null))}>Save marketing</Button>
          </div>
          {mine.length > 0 && (
            <div className="card flush">
              <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>Quarterly results</h2></div>
              <table className="table">
                <thead><tr><th>Quarter</th><th className="r">Revenue</th><th className="r">Profit</th><th className="r">Rank</th></tr></thead>
                <tbody>{mine.map((x) => <tr key={x.quarter}><td>Q{x.quarter}</td><td className="r">{inr(x.revenue)}</td><td className="r">{inr(x.net_profit, { sign: true })}</td><td className="r">{x.rank ?? '–'}</td></tr>)}</tbody>
              </table>
            </div>
          )}
          <div className="card flush">
            <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>One-off payments</h2></div>
            <div className="list" style={{ maxHeight: 360, overflowY: 'auto' }}>
              {(txns.data ?? []).map((x) => (
                <div key={x.id} className="item small">
                  <span className="faint num" style={{ width: 52 }}>Day {x.game_day}</span>
                  <span className="grow">{x.note || x.kind}</span>
                  <span className={`num ${x.amount_inr >= 0 ? 'good' : ''}`}>{inr(x.amount_inr, { sign: true })}</span>
                </div>
              ))}
              {txns.data?.length === 0 && <div className="item small muted">None yet.</div>}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

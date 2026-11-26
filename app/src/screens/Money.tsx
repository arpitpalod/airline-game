// Money: cash and the credit line, marketing spend, profit and loss, and one-off payments.
import { useState } from 'react';
import { call } from '../lib/api';
import { useAirlineDaily, useAirlineRow, useAirlineWeeks, useFinance, useFleet, useGame, useQuarterlies, useTxns } from '../lib/data';
import { byWeek, COST_LINES, sumDaily } from '../lib/derive';
import { inr, num, pct, typedUnit, unit, weekOf, weeks } from '../lib/format';
import type { AirlineDaily, AirlineWeek, Txn } from '../lib/types';
import { ProfitBars } from '../components/charts';
import { useAction } from '../components/toast';
import { Button, Field, Kpi, Loading, PageHeader, Seg, Stepper } from '../components/ui';

type Period = '7' | '28' | '91';
type Tab = 'profit' | 'cash' | 'balance';

export function Money() {
  const { ref, airline, world } = useGame();
  const row = useAirlineRow().data ?? airline;
  const fin = useFinance();
  const daily = useAirlineDaily(91);
  const txns = useTxns();
  const q = useQuarterlies();
  const { run, busy } = useAction();
  const [period, setPeriod] = useState<Period>('7');
  const [tab, setTab] = useState<Tab>('profit');
  const [amount, setAmount] = useState('10');
  const [mkt, setMkt] = useState<number | null>(null);
  const f = fin.data;
  const days = daily.data ?? [];
  const sel = days.filter((d) => d.game_day > world.game_day - Number(period));
  const s = sumDaily(sel);
  const line = (k: keyof AirlineDaily) => sel.reduce((a, d) => a + Number(d[k] ?? 0), 0);
  const mktLakh = mkt ?? Math.round((row.marketing_inr_day * 7) / 1e5);   // set by the day in the database, shown by the week
  const mine = (q.data ?? []).filter((x) => x.airline_id === airline.id).slice(0, 4);
  const amt = Math.round(typedUnit().toInternal(Number(amount)));
  const owed = Number(f?.debt_inr ?? 0), cashNow = Number(f?.cash_inr ?? 0);
  const creditLeft = Math.max(0, Number(f?.credit_limit_inr ?? 0) - owed);

  return (
    <div className="stack-lg">
      <PageHeader title="Money" sub="Cash, borrowing and results" />
      <div className="grid4-d">
        <Kpi label="Cash" value={f ? inr(f.cash_inr) : '…'} tone={f && f.cash_inr < 0 ? 'bad' : undefined} note={ref.param.cash_interest_year ? `earns ${pct(ref.param.cash_interest_year)} a year` : undefined} />
        <Kpi label="Borrowed" value={f ? inr(f.debt_inr) : '…'} note={`at ${pct(ref.param.interest_year)} a year`} />
        <Kpi label="Credit left" value={f ? inr(f.credit_limit_inr - f.debt_inr) : '…'} note={f ? `of ${inr(f.credit_limit_inr)}` : ''} />
        <Kpi label="Seats sold" value={s.ask ? pct(s.rpk / s.ask) : '–'} note={period === '7' ? 'last week' : `last ${weeks(Number(period))}`} />
      </div>

      {world.selling && <Seg value={tab} onChange={setTab} block options={[{ value: 'profit', label: 'Profit' }, { value: 'cash', label: 'Cash flow' }, { value: 'balance', label: 'Balance sheet' }]} />}
      <div className="split">
        <div className="stack-lg">
          {tab === 'cash' && <CashFlow days={days} txns={txns.data ?? []} />}
          {tab === 'balance' && <BalanceSheet />}
          {tab === 'profit' && <>
          <div className="card stack">
            <div className="card-title" style={{ marginBottom: 0 }}>
              <h2>Profit and loss</h2>
              <Seg value={period} onChange={setPeriod} options={[{ value: '7', label: 'Week' }, { value: '28', label: '4 weeks' }, { value: '91', label: 'Quarter' }]} />
            </div>
            {daily.isLoading ? <Loading /> : sel.length === 0 ? <p className="small muted">Results appear after your first week of flying.</p> : (
              <table className="table">
                <tbody>
                  <tr><td>Tickets</td><td className="r">{inr(line('rev_ticket'))}</td></tr>
                  <tr><td><a href="#/extras">Extras (bags, seats, meals)</a></td><td className="r">{inr(line('rev_anc'))}</td></tr>
                  <tr><td className="strong">Revenue</td><td className="r strong">{inr(s.revenue)}</td></tr>
                  {COST_LINES.map((c) => { const v = sel.reduce((a, d) => a + c.of(d), 0); return Math.round(v) ? <tr key={c.key}><td className="muted">{c.label}</td><td className="r muted">−{inr(v).replace('−', '')}</td></tr> : null; })}
                  <tr><td className="strong">Operating profit</td><td className={`r strong ${s.opProfit >= 0 ? 'good' : 'bad'}`}>{inr(s.opProfit, { sign: true })} · {s.revenue ? pct(s.opProfit / s.revenue) : '–'}</td></tr>
                  <tr><td className="muted">Interest paid</td><td className="r muted">{line('c_interest') ? `−${inr(line('c_interest'))}` : inr(0)}</td></tr>
                  {line('i_cash') > 0 && <tr><td className="muted">Interest on cash, at {pct(ref.param.cash_interest_year ?? 0)} a year</td><td className="r muted">+{inr(line('i_cash'))}</td></tr>}
                  {line('c_tax') > 0 && <tr><td className="muted">Tax on the quarter's profit, at {pct(ref.param.tax_rate ?? 0)}</td><td className="r muted">−{inr(line('c_tax'))}</td></tr>}
                  <tr><td className="strong">Profit after interest and tax</td><td className={`r strong ${s.netProfit >= 0 ? 'good' : 'bad'}`}>{inr(s.netProfit, { sign: true })}</td></tr>
                </tbody>
              </table>
            )}
            {s.ask > 0 && (
              <div className="grid3">
                <div><div className="tiny muted">Revenue per seat-km</div><div className="num strong">{unit(s.revenue / s.ask, 2)}</div></div>
                <div><div className="tiny muted">Cost per seat-km</div><div className="num strong">{unit(s.opCost / s.ask, 2)}</div></div>
                <div><div className="tiny muted">Passengers</div><div className="num strong">{num(s.pax)}</div></div>
              </div>
            )}
          </div>
          <div className="card">
            <div className="card-title"><h2>Profit by week</h2><span className="small muted">after interest and tax</span></div>
            <ProfitBars points={byWeek(days).map((w) => ({ day: w.week, v: w.netProfit }))} />
          </div>
          </>}
        </div>

        <div className="stack-lg">
          <div className="card stack">
            <h2>Credit line</h2>
            <p className="small muted">Actions need cash in hand, so borrow before a big payment. A shortfall is drawn from the credit line automatically. If cash stays below zero with the line used up for {weeks(ref.param.insolvency_days)}, the airline goes into administration.</p>
            {f?.credit_cut_from != null && (
              <div className="card warn small">The bank cut your credit line from {inr(f.credit_cut_from)} to {inr(f.credit_limit_inr)}: you owe more than {num(ref.param.credit_debt_limit)} times the last 4 quarters' operating profit{f.debt_inr > 0 ? ', or those quarters lost money' : ''}. The full line returns once you are back within that.</div>
            )}
            {f?.credit_cut_from == null && ref.param.credit_debt_limit > 0 && (
              <p className="tiny muted">The banks in this world watch debt: from your fifth quarter, owing more than {num(ref.param.credit_debt_limit)} times the last 4 quarters' operating profit (or any debt while they lose money) halves the credit line until you are back within it.</p>
            )}
            <Field label={`Amount (${typedUnit().label})`} hint={`Borrow up to ${inr(creditLeft)}${owed > 0 ? `; repay up to ${inr(Math.min(owed, Math.max(0, cashNow)))}` : '; nothing to repay'}.`}>
              <input className="input num" type="number" inputMode="decimal" min={0} value={amount} onChange={(e) => setAmount(e.target.value)} />
            </Field>
            {amt > creditLeft && amt > 0 && <div className="small bad-ink">That is more than the {inr(creditLeft)} your credit line has left.</div>}
            <div className="grid2">
              <Button busy={busy === 'borrow'} disabled={!amt || amt > creditLeft} onClick={() => run('borrow', () => call('borrow', { p_airline: airline.id, p_amount: amt }), `Borrowed ${inr(amt)}`)}>Borrow</Button>
              <Button kind="secondary" busy={busy === 'repay'} disabled={!amt || owed <= 0 || amt > owed || amt > cashNow} onClick={() => run('repay', () => call('repay', { p_airline: airline.id, p_amount: amt }), `Repaid ${inr(amt)}`)}>Repay</Button>
            </div>
          </div>
          <div className="card stack">
            <h2>Marketing</h2>
            <p className="small muted">Marketing lifts your brand, and brand brings passengers. It works best measured against how many passengers you carry: about {unit(100, 0)} for every passenger you carry buys most of the effect.</p>
            <Stepper label="marketing a week" value={mktLakh} step={1} min={0} max={Math.floor((ref.param.marketing_max_inr_day * 7) / 1e5)} onChange={setMkt}
              format={(v) => (v ? `${inr(v * 1e5)} a week` : 'None')} />
            <Button kind="secondary" disabled={mkt == null || mkt === Math.round((row.marketing_inr_day * 7) / 1e5)} busy={busy === 'mkt'}
              onClick={() => run('mkt', () => call('set_marketing', { p_airline: airline.id, p_inr_day: Math.round((mktLakh * 1e5) / 7) }), 'Marketing spend saved').then(() => setMkt(null))}>Save marketing</Button>
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
                  <span className="faint num" style={{ width: 58 }}>Wk {weekOf(Math.max(x.game_day, 1))}</span>
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

// Cash flow by week (selling worlds): tickets are paid for when sold, so cash and profit part ways.
const CASH_COSTS: (keyof AirlineDaily)[] = ['c_fuel', 'c_crew', 'c_maint', 'c_airport', 'c_rent', 'c_slots', 'c_dist', 'c_marketing', 'c_overhead', 'c_interest', 'loan_repaid', 'c_insurance'];
function CashFlow({ days, txns }: { days: AirlineDaily[]; txns: Txn[] }) {
  const { world } = useGame();
  const aw = useAirlineWeeks();
  const last = Math.floor(world.game_day / 7);
  const cols = [last - 2, last - 1, last].filter((w) => w >= 1);
  if (aw.isLoading) return <div className="card"><Loading /></div>;
  const wk = (w: number) => {
    const a: AirlineWeek | undefined = (aw.data ?? []).find((x) => x.week === w);
    const ds = days.filter((d) => weekOf(d.game_day) === w);
    const sum = (k: keyof AirlineDaily) => ds.reduce((s, d) => s + Number(d[k] ?? 0), 0);
    const sales = a?.sales_inr ?? 0;
    const extras = sum('rev_anc');
    // 0033: compensation for cancelled flights comes as one-off payments; it counts with refunds here
    const wkTx = txns.filter((x) => weekOf(Math.max(1, x.game_day)) === w);
    const cancelComp = -wkTx.filter((x) => x.kind === 'cancellation').reduce((s, x) => s + Number(x.amount_inr), 0);
    const refunds = (a?.refunds_inr ?? 0) + (a?.comp_inr ?? 0) + sum('refunds_inr') + cancelComp;
    const costs = CASH_COSTS.reduce((s, k) => s + sum(k), 0) - sum('i_cash');
    const other = wkTx.filter((x) => x.kind !== 'denied_boarding' && x.kind !== 'cancellation').reduce((s, x) => s + Number(x.amount_inr), 0);
    return { sales, extras, refunds, costs, other, net: sales + extras - refunds - costs + other, advance: a?.advance_inr ?? null };
  };
  const data = cols.map((w) => ({ w, ...wk(w) }));
  const row = (label: string, k: keyof ReturnType<typeof wk>, neg = false, strong = false) => (
    <tr className={strong ? 'strong' : ''}><td className={strong ? '' : 'muted'}>{label}</td>
      {data.map((d) => { const v = Number(d[k] ?? 0); return <td key={d.w} style={{ whiteSpace: 'nowrap' }} className={`r ${strong ? (v >= 0 ? 'good' : 'bad') : 'muted'}`}>{neg && v ? '−' : ''}{inr(Math.abs(v), { sign: strong })}</td>; })}</tr>
  );
  return (
    <div className="card flush">
      <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>Cash flow</h2><span className="small muted">by week</span></div>
      {data.length === 0 ? <p className="small muted" style={{ padding: '0 16px 14px' }}>Cash flow appears after the first week.</p> : (
        <div className="scroll-x">
          <table className="table">
            <thead><tr><th /> {data.map((d) => <th key={d.w} className="r">Wk {d.w}</th>)}</tr></thead>
            <tbody>
              {row('Tickets sold', 'sales')}
              {row('Extras', 'extras')}
              {row('Refunds and compensation', 'refunds', true)}
              {row('Running costs, less interest earned', 'costs', true)}
              {row('Aircraft, deposits, tax and other', 'other')}
              {row('Net cash', 'net', false, true)}
              <tr><td className="muted">Advance sales at the end</td>{data.map((d) => <td key={d.w} style={{ whiteSpace: 'nowrap' }} className="r muted">{d.advance != null ? inr(d.advance) : '–'}</td>)}</tr>
            </tbody>
          </table>
        </div>
      )}
      <p className="tiny muted" style={{ padding: '0 16px 14px' }}>Tickets are paid for when they are sold, up to 26 weeks before the flight. Revenue counts when the flight flies, so a week's profit and its cash differ. Advance sales are tickets sold for flights still to come.</p>
    </div>
  );
}

// What the airline owns and owes, now. Net worth here is the one the quarterly ranking uses.
function BalanceSheet() {
  const { ref, world } = useGame();
  const fin = useFinance();
  const fleet = useFleet();
  const aw = useAirlineWeeks();
  if (!fin.data || fleet.isLoading || aw.isLoading) return <div className="card"><Loading /></div>;
  const f = fin.data;
  const terms = (fleet.data ?? []).map((a) => a.terms).filter((t): t is NonNullable<typeof t> => !!t);
  const book = terms.filter((t) => t.holding === 'owned' && t.ordered_day == null && t.price_usd)
    .reduce((s, t) => s + t.price_usd! * world.fx_inr_usd * Math.max(ref.param.book_value_floor, 1 - ref.param.depreciation_year * Math.max(0, world.game_day - (t.start_day ?? world.game_day)) / 364), 0);
  const deposits = terms.reduce((s, t) => s + Number(t.deposit_inr ?? 0), 0);
  const loans = terms.reduce((s, t) => s + Number(t.loan_usd ?? 0) * world.fx_inr_usd + Number(t.loan_inr ?? 0), 0);
  const latest = [...(aw.data ?? [])].sort((a, b) => b.week - a.week)[0];
  const advance = latest?.advance_inr ?? 0;
  const assets = f.cash_inr + book + deposits;
  const owed = advance + f.debt_inr + loans;
  return (
    <div className="card flush">
      <div className="card-title" style={{ padding: '14px 16px 0' }}><h2>Balance sheet</h2><span className="small muted">now</span></div>
      <table className="table">
        <tbody>
          <tr><td className="muted">Cash</td><td className="r">{inr(f.cash_inr)}</td></tr>
          <tr><td className="muted">Aircraft you own (book value)</td><td className="r">{inr(book)}</td></tr>
          <tr><td className="muted">Deposits with lessors and makers</td><td className="r">{inr(deposits)}</td></tr>
          <tr className="strong"><td>What you own</td><td className="r">{inr(assets)}</td></tr>
          <tr><td className="muted">Advance sales (flights still to fly)</td><td className="r">{inr(advance)}</td></tr>
          <tr><td className="muted">Credit line used</td><td className="r">{inr(f.debt_inr)}</td></tr>
          <tr><td className="muted">Aircraft loans</td><td className="r">{inr(loans)}</td></tr>
          <tr className="strong"><td>What you owe</td><td className="r">{inr(owed)}</td></tr>
          <tr className="strong"><td>Net worth</td><td className={`r ${assets - owed >= 0 ? 'good' : 'bad'}`}>{inr(assets - owed, { sign: true })}</td></tr>
        </tbody>
      </table>
      <p className="tiny muted" style={{ padding: '0 16px 14px' }}>Net worth is what the quarterly ranking counts, with five times the last four quarters' profit.</p>
    </div>
  );
}

// Cash in hand against a cost: a payment larger than the cash in hand is refused (game.book), whatever the credit line,
// so the screens say so before the tap and point to Money.
import type { ComponentProps } from 'react';
import { Link } from 'react-router-dom';
import { useFinance } from '../lib/data';
import { inr } from '../lib/format';
import { Button } from './ui';

/** How much cash is missing for a payment of this size: 0 when there is enough (or before the books load). */
export function useShort(cost: number) {
  const fin = useFinance();
  if (!fin.data || !(cost > 0)) return 0;
  return Math.max(0, Math.ceil(cost - Number(fin.data.cash_inr)));
}

export function ShortNote({ cost }: { cost: number }) {
  const fin = useFinance();
  const short = useShort(cost);
  if (!short || !fin.data) return null;
  const left = Math.max(0, Number(fin.data.credit_limit_inr) - Number(fin.data.debt_inr));
  return (
    <div className="card warn small">
      This needs {inr(cost)} in cash and you have {inr(Number(fin.data.cash_inr))}: {inr(short)} short.{' '}
      {left >= short ? <>Borrow it on <Link to="/money">Money</Link> first.</> : <>Your credit line has {inr(left)} left, so free up cash first.</>}
    </div>
  );
}

/** A button for a payment: says what is missing and stays off while the cash in hand is short. */
export function CashButton({ cost, disabled, ...rest }: ComponentProps<typeof Button> & { cost: number }) {
  const short = useShort(cost);
  return (
    <>
      <ShortNote cost={cost} />
      <Button {...rest} disabled={disabled || short > 0} />
    </>
  );
}

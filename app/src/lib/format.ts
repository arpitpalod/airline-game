// Money and numbers the way Indian readers expect: lakh and crore, en-IN grouping.

const group = new Intl.NumberFormat('en-IN', { maximumFractionDigits: 0 });

export function num(x: number | null | undefined, digits = 0) {
  if (x == null || !isFinite(x)) return '–';
  return new Intl.NumberFormat('en-IN', { maximumFractionDigits: digits, minimumFractionDigits: digits }).format(x);
}

/** ₹12.3 cr, ₹4.2 lakh, ₹12,345. Signed when asked. */
export function inr(x: number | null | undefined, opts: { sign?: boolean; digits?: number } = {}) {
  if (x == null || !isFinite(x)) return '–';
  const s = x < 0 ? '−' : opts.sign && x > 0 ? '+' : '';
  const a = Math.abs(x);
  let body: string;
  if (a >= 1e7) body = `${trim(a / 1e7, opts.digits ?? (a >= 1e9 ? 0 : a >= 1e8 ? 1 : 2))} cr`;
  else if (a >= 1e5) body = `${trim(a / 1e5, opts.digits ?? 1)} lakh`;
  else body = group.format(Math.round(a));
  return `${s}₹${body}`;
}

function trim(v: number, d: number) {
  return new Intl.NumberFormat('en-IN', { maximumFractionDigits: d }).format(v);
}

export function usd(x: number | null | undefined) {
  if (x == null || !isFinite(x)) return '–';
  const a = Math.abs(x);
  const s = x < 0 ? '−' : '';
  if (a >= 1e6) return `${s}$${trim(a / 1e6, 1)}M`;
  if (a >= 1e4) return `${s}$${trim(a / 1e3, 0)}k`;
  return `${s}$${group.format(Math.round(a))}`;
}

export function pct(x: number | null | undefined, digits = 0) {
  if (x == null || !isFinite(x)) return '–';
  return `${(x * 100).toFixed(digits)}%`;
}

export function signedPct(x: number | null | undefined, digits = 0) {
  if (x == null || !isFinite(x)) return '–';
  return `${x > 0 ? '+' : x < 0 ? '−' : ''}${Math.abs(x * 100).toFixed(digits)}%`;
}

/** Game calendar: day 1 is the first day of year 1; years are 364 days, quarters 91. */
export function gameDate(day: number) {
  const d = Math.max(day, 1) - 1;
  return { year: Math.floor(d / 364) + 1, quarter: Math.floor((d % 364) / 91) + 1 };
}
export function dayLabel(day: number) {
  const { year, quarter } = gameDate(day);
  return `Day ${day} · Y${year} Q${quarter}`;
}

/** Game days as real time at the world's speed. */
export function realSpan(gameDays: number, speed: number) {
  const hours = (gameDays * 24) / speed;
  if (hours < 1.5) return `${Math.max(1, Math.round(hours * 60))} min`;
  if (hours < 36) return `${Math.round(hours)} hours`;
  const days = hours / 24;
  if (days < 14) return `${Math.round(days)} days`;
  return `${Math.round(days / 7)} weeks`;
}

export function plural(n: number, one: string, many = `${one}s`) {
  return `${num(n)} ${n === 1 ? one : many}`;
}

// Festivals and events (migration 0022): when they fall in the game calendar and which markets they touch.
import type { Airport, DemandEvent } from './types';

export interface EventDates { e: DemandEvent; start: number; end: number }

/** The events running on or starting within `horizon` days of `day`, in date order. A game year is 364 days. */
export function upcomingEvents(events: DemandEvent[], day: number, horizon: number): EventDates[] {
  const y0 = Math.floor((Math.max(day, 1) - 1) / 364);
  const out: EventDates[] = [];
  for (const e of events) {
    for (const y of [y0 - 1, y0, y0 + 1]) {
      const start = y * 364 + e.start_doy;
      const end = start + e.days - 1;
      if (end >= day && start <= day + horizon) out.push({ e, start, end });
    }
  }
  return out.sort((a, b) => a.start - b.start);
}

/** Whether an event touches the market between two airports (the same test as the selling engine). */
export function touches(e: DemandEvent, a: string, b: string, airport: Record<string, Airport>): boolean {
  const pa = airport[a], pb = airport[b];
  if (!pa || !pb) return false;
  const intl = !pa.is_india || !pb.is_india;
  if (e.domestic != null && e.domestic === intl) return false;
  if (e.airports && !e.airports.includes(a) && !e.airports.includes(b)) return false;
  if (e.regions && !e.regions.includes(pa.region) && !e.regions.includes(pb.region)) return false;
  return true;
}

/** "+30% leisure · +30% budget · −10% business" */
export function effectText(e: DemandEvent): string {
  const part = (x: number, who: string) => {
    const p = Math.round((Number(x) - 1) * 100);
    return p === 0 ? null : `${p > 0 ? '+' : '−'}${Math.abs(p)}% ${who}`;
  };
  return [part(e.lei, 'leisure'), part(e.bud, 'budget'), part(e.biz, 'business')].filter(Boolean).join(' · ');
}

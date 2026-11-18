// To-scale cabin drawing: row spacing follows pitch, so tighter pitch visibly packs more rows.
import type { ReactElement } from 'react';
import type { AircraftType } from '../lib/types';
import { layoutRows } from '../lib/game';

export function SeatMap({ type, bizRows, bizPitch, econPitch }: { type: AircraftType; bizRows: number; bizPitch: number | null; econPitch: number }) {
  const g = layoutRows(type, bizRows, bizPitch, econPitch);
  const bp = bizRows > 0 ? (type.biz_kind === 'lieflat' ? 44 : bizPitch ?? 38) : 0;
  const scale = 0.62;                              // px per inch of cabin length
  const seatW = 13, aisle = 12;
  const cols = (n: number) => {                    // seat x positions with aisles: 2-2, 3-3, 3-3-3
    const groups = n === 4 ? [2, 2] : n === 6 ? [3, 3] : n === 9 ? [3, 3, 3] : [n];
    const xs: number[] = []; let x = 0;
    groups.forEach((k, gi) => { for (let i = 0; i < k; i++) { xs.push(x); x += seatW + 2; } if (gi < groups.length - 1) x += aisle; });
    return { xs, w: x - 2 };
  };
  const ec = cols(type.econ_abreast), bc = cols(type.biz_abreast || 4);
  const width = Math.max(ec.w, bc.w) + 24;
  const lenPx = type.cabin_len_in * scale + 40;
  const seats: ReactElement[] = [];
  let y = 20;
  for (let r = 0; r < bizRows; r++) {
    const off = (width - bc.w) / 2;
    bc.xs.forEach((x, i) => seats.push(<rect key={`b${r}-${i}`} x={off + x - 2} y={y} width={seatW + 4} height={bp * scale - 4} rx="4" fill="#7A3FD1" opacity=".85" />));
    y += bp * scale;
  }
  const off = (width - ec.w) / 2;
  let left = g.seatsEcon;
  for (let r = 0; r < g.econRows && left > 0; r++) {
    ec.xs.forEach((x, i) => { if (left-- > 0) seats.push(<rect key={`e${r}-${i}`} x={off + x} y={y} width={seatW} height={Math.max(6, econPitch * scale - 5)} rx="3" fill="var(--accent)" />); });
    y += econPitch * scale;
  }
  return (
    <svg viewBox={`0 0 ${width} ${lenPx}`} style={{ height: 460, maxWidth: '100%', display: 'block', margin: '0 auto' }}
      role="img" aria-label={`${g.seatsBiz} business and ${g.seatsEcon} economy seats`}>
      <rect x="2" y="2" width={width - 4} height={lenPx - 4} rx={width / 2.2} fill="#fff" stroke="var(--line-strong)" />
      {seats}
    </svg>
  );
}

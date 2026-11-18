// Small SVG charts. Load factor is drawn against the healthy 80 to 88% band; profit as bars above and below zero.
import { inr, pct } from '../lib/format';

export function LoadChart({ points, height = 140 }: { points: { day: number; lf: number | null }[]; height?: number }) {
  const W = 420, H = height, L = 34, R = 8, T = 10, B = 22;
  const pts = points.filter((p) => p.lf != null) as { day: number; lf: number }[];
  if (pts.length === 0) return <div className="empty small">No flights yet. Results appear the day after an aircraft flies.</div>;
  const d0 = pts[0].day, d1 = Math.max(pts[pts.length - 1].day, d0 + 1);
  const x = (d: number) => L + ((d - d0) / (d1 - d0)) * (W - L - R);
  const y = (v: number) => T + (1 - v) * (H - T - B);
  const line = pts.map((p, i) => `${i ? 'L' : 'M'}${x(p.day).toFixed(1)},${y(p.lf).toFixed(1)}`).join('');
  const last = pts[pts.length - 1];
  return (
    <svg viewBox={`0 0 ${W} ${H}`} width="100%" role="img" aria-label={`Load factor, latest ${pct(last.lf)}`}>
      <rect x={L} y={y(0.88)} width={W - L - R} height={y(0.8) - y(0.88)} fill="var(--accent-soft)" />
      {[0, 0.5, 1].map((v) => (
        <g key={v}>
          <line x1={L} x2={W - R} y1={y(v)} y2={y(v)} stroke="var(--line)" />
          <text x={L - 6} y={y(v) + 4} textAnchor="end" fontSize="11" fill="var(--muted)">{v * 100}%</text>
        </g>
      ))}
      <text x={W - R - 4} y={y(0.88) - 4} textAnchor="end" fontSize="10" fill="var(--accent-strong)">healthy 80–88%</text>
      <path d={line} fill="none" stroke="var(--accent)" strokeWidth="2.5" strokeLinejoin="round" />
      <circle cx={x(last.day)} cy={y(last.lf)} r="4" fill="var(--accent)" />
      <text x={L} y={H - 6} fontSize="11" fill="var(--muted)">Day {d0}</text>
      <text x={W - R} y={H - 6} textAnchor="end" fontSize="11" fill="var(--muted)">Day {last.day}</text>
    </svg>
  );
}

export function ProfitBars({ points, height = 140 }: { points: { day: number; v: number }[]; height?: number }) {
  const W = 420, H = height, L = 8, R = 8, T = 8, B = 22;
  if (points.length === 0) return <div className="empty small">Daily results appear once the world is running.</div>;
  const max = Math.max(1, ...points.map((p) => Math.abs(p.v)));
  const zero = T + (H - T - B) / 2;
  const scale = (H - T - B) / 2 / max;
  const bw = (W - L - R) / Math.max(points.length, 7);
  const last = points[points.length - 1];
  return (
    <svg viewBox={`0 0 ${W} ${H}`} width="100%" role="img" aria-label={`Daily profit, latest ${inr(last.v)}`}>
      <line x1={L} x2={W - R} y1={zero} y2={zero} stroke="var(--line-strong)" />
      {points.map((p, i) => {
        const h = Math.max(1, Math.abs(p.v) * scale);
        return <rect key={p.day} x={L + i * bw + bw * 0.15} width={bw * 0.7} y={p.v >= 0 ? zero - h : zero} height={h} rx="2"
          fill={p.v >= 0 ? 'var(--accent)' : '#E8891C'}><title>Day {p.day}: {inr(p.v)}</title></rect>;
      })}
      <text x={L} y={H - 6} fontSize="11" fill="var(--muted)">Day {points[0].day}</text>
      <text x={W - R} y={H - 6} textAnchor="end" fontSize="11" fill="var(--muted)">Day {last.day}</text>
    </svg>
  );
}

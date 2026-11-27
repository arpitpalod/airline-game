// Vector map drawn on the device (no tile service): countries from world-atlas, airports and routes on top.
// Drag to pan, wheel or pinch to zoom; India and World buttons reset the view.
import { money } from '../lib/format';
import { geoMercator, geoPath } from 'd3-geo';
import { feature } from 'topojson-client';
import { useMemo, useRef, useState, type PointerEvent as RPE } from 'react';
import world from 'world-atlas/countries-110m.json';
import type { Airport } from '../lib/types';

const W = 1000, H = 640;
const proj = geoMercator().center([75, 25]).scale(380).translate([W / 2, H / 2]);
const path = geoPath(proj);
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const countries = (feature(world as any, (world as any).objects.countries) as any).features as { id: string; geometry: unknown }[];
const countryPaths = countries.map((c) => ({ id: c.id, d: path(c as never) ?? '' }));

type View = { k: number; x: number; y: number };
function fit(lon0: number, lat0: number, lon1: number, lat1: number): View {
  const [x0, y1] = proj([lon0, lat0])!; const [x1, y0] = proj([lon1, lat1])!;
  const k = Math.min(W / (x1 - x0), H / (y1 - y0)) * 0.95;
  return { k, x: W / 2 - ((x0 + x1) / 2) * k, y: H / 2 - ((y0 + y1) / 2) * k };
}
const INDIA = fit(67, 6, 98, 36);
const WORLD = fit(-60, -38, 160, 62);

export interface MapRoute { key: string; a: string; b: string; tone: 'good' | 'warn' | 'low' | 'none'; label?: string }

export function WorldMap({ airports, bases, routes, selected, onSelect, height = 320, highlight }: {
  airports: Airport[]; bases: string[]; routes: MapRoute[]; selected?: string | null; onSelect?: (iata: string) => void;
  height?: number | string; highlight?: string[];
}) {
  const [view, setView] = useState<View>(INDIA);
  const svgRef = useRef<SVGSVGElement>(null);
  const ptrs = useRef(new Map<number, { x: number; y: number }>());
  const moved = useRef(0);
  const pinch = useRef<{ d: number; k: number } | null>(null);

  const pts = useMemo(() => Object.fromEntries(airports.map((a) => [a.iata, proj([a.lon, a.lat])!])), [airports]);
  const routePaths = useMemo(() => routes.map((r) => {
    const A = airports.find((x) => x.iata === r.a), B = airports.find((x) => x.iata === r.b);
    if (!A || !B) return null;
    return { ...r, d: path({ type: 'LineString', coordinates: [[A.lon, A.lat], [B.lon, B.lat]] }) ?? '' };
  }).filter(Boolean) as (MapRoute & { d: string })[], [routes, airports]);

  const baseSet = new Set(bases);
  const linked = new Set([...routes.flatMap((r) => [r.a, r.b]), ...(highlight ?? [])]);
  const k = view.k;

  function toSvg(cx: number, cy: number) {
    const r = svgRef.current!.getBoundingClientRect();
    const s = Math.max(W / r.width, H / r.height);           // viewBox units per px (slice)
    const ox = (r.width * s - W) / 2, oy = (r.height * s - H) / 2;
    return { x: (cx - r.left) * s - ox, y: (cy - r.top) * s - oy, s };
  }
  function zoomAt(f: number, cx: number, cy: number) {
    setView((v) => {
      const k2 = Math.min(40, Math.max(1, v.k * f));
      const ff = k2 / v.k;
      return { k: k2, x: cx - (cx - v.x) * ff, y: cy - (cy - v.y) * ff };
    });
  }
  function down(e: RPE) {
    (e.target as Element).setPointerCapture?.(e.pointerId);
    ptrs.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    moved.current = 0;
    if (ptrs.current.size === 2) {
      const [p, q] = [...ptrs.current.values()];
      pinch.current = { d: Math.hypot(p.x - q.x, p.y - q.y), k: view.k };
    }
  }
  function move(e: RPE) {
    const prev = ptrs.current.get(e.pointerId);
    if (!prev) return;
    ptrs.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (ptrs.current.size === 2 && pinch.current) {
      const [p, q] = [...ptrs.current.values()];
      const d = Math.hypot(p.x - q.x, p.y - q.y);
      const c = toSvg((p.x + q.x) / 2, (p.y + q.y) / 2);
      zoomAt((pinch.current.k * d) / pinch.current.d / view.k, c.x, c.y);
      moved.current += 10;
      return;
    }
    const { s } = toSvg(e.clientX, e.clientY);
    const dx = (e.clientX - prev.x) * s, dy = (e.clientY - prev.y) * s;
    moved.current += Math.abs(dx) + Math.abs(dy);
    setView((v) => ({ ...v, x: v.x + dx, y: v.y + dy }));
  }
  function up(e: RPE) {
    ptrs.current.delete(e.pointerId);
    if (ptrs.current.size < 2) pinch.current = null;
  }
  function wheel(e: React.WheelEvent) {
    const c = toSvg(e.clientX, e.clientY);
    zoomAt(e.deltaY < 0 ? 1.25 : 0.8, c.x, c.y);
  }
  const pick = (iata: string) => { if (moved.current < 8) onSelect?.(iata); };

  // the world's home airports by passengers, the others by their pull (0037: a region's own airports are its home)
  const size = (a: Airport) => (a.home === money.region ? 1.6 + Math.sqrt(a.pax_m ?? 0) * 0.55
    : 1.6 + Math.sqrt(a.mass ?? (a.pax_m ?? 0) / 4) * 0.35);
  const toneColor = { good: 'var(--accent)', warn: '#E8891C', low: '#C2410C', none: '#667085' };

  return (
    <div className="mapbox" style={{ height }}>
      <svg ref={svgRef} viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="xMidYMid slice"
        onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={up} onWheel={wheel} role="img" aria-label="Route map">
        <g transform={`translate(${view.x},${view.y}) scale(${k})`}>
          {countryPaths.map((c) => (
            <path key={c.id} d={c.d} fill={c.id === '356' ? '#FFFFFF' : '#F3F4F6'} stroke="#C9D3DC" strokeWidth={0.6 / k} />
          ))}
          {routePaths.map((r) => (
            <path key={r.key} d={r.d} fill="none" stroke={toneColor[r.tone]} strokeWidth={2.4 / k} strokeLinecap="round"
              strokeDasharray={r.tone === 'none' ? `${5 / k} ${4 / k}` : undefined} opacity={0.9} />
          ))}
          {airports.map((a) => {
            const p = pts[a.iata]; if (!p) return null;
            const isBase = baseSet.has(a.iata), isLinked = linked.has(a.iata), isSel = selected === a.iata;
            const r = (isBase ? size(a) + 2.5 : size(a)) / Math.sqrt(k);
            const showLabel = isBase || isLinked || isSel || k > 4.5 || (k > 2.2 && (a.pax_m ?? 0) > 8);
            return (
              <g key={a.iata} onClick={() => pick(a.iata)} style={{ cursor: 'pointer' }}>
                <circle cx={p[0]} cy={p[1]} r={Math.max(r, 7 / k)} fill="transparent" />
                <circle cx={p[0]} cy={p[1]} r={r} fill={isBase ? 'var(--accent)' : isLinked ? '#344054' : '#98A2B3'}
                  stroke={isSel ? '#101828' : '#fff'} strokeWidth={(isSel ? 2.5 : 1) / k} />
                {showLabel && (
                  <text x={p[0] + r + 3 / k} y={p[1] + 4 / k} fontSize={11 / k} fontWeight={isBase || isSel ? 700 : 500}
                    fill="#101828" stroke="#fff" strokeWidth={3 / k} paintOrder="stroke">{a.iata}</text>
                )}
              </g>
            );
          })}
        </g>
      </svg>
      <div className="map-ctl">
        <button aria-label="Zoom in" onClick={() => zoomAt(1.5, W / 2, H / 2)}>+</button>
        <button aria-label="Zoom out" onClick={() => zoomAt(1 / 1.5, W / 2, H / 2)}>−</button>
        <button aria-label="Show India" style={{ fontSize: 11, fontWeight: 600 }} onClick={() => setView(INDIA)}>IN</button>
        <button aria-label="Show the world" style={{ fontSize: 11, fontWeight: 600 }} onClick={() => setView(WORLD)}>🌐</button>
      </div>
      <div className="map-legend">
        <span className="row" style={{ gap: 4 }}><span className="dot" style={{ background: 'var(--accent)' }} />Base</span>
        <span className="row" style={{ gap: 4 }}><span style={{ width: 14, height: 3, background: 'var(--accent)', borderRadius: 2 }} />70%+ full</span>
        <span className="row" style={{ gap: 4 }}><span style={{ width: 14, height: 3, background: '#E8891C', borderRadius: 2 }} />Under 70%</span>
      </div>
    </div>
  );
}

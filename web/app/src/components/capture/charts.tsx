// The radio charts. Small multiples: every chart is full width and 132 px tall, they all share one x scale (the
// capture's view window) and one crosshair, and only the last one draws the x-axis, so the columns line up.
//
// These are plain SVG rather than a chart library, which is what lets us fix the audit's chart findings directly:
// a scatter click resolves to a time by pointer maths (A24), the MCS y-domain reaches 31 so retransmissions are
// not clipped (A24), each chart has exactly one y-axis with the unit in its label (A25), and the colour rules are
// ours — band colours for cells, the sequential ramp for ordinal series like modulation order and Rx index (A23).
import { createContext, useContext, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { fmtSince } from "@/lib/analysis/format";
import type { BandPalette } from "@/lib/analysis/palette";
import type { CaptureAnalysis, PhySample, PhySeries } from "@engine/types";

export const CHART_H = 132;
const PAD_L = 52;
const PAD_R = 8;
const PAD_T = 8;
const PAD_B = 10;
const AXIS_H = 18;
const STRIP_H = 4;
const MAX_POINTS = 1500;

/** One crosshair across a whole section: whichever chart the pointer is over drives the rest. */
const CrosshairCtx = createContext<{ t: number | null; set: (t: number | null) => void }>({ t: null, set: () => {} });

export function CrosshairProvider({ children }: { children: ReactNode }) {
  const [t, set] = useState<number | null>(null);
  const value = useMemo(() => ({ t, set }), [t]);
  return <CrosshairCtx.Provider value={value}>{children}</CrosshairCtx.Provider>;
}

export interface Scale {
  x: (t: number) => number;
  y: (v: number) => number;
  plotW: number;
  plotH: number;
  domain: [number, number];
}

export interface ChartProps {
  analysis: CaptureAnalysis;
  palette: BandPalette;
  title: string;
  unit: string;
  series?: PhySeries | undefined;
  view: [number, number];
  cursorMs: number;
  onCursor: (ms: number) => void;
  onView: (v: [number, number]) => void;
  /** Draw the x-axis under this chart. Only the last one in a section does. */
  showAxis?: boolean;
  /** Fixed y domain; otherwise it is taken from the data with a small margin. */
  domain?: [number, number] | undefined;
  /** The value shown at the right of the header. */
  valueAtCursor?: string | undefined;
  /** Extra legend or note under the title. */
  note?: ReactNode;
  children: (scale: Scale) => ReactNode;
  /** Reference lines, e.g. the 10% BLER target or 23 dBm. */
  rules?: { value: number; label: string }[];
  /** Points for the y domain when `children` draws something the frame cannot see. */
  values?: number[];
}

export function Chart(props: ChartProps) {
  const {
    analysis, palette, title, unit, series, view, cursorMs, onCursor, onView,
    showAxis = false, domain, valueAtCursor, note, children, rules = [], values = [],
  } = props;
  const ref = useRef<SVGSVGElement | null>(null);
  const wrapRef = useRef<HTMLDivElement | null>(null);
  const width = useElementWidth(wrapRef, 880);
  const crosshair = useContext(CrosshairCtx);
  const drag = useRef<number | null>(null);

  const [start, end] = view;
  const span = Math.max(1, end - start);
  const plotH = CHART_H - PAD_T - PAD_B - (showAxis ? AXIS_H : 0) - STRIP_H;
  const plotW = Math.max(80, width - PAD_L - PAD_R);

  const pool = values.length ? values : (series?.samples ?? []).flatMap(sampleValues);
  const yDomain = domain ?? niceDomain(pool);
  const x = (t: number) => PAD_L + ((t - start) / span) * plotW;
  const y = (v: number) =>
    PAD_T + plotH - ((v - yDomain[0]) / Math.max(1e-9, yDomain[1] - yDomain[0])) * plotH;

  const timeAt = (clientX: number) => {
    const r = ref.current?.getBoundingClientRect();
    if (!r) return start;
    const scaled = ((clientX - r.left) / r.width) * width;
    return Math.max(start, Math.min(end, start + ((scaled - PAD_L) / plotW) * span));
  };

  return (
    <section className="panel min-w-0 px-3 pb-1 pt-2">
      <header className="flex min-h-7 min-w-0 items-center gap-2">
        <h3 className="min-w-0 shrink truncate text-[13px] font-medium">{title}</h3>
        {series?.code && (
          <span className="chip num shrink-0" title="The modem log code this series was decoded from">
            {series.code}{series.version ? ` v${series.version}` : ""}
          </span>
        )}
        <ConfidenceBadge series={series} />
        {series?.badges?.map((b) => (
          <span key={b} className="chip shrink-0" title={badgeHelp(b)}>{b}</span>
        ))}
        <span className="num ml-auto shrink-0 text-[13px] text-[var(--text)]">{valueAtCursor ?? "—"}</span>
      </header>
      {note}
      <div ref={wrapRef} className="min-w-0">
      <svg
        ref={ref}
        viewBox={`0 0 ${width} ${CHART_H}`}
        width="100%"
        height={CHART_H}
        className="block touch-none select-none"
        role="img"
        aria-label={`${title}${unit ? ` in ${unit}` : ""}, ${fmtSince(start)} to ${fmtSince(end)}`}
        onPointerDown={(e) => {
          e.currentTarget.setPointerCapture(e.pointerId);
          drag.current = timeAt(e.clientX);
        }}
        onPointerMove={(e) => {
          const t = timeAt(e.clientX);
          crosshair.set(t);
        }}
        onPointerUp={(e) => {
          const from = drag.current;
          drag.current = null;
          const t = timeAt(e.clientX);
          // A drag wider than 1% of the window zooms; anything shorter is a click that moves the cursor.
          if (from != null && Math.abs(t - from) > span * 0.01) onView([Math.min(from, t), Math.max(from, t)]);
          else onCursor(t);
        }}
        onPointerLeave={() => crosshair.set(null)}
      >
        {/* y gridlines and the one y-axis, at most 4 ticks, unit in the label */}
        {yTicks(yDomain).map((v) => (
          <g key={v}>
            <line x1={PAD_L} y1={y(v)} x2={PAD_L + plotW} y2={y(v)} stroke="var(--line)" />
            <text x={PAD_L - 6} y={y(v) + 3} textAnchor="end" fontSize="10" fill="var(--text-3)" className="num">
              {formatTick(v)}
            </text>
          </g>
        ))}
        <text
          x={10} y={PAD_T + plotH / 2}
          fontSize="10" fill="var(--text-3)" textAnchor="middle"
          transform={`rotate(-90 10 ${PAD_T + plotH / 2})`}
        >
          {unit || " "}
        </text>

        {rules.map((r) => (
          <g key={r.label}>
            <line x1={PAD_L} y1={y(r.value)} x2={PAD_L + plotW} y2={y(r.value)} stroke="var(--warning)" strokeDasharray="4 3" />
            <text x={PAD_L + plotW - 2} y={y(r.value) - 3} textAnchor="end" fontSize="10" fill="var(--warning)">{r.label}</text>
          </g>
        ))}

        {children({ x, y, plotW, plotH, domain: yDomain })}

        {/* Band context strip: which cell was serving, and where the radio was off. */}
        <ContextStrip analysis={analysis} palette={palette} x={x} view={view} yTop={PAD_T + plotH + 3} width={plotW} />

        {/* The shared crosshair, then the cursor on top. */}
        {crosshair.t != null && crosshair.t >= start && crosshair.t <= end && (
          <line x1={x(crosshair.t)} y1={PAD_T} x2={x(crosshair.t)} y2={PAD_T + plotH} stroke="var(--text-3)" strokeDasharray="3 3" />
        )}
        {cursorMs >= start && cursorMs <= end && (
          <line x1={x(cursorMs)} y1={PAD_T} x2={x(cursorMs)} y2={PAD_T + plotH} stroke="var(--text)" />
        )}

        {showAxis &&
          xTicks(start, end, plotW).map((t) => (
            <text key={t} x={x(t)} y={CHART_H - 2} textAnchor="middle" fontSize="10" fill="var(--text-3)" className="num">
              {fmtSince(t)}
            </text>
          ))}
      </svg>
      </div>
    </section>
  );
}

/** The chart's own width, so the SVG's user units are CSS pixels and the pointer maths stays exact. */
function useElementWidth(ref: React.RefObject<HTMLElement | null>, fallback: number): number {
  const [width, setWidth] = useState(fallback);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver((entries) => {
      const next = entries[0]?.contentRect.width;
      if (next && next > 0) setWidth(Math.round(next));
    });
    ro.observe(el);
    setWidth(el.clientWidth || fallback);
    return () => ro.disconnect();
  }, [fallback, ref]);
  return width;
}

function ContextStrip({
  analysis, palette, x, view, yTop, width,
}: {
  analysis: CaptureAnalysis;
  palette: BandPalette;
  x: (t: number) => number;
  view: [number, number];
  yTop: number;
  width: number;
}) {
  const [start, end] = view;
  const clampW = (a: number, b: number) => Math.max(0, x(Math.min(end, b)) - x(Math.max(start, a)));
  return (
    <g>
      <rect x={PAD_L} y={yTop} width={width} height={STRIP_H} fill="var(--surface-2)" />
      {analysis.journey.cells
        .filter((c) => c.lane === "pcell" && c.endMs >= start && c.startMs <= end)
        .map((c) => (
          <rect
            key={`cs-${c.startMs}`}
            x={x(Math.max(start, c.startMs))}
            y={yTop}
            width={clampW(c.startMs, c.endMs)}
            height={STRIP_H}
            fill={palette.colorOf(c.band)}
          />
        ))}
      {analysis.journey.states
        .filter((s) => s.state === "radioOff" && s.endMs >= start && s.startMs <= end)
        .map((s) => (
          <rect
            key={`cs-off-${s.startMs}`}
            x={x(Math.max(start, s.startMs))}
            y={yTop}
            width={clampW(s.startMs, s.endMs)}
            height={STRIP_H}
            fill="var(--line-strong)"
          />
        ))}
    </g>
  );
}

function ConfidenceBadge({ series }: { series?: PhySeries | undefined }) {
  if (!series || series.confidence === "high") return null;
  const help =
    series.confidence === "derived"
      ? "Computed from other decoded values rather than read directly."
      : "Decoded with a record layout that still has some uncertainty.";
  return <span className="chip shrink-0 border-[var(--warning)]/45" title={help}>{series.confidence}</span>;
}

// ------------------------------------------------------------------------------------------------------ marks

/** A line with real gaps: a null sample breaks the path rather than being bridged. */
export function LineMark({
  points, scale, stroke, width = 1.5,
}: {
  points: { t: number; v: number | null }[];
  scale: Scale;
  stroke: string;
  width?: number;
}) {
  let d = "";
  let pen = false;
  for (const p of points) {
    if (p.v == null) {
      pen = false;
      continue;
    }
    d += `${pen ? "L" : "M"}${scale.x(p.t).toFixed(1)} ${scale.y(p.v).toFixed(1)} `;
    pen = true;
  }
  return <path d={d} fill="none" stroke={stroke} strokeWidth={width} strokeLinejoin="round" />;
}

export function StepMark({ points, scale, stroke }: { points: { t: number; v: number | null }[]; scale: Scale; stroke: string }) {
  let d = "";
  let last: { x: number; y: number } | null = null;
  for (const p of points) {
    if (p.v == null) {
      last = null;
      continue;
    }
    const pt = { x: scale.x(p.t), y: scale.y(p.v) };
    d += last ? `L${pt.x.toFixed(1)} ${last.y.toFixed(1)} L${pt.x.toFixed(1)} ${pt.y.toFixed(1)} ` : `M${pt.x.toFixed(1)} ${pt.y.toFixed(1)} `;
    last = pt;
  }
  return <path d={d} fill="none" stroke={stroke} strokeWidth={1.5} />;
}

export function BarMark({
  points, scale, fill, barW,
}: {
  points: { t: number; v: number | null; fill?: string }[];
  scale: Scale;
  fill: string;
  barW?: number;
}) {
  const w = barW ?? Math.max(1, scale.plotW / Math.max(1, points.length) - 1);
  const zero = scale.y(Math.max(scale.domain[0], 0));
  return (
    <g>
      {points.map((p, i) =>
        p.v == null ? null : (
          <rect
            key={i}
            x={scale.x(p.t) - w / 2}
            y={Math.min(zero, scale.y(p.v))}
            width={w}
            height={Math.max(0.5, Math.abs(zero - scale.y(p.v)))}
            fill={p.fill ?? fill}
          />
        ),
      )}
    </g>
  );
}

/** Retransmissions are hollow critical rings rather than a filled dot, so they read as a different thing. */
export function ScatterMark({
  points, scale,
}: {
  points: { t: number; v: number | null; fill: string; hollow?: boolean }[];
  scale: Scale;
}) {
  return (
    <g>
      {points.map((p, i) =>
        p.v == null ? null : (
          <circle
            key={i}
            cx={scale.x(p.t)}
            cy={scale.y(p.v)}
            r={p.hollow ? 2.5 : 1.8}
            fill={p.hollow ? "none" : p.fill}
            stroke={p.hollow ? "var(--critical)" : "none"}
            strokeWidth={p.hollow ? 1 : 0}
          />
        ),
      )}
    </g>
  );
}

/**
 * The PRB allocation strip: one column per logged subframe, filled at exactly the resource blocks the scheduler
 * gave this phone (0xB126's bitmap). The y scale is the PRB index, so a run of set bits is one rectangle - which is
 * what makes the picture readable at a glance: a wide block is a big grant, a scatter of thin marks is a cell
 * handing out fragments.
 */
export function AllocationMark({
  columns, scale, fill, view,
}: {
  columns: { t: number; mask: number[] }[];
  scale: Scale;
  fill: string;
  view: [number, number];
}) {
  if (!columns.length) return null;
  const span = Math.max(1, view[1] - view[0]);
  // One column per subframe would be sub-pixel on a 22 s window, so each is at least a hairline wide.
  const width = Math.max(1, Math.min(6, (scale.plotW / span) * 20));
  const rects: { x: number; y: number; h: number }[] = [];
  for (const c of columns) {
    const x = scale.x(c.t);
    let run = -1;
    const total = c.mask.length * 32;
    for (let prb = 0; prb <= total; prb++) {
      const set = prb < total && ((c.mask[prb >> 5] ?? 0) >>> (prb & 31) & 1) === 1;
      if (set && run < 0) run = prb;
      else if (!set && run >= 0) {
        const top = scale.y(prb), bottom = scale.y(run);
        rects.push({ x, y: top, h: Math.max(1, bottom - top) });
        run = -1;
      }
    }
  }
  return (
    <g>
      {rects.map((r, i) => <rect key={i} x={r.x} y={r.y} width={width} height={r.h} fill={fill} />)}
    </g>
  );
}

/** Stacked bars: throughput by carrier in each cell's band colour, or a 100% modulation mix. */
export function StackedMark({
  buckets, keys, colorOf, scale, gap = 2,
}: {
  buckets: { t: number; parts: Record<string, number> }[];
  keys: string[];
  colorOf: (key: string) => string;
  scale: Scale;
  gap?: number;
}) {
  const w = Math.max(1, scale.plotW / Math.max(1, buckets.length) - gap);
  return (
    <g>
      {buckets.map((b, i) => {
        let acc = 0;
        return (
          <g key={i}>
            {keys.map((k) => {
              const v = b.parts[k] ?? 0;
              if (v <= 0) return null;
              const yTop = scale.y(acc + v);
              const yBottom = scale.y(acc);
              acc += v;
              return (
                <rect key={k} x={scale.x(b.t) - w / 2} y={yTop} width={w} height={Math.max(0.5, yBottom - yTop)} fill={colorOf(k)} />
              );
            })}
          </g>
        );
      })}
    </g>
  );
}

// ----------------------------------------------------------------------------------------------------- scales

function sampleValues(s: PhySample): number[] {
  const out = s.value == null ? [] : [s.value];
  for (const v of s.perIndex ?? []) if (v != null) out.push(v);
  return out;
}

function niceDomain(values: number[]): [number, number] {
  const finite = values.filter((v) => Number.isFinite(v));
  if (!finite.length) return [0, 1];
  let lo = Math.min(...finite);
  let hi = Math.max(...finite);
  if (lo === hi) {
    lo -= 1;
    hi += 1;
  }
  const pad = (hi - lo) * 0.08;
  return [lo - pad, hi + pad];
}

function yTicks([lo, hi]: [number, number]): number[] {
  const step = niceStep((hi - lo) / 3);
  const out: number[] = [];
  for (let v = Math.ceil(lo / step) * step; v <= hi + 1e-9 && out.length < 5; v += step) out.push(round(v));
  return out;
}

function niceStep(raw: number): number {
  if (raw <= 0) return 1;
  const mag = 10 ** Math.floor(Math.log10(raw));
  const norm = raw / mag;
  return (norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 5 ? 5 : 10) * mag;
}

function round(v: number): number {
  return Math.abs(v) < 1e-9 ? 0 : Math.round(v * 1000) / 1000;
}

function formatTick(v: number): string {
  if (Math.abs(v) >= 1000) return `${Math.round(v / 100) / 10}k`;
  return Number.isInteger(v) ? String(v) : v.toFixed(1);
}

function xTicks(start: number, end: number, plotW: number): number[] {
  const span = Math.max(1, end - start);
  const maxTicks = Math.max(2, Math.floor(plotW / 80));
  const step = [10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 30_000, 60_000].find((s) => span / s <= maxTicks) ?? 60_000;
  const out: number[] = [];
  for (let t = Math.ceil(start / step) * step; t <= end; t += step) out.push(t);
  return out;
}

/**
 * At most MAX_POINTS per series, by keeping the minimum and the maximum of each bucket, so a spike is never
 * decimated away.
 */
export function decimate(samples: PhySample[], max = MAX_POINTS): PhySample[] {
  if (samples.length <= max) return samples;
  const size = Math.ceil(samples.length / (max / 2));
  const out: PhySample[] = [];
  for (let i = 0; i < samples.length; i += size) {
    const part = samples.slice(i, i + size).filter((s) => s.value != null);
    if (!part.length) continue;
    let lo = part[0] as PhySample;
    let hi = part[0] as PhySample;
    for (const s of part) {
      if ((s.value ?? 0) < (lo.value ?? 0)) lo = s;
      if ((s.value ?? 0) > (hi.value ?? 0)) hi = s;
    }
    if (lo.tMs <= hi.tMs) out.push(lo, hi);
    else out.push(hi, lo);
  }
  return out;
}

export function badgeHelp(badge: string): string {
  switch (badge) {
    case "derived": return "Computed from other decoded transport values.";
    case "medium confidence": return "Decoded with a record layout that still has some uncertainty.";
    case "before Pcmax": return "The power the network asked for, before the device maximum is applied.";
    case "UL scheduled": return "Scheduled uplink capacity, not measured throughput.";
    case "front-end": return "Measured in the transmit front end, at its own instants: a different quantity from the PUSCH power the network asked for.";
    case "partial coverage": return "The walk over this record reaches about 80% of the transport blocks it declares, so the figure is a floor, never a total.";
    default: return badge;
  }
}

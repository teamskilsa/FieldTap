// The timeline dock: a DevTools/Perfetto-style track view with a readout row, a ruler, a label gutter, one lane
// per thing that can change, an events lane, and an overview minimap.
//
// Layout notes, because the numbers matter (audit E1, E8):
//   - the ruler owns the top 22 px and markers never share it, so tick labels can never be printed over;
//   - lanes are drawn at their own heights (State 18, registration 3, PCell 26, NR 18, SCell 14, Events 24),
//     and any lane that prints a word gives it a line box of its own inside the lane (audit E1);
//   - the whole dock stays under 248 px on the desktop and under 200 px at 390 px.
//
// Segments and markers are real HTML buttons positioned over an SVG that carries only the ruler, the gridlines,
// the handover connectors and the cursor. That is what makes them focusable, labelled and keyboard-reachable
// (audit A20) without hand-rolling SVG focus handling.
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import {
  ArrowLeftRight,
  BadgeCheck,
  ChevronLeft,
  ChevronRight,
  CircleDot,
  CircleMinus,
  CirclePlus,
  CornerDownRight,
  HelpCircle,
  Maximize2,
  Minimize2,
  MoveHorizontal,
  OctagonX,
  Power,
  RefreshCcw,
  RotateCcw,
  Shuffle,
  TriangleAlert,
  type LucideIcon,
} from "lucide-react";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { fmtDuration, fmtMetric, fmtSince, fmtTick, fmtValue, MARKER_LABEL, rsrpQuality, wallClock } from "@/lib/analysis/format";
import { PATTERN_LABEL, patternLayer, useBandPalette, type BandPalette } from "@/lib/analysis/palette";
import { activeCells, pcellAt, sampleAt, seriesOf, valueAt } from "@/lib/analysis/select";
import type { CaptureAnalysis, JourneyCell, Marker, MarkerKind, PhyMetric } from "@engine/types";
import type { Flash } from "@/state/capture";
import { cn } from "@/lib/utils";

const RULER_H = 22;
/** 18 px, not 14: a 11 px word needs a 14 px box of its own inside the lane or its ascenders meet the lane edge. */
const STATE_H = 18;
const REG_H = 3;
const PCELL_H = 26;
const NR_H = 18;
const SCELL_H = 14;
const EVENTS_H = 24;
const MINIMAP_H = 28;
const GUTTER = 140;
const GUTTER_SM = 64;
const MIN_WINDOW_MS = 50;
/** Pills closer than this cluster into one count pill. */
const CLUSTER_PX = 22;
/** Tick labels never come closer than this, so they cannot collide (audit E1). */
const TICK_GAP_PX = 72;

/** The readout row. Units come from the series itself, and fmtMetric decides the precision (see format.ts). */
const METRICS: [PhyMetric, string][] = [
  ["lte_rsrp_filtered", "RSRP"],
  ["lte_rsrq_filtered", "RSRQ"],
  ["lte_cqi_wideband_cw0", "CQI"],
  ["lte_ri", "RI"],
  ["lte_dl_mcs", "MCS"],
];

/** Markers that get a 6 px tick on a sub-row instead of a glyph pill: they are frequent and low-weight. */
const TICK_KINDS = new Set<MarkerKind>(["rrcSetup", "rrcRelease", "rach"]);

const GLYPHS: Record<MarkerKind, LucideIcon> = {
  handover: ArrowLeftRight,
  reselection: RefreshCcw,
  reattach: RotateCcw,
  redirect: CornerDownRight,
  reestablishment: RotateCcw,
  cellChange: Shuffle,
  scgAdd: CirclePlus,
  scgModify: CircleDot,
  scgRelease: CircleMinus,
  attach: BadgeCheck,
  detachSwitchOff: Power,
  rrcSetup: CircleDot,
  rrcRelease: CircleMinus,
  rach: CircleDot,
  failure: OctagonX,
  warning: TriangleAlert,
};

interface Lane {
  key: string;
  label: string;
  sub?: string;
  top: number;
  height: number;
  kind: "state" | "registration" | "pcell" | "pscell" | "scell" | "events";
  scellIndex?: number;
}

interface TrackViewProps {
  analysis: CaptureAnalysis;
  cursorMs: number;
  onCursor: (ms: number) => void;
  view: [number, number];
  onView: (view: [number, number]) => void;
  onFit: () => void;
  onMarker: (m: Marker) => void;
  collapsed: boolean;
  onCollapsed: (v: boolean) => void;
  onAnnounce: (text: string) => void;
  onOpenFlow: (event: number) => void;
  /** Glide the cursor there instead of teleporting it: used for marker steps and "Show on timeline". */
  onGlide: (ms: number) => void;
  /** The moment the rest of the app last asked the timeline to point at. */
  flash: Flash | null;
  onShowOnTimeline: (ms: number) => void;
}

export function TrackView(props: TrackViewProps) {
  const { analysis, cursorMs, onCursor, view, onView, onFit, onMarker, collapsed, onCollapsed, onAnnounce, onGlide, flash } = props;
  const palette = useBandPalette(analysis);
  const plotRef = useRef<HTMLDivElement | null>(null);
  const wrapRef = useRef<HTMLDivElement | null>(null);
  const [width, setWidth] = useState(1000);
  const [hover, setHover] = useState<{ x: number; y: number; body: HoverBody } | null>(null);
  const [pinned, setPinned] = useState(false);
  const [crosshair, setCrosshair] = useState<number | null>(null);
  const drag = useRef<{ mode: "scrub" | "zoom"; from: number } | null>(null);

  const duration = Math.max(1, analysis.durationMs);
  const [start, end] = view;
  const span = Math.max(MIN_WINDOW_MS, end - start);
  // The spec's breakpoint: under 640 px the gutter narrows to 64 px and the SCell lanes are capped.
  const compact = width < 640;
  const gutter = compact ? GUTTER_SM : GUTTER;
  const plotW = Math.max(160, width - gutter);

  useLayoutEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const ro = new ResizeObserver((entries) => {
      const next = entries[0]?.contentRect.width;
      if (next) setWidth(next);
    });
    ro.observe(el);
    setWidth(el.clientWidth || 1000);
    return () => ro.disconnect();
  }, []);

  const lanes = useMemo(() => buildLanes(analysis, palette, compact ? 2 : Infinity), [analysis, compact, palette]);
  const svgH = lanes.length ? (lanes[lanes.length - 1] as Lane).top + (lanes[lanes.length - 1] as Lane).height : RULER_H;

  const xOf = useCallback((t: number) => ((clamp(t, start, end) - start) / span) * plotW, [end, plotW, span, start]);
  const wOf = useCallback(
    (a: number, b: number) => Math.max(1, ((Math.min(end, b) - Math.max(start, a)) / span) * plotW),
    [end, plotW, span, start],
  );
  const timeAt = useCallback(
    (clientX: number) => {
      const rect = plotRef.current?.getBoundingClientRect();
      if (!rect) return cursorMs;
      return clamp(start + ((clientX - rect.left) / (rect.width || plotW)) * span, 0, duration);
    },
    [cursorMs, duration, plotW, span, start],
  );

  const ticks = useMemo(() => buildTicks(start, end, plotW), [end, plotW, start]);
  const pcell = pcellAt(analysis.journey, cursorMs);
  const active = activeCells(analysis.journey, cursorMs);
  const pscell = active.find((c) => c.lane === "pscell");
  const scellCount = active.filter((c) => c.lane === "scell").length;
  const clock = wallClock(analysis, cursorMs);
  const rsrp = valueAt(seriesOf(analysis, "lte_rsrp_filtered"), cursorMs);
  const quality = rsrpQuality(rsrp);

  const setWindow = useCallback(
    (a: number, b: number) => {
      const lo = clamp(Math.min(a, b), 0, duration);
      const hi = clamp(Math.max(a, b), 0, duration);
      onView([lo, Math.max(lo + MIN_WINDOW_MS, hi)]);
    },
    [duration, onView],
  );
  const zoomAround = useCallback(
    (factor: number, anchor: number) => {
      const next = clamp(span * factor, MIN_WINDOW_MS, duration);
      const ratio = span === 0 ? 0.5 : (anchor - start) / span;
      setWindow(anchor - next * ratio, anchor + next * (1 - ratio));
    },
    [duration, setWindow, span, start],
  );
  const pan = useCallback((delta: number) => setWindow(start + delta, end + delta), [end, setWindow, start]);

  const stepMarker = useCallback(
    (dir: -1 | 1) => {
      const times = analysis.journey.markers.map((m) => m.tMs).sort((a, b) => a - b);
      const next = dir < 0 ? [...times].reverse().find((t) => t < cursorMs - 1) : times.find((t) => t > cursorMs + 1);
      if (next == null) return;
      // A glide, not a teleport: over 150 ms the reader can see which way the cursor went and how far.
      onGlide(next);
      const m = analysis.journey.markers.find((x) => x.tMs === next);
      if (m) onAnnounce(`${m.title} at ${fmtSince(m.tMs)}`);
    },
    [analysis.journey.markers, cursorMs, onAnnounce, onGlide],
  );

  // The keyboard map is scoped to the focused track area, so it can never fight the tabs or a text field (A20).
  const onKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
    const step = e.shiftKey ? 1000 : 100;
    let handled = true;
    switch (e.key.toLowerCase()) {
      case "arrowleft": onCursor(clamp(cursorMs - step, 0, duration)); break;
      case "arrowright": onCursor(clamp(cursorMs + step, 0, duration)); break;
      case "[": stepMarker(-1); break;
      case "]": stepMarker(1); break;
      case "w": zoomAround(0.7, cursorMs); break;
      case "s": zoomAround(1 / 0.7, cursorMs); break;
      case "a": pan(-span * 0.2); break;
      case "d": pan(span * 0.2); break;
      case "0": onFit(); break;
      case "escape": setHover(null); setPinned(false); break;
      default: handled = false;
    }
    if (handled) e.preventDefault();
  };

  useEffect(() => {
    onAnnounce(`${fmtSince(cursorMs)}, ${pcell ? `${pcell.band} PCI ${pcell.cell.pci}` : "no serving cell"}`);
  }, [cursorMs, onAnnounce, pcell]);

  // "Show on timeline" from anywhere else in the app: pull the moment into the window if it is outside it, then
  // pulse a ring on it for 900 ms so the eye finds it without the reader having to hunt for the cursor.
  const [flashOn, setFlashOn] = useState(false);
  const flashAt = flash?.at;
  const flashMs = flash?.tMs;
  useEffect(() => {
    if (flashAt == null || flashMs == null) return;
    setFlashOn(true);
    if (flashMs < start || flashMs > end) {
      const half = Math.max(MIN_WINDOW_MS, span) / 2;
      setWindow(flashMs - half, flashMs + half);
    }
    const id = window.setTimeout(() => setFlashOn(false), 900);
    return () => window.clearTimeout(id);
    // Only a new request (a new `at`) restarts the pulse; panning the window mid-pulse must not re-trigger it.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [flashAt]);

  const showCard = useCallback((el: HTMLElement, body: HoverBody) => {
    const r = el.getBoundingClientRect();
    setHover({ x: r.left + r.width / 2, y: r.bottom + 6, body });
  }, []);
  const hideCard = useCallback(() => {
    if (!pinned) setHover(null);
  }, [pinned]);

  if (collapsed) {
    return (
      <div className="flex h-14 items-center gap-3 border-b border-[var(--line)] bg-[var(--surface-1)] px-4">
        <span className="num text-[13px] font-medium">{fmtSince(cursorMs)}</span>
        <span className="chip num min-w-0 truncate">{pcell ? `${pcell.band} · PCI ${pcell.cell.pci}` : "no serving cell"}</span>
        <button className="btn-quiet ml-auto" onClick={() => onCollapsed(false)}>
          <Maximize2 className="size-3.5" /> Expand timeline
        </button>
      </div>
    );
  }

  return (
    <section className="border-b border-[var(--line)] bg-[var(--surface-1)]" aria-label="Cell journey timeline">
      {/* Readout row: the values at the cursor. 36 px, two lines on a phone. */}
      <div className="flex min-h-9 flex-wrap items-center gap-x-3 gap-y-1 border-b border-[var(--line)] px-4 py-1">
        <div className="flex min-w-0 shrink-0 items-center gap-1.5">
          {pcell ? (
            <span className="chip num" style={{ borderColor: palette.colorOf(pcell.band) }}>
              <span className="size-2 rounded-[2px]" style={{ background: palette.colorOf(pcell.band) }} />
              LTE {pcell.band} · {pcell.cell.earfcn} · PCI {pcell.cell.pci}
            </span>
          ) : (
            <span className="chip">No serving cell</span>
          )}
          {pscell && (
            <span className="chip num" style={{ borderColor: "var(--band-nr)" }}>
              + NR {pscell.band} · {pscell.cell.pci === 0xffff ? "pending" : `PCI ${pscell.cell.pci}`}
            </span>
          )}
          {scellCount > 0 && <span className="chip num">CA +{scellCount}</span>}
        </div>

        <div className="flex min-w-0 flex-1 gap-3 overflow-x-auto">
          {METRICS.map(([metric, label]) => {
            const series = seriesOf(analysis, metric);
            const s = sampleAt(series, cursorMs);
            const stale = !s || s.value == null;
            return (
              <span key={metric} className="flex shrink-0 items-baseline gap-1">
                <span className="text-[11px] font-medium tracking-[0.02em] text-[var(--text-3)]">{label}</span>
                <span className="num text-[13px] text-[var(--text)]">
                  {stale ? "—" : fmtMetric(s.value, series?.unit)}
                </span>
                {metric === "lte_rsrp_filtered" && !stale && (
                  <span
                    className="size-2 shrink-0 rounded-full"
                    style={{ background: quality.token }}
                    title={`Signal ${quality.label}`}
                    aria-label={`Signal ${quality.label}`}
                  />
                )}
              </span>
            );
          })}
        </div>

        <div className="flex shrink-0 items-center gap-2">
          <span className="num text-base font-semibold leading-6">{fmtSince(cursorMs)}</span>
          <span className="num hidden text-xs text-[var(--text-2)] sm:inline" title={clock.title}>{clock.text}</span>
          <span className="flex items-center">
            <IconBtn label="Previous marker  [" onClick={() => stepMarker(-1)}><ChevronLeft className="size-4" /></IconBtn>
            <IconBtn label="Next marker  ]" onClick={() => stepMarker(1)}><ChevronRight className="size-4" /></IconBtn>
            <IconBtn label="Fit the whole capture  0" onClick={onFit}><MoveHorizontal className="size-4" /></IconBtn>
            <IconBtn label="Collapse the timeline" onClick={() => onCollapsed(true)}><Minimize2 className="size-4" /></IconBtn>
          </span>
        </div>
      </div>

      {/* Tracks */}
      <div
        ref={wrapRef}
        tabIndex={0}
        role="group"
        aria-label="Cell journey. While focused: arrows move the cursor, brackets step markers, W and S zoom, A and D pan, 0 fits."
        onKeyDown={onKeyDown}
        className="relative outline-none focus-visible:ring-2 focus-visible:ring-[var(--action)] focus-visible:ring-offset-0"
        style={{ height: svgH }}
        onWheel={(e) => {
          if (e.ctrlKey || e.metaKey) {
            e.preventDefault();
            zoomAround(e.deltaY < 0 ? 0.85 : 1 / 0.85, timeAt(e.clientX));
          } else if (e.shiftKey || Math.abs(e.deltaX) > Math.abs(e.deltaY)) {
            e.preventDefault();
            pan(((e.deltaX || e.deltaY) / plotW) * span);
          }
        }}
      >
        {/* The label gutter */}
        <div
          className="absolute inset-y-0 left-0 z-10 border-r border-[var(--line)] bg-[var(--surface-1)]"
          style={{ width: gutter }}
        >
          <div className="flex h-[22px] items-center justify-end pr-2">
            <LegendPopover palette={palette} />
          </div>
          {lanes.map((lane, i) => (
            <div
              key={lane.key}
              className={cn(
                "absolute right-0 flex items-center justify-end gap-1 pr-2",
                i % 2 === 1 && "bg-[var(--surface-2)]",
              )}
              style={{ top: lane.top, height: lane.height, left: 0 }}
            >
              {lane.height >= 14 && (
                <span className="truncate text-[11px] font-medium leading-4 tracking-[0.02em] text-[var(--text-3)]">
                  {compact ? shortLaneLabel(lane) : lane.label}
                </span>
              )}
              {lane.sub && !compact && lane.height >= 14 && (
                <span className="size-2 shrink-0 rounded-[2px]" style={{ background: lane.sub }} />
              )}
            </div>
          ))}
        </div>

        {/* The plot */}
        <div
          ref={plotRef}
          className="absolute inset-y-0 right-0 touch-none"
          style={{ left: gutter }}
          onPointerDown={(e) => {
            if ((e.target as HTMLElement).closest("button")) return;
            e.currentTarget.setPointerCapture(e.pointerId);
            const t = timeAt(e.clientX);
            const onRuler = e.nativeEvent.offsetY <= RULER_H;
            drag.current = { mode: e.shiftKey || onRuler ? "zoom" : "scrub", from: t };
            if (drag.current.mode === "scrub") onCursor(t);
          }}
          onPointerMove={(e) => {
            const t = timeAt(e.clientX);
            setCrosshair(t);
            if (drag.current?.mode === "scrub") onCursor(t);
          }}
          onPointerUp={(e) => {
            const d = drag.current;
            drag.current = null;
            if (d?.mode !== "zoom") return;
            const t = timeAt(e.clientX);
            if (Math.abs(t - d.from) > span * 0.01) setWindow(d.from, t);
            else onCursor(t);
          }}
          onPointerLeave={() => setCrosshair(null)}
          onDoubleClick={onFit}
        >
          <svg
            width={plotW}
            height={svgH}
            viewBox={`0 0 ${plotW} ${svgH}`}
            className="pointer-events-none absolute inset-0 block"
            aria-hidden="true"
          >
            <defs>
              <pattern id="ft-hatch" patternUnits="userSpaceOnUse" width="6" height="6" patternTransform="rotate(45)">
                <line x1="0" y1="0" x2="0" y2="6" stroke="var(--text-3)" strokeWidth="1.5" opacity="0.55" />
              </pattern>
              <marker id="ft-chevron" markerWidth="6" markerHeight="6" refX="5" refY="3" orient="auto">
                <path d="M0,0 L6,3 L0,6" fill="none" stroke="var(--text-2)" strokeWidth="1" />
              </marker>
            </defs>

            {lanes.map((lane, i) =>
              i % 2 === 1 ? (
                <rect key={lane.key} x={0} y={lane.top} width={plotW} height={lane.height} fill="var(--surface-2)" />
              ) : null,
            )}

            {/* Ruler: ticks on top, hairline gridlines down through every lane. */}
            <line x1={0} y1={RULER_H} x2={plotW} y2={RULER_H} stroke="var(--line)" />
            {ticks.values.map((t) => {
              const label = fmtTick(t, ticks.step);
              // Geist at 11 px is about 6.2 px per character. A label that would run past the right edge of the
              // plot is clipped by the SVG, so the last one flips to the left of its own gridline instead.
              const w = label.length * 6.2;
              const past = xOf(t) + 3 + w > plotW;
              return (
                <g key={t}>
                  <line x1={xOf(t)} y1={RULER_H - 4} x2={xOf(t)} y2={svgH} stroke="var(--line)" />
                  <text
                    x={past ? xOf(t) - 3 : xOf(t) + 3}
                    y={14}
                    textAnchor={past ? "end" : "start"}
                    fill="var(--text-3)"
                    fontSize="11"
                    fontWeight="500"
                    letterSpacing="0.02em"
                  >
                    {label}
                  </text>
                </g>
              );
            })}

            {/* Handover connectors: from the command to the arrival on the new PCell. */}
            {analysis.journey.markers
              .filter((m) => m.kind === "handover" && m.arrivalMs != null && m.tMs <= end && (m.arrivalMs ?? 0) >= start)
              .map((m) => {
                const pcellLane = lanes.find((l) => l.kind === "pcell");
                if (!pcellLane) return null;
                const y = pcellLane.top + pcellLane.height / 2;
                return (
                  <path
                    key={`c-${m.id}`}
                    d={`M ${xOf(m.tMs)} ${y} L ${xOf(m.arrivalMs ?? m.tMs)} ${y}`}
                    stroke="var(--text-2)"
                    strokeWidth="1"
                    markerEnd="url(#ft-chevron)"
                    fill="none"
                  />
                );
              })}

            {/* A failure draws one critical line through every lane. Nothing else does. */}
            {analysis.journey.markers
              .filter((m) => m.severity === "failure" && m.tMs >= start && m.tMs <= end)
              .map((m) => (
                <line key={`f-${m.id}`} x1={xOf(m.tMs)} y1={RULER_H} x2={xOf(m.tMs)} y2={svgH} stroke="var(--critical)" strokeWidth="1" />
              ))}

            {crosshair != null && (
              <line x1={xOf(crosshair)} y1={RULER_H} x2={xOf(crosshair)} y2={svgH} stroke="var(--text-3)" strokeWidth="1" strokeDasharray="3 3" />
            )}
            <line x1={xOf(cursorMs)} y1={0} x2={xOf(cursorMs)} y2={svgH} stroke="var(--text)" strokeWidth="1" />
            <path d={`M ${xOf(cursorMs) - 4} 0 H ${xOf(cursorMs) + 4} V 8 L ${xOf(cursorMs)} 12 L ${xOf(cursorMs) - 4} 8 Z`} fill="var(--text)" />
          </svg>

          {/* The interactive layer: real buttons, one per segment and marker. */}
          <div className="absolute inset-0">
            {lanes.map((lane) => (
              <LaneContent
                key={lane.key}
                lane={lane}
                analysis={analysis}
                palette={palette}
                view={view}
                xOf={xOf}
                wOf={wOf}
                plotW={plotW}
                onCursor={onCursor}
                onMarker={onMarker}
                onShowCard={showCard}
                onHideCard={hideCard}
                onPin={() => setPinned(true)}
              />
            ))}
          </div>

          {crosshair != null && (
            <span
              className="num pointer-events-none absolute top-0 rounded-[4px] bg-[var(--surface-3)] px-1 text-[11px] leading-[16px] text-[var(--text-2)] ring-1 ring-[var(--line)]"
              style={{ left: Math.min(plotW - 56, Math.max(0, xOf(crosshair) + 4)) }}
            >
              {fmtSince(crosshair)}
            </span>
          )}

          {flashOn && flashMs != null && flashMs >= start && flashMs <= end && (
            <span
              className="marker-flash pointer-events-none absolute -translate-x-1/2 rounded-full"
              style={{ left: xOf(flashMs), top: RULER_H, height: svgH - RULER_H, width: 26 }}
              aria-hidden="true"
            />
          )}
        </div>
      </div>

      {/* Minimap: the whole capture, with the view window as a brush. */}
      {!compact && (
        <Minimap
          analysis={analysis}
          palette={palette}
          view={view}
          duration={duration}
          gutter={gutter}
          onView={setWindow}
        />
      )}

      {hover && (
        <HoverCard
          hover={hover}
          pinned={pinned}
          onClose={() => { setPinned(false); setHover(null); }}
          onZoom={setWindow}
          onOpenFlow={props.onOpenFlow}
          onShowOnTimeline={props.onShowOnTimeline}
        />
      )}
    </section>
  );
}

// ------------------------------------------------------------------------------------------------------ lanes

function buildLanes(analysis: CaptureAnalysis, palette: BandPalette, maxScellLanes = Infinity): Lane[] {
  const allScells = [
    ...new Set(analysis.journey.cells.filter((c) => c.lane === "scell").map((c) => c.index)),
  ].sort((a, b) => a - b);
  const scellIndexes = allScells.slice(0, maxScellLanes);
  const hiddenScells = allScells.length - scellIndexes.length;
  const hasNr = analysis.journey.cells.some((c) => c.lane === "pscell");

  const lanes: Lane[] = [];
  let top = RULER_H;
  const push = (lane: Omit<Lane, "top">) => {
    lanes.push({ ...lane, top });
    top += lane.height;
  };
  push({ key: "state", label: "State", height: STATE_H, kind: "state" });
  push({ key: "registration", label: "Registration", height: REG_H, kind: "registration" });
  push({ key: "pcell", label: "PCell", height: PCELL_H, kind: "pcell" });
  if (hasNr) push({ key: "pscell", label: "NR · PSCell", height: NR_H, kind: "pscell" });
  for (const index of scellIndexes) {
    // An SCell index is a slot, not a carrier: the reference capture puts B30, then B29, then B66 on SCell 1.
    // Naming the lane after whichever band happened to be first told the reader the lane *was* that band while a
    // segment beside it said otherwise. The lane is named by its band only when one band holds the whole lane;
    // otherwise it is just the slot, and each segment carries its own band (audit E3).
    const bands = [...new Set(analysis.journey.cells.filter((c) => c.lane === "scell" && c.index === index).map((c) => c.band))];
    const only = bands.length === 1 ? bands[0] : undefined;
    const more = hiddenScells > 0 && index === scellIndexes[scellIndexes.length - 1] ? ` +${hiddenScells}` : "";
    push({
      key: `scell-${index}`,
      label: only ? `SCell ${index} · ${only}${more}` : `SCell ${index}${more}`,
      ...(only ? { sub: palette.colorOf(only) } : {}),
      height: SCELL_H,
      kind: "scell",
      scellIndex: index,
    });
  }
  push({ key: "events", label: "Events", height: EVENTS_H, kind: "events" });
  return lanes;
}

interface LaneContentProps {
  lane: Lane;
  analysis: CaptureAnalysis;
  palette: BandPalette;
  view: [number, number];
  xOf: (t: number) => number;
  wOf: (a: number, b: number) => number;
  plotW: number;
  onCursor: (ms: number) => void;
  onMarker: (m: Marker) => void;
  onShowCard: (el: HTMLElement, body: HoverBody) => void;
  onHideCard: () => void;
  onPin: () => void;
}

function LaneContent(props: LaneContentProps) {
  const { lane, analysis, palette, view, xOf, wOf, onCursor, onMarker, onShowCard, onHideCard, onPin } = props;
  const [start, end] = view;
  const visible = (a: number, b: number) => b >= start && a <= end;

  if (lane.kind === "state") {
    return (
      <>
        {analysis.journey.states.filter((s) => visible(s.startMs, s.endMs)).map((s, i) => {
          const w = wOf(s.startMs, s.endMs);
          const label = s.state === "radioOff" ? "radio off" : s.state === "unknown" ? "no data" : s.state;
          // The word gets its own 14 px box inside the 18 px lane, so it sits on a baseline of its own instead of
          // riding the lane's top edge, and it is dropped rather than clipped when the segment is too narrow.
          // Geist at 11 px / 500 measures ~6.0 px per lower-case character; 13 px covers the 1.5 px padding each
          // side plus a pixel of slack, so the estimate errs towards dropping the word rather than ellipsising it.
          const fits = label.length * 6 + 13 <= w;
          return (
            <button
              key={`state-${i}`}
              className="absolute overflow-hidden rounded-[4px] text-left"
              style={{
                left: xOf(s.startMs), width: w, top: lane.top + 1, height: lane.height - 2,
                // connected is a solid fill, idle an outline, radio off a hatch, unknown a dotted baseline:
                // states never wear status colours (they are not good or bad).
                background: s.state === "connected"
                  ? "color-mix(in oklab, var(--text-2) 45%, transparent)"
                  : s.state === "radioOff"
                    ? "repeating-linear-gradient(45deg, color-mix(in oklab, var(--text-3) 70%, transparent) 0 1.5px, transparent 1.5px 5px)"
                    : "transparent",
                border: s.state === "idle" ? "1px solid var(--line-strong)"
                  : s.state === "unknown" ? "1px dotted var(--line-strong)"
                  : s.state === "radioOff" ? "1px solid var(--line-strong)" : "none",
              }}
              aria-label={`${label} from ${fmtSince(s.startMs)} to ${fmtSince(s.endMs)}`}
              onClick={() => onCursor(s.startMs)}
              onMouseEnter={(e) => onShowCard(e.currentTarget, {
                title: label,
                time: `${fmtSince(s.startMs)} – ${fmtSince(s.endMs)}`,
                lines: [s.source ? `From ${s.source}` : "", `Lasted ${fmtDuration(s.endMs - s.startMs)}`].filter(Boolean),
                tMs: s.startMs,
                zoom: [s.startMs, s.endMs],
              })}
              onMouseLeave={onHideCard}
            >
              {fits && (
                <span
                  className="block truncate px-1.5 text-[11px] font-medium text-[var(--text)]"
                  style={{
                    // Its own line box, centred in the lane: the ascenders of 'd' and 'ff' clear the lane edge.
                    lineHeight: `${lane.height - 2}px`,
                    // The ruler gridlines, and the radio-off hatch, run behind the word, so it carries its own
                    // ground rather than being read through a line.
                    textShadow:
                      "0 0 3px var(--surface-1), 0 0 3px var(--surface-1), 0 0 3px var(--surface-1)",
                  }}
                >
                  {label}
                </span>
              )}
            </button>
          );
        })}
      </>
    );
  }

  if (lane.kind === "registration") {
    return (
      <>
        {analysis.journey.registration.filter((r) => visible(r.startMs, r.endMs)).map((r, i) => (
          <span
            key={`reg-${i}`}
            className="absolute"
            title={`${r.state}${r.assumed ? " (assumed)" : ""} ${fmtSince(r.startMs)}–${fmtSince(r.endMs)}`}
            style={{
              left: xOf(r.startMs), width: wOf(r.startMs, r.endMs), top: lane.top, height: lane.height,
              background: r.state === "deregistered"
                ? "repeating-linear-gradient(45deg, var(--warning) 0 2px, transparent 2px 4px)"
                : r.assumed
                  ? "repeating-linear-gradient(90deg, var(--text-3) 0 2px, transparent 2px 4px)"
                  : "color-mix(in oklab, var(--text-2) 45%, transparent)",
            }}
          />
        ))}
      </>
    );
  }

  if (lane.kind === "events") {
    return (
      <EventsLane
        lane={lane}
        analysis={analysis}
        view={view}
        xOf={xOf}
        plotW={props.plotW}
        onCursor={onCursor}
        onMarker={onMarker}
        onShowCard={onShowCard}
        onHideCard={onHideCard}
        onPin={onPin}
      />
    );
  }

  const cells = analysis.journey.cells.filter(
    (c) => c.lane === lane.kind && (lane.scellIndex == null || c.index === lane.scellIndex) && visible(c.startMs, c.endMs),
  );
  return (
    <>
      {cells.map((c) => {
        const w = wOf(c.startMs, c.endMs);
        const color = palette.colorOf(c.band);
        const patterned = palette.patterned(c.band);
        // A patterned band is a neutral grey, so its segments always name themselves — that word is what keeps
        // two neutral lanes apart when the texture alone is too small to read (palette.ts, rule 4).
        const label = fitCellLabel(c, w, patterned);
        return (
          <button
            key={`${c.lane}-${c.index}-${c.startMs}`}
            className="absolute overflow-hidden rounded-[4px] text-left"
            style={{
              left: xOf(c.startMs), width: w, top: lane.top + 1, height: lane.height - 2,
              background: palette.backgroundOf(c.band),
              boxShadow: `inset 0 0 0 1px color-mix(in oklab, ${color} 55%, transparent), inset 3px 0 0 0 ${color}`,
              // openAtEnd fades out, endInferred gets a dashed right edge. Both are in the legend (audit E3).
              maskImage: c.openAtEnd ? "linear-gradient(to right, #000 78%, transparent 100%)" : undefined,
              borderRight: c.endInferred ? `1px dashed ${color}` : undefined,
            }}
            aria-label={cellAria(c, palette)}
            onClick={(e) => { onCursor(c.startMs); onShowCard(e.currentTarget, cellCard(c)); onPin(); }}
            onMouseEnter={(e) => onShowCard(e.currentTarget, cellCard(c))}
            onMouseLeave={onHideCard}
            onFocus={(e) => onShowCard(e.currentTarget, cellCard(c))}
            onBlur={onHideCard}
            // Enter (and Space, which a button already sends as a click) pins the card open, so a keyboard reader
            // gets the same detail a pointer gets on hover.
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                onShowCard(e.currentTarget, cellCard(c));
                onPin();
              }
            }}
          >
            {label && (
              <span
                className="num block truncate px-1.5 text-[11px] font-medium text-[var(--text)]"
                style={{
                  lineHeight: `${lane.height - 2}px`,
                  // A textured band runs behind the label, so the label carries its own ground.
                  ...(patterned
                    ? { textShadow: "0 0 3px var(--surface-1), 0 0 3px var(--surface-1), 0 0 3px var(--surface-1)" }
                    : {}),
                }}
              >
                {label}
              </span>
            )}
            {c.addedMs != null && c.addedMs > c.startMs && w > 8 && (
              <span
                className="absolute bottom-0 h-[3px]"
                style={{ left: Math.max(0, xOf(c.addedMs) - xOf(c.startMs)), right: 0, background: color }}
                aria-hidden="true"
              />
            )}
          </button>
        );
      })}
    </>
  );
}


// ----------------------------------------------------------------------------------------------- events lane

function EventsLane({
  lane, analysis, view, xOf, plotW, onCursor, onMarker, onShowCard, onHideCard, onPin,
}: {
  lane: Lane;
  analysis: CaptureAnalysis;
  view: [number, number];
  xOf: (t: number) => number;
  plotW: number;
  onCursor: (ms: number) => void;
  onMarker: (m: Marker) => void;
  onShowCard: (el: HTMLElement, body: HoverBody) => void;
  onHideCard: () => void;
  onPin: () => void;
}) {
  const [start, end] = view;
  // A marker is centred on its own time, so one at either end of the window hangs half its width past the plot.
  // Nudging those few pixels back inside keeps the glyph whole and the page from scrolling sideways; the exact
  // time is on the marker's card and in its label, so nothing is lost but the last 10 px of parallax.
  const inside = (t: number, halfW: number) => Math.min(plotW - halfW, Math.max(halfW, xOf(t)));
  const inView = analysis.journey.markers.filter((m) => m.tMs >= start && m.tMs <= end);
  const ticks = inView.filter((m) => TICK_KINDS.has(m.kind));
  const pills = inView.filter((m) => !TICK_KINDS.has(m.kind));

  // Cluster anything closer than CLUSTER_PX into one count pill, coloured by its worst member.
  const clusters: Marker[][] = [];
  for (const m of [...pills].sort((a, b) => a.tMs - b.tMs)) {
    const last = clusters[clusters.length - 1];
    if (last && Math.abs(xOf(m.tMs) - xOf((last[0] as Marker).tMs)) < CLUSTER_PX) last.push(m);
    else clusters.push([m]);
  }

  return (
    <>
      {ticks.map((m) => (
        <button
          key={m.id}
          className="absolute w-[7px] -translate-x-1/2 rounded-[1px]"
          style={{ left: inside(m.tMs, 4), top: lane.top + EVENTS_H - 6, height: 6, background: severityColor(m.severity) }}
          aria-label={`${m.title} at ${fmtSince(m.tMs)}`}
          onClick={() => onMarker(m)}
          onMouseEnter={(e) => onShowCard(e.currentTarget, markerCard(m))}
          onMouseLeave={onHideCard}
          onFocus={(e) => onShowCard(e.currentTarget, markerCard(m))}
          onBlur={onHideCard}
          onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); onShowCard(e.currentTarget, markerCard(m)); onPin(); } }}
        />
      ))}

      {clusters.map((group) => {
        const first = group[0] as Marker;
        const worst = group.reduce((a, b) => (rank(b.severity) > rank(a.severity) ? b : a));
        const color = severityColor(worst.severity);
        if (group.length === 1) {
          const Glyph = GLYPHS[first.kind] ?? CircleDot;
          return (
            <button
              key={first.id}
              className="absolute grid size-5 -translate-x-1/2 place-items-center rounded-full bg-[var(--surface-3)] transition-transform duration-[120ms] hover:scale-110"
              style={{ left: inside(first.tMs, 11), top: lane.top + 1, boxShadow: `inset 0 0 0 1px ${color}` }}
              aria-label={`${first.title} at ${fmtSince(first.tMs)}${first.detail ? `. ${first.detail}` : ""}. Enter opens its card, click jumps to it.`}
              onClick={() => onMarker(first)}
              onMouseEnter={(e) => onShowCard(e.currentTarget, markerCard(first))}
              onMouseLeave={onHideCard}
              onFocus={(e) => onShowCard(e.currentTarget, markerCard(first))}
              onBlur={onHideCard}
              onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); onShowCard(e.currentTarget, markerCard(first)); onPin(); } }}
            >
              <Glyph className="size-3" style={{ color }} />
            </button>
          );
        }
        return (
          <Popover key={`cluster-${first.id}`}>
            <PopoverTrigger asChild>
              <button
                className="num absolute h-5 -translate-x-1/2 rounded-full bg-[var(--surface-3)] px-1.5 text-[11px] font-medium leading-5"
                style={{ left: inside(first.tMs, 14), top: lane.top + 1, boxShadow: `inset 0 0 0 1px ${color}`, color: "var(--text)" }}
                aria-label={`${group.length} events around ${fmtSince(first.tMs)}`}
                onMouseEnter={onPin}
              >
                {group.length}
              </button>
            </PopoverTrigger>
            <PopoverContent align="center" className="w-[280px] p-1">
              <p className="px-2 py-1 text-[11px] font-medium uppercase tracking-[0.02em] text-[var(--text-3)]">
                {group.length} events
              </p>
              {group.map((m) => {
                const Glyph = GLYPHS[m.kind] ?? CircleDot;
                return (
                  <button
                    key={m.id}
                    className="grid w-full grid-cols-[16px_minmax(0,1fr)_auto] items-center gap-2 rounded-[4px] px-2 py-1 text-left text-[13px] hover:bg-[var(--surface-2)]"
                    onClick={() => { onCursor(m.tMs); onMarker(m); }}
                  >
                    <Glyph className="size-4" style={{ color: severityColor(m.severity) }} />
                    <span className="min-w-0 truncate">{m.title}</span>
                    <span className="num text-[11px] text-[var(--text-3)]">{fmtSince(m.tMs)}</span>
                  </button>
                );
              })}
            </PopoverContent>
          </Popover>
        );
      })}
    </>
  );
}

// -------------------------------------------------------------------------------------------------- minimap

function Minimap({
  analysis, palette, view, duration, gutter, onView,
}: {
  analysis: CaptureAnalysis;
  palette: BandPalette;
  view: [number, number];
  duration: number;
  gutter: number;
  onView: (a: number, b: number) => void;
}) {
  const ref = useRef<HTMLDivElement | null>(null);
  const drag = useRef<{ mode: "move" | "left" | "right" | "new"; from: number; view: [number, number] } | null>(null);
  const pct = (t: number) => `${(clamp(t, 0, duration) / duration) * 100}%`;
  const timeAt = (clientX: number) => {
    const r = ref.current?.getBoundingClientRect();
    if (!r) return 0;
    return clamp(((clientX - r.left) / r.width) * duration, 0, duration);
  };

  return (
    <div className="hidden items-stretch border-t border-[var(--line)] sm:flex" style={{ height: MINIMAP_H }}>
      <div className="shrink-0 border-r border-[var(--line)] bg-[var(--surface-1)]" style={{ width: gutter }} />
      <div
        ref={ref}
        // overflow-hidden because the two brush handles sit 4 px outside the brush so they are easy to grab.
        // When the window covers the whole capture the brush is flush with this box, and those 4 px became 4 px
        // of horizontal page scroll. Clipping them costs nothing: the brush edge itself is still the grab area.
        className="relative min-w-0 flex-1 touch-none overflow-hidden bg-[var(--surface-1)]"
        role="group"
        aria-label="Overview minimap. Drag the bright window to pan, its edges to resize."
        onPointerDown={(e) => {
          e.currentTarget.setPointerCapture(e.pointerId);
          const t = timeAt(e.clientX);
          const target = (e.target as HTMLElement).dataset["handle"];
          const mode = target === "left" || target === "right" ? target : target === "brush" ? "move" : "new";
          drag.current = { mode, from: t, view };
          if (mode === "new") onView(t, t + Math.max(MIN_WINDOW_MS, view[1] - view[0]) * 0.001);
        }}
        onPointerMove={(e) => {
          const d = drag.current;
          if (!d) return;
          const t = timeAt(e.clientX);
          if (d.mode === "move") {
            const delta = t - d.from;
            onView(d.view[0] + delta, d.view[1] + delta);
          } else if (d.mode === "left") onView(t, d.view[1]);
          else if (d.mode === "right") onView(d.view[0], t);
          else onView(d.from, t);
        }}
        onPointerUp={() => { drag.current = null; }}
      >
        {/* The whole capture in miniature: PCell band strip, NR strip, marker ticks. */}
        {analysis.journey.cells.filter((c) => c.lane === "pcell").map((c) => (
          <span key={`mm-p-${c.startMs}`} className="absolute top-1 h-2.5" style={{ left: pct(c.startMs), width: pct(c.endMs - c.startMs), background: palette.backgroundOf(c.band), boxShadow: `inset 0 0 0 1px ${palette.colorOf(c.band)}` }} />
        ))}
        {analysis.journey.cells.filter((c) => c.lane === "pscell").map((c) => (
          <span key={`mm-n-${c.startMs}`} className="absolute top-[14px] h-1.5" style={{ left: pct(c.startMs), width: pct(c.endMs - c.startMs), background: "var(--band-nr)" }} />
        ))}
        {analysis.journey.markers.map((m) => (
          <span key={`mm-m-${m.id}`} className="absolute bottom-0.5 h-1.5 w-px" style={{ left: pct(m.tMs), background: severityColor(m.severity) }} />
        ))}

        {/* Outside the window is dimmed; the window itself is the brush. */}
        <span className="pointer-events-none absolute inset-y-0 left-0 bg-[var(--bg)]/65" style={{ width: pct(view[0]) }} />
        <span className="pointer-events-none absolute inset-y-0 right-0 bg-[var(--bg)]/65" style={{ left: pct(view[1]) }} />
        <span
          data-handle="brush"
          className="absolute inset-y-0 cursor-grab ring-1 ring-inset ring-[var(--action)]"
          style={{ left: pct(view[0]), width: pct(view[1] - view[0]) }}
        >
          <span data-handle="left" className="absolute inset-y-0 -left-1 w-2 cursor-ew-resize" />
          <span data-handle="right" className="absolute inset-y-0 -right-1 w-2 cursor-ew-resize" />
        </span>
      </div>
    </div>
  );
}

// ------------------------------------------------------------------------------------------------ hover card

interface HoverBody {
  title: string;
  time: string;
  lines: string[];
  zoom?: [number, number] | undefined;
  event?: number | undefined;
  /** The moment this card is about, for "Show on timeline". */
  tMs?: number | undefined;
}

function HoverCard({ hover, pinned, onClose, onZoom, onOpenFlow, onShowOnTimeline }: {
  hover: { x: number; y: number; body: HoverBody };
  pinned: boolean;
  onClose: () => void;
  onZoom: (a: number, b: number) => void;
  onOpenFlow: (event: number) => void;
  onShowOnTimeline: (ms: number) => void;
}) {
  const { body } = hover;
  return (
    <div
      className="instrument-shadow fixed z-50 w-[280px] rounded-[8px] border border-[var(--line)] bg-[var(--surface-3)] p-3"
      style={{ left: Math.max(8, Math.min(hover.x - 140, window.innerWidth - 292)), top: hover.y }}
      role={pinned ? "dialog" : "tooltip"}
    >
      <div className="flex items-baseline justify-between gap-2">
        <p className="min-w-0 truncate text-[13px] font-medium">{body.title}</p>
        <span className="num shrink-0 text-[11px] text-[var(--text-3)]">{body.time}</span>
      </div>
      {body.lines.map((l) => (
        <p key={l} className="num mt-1 text-[11px] leading-4 text-[var(--text-2)]">{l}</p>
      ))}
      {pinned && (
        <div className="mt-2 flex gap-1.5">
          {body.event != null && (
            <button className="btn-quiet" onClick={() => { onOpenFlow(body.event as number); onClose(); }}>
              Show in call flow
            </button>
          )}
          {body.tMs != null && (
            <button className="btn-quiet" onClick={() => { onShowOnTimeline(body.tMs as number); onClose(); }}>
              Show on timeline
            </button>
          )}
          {body.zoom && (
            <button className="btn-quiet" onClick={() => { onZoom(body.zoom?.[0] ?? 0, body.zoom?.[1] ?? 0); onClose(); }}>
              Zoom here
            </button>
          )}
          <button className="btn-quiet" onClick={onClose}>Close</button>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------- pieces

function LegendPopover({ palette }: { palette: BandPalette }) {
  return (
    <Popover>
      <PopoverTrigger asChild>
        <button className="icon-btn size-5" aria-label="What the timeline colours and edges mean">
          <HelpCircle className="size-3.5" />
        </button>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-[320px] space-y-3 text-[12px]">
        <div>
          <p className="mb-1.5 text-[11px] font-medium uppercase tracking-[0.02em] text-[var(--text-3)]">Bands</p>
          {palette.bands.map((b) => (
            <p key={b.band} className="flex items-center gap-2 py-0.5">
              <span
                className="size-3 shrink-0 rounded-[2px]"
                style={{
                  background: b.pattern === "solid"
                    ? b.color
                    : `${patternLayer(b.pattern, b.color)}, var(--surface-2)`,
                  boxShadow: b.pattern === "solid" ? undefined : `inset 0 0 0 1px ${b.color}`,
                }}
              />
              <span className="num">{b.band}</span>
              <span className="num ml-auto text-[var(--text-3)]">{fmtDuration(b.onAirMs)}</span>
              {b.pattern !== "solid" && (
                <span className="shrink-0 text-[var(--text-3)]">{PATTERN_LABEL[b.pattern]}</span>
              )}
            </p>
          ))}
          <p className="mt-1.5 text-[var(--text-3)]">
            Three colours are proven to stay apart for colour-blind readers, so the three bands with the most time
            on air take them. The rest take the neutral grey with a texture of its own — hatch, dots, cross-hatch —
            and always print their name on the segment, so two grey lanes are never the same. Every 5G band takes
            the pink.
          </p>
        </div>
        <div className="space-y-1">
          <p className="text-[11px] font-medium uppercase tracking-[0.02em] text-[var(--text-3)]">Edges</p>
          <p><span className="num">Faded right edge</span> — still open when the trace ends.</p>
          <p><span className="num">Dashed right edge</span> — the end was inferred, not logged.</p>
          <p><span className="num">Hatched state lane</span> — the radio was off.</p>
          <p><span className="num">Dotted state lane</span> — no data.</p>
        </div>
      </PopoverContent>
    </Popover>
  );
}

function IconBtn({ label, onClick, children }: { label: string; onClick: () => void; children: React.ReactNode }) {
  return (
    <button className="icon-btn" aria-label={label} title={label} onClick={onClick}>
      {children}
    </button>
  );
}

// ----------------------------------------------------------------------------------------------------- utils

function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, v));
}

function buildTicks(start: number, end: number, plotW: number): { values: number[]; step: number } {
  const span = Math.max(1, end - start);
  const maxTicks = Math.max(2, Math.floor(plotW / TICK_GAP_PX));
  const steps = [10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000, 30_000, 60_000];
  const step = steps.find((s) => span / s <= maxTicks) ?? 60_000;
  const values: number[] = [];
  for (let t = Math.ceil(start / step) * step; t <= end; t += step) values.push(t);
  return { values, step };
}

/**
 * 'B66 · 66886 / PCI 301' → 'B66 · PCI 301' → 'B66' → nothing, whichever fits (audit E3).
 *
 * `always` keeps the band name even when it does not fit: a band drawn in the neutral colour has no hue to
 * identify it, so the truncated word is the only thing left that can. The span truncates with an ellipsis.
 */
function fitCellLabel(c: JourneyCell, width: number, always = false): string {
  const pending = c.cell.nr && c.cell.pci === 0xffff;
  const options = pending
    ? [`${c.band} · NR cell pending`, c.band]
    : [`${c.band} · ${c.cell.earfcn} / PCI ${c.cell.pci}`, `${c.band} · PCI ${c.cell.pci}`, c.band];
  // Geist Mono at 11 px is about 6.6 px per character; 12 px covers the padding.
  const fits = (s: string) => s.length * 6.6 + 12 <= width;
  return options.find(fits) ?? (always && width >= 14 ? c.band : "");
}

function cellAria(c: JourneyCell, palette: BandPalette): string {
  const what = c.lane === "scell" ? `SCell ${c.index}` : c.lane === "pscell" ? "NR PSCell" : "PCell";
  const end = c.openAtEnd ? "still open at the end of the trace" : c.endInferred ? `${fmtSince(c.endMs)} (inferred)` : fmtSince(c.endMs);
  const texture = palette.patterned(c.band) ? `, drawn ${PATTERN_LABEL[palette.patternOf(c.band)]}` : "";
  return `${what} ${c.band}${texture}, ${c.cell.nr ? "NR-ARFCN" : "EARFCN"} ${c.cell.earfcn}, PCI ${c.cell.pci}, from ${fmtSince(c.startMs)} to ${end}`;
}

function cellCard(c: JourneyCell): HoverBody {
  const what = c.lane === "scell" ? `SCell ${c.index}` : c.lane === "pscell" ? "NR PSCell" : "PCell";
  const lines = [
    `${c.cell.nr ? "NR-ARFCN" : "EARFCN"} ${c.cell.earfcn} · PCI ${c.cell.pci === 0xffff ? "pending" : c.cell.pci}`,
    c.dlMhz != null ? `Downlink ${fmtMetric(c.dlMhz, "MHz")}` : "",
    c.bandCandidates?.length ? `Band candidates ${c.bandCandidates.map((b) => `n${b}`).join(" / ")}` : "",
    `Lasted ${fmtDuration(c.endMs - c.startMs)}`,
    c.startReason ? `Entered: ${c.startReason}` : "",
    c.endReason ? `Left: ${c.endReason}` : c.openAtEnd ? "Still open when the trace ended" : "",
    c.endInferred ? "The end was inferred, not logged" : "",
    c.source ? `Evidence: ${c.source === "phy" ? "from PHY" : c.source}` : "",
  ].filter(Boolean);
  return { title: `${what} · ${c.band}`, time: `${fmtSince(c.startMs)} – ${fmtSince(c.endMs)}`, lines, tMs: c.startMs, zoom: [c.startMs, c.endMs] };
}

function markerCard(m: Marker): HoverBody {
  const lines = [
    m.detail ?? "",
    m.durationMs != null ? `Took ${fmtDuration(m.durationMs)}` : "",
    m.arrivalMs != null ? `Arrived ${fmtSince(m.arrivalMs)}` : "",
    m.ta != null ? `Timing advance ${m.ta}${m.distanceM != null ? ` ≈ ${fmtValue(m.distanceM)} m` : ""}` : "",
    m.inferred ? "Inferred, not logged" : "",
    MARKER_LABEL[m.kind],
  ].filter(Boolean);
  return { title: m.title, time: fmtSince(m.tMs), lines, tMs: m.tMs, ...(m.event != null ? { event: m.event } : {}) };
}

function severityColor(s: Marker["severity"]): string {
  if (s === "failure") return "var(--critical)";
  if (s === "warning") return "var(--warning)";
  return "var(--info)";
}

function rank(s: Marker["severity"]): number {
  return s === "failure" ? 2 : s === "warning" ? 1 : 0;
}

function shortLaneLabel(lane: Lane): string {
  if (lane.kind === "state") return "State";
  if (lane.kind === "registration") return "";
  if (lane.kind === "pcell") return "PCell";
  if (lane.kind === "pscell") return "NR";
  if (lane.kind === "events") return "Events";
  // The band is dropped in the 64 px gutter, but the "+1" for the SCell lanes that did not fit is not: it is the
  // only thing telling the reader the phone had more carriers than the phone screen can show.
  const more = lane.label.match(/\s(\+\d+)$/)?.[1] ?? "";
  return `SC${lane.scellIndex}${more}`;
}

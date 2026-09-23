// The call flow, drawn as a sequence diagram from analysis.ladder — not rebuilt from the events (audit A16). The
// engine has already folded repeated broadcast runs, grouped procedures and placed the move rows, so the UI's job
// is only to lay them out and keep them in step with the cursor.
//
// The cursor row is the last row at or before the cursor, never the nearest one, so it can never point at a
// message that has not happened yet. J/K and / are scoped to this panel, so they cannot fight the tabs or a text
// field (audit A20).
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import {
  ArrowDown, ArrowLeftRight, ArrowUp, ChevronDown, ChevronUp, CircleCheck, CircleDashed, Lock, OctagonX,
  RadioTower, Search, Server, Smartphone,
} from "lucide-react";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Sheet, SheetContent, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { MessageDetailPanel } from "@/components/capture/MessageDetailPanel";
import { bandChip, displayText, fmtSince } from "@/lib/analysis/format";
import { useBandPalette } from "@/lib/analysis/palette";
import type { CaptureAnalysis, Event, FlowFilter, LadderRow } from "@engine/types";
import { cn } from "@/lib/utils";

const ROW_H = 36;
/** The time gutter, matching the grid's first column. */
const GUTTER_PX = 88;
const PANEL_MIN = 320;
const PANEL_MAX = 640;
/** Lifeline positions across the diagram area, as fractions. */
const LIFELINES = { phone: 0.166, ran: 0.5, core: 0.833 };

export function CallFlowTab({
  analysis, masked, cursorMs, selectedEvent, followCursor, initialProcedure, onSelect, onRequestReveal, searchRef,
}: {
  analysis: CaptureAnalysis;
  masked: boolean;
  cursorMs: number;
  selectedEvent: number | null;
  followCursor: boolean;
  initialProcedure?: string;
  onSelect: (e: Event | null) => void;
  onRequestReveal: () => void;
  /** Handed up so the page's "/" shortcut can focus this box from anywhere. */
  searchRef?: React.RefObject<HTMLInputElement | null>;
}) {
  const palette = useBandPalette(analysis);
  const [filter, setFilter] = useState<FlowFilter>("ALL");
  const [query, setQuery] = useState("");
  const [procedure, setProcedure] = useState<string | null>(initialProcedure ?? null);
  const [fold, setFold] = useState(true);
  const [follow, setFollow] = useState(followCursor);
  const [matchIndex, setMatchIndex] = useState(0);
  const [panelWidth, setPanelWidth] = useState(420);
  const wide = useWideViewport();
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const ownSearchRef = useRef<HTMLInputElement | null>(null);
  const searchBox = searchRef ?? ownSearchRef;
  const regionRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (initialProcedure) setProcedure(initialProcedure);
  }, [initialProcedure]);

  const rows = useMemo(() => expand(analysis.ladder.rows[filter], analysis, fold), [analysis, filter, fold]);
  const visible = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return rows.filter((row) => {
      if (procedure && !inProcedure(row, analysis, procedure)) return false;
      if (!needle) return true;
      return rowText(row, analysis, masked).includes(needle);
    });
  }, [analysis, masked, procedure, query, rows]);

  const matches = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) return [];
    return visible.flatMap((r, i) => (rowText(r, analysis, masked).includes(needle) ? [i] : []));
  }, [analysis, masked, query, visible]);

  // The gutter bracket (audit E7): a 2 px rule down the time column beside every row a procedure owns, so a
  // banner and its messages read as one block instead of a heading with loose rows under it. Built once per
  // capture from the procedures' own first/last event indices — the ladder is virtualised, so each row has to be
  // able to draw its own piece of the bracket without knowing about its neighbours.
  const bracket = useMemo(() => buildBrackets(analysis), [analysis]);

  const cursorRow = useMemo(() => lastAtOrBefore(visible, analysis, cursorMs), [analysis, cursorMs, visible]);
  const virtualizer = useVirtualizer({
    count: visible.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: (i) => (visible[i]?.type === "message" ? ROW_H : 30),
    overscan: 12,
  });
  const selected = selectedEvent == null ? null : analysis.events[selectedEvent] ?? null;

  useEffect(() => {
    if (follow && cursorRow >= 0) virtualizer.scrollToIndex(cursorRow, { align: "center" });
  }, [cursorRow, follow, virtualizer]);

  const moveMessage = useCallback(
    (dir: 1 | -1) => {
      const current = selectedEvent ?? analysis.events.findLast((e) => e.sinceStartMs <= cursorMs)?.index ?? 0;
      const next = analysis.events[current + dir];
      if (next) onSelect(next);
    },
    [analysis.events, cursorMs, onSelect, selectedEvent],
  );

  const moveMatch = (dir: 1 | -1) => {
    if (!matches.length) return;
    const next = (matchIndex + dir + matches.length) % matches.length;
    setMatchIndex(next);
    virtualizer.scrollToIndex(matches[next] ?? 0, { align: "center" });
  };

  // Scoped to this region: pressing J in the search box types a J.
  const onKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
    const inField = (e.target as HTMLElement).tagName === "INPUT";
    if (e.key === "/" && !inField) {
      e.preventDefault();
      searchBox.current?.focus();
      return;
    }
    if (inField) {
      if (e.key === "Escape") (e.target as HTMLInputElement).blur();
      return;
    }
    if (e.key.toLowerCase() === "j") { e.preventDefault(); moveMessage(1); }
    else if (e.key.toLowerCase() === "k") { e.preventDefault(); moveMessage(-1); }
    else if (e.key === "Escape" && selectedEvent != null) onSelect(null);
  };

  // Messages, not rows: a folded broadcast run counts as the messages it holds, so these add up to the tab's count.
  const messagesIn = (rows: LadderRow[]) =>
    rows.reduce((n, r) => (r.type === "message" ? n + 1 + r.repeats.length : n), 0);
  const counts = {
    ALL: messagesIn(analysis.ladder.rows.ALL),
    RRC: messagesIn(analysis.ladder.rows.RRC),
    NAS: messagesIn(analysis.ladder.rows.NAS),
  };

  return (
    <div
      ref={regionRef}
      className="min-w-0 outline-none"
      style={{ "--flow-gutter": `${GUTTER_PX}px` } as React.CSSProperties}
      onKeyDown={onKeyDown}
      role="group"
      aria-label="Call flow"
    >
      {/* Toolbar */}
      <div className="sticky top-[calc(var(--header-h)+var(--dock-h,0px)+40px)] z-10 -mx-4 flex min-h-11 flex-wrap items-center gap-2 border-b border-[var(--line)] bg-[var(--bg)]/95 px-4 py-1.5 backdrop-blur sm:-mx-6 sm:px-6">
        <div className="flex shrink-0 rounded-[6px] border border-[var(--line)] p-0.5">
          {(["ALL", "RRC", "NAS"] as FlowFilter[]).map((f) => (
            <button
              key={f}
              onClick={() => setFilter(f)}
              aria-pressed={filter === f}
              className={cn(
                "flex h-7 items-center gap-1 rounded-[4px] px-2 text-[13px] transition-colors duration-[120ms]",
                filter === f ? "bg-[var(--surface-2)] font-medium text-[var(--text)]" : "text-[var(--text-3)] hover:text-[var(--text)]",
              )}
            >
              {f === "ALL" ? "All" : f}
              <span className="num text-[11px] text-[var(--text-3)]">{counts[f]}</span>
            </button>
          ))}
        </div>

        <div className="relative min-w-0 flex-1 sm:max-w-xs">
          <Search className="pointer-events-none absolute left-2 top-1/2 size-3.5 -translate-y-1/2 text-[var(--text-3)]" />
          <input
            ref={searchBox}
            value={query}
            onChange={(e) => { setQuery(e.target.value); setMatchIndex(0); }}
            placeholder="Search messages   /"
            aria-label="Search messages"
            className="h-8 w-full rounded-[6px] border border-[var(--line)] bg-[var(--surface-1)] pl-7 pr-2 text-[13px] placeholder:text-[var(--text-3)]"
          />
        </div>
        {query && (
          <span className="num shrink-0 text-xs text-[var(--text-3)]">
            {matches.length ? matchIndex + 1 : 0} of {matches.length}
          </span>
        )}
        <span className="flex shrink-0">
          <button className="icon-btn" aria-label="Previous match" onClick={() => moveMatch(-1)}><ChevronUp className="size-4" /></button>
          <button className="icon-btn" aria-label="Next match" onClick={() => moveMatch(1)}><ChevronDown className="size-4" /></button>
        </span>

        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <button className="btn-quiet shrink-0">{procedure ?? "All procedures"}</button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="max-h-80 overflow-y-auto">
            <DropdownMenuItem onSelect={() => setProcedure(null)}>All procedures</DropdownMenuItem>
            {analysis.ladder.procedureGroups.map((g) => (
              <DropdownMenuItem key={g.name} onSelect={() => setProcedure(g.name)}>
                {g.name}
                <span className="num ml-auto pl-3 text-[11px] text-[var(--text-3)]">{g.succeeded}/{g.n}</span>
              </DropdownMenuItem>
            ))}
          </DropdownMenuContent>
        </DropdownMenu>

        <Toggle on={fold} onChange={setFold} label="Fold broadcast" />
        <Toggle on={follow} onChange={setFollow} label="Follow cursor" />
      </div>

      <div className="mt-3 flex min-w-0 gap-0">
        <section className="panel min-w-0 flex-1 overflow-hidden" aria-label="Call flow sequence">
          {/* Sticky lane header with the lifelines */}
          <div className="relative grid h-8 grid-cols-[var(--flow-gutter)_minmax(0,1fr)] items-center border-b border-[var(--line)] bg-[var(--surface-2)] text-[11px] font-medium uppercase tracking-[0.02em] text-[var(--text-3)]">
            <span className="pl-3">Time</span>
            <div className="relative h-full">
              {(Object.keys(LIFELINES) as (keyof typeof LIFELINES)[]).map((k) => (
                <span
                  key={k}
                  className="absolute top-1/2 flex -translate-x-1/2 -translate-y-1/2 items-center gap-1 whitespace-nowrap"
                  style={{ left: `${LIFELINES[k] * 100}%` }}
                >
                  {k === "phone" ? <Smartphone className="size-3.5" /> : k === "ran" ? <RadioTower className="size-3.5" /> : <Server className="size-3.5" />}
                  <span className="hidden sm:inline">{analysis.ladder.lanes[k]}</span>
                </span>
              ))}
            </div>
          </div>

          <div ref={scrollRef} className="relative h-[min(68vh,680px)] overflow-auto">
            {/* The lifelines themselves run the whole height. */}
            <div
              className="pointer-events-none absolute right-0 top-0"
              style={{ left: GUTTER_PX, height: virtualizer.getTotalSize() }}
            >
              {Object.values(LIFELINES).map((f) => (
                <span key={f} className="absolute inset-y-0 w-px bg-[var(--line-strong)]" style={{ left: `${f * 100}%` }} />
              ))}
            </div>
            <div style={{ height: virtualizer.getTotalSize(), position: "relative" }}>
              {virtualizer.getVirtualItems().map((item) => {
                const row = visible[item.index];
                if (!row) return null;
                return (
                  <div
                    key={row.key}
                    ref={virtualizer.measureElement}
                    data-index={item.index}
                    style={{ position: "absolute", top: 0, left: 0, width: "100%", transform: `translateY(${item.start}px)` }}
                  >
                    <Row
                      row={row}
                      analysis={analysis}
                      masked={masked}
                      query={query}
                      isCursor={item.index === cursorRow}
                      isSelected={row.type === "message" && row.event === selectedEvent}
                      bracket={bracketFor(row, bracket)}
                      bandOf={(cell) => bandChip(cell, analysis)}
                      colorOf={palette.colorOf}
                      onSelect={onSelect}
                    />
                  </div>
                );
              })}
            </div>
          </div>
        </section>

        {/* The docked detail panel, with a drag handle. Under 1024 px it becomes a bottom sheet instead.
            The choice is made here, not with a `lg:hidden` wrapper: the sheet portals to <body>, so a CSS-only
            hide would leave it rendered (and its overlay dimming the page) on the desktop too. */}
        {selected && wide && (
          <div className="flex">
            <Resizer width={panelWidth} onWidth={setPanelWidth} />
            <div style={{ width: panelWidth }} className="min-w-0">
              <MessageDetailPanel
                analysis={analysis}
                event={selected}
                masked={masked}
                onClose={() => onSelect(null)}
                onMove={moveMessage}
                onRequestReveal={onRequestReveal}
              />
            </div>
          </div>
        )}
      </div>

      {!wide && (
        <Sheet open={!!selected} onOpenChange={(open: boolean) => !open && onSelect(null)}>
          <SheetContent side="bottom" className="max-h-[86svh] overflow-y-auto border-[var(--line)] bg-[var(--surface-1)] p-0">
            <SheetHeader className="sr-only">
              <SheetTitle>{selected?.name ?? "Message"}</SheetTitle>
            </SheetHeader>
            <MessageDetailPanel
              analysis={analysis}
              event={selected}
              masked={masked}
              onClose={() => onSelect(null)}
              onMove={moveMessage}
              onRequestReveal={onRequestReveal}
              embedded
            />
          </SheetContent>
        </Sheet>
      )}
    </div>
  );
}

/** True while the viewport is at least `min` wide. Matches the lg breakpoint the docked panel needs. */
function useWideViewport(min = 1024): boolean {
  const [wide, setWide] = useState(() => typeof window !== "undefined" && window.innerWidth >= min);
  useEffect(() => {
    const mq = window.matchMedia(`(min-width: ${min}px)`);
    const on = () => setWide(mq.matches);
    on();
    mq.addEventListener("change", on);
    return () => mq.removeEventListener("change", on);
  }, [min]);
  return wide;
}

// -------------------------------------------------------------------------------------------------------- rows

function Row({
  row, analysis, masked, query, isCursor, isSelected, bracket, bandOf, colorOf, onSelect,
}: {
  row: LadderRow;
  analysis: CaptureAnalysis;
  masked: boolean;
  query: string;
  isCursor: boolean;
  isSelected: boolean;
  bracket: BracketPiece | null;
  bandOf: (cell: NonNullable<Event["cell"]>) => string;
  colorOf: (band: string) => string;
  onSelect: (e: Event) => void;
}) {
  if (row.type === "procedure") {
    const p = analysis.procedures[row.procedure];
    const outcome = p?.outcome ?? row.outcome;
    // A one-message procedure — a Detach that is only its own request, a reconfiguration with no answer — starts
    // and ends on the same event, so "0.0 ms" is not a measurement of anything. Say nothing instead.
    const instant = p ? p.first === p.last || p.durationMs === 0 : row.duration.startsWith("0.0 ");
    const Icon = outcome === "SUCCEEDED" ? CircleCheck : outcome === "FAILED" ? OctagonX : CircleDashed;
    const tint = outcome === "FAILED" ? "var(--critical)" : outcome === "SUCCEEDED" ? "var(--good)" : "var(--text-3)";
    return (
      <div className="grid min-h-[30px] grid-cols-[var(--flow-gutter)_minmax(0,1fr)] items-center border-y border-[var(--line)] bg-[var(--surface-2)] text-xs">
        <span className="num relative pl-3 text-[var(--text-3)]">
          <Bracket piece={bracket} tint={tint} />
          {p ? fmtSince(analysis.events[p.first]?.sinceStartMs ?? 0) : ""}
        </span>
        <div className="flex min-w-0 items-center gap-2 pr-3">
          <Icon className="size-3.5 shrink-0" style={{ color: tint }} />
          <span className="min-w-0 truncate font-medium">{row.name}</span>
          <span className="num ml-auto shrink-0 text-[var(--text-3)]">
            {instant ? <span className="text-[var(--text-3)]">one message</span> : row.duration}
          </span>
        </div>
      </div>
    );
  }

  if (row.type === "move") {
    const step = analysis.steps[row.step];
    return (
      <div className="grid min-h-[30px] grid-cols-[var(--flow-gutter)_minmax(0,1fr)] items-center border-y border-dashed border-[var(--line-strong)] text-xs">
        <span className="num pl-3 text-[var(--text-3)]">{step ? fmtSince(step.sinceStartMs) : ""}</span>
        <div className="flex min-w-0 items-center gap-2 pr-3">
          <ArrowLeftRight className="size-3.5 shrink-0 text-[var(--text-2)]" />
          <span className="shrink-0 font-medium">{moveLabel(row.move)}</span>
          <span className="min-w-0 truncate">→ {row.to}</span>
          {row.band && (
            <span className="chip num shrink-0" style={{ borderColor: colorOf(row.band) }}>
              {row.band}{row.downlink ? ` · ${row.downlink}` : ""}
            </span>
          )}
          {step?.annotation && <span className="ml-auto hidden shrink-0 text-[var(--text-3)] sm:inline">{step.annotation}</span>}
        </div>
      </div>
    );
  }

  const event = analysis.events[row.event];
  if (!event) return null;
  const nas = event.layer === "NAS";
  const from = nas
    ? event.uplink ? LIFELINES.phone : LIFELINES.core
    : event.uplink ? LIFELINES.phone : LIFELINES.ran;
  const to = nas
    ? event.uplink ? LIFELINES.core : LIFELINES.phone
    : event.uplink ? LIFELINES.ran : LIFELINES.phone;
  const left = Math.min(from, to);
  const right = Math.max(from, to);
  const summary = displayText(event, masked);

  return (
    <button
      onClick={() => onSelect(event)}
      aria-current={isSelected ? "true" : undefined}
      className={cn(
        "grid w-full grid-cols-[var(--flow-gutter)_minmax(0,1fr)] items-center border-b border-[var(--line)] text-left transition-colors duration-[120ms] hover:bg-[var(--surface-2)]",
        isCursor && "bg-[var(--surface-2)] shadow-[inset_2px_0_0_0_var(--action)]",
        isSelected && "shadow-[inset_2px_0_0_0_var(--action)]",
        event.isFailure && "shadow-[inset_2px_0_0_0_var(--critical)]",
      )}
      style={{ minHeight: ROW_H }}
    >
      <span className="num relative py-1 pl-3 text-[11px] leading-4 text-[var(--text-3)]">
        <Bracket piece={bracket} tint="var(--line-strong)" />
        {row.since}
        {row.gap && <span className="block text-[var(--text-3)]">+{row.gap}</span>}
      </span>

      <span className="block min-w-0 py-1.5 pr-3">
        <span className="flex min-w-0 items-center gap-1.5">
          {event.uplink ? <ArrowUp className="size-3 shrink-0 text-[var(--text-3)] lg:hidden" /> : <ArrowDown className="size-3 shrink-0 text-[var(--text-3)] lg:hidden" />}
          <span className="chip shrink-0">{event.layer}</span>
          {event.rat === "NR" && <span className="chip shrink-0" style={{ borderColor: "var(--band-nr)" }}>NR</span>}
          <span className="min-w-0 truncate text-[13px] font-medium">{highlight(row.name, query)}</span>
          {row.count > 1 && <span className="chip num shrink-0">×{row.count}{row.mixed ? " mixed" : ""}</span>}
          {event.ciphered && <span className="chip shrink-0" title="Ciphered: no plain copy was logged"><Lock className="size-3" /></span>}
          {event.isHandoverCommand && <span className="chip shrink-0"><ArrowLeftRight className="size-3" /> handover</span>}
          {event.cell && (
            <span className="chip num ml-auto hidden max-w-40 shrink-0 truncate sm:inline-flex">
              {row.cells || bandOf(event.cell)}
            </span>
          )}
        </span>

        {/* The arrow gets its own band between the name and the summary, so it never strikes through either. */}
        <span className="relative block h-2.5">
          <span
            className="absolute top-1/2 h-px -translate-y-1/2"
            style={{
              left: `${left * 100}%`,
              width: `${(right - left) * 100}%`,
              background: nas ? "var(--text-2)" : "var(--action)",
            }}
          />
          <span
            className="absolute top-1/2 size-0 -translate-y-1/2"
            style={{
              left: `calc(${to * 100}% - ${to > from ? 4 : 0}px)`,
              borderTop: "3px solid transparent",
              borderBottom: "3px solid transparent",
              [to > from ? "borderLeft" : "borderRight"]: `4px solid ${nas ? "var(--text-2)" : "var(--action)"}`,
            }}
          />
          {nas && (
            <span
              className="absolute top-1/2 size-1.5 -translate-y-1/2 rotate-45 border border-[var(--text-2)]"
              style={{ left: `calc(${from * 100}% - 3px)` }}
            />
          )}
        </span>

        {summary && (
          <span className="block min-w-0 truncate text-xs text-[var(--text-3)]" title={summary}>
            {highlight(summary, query)}
          </span>
        )}
      </span>
    </button>
  );
}

/** Which part of a procedure's bracket a row draws: the top cap, the middle rule, or the bottom cap. */
type BracketPiece = "start" | "middle" | "end" | "only";

function Bracket({ piece, tint }: { piece: BracketPiece | null; tint: string }) {
  if (!piece) return null;
  const top = piece === "start" || piece === "only" ? "50%" : "0";
  const bottom = piece === "end" || piece === "only" ? "50%" : "0";
  return (
    <span
      aria-hidden="true"
      className="absolute left-1 w-[2px] rounded-full"
      style={{ top, bottom, background: tint, opacity: 0.85 }}
    />
  );
}

/** event index → the procedure it belongs to, and whether it is that procedure's last event. */
function buildBrackets(analysis: CaptureAnalysis): Map<number, { procedure: number; last: boolean }> {
  const map = new Map<number, { procedure: number; last: boolean }>();
  analysis.procedures.forEach((p, procedure) => {
    for (let e = p.first; e <= p.last; e++) {
      // A message can sit inside two nested procedures (a reconfiguration inside an attach); the innermost one,
      // which is the last to claim it, is the one whose bracket is drawn.
      map.set(e, { procedure, last: e === p.last });
    }
  });
  return map;
}

function bracketFor(row: LadderRow, map: Map<number, { procedure: number; last: boolean }>): BracketPiece | null {
  if (row.type === "procedure") return "start";
  if (row.type !== "message") return null;
  const hit = map.get(row.event);
  if (!hit) return null;
  return hit.last ? "end" : "middle";
}

function Toggle({ on, onChange, label }: { on: boolean; onChange: (v: boolean) => void; label: string }) {
  return (
    <button
      onClick={() => onChange(!on)}
      aria-pressed={on}
      className={cn(
        "btn-quiet shrink-0",
        on && "border-[var(--action)]/50 bg-[color-mix(in_oklab,var(--action)_12%,var(--surface-1))] text-[var(--text)]",
      )}
    >
      {on && <CircleCheck className="size-3.5" />}
      {label}
    </button>
  );
}

function Resizer({ width, onWidth }: { width: number; onWidth: (w: number) => void }) {
  const from = useRef<{ x: number; w: number } | null>(null);
  return (
    <div
      role="separator"
      aria-label="Resize the details panel"
      aria-orientation="vertical"
      tabIndex={0}
      className="group mx-1 w-1.5 shrink-0 cursor-ew-resize rounded-full bg-[var(--line)] transition-colors duration-[120ms] hover:bg-[var(--line-strong)]"
      onPointerDown={(e) => {
        e.currentTarget.setPointerCapture(e.pointerId);
        from.current = { x: e.clientX, w: width };
      }}
      onPointerMove={(e) => {
        if (!from.current) return;
        const next = from.current.w - (e.clientX - from.current.x);
        onWidth(Math.max(PANEL_MIN, Math.min(PANEL_MAX, next)));
      }}
      onPointerUp={() => { from.current = null; }}
      onKeyDown={(e) => {
        if (e.key === "ArrowLeft") onWidth(Math.min(PANEL_MAX, width + 24));
        if (e.key === "ArrowRight") onWidth(Math.max(PANEL_MIN, width - 24));
      }}
    />
  );
}

// ------------------------------------------------------------------------------------------------------- utils

function moveLabel(move: string): string {
  switch (move) {
    case "HANDOVER": return "Handover";
    case "RESELECTION": return "Reselection";
    case "REDIRECT": return "Redirect";
    case "REESTABLISHMENT": return "Re-establishment";
    case "CELL_CHANGE": return "Cell change";
    case "FIRST_SEEN": return "First seen on";
    default: return move;
  }
}

/** With folding off, the folded repeats are laid back out as their own rows. */
function expand(rows: LadderRow[], analysis: CaptureAnalysis, fold: boolean): LadderRow[] {
  if (fold) return rows;
  const out: LadderRow[] = [];
  for (const row of rows) {
    out.push(row);
    if (row.type !== "message") continue;
    for (const index of row.repeats) {
      const e = analysis.events[index];
      if (!e) continue;
      out.push({
        ...row,
        key: `${row.key}-repeat-${index}`,
        event: index,
        repeats: [],
        count: 1,
        mixed: false,
        name: e.name,
        since: fmtSince(e.sinceStartMs),
      });
    }
  }
  return out;
}

function rowTime(row: LadderRow, analysis: CaptureAnalysis): number {
  if (row.type === "message") return analysis.events[row.event]?.sinceStartMs ?? 0;
  if (row.type === "move") return analysis.steps[row.step]?.sinceStartMs ?? 0;
  const p = analysis.procedures[row.procedure];
  return p ? analysis.events[p.first]?.sinceStartMs ?? 0 : 0;
}

function rowText(row: LadderRow, analysis: CaptureAnalysis, masked: boolean): string {
  if (row.type === "message") {
    const e = analysis.events[row.event];
    return `${row.name} ${e ? displayText(e, masked) ?? "" : ""} ${e?.channel ?? ""} ${row.cells}`.toLowerCase();
  }
  if (row.type === "procedure") return row.name.toLowerCase();
  return `${row.to} ${row.band ?? ""}`.toLowerCase();
}

function inProcedure(row: LadderRow, analysis: CaptureAnalysis, name: string): boolean {
  if (row.type === "procedure") return row.name === name;
  if (row.type !== "message") return false;
  return analysis.procedures.some((p) => p.name === name && row.event >= p.first && row.event <= p.last);
}

/** The last row at or before the cursor. Rows are in time order, so this is a scan from the end. */
function lastAtOrBefore(rows: LadderRow[], analysis: CaptureAnalysis, cursorMs: number): number {
  for (let i = rows.length - 1; i >= 0; i--) {
    const row = rows[i];
    if (row && rowTime(row, analysis) <= cursorMs) return i;
  }
  return -1;
}

function highlight(text: string, query: string): React.ReactNode {
  const needle = query.trim();
  if (!needle) return text;
  const at = text.toLowerCase().indexOf(needle.toLowerCase());
  if (at < 0) return text;
  return (
    <>
      {text.slice(0, at)}
      <mark className="bg-[color-mix(in_oklab,var(--action)_25%,transparent)] text-[var(--text)]">
        {text.slice(at, at + needle.length)}
      </mark>
      {text.slice(at + needle.length)}
    </>
  );
}

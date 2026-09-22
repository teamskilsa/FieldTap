import { Link, useNavigate, useSearch } from "@tanstack/react-router";
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { AlertTriangle, BookOpen, FileArchive, OctagonX, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { CaptureHeader } from "@/components/capture/CaptureHeader";
import { CallFlowTab } from "@/components/capture/CallFlowTab";
import { OverviewTab } from "@/components/capture/OverviewTab";
import { RadioTab, type RadioSection } from "@/components/capture/RadioTab";
import { TrackView } from "@/components/journey/TrackView";
import { fmtSince } from "@/lib/analysis/format";
import { loadDevAnalysis } from "@/lib/analysis/dev-fixture";
import { createSampleAnalysis, type SampleVariant } from "@/lib/analysis/sample";
import { usePageMeta } from "@/lib/meta";
import { useCapture } from "@/state/capture";
import type { ImportProblem } from "@engine/types";

const VARIANTS = new Set<SampleVariant>(["ok", "expiredSince", "traceGaps", "loggingOff", "notSysdiagnose"]);

export type CaptureTab = "overview" | "flow" | "radio";
const TABS = new Set<CaptureTab>(["overview", "flow", "radio"]);
const SECTIONS = new Set<RadioSection>([
  "Signal", "Downlink", "Uplink", "CSI", "NR", "Carriers", "Antennas", "RACH", "Not available",
]);

/**
 * The whole view lives in the URL, so a view can be shared or bookmarked:
 *
 *   /capture?sample=ok&tab=radio&t=15040&w=12000-18000&section=nr
 *
 * `tab` picks the tab, `t` the cursor in ms since the time base, `w` the visible window as `start-end` in the
 * same units, and `section` the Radio section (matched case-insensitively, so `nr` and `not-available` work in a
 * typed URL). Each is written back with `replace: true` as the reader moves, so the back button steps between
 * places they navigated to rather than every scrub of the cursor. A real capture is never in a link — only the
 * sample and the dev fixture load themselves — so a shared URL can never carry someone's data.
 */
export interface CaptureSearch {
  /** Reloads the synthetic sample, so /capture survives a refresh (audit A27). */
  sample?: SampleVariant | undefined;
  /** Which tab is open, so a reload and a shared link both land in the same place. */
  tab?: CaptureTab | undefined;
  /** The cursor, in ms since the time base. */
  t?: number | undefined;
  /**
   * The visible window as `"start-end"` in ms since the time base. It is kept as the *string* the URL carries,
   * not a tuple: the router serialises an array member as JSON (`w=%5B0%2C22096%5D`), which is unreadable in a
   * shared link and does not survive its own round trip.
   */
  w?: string | undefined;
  /** Which Radio section is open. */
  section?: RadioSection | undefined;
  /** Dev only: load public/dev/analysis.json, a real capture that is never committed. */
  dev?: true | undefined;
}

const num = (v: unknown): number | undefined => {
  const n = typeof v === "number" ? v : typeof v === "string" ? Number(v) : NaN;
  return Number.isFinite(n) && n >= 0 ? n : undefined;
};

/**
 * `w=12000-18000` — a plain hyphen, because both ends are times since the start and never negative. A tuple is
 * also accepted, so a link written by an older build still opens.
 */
export function parseWindow(v: unknown): [number, number] | undefined {
  const parts = typeof v === "string" ? v.split("-") : Array.isArray(v) ? v : null;
  if (!parts || parts.length !== 2) return undefined;
  const lo = num(parts[0]);
  const hi = num(parts[1]);
  return lo != null && hi != null && hi > lo ? [lo, hi] : undefined;
}

/** The window as the URL carries it. */
const windowParam = ([a, b]: [number, number]) => `${Math.round(a)}-${Math.round(b)}`;

function parseSection(v: unknown): RadioSection | undefined {
  if (typeof v !== "string") return undefined;
  const wanted = v.replace(/[-_]/g, " ").trim().toLowerCase();
  return [...SECTIONS].find((s) => s.toLowerCase() === wanted);
}

export function validateCaptureSearch(search: Record<string, unknown>): CaptureSearch {
  const sample = search["sample"];
  const dev = search["dev"];
  const tab = search["tab"];
  const t = num(search["t"]);
  const w = parseWindow(search["w"]);
  const section = parseSection(search["section"]);
  return {
    sample: typeof sample === "string" && VARIANTS.has(sample as SampleVariant) ? (sample as SampleVariant) : undefined,
    tab: typeof tab === "string" && TABS.has(tab as CaptureTab) ? (tab as CaptureTab) : undefined,
    ...(t != null ? { t } : {}),
    ...(w ? { w: windowParam(w) } : {}),
    ...(section ? { section } : {}),
    dev: import.meta.env.DEV && (dev === "1" || dev === 1 || dev === true) ? true : undefined,
  };
}

export function CapturePage() {
  usePageMeta(
    "Capture timeline — FieldTap Log Analyzer",
    "Explore the decoded cell journey, signalling timeline, call flow and radio detail from an iPhone modem log.",
  );
  const search = useSearch({ from: "/capture" });
  const {
    analysis, setAnalysis, cursorMs, setCursorMs, glideCursorTo, flash, showOnTimeline,
    view, setView, fitView, masked, setMasked,
    selectedEvent, setSelectedEvent, activeTab, setActiveTab, followCursor, dockCollapsed, setDockCollapsed,
    announcement, setAnnouncement,
  } = useCapture();
  const [dismissed, setDismissed] = useState<string[]>([]);
  const [flowProcedure, setFlowProcedure] = useState<string | undefined>();
  const [radioSection, setRadioSection] = useState<RadioSection | undefined>(search.section);
  const [devError, setDevError] = useState<string | null>(null);
  const [shortcuts, setShortcuts] = useState(false);
  const navigate = useNavigate();
  const dockRef = useRef<HTMLDivElement | null>(null);
  const flowSearchRef = useRef<HTMLInputElement | null>(null);
  /** The URL's cursor and window are applied once, when the analysis they describe arrives. */
  const restored = useRef<string | null>(null);

  // Restore the sample on a reload, and load the dev fixture when asked for one.
  useEffect(() => {
    if (search.dev) {
      if (analysis?.fileName.startsWith("dev:")) return;
      void loadDevAnalysis().then(setAnalysis, (e: Error) => setDevError(e.message));
      return;
    }
    if (search.sample && (!analysis || !analysis.fileName.includes("_SAMPLE"))) {
      setAnalysis(createSampleAnalysis({ variant: search.sample }));
    }
  }, [analysis, search.dev, search.sample, setAnalysis]);

  // Everything below the dock sticks to its real height, so nothing hides under it at any width (audit A21).
  useLayoutEffect(() => {
    const el = dockRef.current;
    const root = document.documentElement;
    if (!el) {
      root.style.setProperty("--dock-h", "0px");
      return;
    }
    const ro = new ResizeObserver(() => root.style.setProperty("--dock-h", `${Math.round(el.offsetHeight)}px`));
    ro.observe(el);
    return () => {
      ro.disconnect();
      root.style.removeProperty("--dock-h");
    };
  }, [analysis, dockCollapsed]);

  // The tab lives in the URL; the store follows it.
  useEffect(() => {
    if (search.tab && search.tab !== activeTab) setActiveTab(search.tab);
  }, [activeTab, search.tab, setActiveTab]);

  // …and so do the cursor, the window and the Radio section, once, when the capture the link describes is open.
  // `setAnalysis` fits the window and parks the cursor at the attach, so this has to run after it, not with it.
  useEffect(() => {
    if (!analysis || restored.current === analysis.fileName) return;
    restored.current = analysis.fileName;
    if (search.t != null) setCursorMs(search.t);
    const w = parseWindow(search.w);
    if (w) setView(w);
    if (search.section) setRadioSection(search.section);
  }, [analysis, search.section, search.t, search.w, setCursorMs, setView]);

  // The URL follows the cursor and the window back, coalesced to one write per animation frame so a scrub or a
  // 150 ms glide does not push a history entry per frame. `replace` keeps the back button meaningful.
  const writeUrl = useCallback(
    (next: Partial<CaptureSearch>) => {
      void navigate({ to: "/capture", search: (old) => ({ ...old, ...next }), replace: true });
    },
    [navigate],
  );
  useEffect(() => {
    if (!analysis || restored.current !== analysis.fileName) return;
    const id = window.setTimeout(() => {
      writeUrl({ t: Math.round(cursorMs), w: windowParam(view) });
    }, 180);
    return () => window.clearTimeout(id);
  }, [analysis, cursorMs, view, writeUrl]);

  const goToTab = useCallback(
    (tab: CaptureTab) => {
      setActiveTab(tab);
      void navigate({ to: "/capture", search: (old) => ({ ...old, tab }), replace: true });
    },
    [navigate, setActiveTab],
  );

  const jump = useCallback(
    (tMs: number, event?: number) => {
      setCursorMs(tMs);
      if (event != null) setSelectedEvent(event);
    },
    [setCursorMs, setSelectedEvent],
  );
  const openFlow = (procedure?: string) => {
    setFlowProcedure(procedure);
    goToTab("flow");
  };
  const openRadio = useCallback(
    (section?: RadioSection) => {
      setRadioSection(section);
      setActiveTab("radio");
      void navigate({
        to: "/capture",
        search: (old) => ({ ...old, tab: "radio" as const, ...(section ? { section } : {}) }),
        replace: true,
      });
    },
    [navigate, setActiveTab],
  );

  // Under 640 px the dock is a third of the screen, so it folds itself away as the reader scrolls into the
  // content and comes back at the top. It is kept apart from the dock's own collapse toggle on purpose: an
  // automatic fold must never overwrite the preference the reader set by hand (that one persists, this does not).
  const [autoCollapsed, setAutoCollapsed] = useState(false);
  useEffect(() => {
    let last = window.scrollY;
    const onScroll = () => {
      if (window.innerWidth >= 640) {
        setAutoCollapsed(false);
        return;
      }
      const y = window.scrollY;
      if (y > last + 6 && y > 120) setAutoCollapsed(true);
      else if (y < last - 6 && y < 80) setAutoCollapsed(false);
      last = y;
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onScroll);
    };
  }, []);

  const stepMarker = useCallback(
    (dir: -1 | 1) => {
      if (!analysis) return;
      const times = analysis.journey.markers.map((m) => m.tMs).sort((a, b) => a - b);
      const next = dir < 0 ? [...times].reverse().find((t) => t < cursorMs - 1) : times.find((t) => t > cursorMs + 1);
      if (next == null) return;
      glideCursorTo(next);
      const m = analysis.journey.markers.find((x) => x.tMs === next);
      if (m) setAnnouncement(`${m.title} at ${fmtSince(m.tMs)}`);
    },
    [analysis, cursorMs, glideCursorTo, setAnnouncement],
  );

  /**
   * The page-level keyboard map. It is deliberately the *fallback*: the dock and the call-flow panel handle their
   * own keys while they hold focus and call preventDefault, so this never fights them, and it stands down inside
   * any text field. Everything it does is also reachable by pointer, and listed under `?`.
   */
  useEffect(() => {
    if (!analysis) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
      const el = e.target as HTMLElement | null;
      if (el && (el.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName))) return;
      const step = e.shiftKey ? 1000 : 100;
      let handled = true;
      switch (e.key) {
        case "ArrowLeft": setCursorMs(cursorMs - step); break;
        case "ArrowRight": setCursorMs(cursorMs + step); break;
        case "[": stepMarker(-1); break;
        case "]": stepMarker(1); break;
        case "0": fitView(); break;
        case "1": goToTab("overview"); break;
        case "2": goToTab("flow"); break;
        case "3": goToTab("radio"); break;
        case "?": setShortcuts((v) => !v); break;
        case "/":
          goToTab("flow");
          // After the tab has mounted its toolbar.
          window.setTimeout(() => flowSearchRef.current?.focus(), 0);
          break;
        default: handled = false;
      }
      if (handled) e.preventDefault();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [analysis, cursorMs, fitView, goToTab, setCursorMs, stepMarker]);

  if (!analysis) return <EmptyCapture error={devError} pendingDev={!!search.dev && !devError} />;

  const blocking = analysis.problems.filter((p) => p.blocking);
  const warnings = analysis.problems.filter((p) => !p.blocking && !dismissed.includes(p.kind));

  if (blocking.length) {
    return (
      <div className="mx-auto max-w-[960px] px-4 pb-16 sm:px-6">
        <CaptureHeader analysis={analysis} />
        <div className="mt-4 space-y-3">
          {blocking.map((p) => <ProblemCard key={p.kind} problem={p} />)}
        </div>
        <div className="mt-6 flex flex-wrap gap-2">
          <Button asChild><Link to="/guide"><BookOpen className="size-4" /> Open the guide</Link></Button>
          <Button variant="outline" asChild><Link to="/"><FileArchive className="size-4" /> Try another file</Link></Button>
        </div>
      </div>
    );
  }

  return (
    // No overflow-x-hidden here: it would make this a scroll container and break the dock's position:sticky.
    // The body already clips horizontal overflow (styles.css).
    <div className="mx-auto max-w-[1440px] px-4 pb-16 sm:px-6">
      <a href="#timeline" className="skip-link">Skip to the timeline</a>
      <a href="#content" className="skip-link skip-link-2">Skip to the content</a>

      <CaptureHeader analysis={analysis} />
      {warnings.length > 0 && (
        <div className="mt-2 space-y-2">
          {warnings.map((p) => (
            <div key={p.kind} className="grid grid-cols-[18px_minmax(0,1fr)_auto] items-center gap-2 rounded-md border border-[var(--warning)]/45 bg-[color-mix(in_oklab,var(--warning)_10%,var(--surface-1))] px-3 py-2 text-[13px]">
              <AlertTriangle className="size-[18px] text-[var(--warning)]" />
              <span className="min-w-0">
                {p.message}{" "}
                <Link to="/guide" className="font-medium text-[var(--action)] underline underline-offset-2">Open the guide</Link>
              </span>
              <button className="icon-btn" aria-label={`Dismiss: ${p.message}`} onClick={() => setDismissed((d) => [...d, p.kind])}>
                <X className="size-3.5" />
              </button>
            </div>
          ))}
        </div>
      )}

      <div id="timeline" ref={dockRef} className="sticky top-[var(--header-h)] z-30 -mx-4 sm:-mx-6">
        <TrackView
          analysis={analysis}
          cursorMs={cursorMs}
          onCursor={setCursorMs}
          view={view}
          onView={setView}
          onFit={fitView}
          onMarker={(m) => jump(m.tMs, m.event)}
          collapsed={dockCollapsed || autoCollapsed}
          onCollapsed={(v) => { setAutoCollapsed(false); setDockCollapsed(v); }}
          onAnnounce={setAnnouncement}
          onOpenFlow={(event) => { setSelectedEvent(event); goToTab("flow"); }}
          onGlide={glideCursorTo}
          flash={flash}
          onShowOnTimeline={showOnTimeline}
        />
      </div>
      <div className="sr-only" aria-live="polite">{announcement}</div>

      <Tabs value={activeTab} onValueChange={(v) => goToTab(v as CaptureTab)} className="min-w-0">
        <div className="sticky top-[calc(var(--header-h)+var(--dock-h,0px))] z-20 -mx-4 border-b border-[var(--line)] bg-[var(--bg)]/95 px-4 backdrop-blur sm:-mx-6 sm:px-6" id="content">
          <TabsList className="h-10 min-w-0 justify-start gap-1 overflow-x-auto rounded-none bg-transparent p-0">
            <TabsTrigger value="overview" className="tab-trigger">Overview</TabsTrigger>
            <TabsTrigger value="flow" className="tab-trigger">
              Call flow <span className="num ml-1 text-[11px] text-[var(--text-3)]">{analysis.events.length}</span>
            </TabsTrigger>
            <TabsTrigger value="radio" className="tab-trigger">
              Radio <span className="num ml-1 text-[11px] text-[var(--text-3)]">{analysis.phy.length}</span>
            </TabsTrigger>
          </TabsList>
        </div>
        <TabsContent value="overview" className="mt-4 min-w-0">
          <OverviewTab
            analysis={analysis}
            masked={masked}
            onJump={jump}
            onOpenFlow={openFlow}
            onOpenRadio={openRadio}
            onShowOnTimeline={showOnTimeline}
          />
        </TabsContent>
        <TabsContent value="flow" className="mt-4 min-w-0">
          <CallFlowTab
            analysis={analysis}
            masked={masked}
            cursorMs={cursorMs}
            selectedEvent={selectedEvent}
            followCursor={followCursor}
            {...(flowProcedure ? { initialProcedure: flowProcedure } : {})}
            onSelect={(e) => {
              if (e) { setCursorMs(e.sinceStartMs); setSelectedEvent(e.index); } else setSelectedEvent(null);
            }}
            onRequestReveal={() => setMasked(false)}
            searchRef={flowSearchRef}
          />
        </TabsContent>
        <TabsContent value="radio" className="mt-4 min-w-0">
          <RadioTab
            analysis={analysis}
            cursorMs={cursorMs}
            view={view}
            onCursor={setCursorMs}
            onView={setView}
            {...(radioSection ? { initialSection: radioSection } : {})}
            onSection={(s) => {
              setRadioSection(s);
              void navigate({ to: "/capture", search: (old) => ({ ...old, section: s }), replace: true });
            }}
          />
        </TabsContent>
      </Tabs>

      <ShortcutsDialog open={shortcuts} onOpenChange={setShortcuts} />
    </div>
  );
}

const SHORTCUTS: [string, string][] = [
  ["← →", "Move the cursor 100 ms"],
  ["Shift ← →", "Move the cursor 1 s"],
  ["[  ]", "Previous / next marker"],
  ["0", "Fit the whole capture"],
  ["1  2  3", "Overview / Call flow / Radio"],
  ["/", "Search the messages"],
  ["J  K", "Previous / next message (in the call flow)"],
  ["W  S", "Zoom the timeline in / out (while the dock has focus)"],
  ["A  D", "Pan the timeline (while the dock has focus)"],
  ["Enter", "Open the card of the focused segment or marker"],
  ["⌘K  Ctrl K", "Command palette"],
  ["Esc", "Close a card, a panel or the palette"],
  ["?", "This list"],
];

function ShortcutsDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (v: boolean) => void }) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-[420px]">
        <DialogHeader>
          <DialogTitle>Keyboard shortcuts</DialogTitle>
          <DialogDescription>Everything here is also reachable with a pointer.</DialogDescription>
        </DialogHeader>
        <dl className="grid grid-cols-[132px_minmax(0,1fr)] gap-x-3">
          {SHORTCUTS.map(([keys, what]) => (
            <div key={keys} className="col-span-2 grid grid-cols-subgrid border-b border-[var(--line)] py-1 last:border-b-0">
              <dt className="num text-[12px] text-[var(--text-2)]">{keys}</dt>
              <dd className="text-[13px]">{what}</dd>
            </div>
          ))}
        </dl>
      </DialogContent>
    </Dialog>
  );
}

function ProblemCard({ problem }: { problem: ImportProblem }) {
  return (
    <section className="panel grid grid-cols-[20px_minmax(0,1fr)] gap-3 border-l-2 border-l-[var(--critical)] p-4">
      <OctagonX className="size-5 text-[var(--critical)]" />
      <div className="min-w-0">
        <p className="text-sm font-medium">{problem.message}</p>
        {problem.detail && <p className="mt-1 text-xs text-[var(--text-3)]">{problem.detail}</p>}
        <p className="mt-2 text-xs text-[var(--text-3)]">{whatToDo(problem)}</p>
      </div>
    </section>
  );
}

function whatToDo(problem: ImportProblem): string {
  switch (problem.kind) {
    case "notASysdiagnose":
      return "Open the sysdiagnose_….tar.gz exactly as it came off the iPhone, without unzipping it first.";
    case "truncatedArchive":
      return "The copy stopped part way through. Share the file off the iPhone again.";
    case "loggingNotEnabled":
      return "The profile has to be installed before the modem writes anything. Part A of the guide walks through it.";
    case "noBasebandTrace":
      return "Without a trace there is nothing to read. Install the profile, restart the iPhone, then record again.";
    case "profileMissing":
    case "profileExpired":
    case "profileExpiresSoon":
      return "Install Apple's Baseband profile again before the next capture — it removes itself after 7 days.";
    case "profileInstalledAfterTrace":
      return "The trace is older than the profile. Restart the iPhone, then record again.";
    case "profileInstalledNoTrace":
      return "Logging was on but the modem wrote nothing. Restart the iPhone and record again.";
    case "traceGaps":
      return "Some trace files are missing inside the kept window, so messages around them may be cut.";
    case "unsupportedTrace":
      return "This trace is not one the decoder can read yet.";
    default:
      return "Record again with the guide open.";
  }
}

function EmptyCapture({ error, pendingDev }: { error: string | null; pendingDev: boolean }) {
  const navigate = useNavigate();
  return (
    <div className="mx-auto grid min-h-[60vh] max-w-[480px] place-items-center px-4">
      <div className="panel w-full p-6 text-center">
        <h1 className="text-base font-semibold">{error ? "The dev fixture didn't load" : "No log open"}</h1>
        <p className="mt-2 text-sm text-[var(--text-3)]">
          {error
            ? error
            : pendingDev && import.meta.env.DEV
              // `import.meta.env.DEV` is a compile-time constant, so this line — the only mention of the dev
              // fixture left in the UI — is dropped from the production bundle along with the loader itself.
              ? "Reading public/dev/analysis.json…"
              : "Open a sysdiagnose to see what your phone's modem did. A real file is held in this tab only and never stored."}
        </p>
        <div className="mt-5 flex flex-wrap justify-center gap-2">
          <Button asChild><Link to="/">Open a log</Link></Button>
          <Button variant="outline" onClick={() => void navigate({ to: "/capture", search: { sample: "ok" } })}>
            Load sample
          </Button>
        </div>
      </div>
    </div>
  );
}

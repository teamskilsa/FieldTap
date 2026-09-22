import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import type { CaptureAnalysis } from "@engine/types";

type CaptureTab = "overview" | "flow" | "radio";

/** A request to draw attention to a moment on the timeline. `at` makes each request distinct from the last. */
export interface Flash {
  tMs: number;
  at: number;
}

interface CaptureCtx {
  analysis: CaptureAnalysis | null;
  setAnalysis: (a: CaptureAnalysis | null) => void;
  cursorMs: number;
  setCursorMs: (ms: number) => void;
  /** Move the cursor over 150 ms instead of teleporting it, so the eye can follow the jump. */
  glideCursorTo: (ms: number) => void;
  moveCursor: (deltaMs: number) => void;
  flash: Flash | null;
  /** Glide the cursor there and make the timeline flash whatever sits at that moment. */
  showOnTimeline: (ms: number) => void;
  view: [number, number];
  setView: (view: [number, number]) => void;
  fitView: () => void;
  masked: boolean;
  setMasked: (v: boolean) => void;
  selectedEvent: number | null;
  setSelectedEvent: (i: number | null) => void;
  activeTab: CaptureTab;
  setActiveTab: (tab: CaptureTab) => void;
  followCursor: boolean;
  setFollowCursor: (v: boolean) => void;
  dockCollapsed: boolean;
  setDockCollapsed: (v: boolean) => void;
  announcement: string;
  setAnnouncement: (v: string) => void;
}

const Ctx = createContext<CaptureCtx | null>(null);

const safeRead = (key: string) => {
  try {
    return typeof window === "undefined" ? null : window.localStorage.getItem(key);
  } catch {
    return null;
  }
};
const safeWrite = (key: string, value: string) => {
  try {
    window.localStorage.setItem(key, value);
  } catch {
    // ignored
  }
};

export function CaptureProvider({ children }: { children: ReactNode }) {
  const [analysis, setAnalysisRaw] = useState<CaptureAnalysis | null>(null);
  const [cursorMs, setCursorMsRaw] = useState(0);
  const [view, setViewRaw] = useState<[number, number]>([0, 1]);
  const [masked, setMasked] = useState(true);
  const [selectedEvent, setSelectedEvent] = useState<number | null>(null);
  const [activeTab, setActiveTab] = useState<CaptureTab>("overview");
  const [followCursor, setFollowCursorRaw] = useState(true);
  const [dockCollapsed, setDockCollapsedRaw] = useState(false);
  const [announcement, setAnnouncement] = useState("");
  const [flash, setFlash] = useState<Flash | null>(null);
  const glide = useRef<number | null>(null);

  useEffect(() => {
    setFollowCursorRaw(safeRead("fieldtap.followCursor") !== "false");
    setDockCollapsedRaw(safeRead("fieldtap.dockCollapsed") === "true");
  }, []);

  const duration = analysis?.durationMs ?? analysis?.journey.durationMs ?? 0;

  const clamp = useCallback((ms: number) => Math.max(0, Math.min(duration, ms)), [duration]);
  const clampView = useCallback(
    ([a, b]: [number, number]): [number, number] => {
      const min = 50;
      const start = Math.max(0, Math.min(duration, a));
      const end = Math.max(start + min, Math.min(duration, b));
      if (end > duration) return [Math.max(0, duration - Math.max(min, b - a)), duration];
      return [start, end];
    },
    [duration],
  );

  const setAnalysis = useCallback((a: CaptureAnalysis | null) => {
    setAnalysisRaw(a);
    setSelectedEvent(null);
    const dur = a?.durationMs ?? a?.journey.durationMs ?? 0;
    const first = a?.journey.markers.find((m) => m.kind === "attach")?.tMs ?? a?.journey.markers[0]?.tMs ?? 0;
    setCursorMsRaw(Math.max(0, Math.min(dur, first)));
    setViewRaw([0, Math.max(1, dur)]);
  }, []);

  const setCursorMs = useCallback(
    (ms: number) => {
      // A drag or an arrow key cancels a glide that is still running, so the two can never fight.
      if (glide.current != null) {
        cancelAnimationFrame(glide.current);
        glide.current = null;
      }
      setCursorMsRaw(clamp(ms));
    },
    [clamp],
  );

  /**
   * A 150 ms ease-out from where the cursor is to where the jump landed. Without it a marker jump is a teleport
   * and the reader loses which way the timeline moved. Reduced-motion users get the teleport, which is the point
   * of the preference.
   */
  const glideCursorTo = useCallback(
    (ms: number) => {
      const to = clamp(ms);
      if (glide.current != null) cancelAnimationFrame(glide.current);
      glide.current = null;
      const reduced =
        typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      if (reduced) {
        setCursorMsRaw(to);
        return;
      }
      setCursorMsRaw((from) => {
        if (Math.abs(to - from) < 1) return to;
        const t0 = performance.now();
        const step = (now: number) => {
          const k = Math.min(1, (now - t0) / 150);
          const eased = 1 - (1 - k) * (1 - k) * (1 - k);
          setCursorMsRaw(from + (to - from) * eased);
          glide.current = k < 1 ? requestAnimationFrame(step) : null;
        };
        glide.current = requestAnimationFrame(step);
        return from;
      });
    },
    [clamp],
  );

  const showOnTimeline = useCallback(
    (ms: number) => {
      glideCursorTo(ms);
      setFlash({ tMs: clamp(ms), at: performance.now() });
    },
    [clamp, glideCursorTo],
  );

  useEffect(() => () => {
    if (glide.current != null) cancelAnimationFrame(glide.current);
  }, []);

  const moveCursor = useCallback((delta: number) => setCursorMsRaw((c) => clamp(c + delta)), [clamp]);
  const setView = useCallback((next: [number, number]) => setViewRaw(clampView(next)), [clampView]);
  const fitView = useCallback(() => setViewRaw([0, Math.max(1, duration)]), [duration]);
  const setFollowCursor = useCallback((v: boolean) => {
    setFollowCursorRaw(v);
    safeWrite("fieldtap.followCursor", String(v));
  }, []);
  const setDockCollapsed = useCallback((v: boolean) => {
    setDockCollapsedRaw(v);
    safeWrite("fieldtap.dockCollapsed", String(v));
  }, []);

  const value = useMemo(
    () => ({
      analysis,
      setAnalysis,
      cursorMs,
      setCursorMs,
      glideCursorTo,
      moveCursor,
      flash,
      showOnTimeline,
      view,
      setView,
      fitView,
      masked,
      setMasked,
      selectedEvent,
      setSelectedEvent,
      activeTab,
      setActiveTab,
      followCursor,
      setFollowCursor,
      dockCollapsed,
      setDockCollapsed,
      announcement,
      setAnnouncement,
    }),
    [
      analysis,
      setAnalysis,
      cursorMs,
      setCursorMs,
      glideCursorTo,
      moveCursor,
      flash,
      showOnTimeline,
      view,
      setView,
      fitView,
      masked,
      selectedEvent,
      activeTab,
      followCursor,
      setFollowCursor,
      dockCollapsed,
      setDockCollapsed,
      announcement,
    ],
  );

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useCapture() {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error("useCapture must be used inside CaptureProvider");
  return ctx;
}

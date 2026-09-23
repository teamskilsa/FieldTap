import { Link, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  CommandSeparator,
  CommandShortcut,
} from "@/components/ui/command";
import { Button } from "@/components/ui/button";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { SettingsDrawer } from "@/components/SettingsDrawer";
import { useCapture } from "@/state/capture";
import { createSampleAnalysis, type SampleVariant } from "@/lib/analysis/sample";
import { findingText, fmtSince } from "@/lib/analysis/format";
import type { RadioSection } from "@/components/capture/RadioTab";
import type { CaptureTab } from "@/routes/capture";
import {
  BadgeCheck,
  FileUp,
  Moon,
  RadioTower,
  Radio,
  Search,
  ShieldCheck,
  Signal,
  Sun,
  SunMoon,
} from "lucide-react";
import { cn } from "@/lib/utils";

type ThemeMode = "system" | "dark" | "light";
const THEME_KEY = "fieldtap.theme";
const THEMES: ThemeMode[] = ["system", "dark", "light"];
/** How many rows of each long list the palette shows before the reader types anything. */
const LIMIT = 8;
const RADIO_SECTIONS: RadioSection[] = [
  "Signal", "Downlink", "Uplink", "CSI", "NR", "Carriers", "Antennas", "RACH", "Not available",
];

function safeTheme(): ThemeMode {
  try {
    const v = window.localStorage.getItem(THEME_KEY);
    return v === "dark" || v === "light" || v === "system" ? v : "system";
  } catch {
    return "system";
  }
}

function applyTheme(mode: ThemeMode) {
  const dark = mode === "dark" || (mode === "system" && window.matchMedia("(prefers-color-scheme: dark)").matches);
  document.documentElement.classList.toggle("dark", dark);
  document.documentElement.dataset["theme"] = mode;
}

export function Header() {
  const { analysis, setAnalysis, setCursorMs, showOnTimeline, setSelectedEvent, setActiveTab, masked, setMasked } = useCapture();
  const navigate = useNavigate();
  const [palette, setPalette] = useState(false);
  // Controlled, so the long lists below can stay short until the reader actually types. A real capture can hold
  // thousands of messages, and rendering every one of them into the dialog makes ⌘K feel broken.
  const [query, setQuery] = useState("");
  const [confirmReveal, setConfirmReveal] = useState(false);
  const [theme, setTheme] = useState<ThemeMode>("system");

  useEffect(() => {
    const initial = safeTheme();
    setTheme(initial);
    applyTheme(initial);
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const on = () => initial === "system" && applyTheme("system");
    mq.addEventListener("change", on);
    return () => mq.removeEventListener("change", on);
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setQuery("");
        setPalette((v) => !v);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const setThemeMode = (mode: ThemeMode) => {
    setTheme(mode);
    try {
      window.localStorage.setItem(THEME_KEY, mode);
    } catch {
      // ignored
    }
    applyTheme(mode);
  };
  const cycleTheme = () => setThemeMode(THEMES[(THEMES.indexOf(theme) + 1) % THEMES.length] ?? "system");
  const loadSample = (variant: SampleVariant = "ok") => {
    setAnalysis(createSampleAnalysis({ variant }));
    setPalette(false);
    void navigate({ to: "/capture", search: (old) => ({ ...old, sample: variant }) });
  };
  const openTab = (tab: CaptureTab) => {
    setActiveTab(tab);
    setPalette(false);
    void navigate({ to: "/capture", search: (old) => ({ ...old, tab }) });
  };
  const jump = (tab: CaptureTab, t: number, event?: number) => {
    setCursorMs(t);
    if (event != null) setSelectedEvent(event);
    openTab(tab);
  };
  const openSection = (section: RadioSection) => {
    setActiveTab("radio");
    setPalette(false);
    void navigate({ to: "/capture", search: (old) => ({ ...old, tab: "radio" as const, section }) });
  };
  const point = (t: number) => {
    setPalette(false);
    setActiveTab("overview");
    void navigate({ to: "/capture", search: (old) => ({ ...old, tab: "overview" as const }) });
    showOnTimeline(t);
  };
  // Until the reader types, each list shows its first LIMIT rows; cmdk filters the rest once there is a query.
  const cap = <T,>(items: T[]): T[] => (query.trim() ? items : items.slice(0, LIMIT));
  const ThemeIcon = theme === "dark" ? Moon : theme === "light" ? Sun : SunMoon;

  return (
    <TooltipProvider delayDuration={250}>
      <header className="sticky top-0 z-50 h-[var(--header-h)] border-b bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/80">
        <div className="mx-auto flex h-full max-w-[1440px] items-center gap-2 px-3 sm:px-4">
          <Link to="/" className="flex min-w-0 items-center gap-2" aria-label="FieldTap home">
            <span className="flex size-7 shrink-0 items-center justify-center rounded-md border bg-card">
              <RadioTower className="size-4 text-primary" />
            </span>
            <span className="hidden min-w-0 items-baseline gap-1 sm:flex">
              <span className="text-sm font-semibold leading-none">FieldTap</span>
              <span className="text-xs text-muted-foreground">Log Analyzer</span>
            </span>
          </Link>

          <nav className="ml-1 flex h-full items-center gap-1 text-xs sm:ml-2">
            <NavLink to="/" label="Open" exact />
            <NavLink to="/guide" label="Guide" />
            <NavLink to="/capture" label="Capture" disabled={!analysis} />
          </nav>

          <span className="ml-auto hidden items-center gap-1 rounded-full border bg-card px-2 py-1 text-[11px] font-medium text-muted-foreground md:inline-flex">
            <ShieldCheck className="size-3.5 text-signal-excellent" />
            On-device privacy
          </span>

          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="outline" size="sm" onClick={() => setPalette(true)} className="hidden h-7 gap-1.5 px-2 md:inline-flex">
                <Search className="size-3.5" />
                <span className="text-xs text-muted-foreground">⌘K</span>
              </Button>
            </TooltipTrigger>
            <TooltipContent>Command palette</TooltipContent>
          </Tooltip>

          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="icon" onClick={cycleTheme} aria-label={`Theme: ${theme}`} className="size-8">
                <ThemeIcon className="size-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent>Theme: {theme}</TooltipContent>
          </Tooltip>
          <SettingsDrawer iconOnly />
        </div>
      </header>

      <CommandDialog open={palette} onOpenChange={(v) => { setPalette(v); if (!v) setQuery(""); }}>
        <CommandInput
          value={query}
          onValueChange={setQuery}
          placeholder="Jump to a marker, finding, message, cell, section or setting…"
        />
        <CommandList>
          <CommandEmpty>No results found.</CommandEmpty>
          <CommandGroup heading="Navigation">
            <CommandItem onSelect={() => { setPalette(false); void navigate({ to: "/" }); }}><FileUp /> Open log</CommandItem>
            <CommandItem onSelect={() => { setPalette(false); void navigate({ to: "/guide" }); }}>Guide</CommandItem>
            {analysis && <CommandItem onSelect={() => { setPalette(false); void navigate({ to: "/capture" }); }}>Capture</CommandItem>}
            {analysis && <CommandItem onSelect={() => openTab("overview")}>Overview tab</CommandItem>}
            {analysis && <CommandItem onSelect={() => openTab("flow")}>Call flow tab<CommandShortcut>{analysis.events.length}</CommandShortcut></CommandItem>}
            {analysis && <CommandItem onSelect={() => openTab("radio")}>Radio tab<CommandShortcut>{analysis.phy.length}</CommandShortcut></CommandItem>}
            {analysis && <CommandItem onSelect={() => openTab("security")}><ShieldCheck /> Security tab<CommandShortcut>fake base station</CommandShortcut></CommandItem>}
          </CommandGroup>
          <CommandSeparator />
          <CommandGroup heading="Sample captures">
            {(["ok", "expiredSince", "traceGaps", "loggingOff", "notSysdiagnose"] as SampleVariant[]).map((variant) => (
              <CommandItem key={variant} onSelect={() => loadSample(variant)}>
                <BadgeCheck /> Sample: {variant}
              </CommandItem>
            ))}
          </CommandGroup>
          {analysis && (
            <>
              <CommandSeparator />
              <CommandGroup heading="Radio sections">
                {RADIO_SECTIONS.map((section) => (
                  <CommandItem key={section} onSelect={() => openSection(section)}>
                    <Signal /> Radio: {section}
                  </CommandItem>
                ))}
              </CommandGroup>
            </>
          )}
          <CommandSeparator />
          <CommandGroup heading="Settings">
            {THEMES.map((mode) => (
              <CommandItem key={mode} onSelect={() => setThemeMode(mode)}>
                {mode === "dark" ? <Moon /> : mode === "light" ? <Sun /> : <SunMoon />} Theme: {mode}
                {theme === mode && <CommandShortcut>active</CommandShortcut>}
              </CommandItem>
            ))}
            <CommandItem onSelect={() => { if (masked) setConfirmReveal(true); else setMasked(true); setPalette(false); }}>
              <ShieldCheck /> {masked ? "Show identifiers" : "Hide identifiers"}
            </CommandItem>
          </CommandGroup>
          <CommandSeparator />
          <CommandGroup heading="Keyboard shortcuts">
            <CommandItem>Move the cursor 100 ms<CommandShortcut>← →</CommandShortcut></CommandItem>
            <CommandItem>Move the cursor 1 s<CommandShortcut>⇧ ← →</CommandShortcut></CommandItem>
            <CommandItem>Previous and next marker<CommandShortcut>[ ]</CommandShortcut></CommandItem>
            <CommandItem>Fit the whole capture<CommandShortcut>0</CommandShortcut></CommandItem>
            <CommandItem>Overview, Call flow, Radio, Security<CommandShortcut>1 2 3 4</CommandShortcut></CommandItem>
            <CommandItem>Search the messages<CommandShortcut>/</CommandShortcut></CommandItem>
            <CommandItem>Previous and next message<CommandShortcut>J K</CommandShortcut></CommandItem>
            <CommandItem>Open the focused card<CommandShortcut>Enter</CommandShortcut></CommandItem>
            <CommandItem>All shortcuts<CommandShortcut>?</CommandShortcut></CommandItem>
            <CommandItem>Close a card, panel or the palette<CommandShortcut>Esc</CommandShortcut></CommandItem>
            <CommandItem>Open command palette<CommandShortcut>⌘K</CommandShortcut></CommandItem>
          </CommandGroup>
          {analysis && (
            <>
              <CommandSeparator />
              <CommandGroup heading="Markers">
                {cap(analysis.journey.markers).map((m) => (
                  <CommandItem key={m.id} onSelect={() => jump("overview", m.tMs, m.event)}>
                    {m.title}<CommandShortcut>{fmtSince(m.tMs)}</CommandShortcut>
                  </CommandItem>
                ))}
              </CommandGroup>
              <CommandGroup heading="Findings">
                {cap(analysis.journey.findings).map((f) => (
                  <CommandItem key={f.id} onSelect={() => f.tMs != null && jump("overview", f.tMs, f.event)}>
                    <span className="truncate">{findingText(f, analysis)}</span>{f.tMs != null && <CommandShortcut>{fmtSince(f.tMs)}</CommandShortcut>}
                  </CommandItem>
                ))}
              </CommandGroup>
              <CommandGroup heading="Cells">
                {cap(analysis.journey.cells).map((c) => (
                  <CommandItem
                    key={`${c.lane}-${c.index}-${c.startMs}`}
                    onSelect={() => point(c.startMs)}
                  >
                    <Radio />
                    <span className="truncate">
                      {c.lane === "scell" ? `SCell ${c.index}` : c.lane === "pscell" ? "NR PSCell" : "PCell"} ·{" "}
                      {c.band} · {c.cell.nr ? "NR-ARFCN" : "EARFCN"} {c.cell.earfcn} · PCI {c.cell.pci}
                    </span>
                    <CommandShortcut>{fmtSince(c.startMs)}</CommandShortcut>
                  </CommandItem>
                ))}
              </CommandGroup>
              <CommandGroup heading="Messages">
                {cap(analysis.events).map((e) => (
                  <CommandItem key={e.index} onSelect={() => jump("flow", e.sinceStartMs, e.index)}>
                    <span className="truncate">{e.name}</span><CommandShortcut>{fmtSince(e.sinceStartMs)}</CommandShortcut>
                  </CommandItem>
                ))}
              </CommandGroup>
            </>
          )}
        </CommandList>
      </CommandDialog>
      <AlertDialog open={confirmReveal} onOpenChange={setConfirmReveal}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Show identifiers on screen?</AlertDialogTitle>
            <AlertDialogDescription>IMSI, IMEI, phone numbers, IP addresses and temporary identities will be shown in full.</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Keep hidden</AlertDialogCancel>
            <AlertDialogAction onClick={() => setMasked(false)}>Show identifiers</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </TooltipProvider>
  );
}

function NavLink({ to, label, exact, disabled }: { to: "/" | "/guide" | "/capture"; label: string; exact?: boolean; disabled?: boolean }) {
  if (disabled) return <span className="rounded-md px-2 py-1 text-muted-foreground/50">{label}</span>;
  return (
    <Link
      to={to}
      className="rounded-md px-2 py-1 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
      activeProps={{ className: cn("rounded-md px-2 py-1 bg-accent text-foreground") }}
      {...(exact ? { activeOptions: { exact: true } } : {})}
    >
      {label}
    </Link>
  );
}

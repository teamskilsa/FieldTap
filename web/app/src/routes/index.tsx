import { Link, useNavigate } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";
import { CheckCircle2, Circle, CloudOff, EyeOff, FileArchive, Loader2, Lock, Sparkles, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Progress } from "@/components/ui/progress";
import { analyzeFile, STAGE_LABELS, STAGE_ORDER } from "@/engine";
import { createSampleAnalysis } from "@/lib/analysis/sample";
import type { ImportProgress, ImportStage } from "@engine/types";
import { usePageMeta } from "@/lib/meta";
import { useCapture } from "@/state/capture";
import { cn } from "@/lib/utils";

export function HomePage() {
  usePageMeta(
    "FieldTap Log Analyzer — iPhone modem logs, privately",
    "Open an iPhone sysdiagnose baseband log and inspect cellular signalling, handovers, 5G legs and radio quality entirely in your browser.",
  );
  const { setAnalysis } = useCapture();
  const navigate = useNavigate();
  const [progress, setProgress] = useState<ImportProgress | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [dragging, setDragging] = useState(false);
  const [fileInfo, setFileInfo] = useState<{ name: string; size: number } | null>(null);
  const [startedAt, setStartedAt] = useState(0);
  const [tick, setTick] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const abortRef = useRef<AbortController | null>(null);

  useEffect(() => {
    if (!progress) return undefined;
    const id = window.setInterval(() => setTick((v) => v + 1), 250);
    return () => window.clearInterval(id);
  }, [progress]);

  const start = async (file: File) => {
    setError(null);
    setFileInfo({ name: file.name, size: file.size });
    setStartedAt(Date.now());
    setTick((v) => v + 1);
    const ac = new AbortController();
    abortRef.current = ac;
    setProgress({ stage: "reading", fraction: 0, detail: "Starting…" });
    try {
      const analysis = await analyzeFile(file, setProgress, ac.signal);
      setAnalysis(analysis);
      void navigate({ to: "/capture" });
    } catch (e) {
      const err = e instanceof Error ? e : new Error("This file could not be read.");
      if (err.name !== "AbortError") setError(err.message || "This file could not be read.");
      setProgress(null);
    }
  };

  const sample = () => {
    setAnalysis(createSampleAnalysis({ variant: "ok" }));
    void navigate({ to: "/capture", search: { sample: "ok" } });
  };

  const stageIndex = progress ? STAGE_ORDER.indexOf(progress.stage as ImportStage) : -1;
  const elapsed = startedAt ? Date.now() - startedAt + tick * 0 : 0;

  return (
    <div
      className="mx-auto max-w-[960px] px-4 py-10 sm:py-14"
      onDragOver={(e) => { e.preventDefault(); setDragging(true); }}
      onDragLeave={(e) => { if (e.currentTarget === e.target) setDragging(false); }}
      onDrop={(e) => { e.preventDefault(); setDragging(false); const f = e.dataTransfer.files?.[0]; if (f) void start(f); }}
    >
      <h1 className="text-2xl font-semibold tracking-normal">Read your iPhone's modem log</h1>
      <p className="mt-2 max-w-2xl text-sm text-muted-foreground">
        Open a Baseband sysdiagnose archive and inspect signalling, cell changes, 5G legs and radio measurements in this tab.
      </p>

      <div className="mt-5 grid gap-2 sm:grid-cols-3">
        <TrustItem icon={<Lock className="size-4" />} text="Runs in this tab" />
        <TrustItem icon={<CloudOff className="size-4" />} text="Nothing is uploaded" />
        <TrustItem icon={<EyeOff className="size-4" />} text="Identifiers hidden" />
      </div>
      <p className="mt-4 rounded-lg border border-signal-excellent/40 bg-signal-excellent/10 p-3 text-sm font-semibold">
        Your log never leaves this computer — it is processed in your browser.
      </p>

      {!progress ? (
        <>
          <div
            onDragOver={(e) => { e.preventDefault(); setDragging(true); }}
            onDragLeave={() => setDragging(false)}
            onDrop={(e) => { e.preventDefault(); setDragging(false); const f = e.dataTransfer.files?.[0]; if (f) void start(f); }}
            className={cn("mt-6 grid min-h-[220px] place-items-center rounded-xl border-[1.5px] border-dashed border-line-strong bg-surface-1 p-8 text-center transition-[border-color,box-shadow]", dragging && "border-primary shadow-[0_0_0_4px_color-mix(in_oklab,var(--action)_15%,transparent)]")}
          >
            <div>
            <FileArchive className="mx-auto size-10 text-muted-foreground" />
            <p className="mt-3 text-sm font-medium">Drop sysdiagnose_….tar.gz</p>
            <input ref={inputRef} type="file" accept=".gz,.tar.gz,.tgz,.tar" className="hidden" onChange={(e) => { const f = e.target.files?.[0]; if (f) void start(f); }} />
            <div className="mt-4 flex flex-wrap justify-center gap-2">
              <Button onClick={() => inputRef.current?.click()}>Choose a file</Button>
              <Button variant="outline" onClick={sample}><Sparkles className="size-4" /> Try the sample</Button>
            </div>
            </div>
          </div>
          {error && <p className="mt-4 text-sm text-destructive">{error}</p>}
          <p className="mt-6 text-sm text-muted-foreground">Don't have a log yet? <Link to="/guide" className="font-medium text-primary underline">How to record your iPhone's modem log</Link></p>
        </>
      ) : (
        <section className="panel mt-6 space-y-4 p-5">
          <div className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3">
            <div className="min-w-0">
              <p className="flex items-center gap-2 text-sm font-medium"><Loader2 className="size-4 animate-spin text-primary" /> Analysing in your browser…</p>
              {fileInfo && <p className="num mt-1 truncate text-xs text-muted-foreground">{fileInfo.name} · {formatBytes(fileInfo.size)}</p>}
            </div>
            <span className="num text-xs text-muted-foreground">{formatElapsed(elapsed)}</span>
          </div>
          {STAGE_ORDER.map((s, i) => {
            const done = i < stageIndex || progress.stage === "done";
            const current = i === stageIndex;
            const pct = done ? 100 : current ? Math.round(progress.fraction * 100) : 0;
            return (
              <div key={s} className="grid grid-cols-[20px_minmax(0,1fr)] gap-2">
                <span className="mt-0.5">{done ? <CheckCircle2 className="size-4 text-signal-excellent" /> : current ? <Loader2 className="size-4 animate-spin text-primary" /> : <Circle className="size-4 text-muted-foreground" />}</span>
                <div className="min-w-0 space-y-1">
                <div className="grid grid-cols-[minmax(0,1fr)_auto] gap-2 text-xs"><span className={cn("min-w-0 truncate", current && "font-medium", !done && !current && "text-muted-foreground")}>{STAGE_LABELS[s]}<span className="ml-2 text-muted-foreground">{current ? progress.detail : done ? "done" : "waiting"}</span></span><span className="num text-muted-foreground">{formatElapsed(elapsed)}</span></div>
                <Progress value={pct} className="h-1.5" />
                </div>
              </div>
            );
          })}
          <Button variant="outline" size="sm" onClick={() => { abortRef.current?.abort(); setProgress(null); }}><X className="size-4" /> Cancel</Button>
        </section>
      )}
    </div>
  );
}

function TrustItem({ icon, text }: { icon: React.ReactNode; text: string }) {
  return <div className="flex items-center gap-2 rounded-lg border bg-surface-1 px-3 py-2 text-sm text-muted-foreground">{icon}<span>{text}</span></div>;
}

function formatBytes(bytes: number) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${Math.round(bytes / (1024 * 1024))} MB`;
}

function formatElapsed(ms: number) {
  return `${(Math.max(0, ms) / 1000).toFixed(1)} s`;
}

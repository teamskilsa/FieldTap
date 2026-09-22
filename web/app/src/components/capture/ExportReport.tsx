// "Export a redacted report": one self-contained HTML file and the redacted analysis as JSON, both built here in
// the tab and handed to the browser's own download. There is no upload and no server step — the files are made
// from a Blob and an object URL, which never touches the network.
import { useState } from "react";
import { Download, FileJson, FileText, Loader2, ShieldCheck } from "lucide-react";
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { reportFileBase, reportHtml } from "@/lib/report/html";
import { redactAnalysis } from "@/lib/report/redact";
import { LOCATION_LOG_CODES } from "@engine/report/privacy";
import type { CaptureAnalysis } from "@engine/types";
import { cn } from "@/lib/utils";

/** The codes named in the dialog: the position reports and the NMEA-carrying links, as the reader can check. */
const LOCATION_CODES = [0x1476, 0x147c, 0x147e, 0x1391, 0x1544]
  .map((c) => LOCATION_LOG_CODES.find((x) => x.code === c)?.hex ?? "")
  .join(", ");

/** Hand a string to the browser as a file. An object URL is local to this document; nothing is requested. */
function save(name: string, mime: string, text: string) {
  const url = URL.createObjectURL(new Blob([text], { type: mime }));
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.rel = "noopener";
  document.body.append(a);
  a.click();
  a.remove();
  // Revoked on the next frame: Safari needs the URL to still resolve when the click is handled.
  requestAnimationFrame(() => URL.revokeObjectURL(url));
}

export function ExportReport({ analysis, className, label }: {
  analysis: CaptureAnalysis;
  className?: string;
  /** Shown beside the icon. Omitted for the icon-only button in the capture header. */
  label?: string;
}) {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState<null | "html" | "json">(null);
  const [done, setDone] = useState<string | null>(null);

  const run = (what: "html" | "json") => {
    setBusy(what);
    setDone(null);
    // A frame first, so the button can paint its spinner before a 5 MB capture is walked and serialised.
    requestAnimationFrame(() => {
      try {
        const redacted = redactAnalysis(analysis);
        const base = reportFileBase(analysis);
        if (what === "html") save(`${base}.html`, "text/html;charset=utf-8", reportHtml(redacted));
        else save(`${base}.json`, "application/json", JSON.stringify(redacted, null, 2));
        setDone(what === "html" ? `${base}.html` : `${base}.json`);
      } finally {
        setBusy(null);
      }
    });
  };

  return (
    <Dialog open={open} onOpenChange={(v) => { setOpen(v); if (!v) setDone(null); }}>
      <DialogTrigger asChild>
        <button className={cn("btn-quiet shrink-0", className)} title="Export a redacted report">
          <Download className="size-3.5 shrink-0" />
          {/* On a phone the header has no room for the word, so the button is the icon and its label is for
              screen readers only. */}
          {label ? <span className="hidden sm:inline">{label}</span> : null}
          <span className="sr-only">Export a redacted report</span>
        </button>
      </DialogTrigger>
      <DialogContent className="max-w-[460px]">
        <DialogHeader>
          <DialogTitle>Export a redacted report</DialogTitle>
          <DialogDescription>
            Both files are built here in this tab and saved straight to your computer. Nothing is uploaded.
          </DialogDescription>
        </DialogHeader>

        <div className="rounded-md border border-[var(--line)] bg-[var(--surface-2)] p-3 text-[12px] leading-5 text-[var(--text-2)]">
          <p className="flex items-center gap-1.5 font-medium text-[var(--text)]">
            <ShieldCheck className="size-3.5 text-[var(--good)]" /> What is removed
          </p>
          <p className="mt-1">
            IMSI, IMEI, phone numbers, IP addresses and temporary identities; the TAC and the cell identity of
            every cell; the raw bytes of every message. The masking is the engine's own, the same one the screen
            uses while identifiers are hidden.
          </p>
          <p className="mt-1.5">
            The modem's own GNSS records are excluded by log code — its position reports and the QMI links that
            carry NMEA sentences ({LOCATION_CODES}). A modem trace holds a 5 Hz position track; FieldTap does not
            decode it and does not write it out.
          </p>
          <p className="mt-1.5">
            Bands, EARFCNs, PCIs, the PLMN, every timing and every measurement are kept — they describe the
            network, not you.
          </p>
        </div>

        <DialogFooter className="sm:justify-start">
          <Button onClick={() => run("html")} disabled={busy != null}>
            {busy === "html" ? <Loader2 className="size-4 animate-spin" /> : <FileText className="size-4" />}
            Report (HTML)
          </Button>
          <Button variant="outline" onClick={() => run("json")} disabled={busy != null}>
            {busy === "json" ? <Loader2 className="size-4 animate-spin" /> : <FileJson className="size-4" />}
            Analysis (JSON)
          </Button>
        </DialogFooter>
        <p className="num min-h-4 text-[11px] text-[var(--text-3)]" aria-live="polite">
          {done ? `Saved ${done}` : ""}
        </p>
      </DialogContent>
    </Dialog>
  );
}

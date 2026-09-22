// One message, in four tabs: what it says, which cell it was on, how it travelled, and the bytes.
//
// While identifiers are hidden the panel shows the masked strings the engine delivered — it never masks anything
// itself (audit A19) — and hides the hex dump, the TAC and the cell identity entirely. Copy copies the masked text
// by default, so a screenshot and a paste agree.
import { useState } from "react";
import { Check, ChevronDown, ChevronUp, Copy, Lock, X } from "lucide-react";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { bandChip, displayFieldValue, displayText, fmtSince, wallClock } from "@/lib/analysis/format";
import type { CaptureAnalysis, Event, Field } from "@engine/types";
import { cn } from "@/lib/utils";

export function MessageDetailPanel({
  analysis, event, masked, onClose, onMove, onRequestReveal, embedded = false,
}: {
  analysis: CaptureAnalysis;
  event: Event | null;
  masked: boolean;
  onClose: () => void;
  onMove: (dir: 1 | -1) => void;
  onRequestReveal: () => void;
  /** Inside the mobile sheet: no border, no own scroll container. */
  embedded?: boolean;
}) {
  const [copied, setCopied] = useState(false);

  if (!event) {
    return (
      <aside className={cn("grid h-full place-items-center p-6 text-center", !embedded && "panel")}>
        <p className="max-w-[220px] text-sm text-[var(--text-3)]">
          Pick a message to read its decoded fields, its cell, how it travelled and its bytes.
        </p>
      </aside>
    );
  }

  const clock = wallClock(analysis, event.sinceStartMs);
  const detail = event.cell
    ? analysis.cellDetails.find(
        (c) => c.cell.earfcn === event.cell?.earfcn && c.cell.pci === event.cell?.pci && c.cell.nr === event.cell?.nr,
      )
    : undefined;
  const lane = event.layer === "RRC" ? analysis.ladder.lanes.ran : analysis.ladder.lanes.core;
  const direction = event.uplink ? `${analysis.ladder.lanes.phone} → ${lane}` : `${lane} → ${analysis.ladder.lanes.phone}`;

  const copy = () => {
    const text = [
      `${fmtSince(event.sinceStartMs)} ${event.name} (${event.layer} ${event.channel})`,
      displayText(event, masked) ?? "",
      ...flatten(event.fields, masked),
    ]
      .filter(Boolean)
      .join("\n");
    void navigator.clipboard?.writeText(text);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1500);
  };

  return (
    <aside className={cn("flex h-full min-h-0 flex-col", !embedded && "panel")} aria-label="Message details">
      <header className="grid grid-cols-[minmax(0,1fr)_auto] gap-2 border-b border-[var(--line)] p-3">
        <div className="min-w-0">
          <h3 className="truncate text-base font-semibold leading-6">{event.name}</h3>
          <p className="num mt-0.5 truncate text-xs text-[var(--text-2)]" title={clock.title}>
            {direction} · {fmtSince(event.sinceStartMs)} · {clock.text}
          </p>
          <div className="mt-1.5 flex flex-wrap gap-1">
            <span className="chip">{event.layer}</span>
            <span className="chip num">{event.channel}</span>
            <span className="chip">{event.rat}</span>
            {event.ciphered && <span className="chip"><Lock className="size-3" /> ciphered</span>}
            {event.isFailure && <span className="chip border-[var(--critical)]/50">failure</span>}
          </div>
        </div>
        <div className="flex shrink-0 items-start gap-0.5">
          <button className="icon-btn" aria-label="Previous message  K" title="Previous message  K" onClick={() => onMove(-1)}>
            <ChevronUp className="size-4" />
          </button>
          <button className="icon-btn" aria-label="Next message  J" title="Next message  J" onClick={() => onMove(1)}>
            <ChevronDown className="size-4" />
          </button>
          <button className="icon-btn" aria-label="Close the details  Esc" onClick={onClose}>
            <X className="size-4" />
          </button>
        </div>
      </header>

      <Tabs defaultValue="decoded" className="flex min-h-0 flex-1 flex-col">
        <TabsList className="mx-3 mt-2 grid shrink-0 grid-cols-4 gap-1 bg-transparent p-0">
          <TabsTrigger value="decoded" className="tab-trigger h-8">Decoded</TabsTrigger>
          <TabsTrigger value="cell" className="tab-trigger h-8">Cell</TabsTrigger>
          <TabsTrigger value="transport" className="tab-trigger h-8">Transport</TabsTrigger>
          <TabsTrigger value="bytes" className="tab-trigger h-8">Bytes</TabsTrigger>
        </TabsList>

        <div className={cn("min-h-0 flex-1 px-3 pb-3", !embedded && "overflow-y-auto")}>
          <TabsContent value="decoded" className="mt-3">
            {displayText(event, masked) && (
              <p className="num mb-2 text-[13px] text-[var(--text-2)]">{displayText(event, masked)}</p>
            )}
            {event.causeName && (
              <p className="num mb-2 text-[13px]">
                <span className="text-[var(--text-3)]">Cause </span>
                {event.causeName}
                {event.cause != null ? ` (${event.cause})` : ""}
              </p>
            )}
            <FieldTree fields={event.fields} masked={masked} />
            <button className="btn-quiet mt-3" onClick={copy}>
              {copied ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
              {copied ? "Copied" : masked ? "Copy (identifiers hidden)" : "Copy"}
            </button>
          </TabsContent>

          <TabsContent value="cell" className="mt-3">
            <dl>
              <Fact k="Cell" v={event.cell ? bandChip(event.cell, analysis) : "—"} />
              <Fact k={event.cell?.nr ? "NR-ARFCN" : "EARFCN"} v={event.cell ? String(event.cell.earfcn) : "—"} />
              <Fact k="PCI" v={event.cell ? (event.cell.pci === 0xffff ? "pending" : String(event.cell.pci)) : "—"} />
              <Fact k="DL MHz" v={detail?.downlinkEarfcn != null ? String(detail.downlinkEarfcn) : "—"} />
              <Fact k="Bandwidth" v={detail?.bandwidthMhz != null ? `${detail.bandwidthMhz} MHz` : "—"} />
              <Fact k="PLMN" v={detail?.plmn ?? "—"} />
              <Fact k="TAC" v={masked ? "hidden" : detail?.tac != null ? String(detail.tac) : "—"} locked={masked} />
              <Fact
                k="Cell identity"
                v={masked ? "hidden" : detail?.cellIdentity != null ? String(detail.cellIdentity) : "—"}
                locked={masked}
              />
            </dl>
          </TabsContent>

          <TabsContent value="transport" className="mt-3">
            <dl>
              <Fact k="Carried in" v={event.carrier ?? "directly in its own record"} />
              <Fact
                k="Protection"
                v={
                  event.protection
                    ? `${event.protection.headerName} · seq ${event.protection.sequence} · MAC ${event.protection.mac}`
                    : "—"
                }
              />
              <Fact k="Log code" v={event.logCode ?? "—"} />
              <Fact k="Record" v={event.record == null ? "—" : String(event.record)} />
              <Fact k="PDU length" v={event.pduLength == null ? "—" : `${event.pduLength} bytes`} />
            </dl>
          </TabsContent>

          <TabsContent value="bytes" className="mt-3">
            {masked ? (
              <div className="rounded-[6px] border border-dashed border-[var(--line-strong)] p-4 text-sm text-[var(--text-3)]">
                <Lock className="mb-2 size-4" />
                The bytes hold identifiers, so they stay hidden while identifiers are masked.
                <button className="btn-quiet mt-3 block" onClick={onRequestReveal}>Show identifiers…</button>
              </div>
            ) : (
              <pre className="num max-h-80 overflow-auto rounded-[6px] bg-[var(--surface-2)] p-3 text-[11px] leading-5">
                {hexDump(event.pduHex)}
              </pre>
            )}
          </TabsContent>
        </div>
      </Tabs>
    </aside>
  );
}

function FieldTree({ fields, masked, depth = 0 }: { fields: Field[]; masked: boolean; depth?: number }) {
  if (!fields.length) return <p className="text-sm text-[var(--text-3)]">No decoded fields.</p>;
  return (
    <ul className={depth ? "ml-2 border-l border-[var(--line)] pl-2" : ""}>
      {fields.map((f, i) => (
        <li key={`${f.label}-${i}`} className="py-[1px] text-[13px]">
          <span className="text-[var(--text-3)]">{f.label}</span>
          {f.value && (
            <span className="num ml-2">
              {masked && f.masked ? (
                <span className="chip"><Lock className="size-3" /> hidden</span>
              ) : (
                displayFieldValue(f, masked)
              )}
            </span>
          )}
          {f.children.length > 0 && <FieldTree fields={f.children} masked={masked} depth={depth + 1} />}
        </li>
      ))}
    </ul>
  );
}

function Fact({ k, v, locked }: { k: string; v: string; locked?: boolean }) {
  return (
    <div className="grid grid-cols-[110px_minmax(0,1fr)] gap-3 border-b border-[var(--line)] py-1 last:border-b-0">
      <dt className="text-xs text-[var(--text-3)]">{k}</dt>
      <dd className="num min-w-0 break-words text-[13px]">
        {locked ? <span className="chip"><Lock className="size-3" /> {v}</span> : v}
      </dd>
    </div>
  );
}

function flatten(fields: Field[], masked: boolean, depth = 0): string[] {
  return fields.flatMap((f) => [
    `${"  ".repeat(depth)}${f.label}: ${displayFieldValue(f, masked)}`,
    ...flatten(f.children, masked, depth + 1),
  ]);
}

/** 8 bytes a line, with the offset and the printable ASCII, as a protocol dump normally reads. */
function hexDump(hex?: string): string {
  if (!hex) return "No bytes were kept for this message.";
  const bytes = hex.match(/[0-9a-f]{2}/gi) ?? [];
  const lines: string[] = [];
  for (let i = 0; i < bytes.length; i += 8) {
    const chunk = bytes.slice(i, i + 8);
    const ascii = chunk
      .map((b) => {
        const n = parseInt(b, 16);
        return n >= 32 && n <= 126 ? String.fromCharCode(n) : ".";
      })
      .join("");
    lines.push(`${i.toString(16).padStart(4, "0")}  ${chunk.join(" ").padEnd(23, " ")}  ${ascii}`);
  }
  return lines.join("\n");
}

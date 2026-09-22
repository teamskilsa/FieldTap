// A single self-contained HTML file describing one capture, built in the browser from a redacted analysis.
//
// Rules it follows, because this is the file that leaves the machine:
//   - no <script>, no <link>, no <img>, no font or stylesheet URL: it opens with the network unplugged, and it
//     cannot phone anywhere when someone else opens it;
//   - every string it prints is escaped, so a message summary can never become markup;
//   - it reads in both a light and a dark browser, from one small stylesheet inlined at the top;
//   - it is a *report*, not a copy of the app: the story, the facts, the coverage, the measurements, the cells,
//     the procedures and what could not be read. The full redacted object goes out beside it as JSON for anyone
//     who wants to work with it.
import {
  findingText, fmtDuration, fmtSince, pressWindow, profileLine, recordedAt, signedSeconds,
} from "@/lib/analysis/format";
import type { CaptureAnalysis } from "@engine/types";

const esc = (v: unknown): string =>
  String(v ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

const row = (k: string, v: unknown) => `<tr><th>${esc(k)}</th><td>${esc(v)}</td></tr>`;

const STYLE = `
:root{color-scheme:light dark;--bg:#fff;--fg:#14161a;--dim:#5b6472;--line:#e3e6ea;--panel:#fafbfc;
  --warn:#b27600;--bad:#d03b3b;--ok:#0ca30c}
@media (prefers-color-scheme:dark){:root{--bg:#16181d;--fg:#eef0f3;--dim:#9aa3b0;--line:#2c3038;--panel:#1b1e24;
  --warn:#fab219;--bad:#e66767;--ok:#3fc23f}}
*{box-sizing:border-box}
body{margin:0;padding:32px 20px 64px;background:var(--bg);color:var(--fg);
  font:13px/20px ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;font-variant-numeric:tabular-nums}
main{max-width:880px;margin:0 auto}
h1{font-size:19px;line-height:28px;margin:0}
h2{font-size:14px;line-height:20px;margin:32px 0 8px;padding-bottom:6px;border-bottom:1px solid var(--line)}
p{margin:6px 0}
.sub{color:var(--dim);margin:4px 0 0}
.note{border:1px solid var(--line);border-radius:8px;background:var(--panel);padding:12px 14px;margin:16px 0}
table{width:100%;border-collapse:collapse;margin-top:4px}
th,td{text-align:left;vertical-align:top;padding:5px 10px 5px 0;border-bottom:1px solid var(--line);font-weight:400}
th{color:var(--dim);white-space:nowrap;width:180px}
thead th{width:auto;font-weight:500}
td.n,th.n,.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.t{color:var(--dim);white-space:nowrap;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.bad{color:var(--bad)}.warn{color:var(--warn)}.ok{color:var(--ok)}
.chip{display:inline-block;border:1px solid var(--line);border-radius:999px;padding:1px 8px;margin:0 4px 4px 0;
  color:var(--dim);font-size:11px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
footer{margin-top:40px;padding-top:12px;border-top:1px solid var(--line);color:var(--dim);font-size:11px}
`;

export function reportFileBase(analysis: CaptureAnalysis): string {
  const stamp = (analysis.triggerTime ?? new Date().toISOString()).replace(/[:.]/g, "-").slice(0, 19);
  return `fieldtap-report-${stamp}`;
}

/** The whole report, as one string of HTML. */
export function reportHtml(a: CaptureAnalysis, generatedAt = new Date()): string {
  const profile = profileLine(a);
  const t = a.traceWindow;
  const press = pressWindow(a);

  const findings = a.journey.findings
    .map((f) => {
      const tone = f.severity === "failure" ? "bad" : f.severity === "warning" ? "warn" : "";
      return `<tr><td class="t">${esc(f.tMs == null ? "" : fmtSince(f.tMs))}</td>` +
        `<td class="${tone}">${esc(findingText(f, a))}</td></tr>`;
    })
    .join("");

  const tiles = a.journey.tiles
    .map((tile) =>
      `<tr><th>${esc(tile.title)}</th><td class="n">${esc(tile.value ?? "—")}</td>` +
      `<td class="n">${tile.attempts > 0 ? esc(`${tile.succeeded}/${tile.attempts}`) : ""}</td>` +
      `<td>${esc(tile.group)}</td></tr>`,
    )
    .join("");

  const cells = a.cellDetails
    .map((c) =>
      `<tr><td class="n">B${esc(c.band)}</td><td class="n">${esc(c.downlinkEarfcn)}</td>` +
      `<td class="n">${esc(c.pci)}</td><td class="n">${esc(c.plmn)}</td>` +
      `<td class="n">${c.bandwidthMhz != null ? esc(`${c.bandwidthMhz} MHz`) : "—"}</td></tr>`,
    )
    .join("");

  const procedures = a.procedures
    .map((p) => {
      const at = a.events[p.first]?.sinceStartMs ?? 0;
      const tone = p.outcome === "FAILED" ? "bad" : p.outcome === "UNANSWERED" ? "warn" : "ok";
      const took = p.first === p.last || p.durationMs === 0 ? "one message" : fmtDuration(p.durationMs);
      return `<tr><td class="t">${esc(fmtSince(at))}</td><td>${esc(p.name)}</td>` +
        `<td class="n">${esc(took)}</td><td class="${tone}">${esc(p.outcome.toLowerCase())}</td></tr>`;
    })
    .join("");

  const missing = a.availability
    .filter((x) => x.status !== "available")
    .map((x) => `<tr><th>${esc(x.title)}</th><td>${esc(x.reason)}</td></tr>`)
    .join("");

  const journeyCells = a.journey.cells
    .map((c) => `<span class="chip">${esc(`${c.lane === "scell" ? `SCell ${c.index}` : c.lane === "pscell" ? "NR" : "PCell"} · ${c.band} · PCI ${c.cell.pci}`)}</span>`)
    .join("");

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>FieldTap report — ${esc(a.fileName)}</title>
<style>${STYLE}</style>
</head>
<body>
<main>
<h1>FieldTap capture report</h1>
<p class="sub mono">${esc(a.fileName)}</p>
<p class="sub">${esc(recordedAt(a))} · ${esc(fmtDuration(a.durationMs))} of modem trace</p>

<div class="note">
<strong>Identifiers have been removed from this report.</strong>
IMSI, IMEI, phone numbers, IP addresses, temporary identities, the TAC, the cell identity and the raw message
bytes are not in this file or in the JSON beside it. Bands, EARFCNs, PCIs, the PLMN, timings and measurements
are kept: they describe the network, not the person.
</div>

<h2>What this trace covers</h2>
${t
  ? `<p>${
      press
        ? `This trace covers ${esc(signedSeconds(press.from))} to ${esc(signedSeconds(press.to))} around the press.`
        : `This trace is ${esc(fmtDuration(a.durationMs))} long; the press time is not in the file.`
    }</p>
     <p>${esc(`${t.filesKept.toLocaleString("en-US")} of ${t.filesOnPhone.toLocaleString("en-US")} trace files survived: ${t.filesOverwritten} had already been overwritten by the modem, ${t.filesMissing} ${t.filesMissing === 1 ? "is" : "are"} missing.`)}</p>
     <p class="sub">Next time: press the buttons first, do the thing 3–5 s later, and finish by about +12 s. For a surprise event, press within 2–3 s of it.</p>`
  : "<p>There is no modem trace in this file.</p>"}

<h2>What happened</h2>
<table>${findings || '<tr><td colspan="2">No findings.</td></tr>'}</table>

<h2>Capture facts</h2>
<table>
${row("Recorded", recordedAt(a))}
${row("Length", fmtDuration(a.durationMs))}
${row("Plain records", `${a.records.toLocaleString("en-US")} in ${a.codes} codes`)}
${row("Decoded messages", a.events.length.toLocaleString("en-US"))}
${row("Encrypted", `${a.encrypted.records.toLocaleString("en-US")} in ${a.encrypted.codes} codes`)}
${row("CRC errors", a.crcErrors.toLocaleString("en-US"))}
${row("Logging profile", profile.text)}
${row("Contract", a.contract)}
</table>

<h2>Key measurements</h2>
<table><thead><tr><th>Measurement</th><th class="n">Value</th><th class="n">Attempts</th><th>Group</th></tr></thead>
<tbody>${tiles || '<tr><td colspan="4">No measurements.</td></tr>'}</tbody></table>

<h2>Cells this capture saw</h2>
<table><thead><tr><th>Band</th><th>EARFCN</th><th>PCI</th><th>PLMN</th><th>Bandwidth</th></tr></thead>
<tbody>${cells || '<tr><td colspan="5">No cell detail was decoded.</td></tr>'}</tbody></table>
<p>${journeyCells}</p>

<h2>Procedures</h2>
<table><thead><tr><th>Time</th><th>Procedure</th><th class="n">Took</th><th>Outcome</th></tr></thead>
<tbody>${procedures || '<tr><td colspan="4">No procedures.</td></tr>'}</tbody></table>

<h2>What could not be read</h2>
<table>${missing || "<tr><td>Everything this decoder knows about was read.</td></tr>"}</table>

<footer>
Generated by FieldTap Log Analyzer in the browser on ${esc(generatedAt.toISOString())}. No part of this capture
was uploaded to produce it. This file contains no scripts and loads nothing from the network.
</footer>
</main>
</body>
</html>
`;
}

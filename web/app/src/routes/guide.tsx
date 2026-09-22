import { Link } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from "@/components/ui/accordion";
import { Checkbox } from "@/components/ui/checkbox";
import { Check, ExternalLink, HelpCircle } from "lucide-react";
import { fmtSince, profileLine } from "@/lib/analysis/format";
import { usePageMeta } from "@/lib/meta";
import { useCapture } from "@/state/capture";

/** Still being refined — keep the exact timing wording in this one place. */
const CAPTURE_TIMING =
  "Press both volume buttons and the side button together briefly (about a quarter of a second) and let go. You feel a short buzz. Keep reproducing the problem for about 45 seconds afterwards: the modem keeps roughly the last 128 MB, and which part it keeps depends on how long the iPhone takes to collect.";

const PROFILE_URL =
  "https://developer.apple.com/feedback-assistant/profiles-and-logs/?name=baseband";

interface StepDef {
  title: string;
  body: string;
  action?: { label: string; href?: string; to?: "/" };
  trouble: string;
}

const PART_A: StepDef[] = [
  {
    title: "Open Apple's logging page and sign in",
    body: "Apple hosts the logging profile on its own site. Open the page and sign in with your Apple Account — a free account is enough.",
    action: { label: "Open Apple's page", href: PROFILE_URL },
    trouble:
      "Having trouble? If the page asks you to join a paid developer programme, you are on the wrong page — use the button above, which goes straight to the profiles and logs page.",
  },
  {
    title: "Download the Baseband profile",
    body: "On that page, scroll to the iOS section, tap “Baseband”, and download it. Do this on the iPhone itself, using Safari.",
    trouble:
      "Having trouble? If you downloaded it on a computer by mistake, open the page again on the iPhone — the profile has to be downloaded on the phone.",
  },
  {
    title: "Install the profile on the iPhone",
    body: "Open Settings within 8 minutes. Tap “Profile Downloaded” near the top, then Install, and enter your passcode. Confirm the warning screens.",
    trouble:
      "Having trouble? If “Profile Downloaded” is not there, the 8 minutes have passed. Download the profile again and go straight to Settings.",
  },
  {
    title: "Restart if the phone asks",
    body: "Some iPhones ask to restart before logging starts. If yours does, restart it now. Logging then stays on for 7 days and switches itself off.",
    trouble:
      "Having trouble? If you are not sure logging is on, open the log here — the analysis tells you whether logging was active during the recording.",
  },
];

const PART_B: StepDef[] = [
  {
    title: "Reproduce the problem and take the recording",
    body: CAPTURE_TIMING,
    trouble:
      "Having trouble? Nothing appears on screen when it works — the short buzz is the only sign. Take the recording while the problem is happening, or within a minute after.",
  },
  {
    title: "Wait up to 10 minutes",
    body: "The iPhone needs a few minutes to collect and package everything. Leave it alone; there is no progress bar.",
    trouble:
      "Having trouble? If nothing appears after 10 minutes, take the recording again and check the button timing in step 1.",
  },
  {
    title: "Find the recording and share it",
    body: "Settings → Privacy & Security → Analytics & Improvements → Analytics Data. Scroll to the newest entry starting with “sysdiagnose_”, open it, then Share — AirDrop to your Mac, or Save to Files.",
    trouble:
      "Having trouble? The list is alphabetical, so look for the name with today's date. The file is large, so AirDrop or Files works better than email.",
  },
  {
    title: "Open it here",
    body: "Come back to this page with the file on the same device and drop it in. It is read in this browser tab and never sent anywhere.",
    action: { label: "Open a log", to: "/" },
    trouble:
      "Having trouble? Keep the .tar.gz exactly as it came off the phone — do not unzip it first.",
  },
];

export function GuidePage() {
  usePageMeta(
    "How to record your iPhone's modem log — FieldTap Log Analyzer",
    "Install Apple's Baseband logging profile, record a sysdiagnose while the problem happens, and open it here.",
  );
  const { analysis } = useCapture();
  const status = analysis ? profileLine(analysis) : null;
  const timing = analysis?.traceWindow?.afterPressStartS != null && analysis.traceWindow.afterPressEndS != null
    ? `In your last capture the modem kept ${fmtSince(analysis.traceWindow.afterPressStartS * 1000)}–${fmtSince(Math.floor(analysis.traceWindow.afterPressEndS) * 1000)} after the press.`
    : "The modem keeps only part of the ring buffer around your button press.";

  return (
    <div className="mx-auto max-w-3xl px-4 py-10">
      <h1 className="text-[20px] font-semibold leading-7">
        How to record your iPhone's modem log
      </h1>
      <p className="mt-2 text-sm text-[var(--text-3)]">
        Two parts: switch logging on (needed once a week), then record while the problem
        happens. Everything you record stays on your own devices.
      </p>

      <section className="panel mt-6 p-4" aria-label="Last analysis status">
        <p className="text-xs font-semibold uppercase text-muted-foreground">Last file</p>
        <p className="mt-1 text-sm font-medium">{status ? status.text : "Not checked yet: open a log and FieldTap will tell you"}</p>
        {analysis?.guide.needsAttention && <p className="mt-1 text-xs text-muted-foreground">Start with Part A before recording again.</p>}
      </section>

      <StepList
        title="Part A — turn on logging (every 7 days)"
        part="a"
        steps={PART_A}
      />
      <StepList title="Part B — record the problem" part="b" steps={PART_B} timing={timing} />

      <h2 className="mt-10 text-base font-semibold">Troubleshooting</h2>
      <Accordion type="single" collapsible className="mt-2">
        <AccordionItem value="1">
          <AccordionTrigger>I can't find “Profile Downloaded” in Settings</AccordionTrigger>
          <AccordionContent>
            That line disappears about 8 minutes after the download. Open Apple's page on
            the iPhone again, download the Baseband profile, then go straight to Settings
            and tap it.
          </AccordionContent>
        </AccordionItem>
        <AccordionItem value="2">
          <AccordionTrigger>
            It says Stolen Device Protection is stopping the install
          </AccordionTrigger>
          <AccordionContent>
            When you are away from a familiar place, iOS delays some changes by an hour.
            Either wait where you usually are (home or work) and try again, or turn Stolen
            Device Protection off in Settings → Face ID &amp; Passcode while you install
            the profile, then turn it back on.
          </AccordionContent>
        </AccordionItem>
        <AccordionItem value="3">
          <AccordionTrigger>The sysdiagnose is not in the list yet</AccordionTrigger>
          <AccordionContent>
            It can take up to 10 minutes to appear. If it still isn't there, the button
            press probably didn't register — take the recording again, and check you felt
            the short buzz when you let go.
          </AccordionContent>
        </AccordionItem>
        <AccordionItem value="4">
          <AccordionTrigger>The analysis says logging was off</AccordionTrigger>
          <AccordionContent>
            The profile lasts 7 days and then removes itself, so a log taken after that
            contains no modem trace. Install the profile again (Part A) and record once
            more.
          </AccordionContent>
        </AccordionItem>
      </Accordion>

      <Accordion type="single" collapsible className="panel mt-10 px-4">
        <AccordionItem value="profile" className="border-b-0">
          <AccordionTrigger>Why can't the profile be built into this app?</AccordionTrigger>
          <AccordionContent className="space-y-2 text-sm text-muted-foreground">
            <p>Only Apple can turn modem logging on inside iOS.</p>
            <p>iOS does not let apps or websites install configuration profiles — you have to tap through Settings yourself.</p>
            <p>Apple's profile may not be redistributed, so it has to be downloaded from Apple's own page each time.</p>
          </AccordionContent>
        </AccordionItem>
      </Accordion>
    </div>
  );
}

function StepList({ title, part, steps, timing }: { title: string; part: "a" | "b"; steps: StepDef[]; timing?: string }) {
  return (
    <section className="mt-8">
      <h2 className="text-base font-semibold">{title}</h2>
      <div className="relative mt-3 space-y-3 before:absolute before:bottom-6 before:left-3 before:top-6 before:w-0.5 before:bg-line">
        {steps.map((s, i) => (
          <StepCard key={s.title} step={s} part={part} n={i + 1} total={steps.length} />
        ))}
      </div>
      {timing && <TimingCallout text={timing} />}
    </section>
  );
}

function StepCard({ step, part, n, total }: { step: StepDef; part: "a" | "b"; n: number; total: number }) {
  const [open, setOpen] = useState(false);
  const key = `fieldtap.guide.${part}.${n}`;
  const [done, setDone] = useState(false);
  useEffect(() => {
    try { setDone(window.localStorage.getItem(key) === "true"); } catch { setDone(false); }
  }, [key]);
  const setDoneSafe = (v: boolean) => {
    setDone(v);
    try { window.localStorage.setItem(key, String(v)); } catch { /* ignored */ }
  };
  return (
    <div className="relative grid grid-cols-[24px_minmax(0,1fr)] gap-4">
      <span className="z-10 grid size-6 place-items-center rounded-full border bg-background text-xs font-semibold text-muted-foreground">{done ? <Check className="size-3.5 text-signal-excellent" /> : n}</span>
      <div className="panel p-5">
        <p className="text-xs font-semibold uppercase tracking-wide text-primary">
          Step {n} of {total}
        </p>
        <h3 className="mt-1 text-base font-semibold">{step.title}</h3>
        <p className="mt-2 text-sm text-muted-foreground">{step.body}</p>
        {step.action?.href && (
          <Button asChild className="mt-4">
            <a href={step.action.href} target="_blank" rel="noopener noreferrer">
              {step.action.label} <ExternalLink className="size-4" />
            </a>
          </Button>
        )}
        {step.action?.to && (
          <Button asChild className="mt-4">
            <Link to={step.action.to}>{step.action.label}</Link>
          </Button>
        )}
        <label className="mt-4 flex items-center gap-2 text-xs text-muted-foreground">
          <Checkbox checked={done} onCheckedChange={(v) => setDoneSafe(v === true)} />
          Mark as done
        </label>
        <button
          onClick={() => setOpen((o) => !o)}
          className="mt-3 flex items-center gap-1.5 text-xs text-muted-foreground hover:text-foreground"
        >
          <HelpCircle className="size-3.5" /> Having trouble?
        </button>
        {open && <p className="mt-2 text-xs text-muted-foreground">{step.trouble}</p>}
      </div>
    </div>
  );
}

function TimingCallout({ text }: { text: string }) {
  return (
    <div className="panel mt-4 grid gap-4 p-4 sm:grid-cols-[180px_minmax(0,1fr)]">
      <svg viewBox="0 0 180 64" role="img" aria-label="Capture timing illustration" className="h-16 w-full">
        <line x1="12" y1="34" x2="168" y2="34" stroke="var(--line-strong)" strokeWidth="2" />
        <rect x="64" y="22" width="76" height="24" rx="4" fill="var(--primary)" opacity="0.18" />
        <circle cx="52" cy="34" r="6" fill="var(--primary)" />
        <text x="42" y="16" fill="var(--text-3)" fontSize="10">press</text>
        <text x="78" y="58" fill="var(--text-3)" fontSize="10">kept window</text>
      </svg>
      <p className="self-center text-sm text-muted-foreground">{text}</p>
    </div>
  );
}

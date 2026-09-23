import { useState } from "react";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from "@/components/ui/sheet";
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
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import { Label } from "@/components/ui/label";
import { Settings } from "lucide-react";
import { ExportReport } from "@/components/capture/ExportReport";
import { useCapture } from "@/state/capture";
import { CONTRACT_VERSION } from "@engine/types";

type ThemeMode = "system" | "dark" | "light";

function applyTheme(mode: ThemeMode) {
  const dark = mode === "dark" || (mode === "system" && window.matchMedia("(prefers-color-scheme: dark)").matches);
  document.documentElement.classList.toggle("dark", dark);
  document.documentElement.dataset["theme"] = mode;
  try { window.localStorage.setItem("fieldtap.theme", mode); } catch { /* ignored */ }
}

export function SettingsDrawer({ iconOnly = false }: { iconOnly?: boolean }) {
  const { analysis, masked, setMasked } = useCapture();
  const [confirm, setConfirm] = useState(false);
  const [theme, setTheme] = useState<ThemeMode>(() => {
    if (typeof window === "undefined") return "system";
    const v = window.localStorage.getItem("fieldtap.theme");
    return v === "dark" || v === "light" || v === "system" ? v : "system";
  });

  const setThemeMode = (mode: ThemeMode) => {
    setTheme(mode);
    applyTheme(mode);
  };

  return (
    <>
      <Sheet>
        <SheetTrigger asChild>
          <Button variant="ghost" size={iconOnly ? "icon" : "sm"} aria-label="Settings">
            <Settings className="size-4" />
            {!iconOnly && <span>Settings</span>}
          </Button>
        </SheetTrigger>
        <SheetContent className="w-full border-line bg-surface-1 sm:max-w-md">
          <SheetHeader>
            <SheetTitle>Settings</SheetTitle>
            <SheetDescription>
              Your log never leaves this computer — it is processed in your browser.
            </SheetDescription>
          </SheetHeader>
          <div className="space-y-6 px-4">
            <section className="space-y-3">
            <div className="flex items-start justify-between gap-4">
              <div>
                <Label htmlFor="ids" className="text-sm font-medium">
                  Show identifiers
                </Label>
                <p className="mt-1 text-xs text-muted-foreground">
                  IMSI, IMEI, phone number, IP addresses and temporary identities are hidden by default.
                </p>
              </div>
              <Switch id="ids" checked={!masked} onCheckedChange={(v) => (v ? setConfirm(true) : setMasked(true))} />
            </div>
            </section>

            {analysis && (
              <section>
                <h4 className="text-sm font-medium text-foreground">Export a redacted report</h4>
                <p className="mt-1 text-xs text-muted-foreground">
                  A self-contained HTML report and the analysis as JSON, both with identifiers stripped and both
                  built in this tab. Nothing is uploaded.
                </p>
                <div className="mt-2">
                  <ExportReport analysis={analysis} label="Export a redacted report" />
                </div>
              </section>
            )}

            <section>
              <h4 className="text-sm font-medium text-foreground">Theme</h4>
              <div className="mt-2 grid grid-cols-3 gap-2">
                {(["system", "dark", "light"] as ThemeMode[]).map((mode) => (
                  <Button key={mode} type="button" size="sm" variant={theme === mode ? "secondary" : "outline"} onClick={() => setThemeMode(mode)} className="capitalize">{mode}</Button>
                ))}
              </div>
            </section>

            <div className="space-y-2 text-xs text-muted-foreground">
              <h4 className="text-sm font-medium text-foreground">About</h4>
              <p className="num">Contract: {analysis?.contract ?? CONTRACT_VERSION}</p>
              <p>
                FieldTap reads an iPhone sysdiagnose recorded with Apple's Baseband logging profile. Everything runs in this browser tab.
              </p>
              <p>No upload, no account, no database, no analytics and no third-party scripts can see file contents.</p>
              <h4 className="pt-3 text-sm font-medium text-foreground">Licences</h4>
              {/* The real dependency list, checked against package.json. Recharts used to be here and never was
                  a dependency: every chart in this app is hand-drawn SVG (components/capture/charts.tsx). */}
              <p>
                Open-source components: React, TanStack Router, TanStack Virtual, Tailwind CSS, Radix UI, cmdk
                and Lucide icons.
              </p>
            </div>
          </div>
        </SheetContent>
      </Sheet>

      <AlertDialog open={confirm} onOpenChange={setConfirm}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Show identifiers on screen?</AlertDialogTitle>
            <AlertDialogDescription>
              Your IMSI, IMEI, phone number, IP addresses and temporary identities will be shown in full. Only do this if nobody can see your screen.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Keep hidden</AlertDialogCancel>
            <AlertDialogAction onClick={() => setMasked(false)}>Show identifiers</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}

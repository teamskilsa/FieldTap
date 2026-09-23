// DEV ONLY. The one place in the app that touches the network, and only ever a same-origin static file the
// developer put there: public/dev/analysis.json, a CaptureAnalysis written by the engine from a real capture.
// public/dev/ is git-ignored, so capture-derived data never reaches the repository, and this module refuses to
// run in a production build — `import.meta.env.DEV` is a compile-time constant, so the branch below (and the
// fetch with it) is dropped from the bundle.
import type { CaptureAnalysis } from "@engine/types";
import { CONTRACT_VERSION } from "@engine/types";

const DEV_FIXTURES = {
  // A real capture written by the engine's pipeline tool (capture-derived, git-ignored).
  real: "/dev/analysis.json",
  // A fully-synthetic FLAGGED capture (deno run -A tools/flagged-fixture.ts), for a screenshot of a suspicious
  // Security screen. Invented data only.
  flagged: "/dev/flagged.json",
} as const;

export type DevFixture = keyof typeof DEV_FIXTURES;

export async function loadDevAnalysis(which: DevFixture = "real"): Promise<CaptureAnalysis> {
  if (!import.meta.env.DEV) throw new Error("The dev fixture is only available in a dev build.");

  const url = DEV_FIXTURES[which];
  const response = await fetch(url, { cache: "no-store" });
  if (!response.ok) {
    throw new Error(
      `No dev fixture at public${url} (${response.status}). Write one with the engine's tools.`,
    );
  }
  const analysis = (await response.json()) as CaptureAnalysis;
  if (analysis.contract !== CONTRACT_VERSION) {
    throw new Error(`The fixture is contract ${String(analysis.contract)}, this build expects ${CONTRACT_VERSION}.`);
  }
  // Marked so the capture page can tell a dev fixture from the sample, and so no screenshot mistakes one for
  // the other. The name itself is not a capture identifier.
  return { ...analysis, fileName: `dev:${which}:${analysis.fileName}` };
}

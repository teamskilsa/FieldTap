# App, account, cloud: what makes sense

> **Decision, 2026-09-10:** the user decided to build the app anyway, without a modem, as a
> measurement logger feeding the same report and account. The build plan is in
> [`APP-PLAN.md`](APP-PLAN.md). Everything below about layer 3, the account, pricing and
> the redaction rule still applies; only the "no app" conclusion was overruled.

The question was whether an app should do the logging and upload to an account.
Short answer: **yes to the account, no to the app doing the logging** — and there
is one engineering requirement that decides whether the upload is a product or a
liability.

Research: [`research/cloud-collection-market.md`](research/cloud-collection-market.md),
[`research/upload-privacy-legal.md`](research/upload-privacy-legal.md),
[`research/cellular-app-landscape.md`](research/cellular-app-landscape.md),
[`research/android-app-question.md`](research/android-app-question.md).

---

## The one fact the whole market turns on

**Nobody collects layer 3 by crowdsourcing. Not one player.** RantCell says it in
its own FAQ: *"RantCell does not support layer 2 or layer 3 messages."*
Opensignal's privacy policy enumerates every field it collects and there is no
protocol layer in it.

That is not a product choice, it is an operating-system boundary. Android's
public API gives cell identity and signal strength and stops. Below that you need
Qualcomm diag, and since Android 11 the security policy blocks that from any app
without rebuilding the boot image.

So the market split in two:

| | Sells | Devices | Layer 3 | Examples |
| --- | --- | --- | --- | --- |
| **Crowdsourced** | statistics | millions | **No** | Ookla, Opensignal, CellMapper, RantCell |
| **Professional probe** | root cause | tens | Yes | QualiPoc, Nemo, TEMS, XCAL, NSG |

Everyone selling layer 3 solves device access by **not being a mass-market app**.
They ship provisioned handsets, or a supported-device list, or external hardware.

### The position nobody occupies

Layer 3 on a **stock, unrooted, carrier-unlocked handset**, or from a modem
module with no phone at all. That is where the Samsung dialer-code finding and
the modem module put us. **That, not a dashboard, is the differentiator.**

---

## Therefore: no to an app that does the logging

An app that logs and uploads has exactly two possible shapes, and both are bad.

**Non-root app.** You become the sixth entrant into a category where NetMonster
has five million installs, Network Cell Info has ten million, LTE Discovery has
a million, and G-NetTrack Pro costs $34.99 once. All of them sit at the identical
public-API ceiling. Nothing you build can exceed it, and you would be teaching
the market that this is a NetMonster clone.

**Rooted app.** Back to root, which throws away the advantage. Worse, rooting a
Samsung has been reported to break diag permanently. And the reference
implementation for this shape, MobileInsight, is dead: a February 2026 paper
exists specifically because Android's security policy broke it.

There is also a structural point that settles it. Both no-root diag routes work
by changing the phone's **USB composition** — publishing diag for a host at the
other end of the cable. A phone cannot be a USB host to its own port. The capture
device is always something else.

---

## Yes to the account and the cloud

The account is a good idea. It is just not attached to a phone app.

**What it is:** the laptop, or the modem, or an Android acting as a USB host,
captures the session. The account is where sessions land, so a team sees
everything in one place instead of emailing folders around.

Every professional vendor has this and charges for it: Nemo Cloud, VistaTest,
XCAL-Manager, SmartBenchmarker. It is fleet management, not crowdsourcing.

### What the market will pay

| Product | Price | Layer 3? |
| --- | --- | --- |
| G-NetTrack Pro | $34.99 once | No |
| NSG | about $50/month | Yes, needs root |
| **RantCell** | **$1,600/yr for 5 devices** (about $320/device/yr) | **No** |
| **HiCellTek** | **€22.99/mo, or €249/mo/device** | **Yes** |
| QualiPoc | a preloaded handset lists around $9,250 | Yes |

**RantCell is the shape of the business and it has no layer 3.** That is the
gap: the same cloud workflow, with real decode underneath.

**HiCellTek is the one direct competitor** — layer 3 on Android, cloud, published
pricing, explicitly marketed as the XCAL alternative. Treat it as validation and
as a warning: it is a solo founder currently offering a €3,000 kit for €700,
which is what buying reference customers looks like.

---

## The requirement that decides whether upload is viable

A diag capture contains **other people's identifiers**. The paging channel
carries up to sixteen records per message, addressed to other subscribers. Your
own repository already refuses to commit capture files for exactly this reason.

Uploading changes the legal position, unambiguously. Capture and disclosure are
regulated separately in every jurisdiction examined, and the disclosure rules are
the harsher ones:

- In the US, the exemption for radio you can freely receive **expressly excludes
  cellular**. "It was unencrypted and in the air" is not a defence — that is
  precisely the argument Google lost over Street View WiFi, and settled for $13M.
- One US provision reaches **the party who receives** intercepted material, which
  means the cloud service, not just the app.
- In the UK, disclosure is its own separate offence.
- In Germany, unintentional reception is **expressly not a defence** to
  disclosing it.

**But this is an engineering problem, not a business-model problem.** If the
third-party identifiers never leave the device, almost all of it becomes moot.

### The rule

> Parse the paging record list, keep only the record matching this device's own
> temporary identity, and **discard the rest before writing to disk** — not
> before upload, so that a crash dump or a support bundle cannot leak them
> either. If the redactor cannot parse a message, drop it and mark the session
> partially redacted. Never fall through to uploading raw because parsing failed.

Two more that matter:

- **Never use a plain hash as a pseudonym.** A hashed subscriber identity is
  brute-forceable in minutes: it is fifteen digits, and the space collapses once
  the network code is known.
- **Separate the pipelines.** KPI data and raw diag are different legal objects.
  Different consent, different storage, different buttons. Raw upload opt-in per
  session, never a global setting.

Publishing that redaction design is the only credible answer to the first
question a serious operator's security team will ask, **and no competitor has
one.** It is a sales asset, not just compliance.

### What is not a problem

Operators do not appear to object to third parties mapping their networks. There
is no enforcement precedent against CellMapper or similar in a decade, cell
identities are broadcast in the clear, and regulators actively want the data —
the FCC accepts third-party drive tests to challenge carrier coverage claims. The
thing that would damage the relationship is not mapping their cells. It is being
the vendor that centralised their subscribers' identities.

---

## Distribution, and 5gto6g.com

Owning the domain helps more than expected.

- **Direct download from your own site is explicitly excluded** from Android's
  September 2026 verification enforcement. It still works.
- But since August 2026 an unverified developer's app makes the user go through a
  multi-step flow with a **24-hour wait**. Not a block, but not a one-tap install.
- **Register in the Android Developer Console now.** It is cheap, removes that
  friction, and protects the package name — the rules award a contested name to
  whoever has more installs.
- For the real buyer, an operator or integrator with a device fleet, **managed
  distribution** is the right channel and sidesteps most of this.
- **iOS has no live route, but it has an after-the-fact one.** There is still no
  public interface for cell measurements, and the jailbreak route covers only
  pre-2018 hardware. But with Apple's own Baseband logging profile, a stock
  iPhone's sysdiagnose carries the modem's DIAG trace, which FieldTap turns into a
  `.qmdl` and decodes: see
  [`research/iphone-baseband-capture.md`](research/iphone-baseband-capture.md).

---

## The plan

**1. Prove the modem module on hardware.** Nothing else matters until real RRC
and NAS from real hardware appear in Wireshark. Days to weeks.

**2. Build the redaction pass, before any upload feature exists.** Drop foreign
paging records at the point of capture. This is what makes everything after it
sellable, and it is a differentiator no competitor advertises.

**3. Local web UI.** Per the existing UI plan. Sessions, live view, map.

**4. Accounts and upload, KPI-first.** Sessions sync to an account, a team sees
one dashboard. Raw diag upload opt-in per session and gated behind the enterprise
tier, where a data-processing agreement exists anyway. The commercial boundary
happens to sit exactly where the legal one does.

**5. Price against RantCell, not against the free apps.** Their $320 per device
per year buys no layer 3. That is the sentence the sales deck is built on.

**Not on the plan:** an app that does the capturing, an iOS app that measures
live (the iPhone app imports a sysdiagnose after the fact; see
[`research/iphone-baseband-capture.md`](research/iphone-baseband-capture.md)), and
competing with Ookla on scale.

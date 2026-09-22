# Competitive landscape

Directional as of the analysis date. Pricing and chipset-support claims move — confirm
against live quotes before quoting any of it externally.

## The two products that matter

### XCAL-Mobile (Accuver)

    supported handset -> diag/DM port -> on-device collection + GPS tagging
      -> proprietary log -> XCAP on a workstation

The phone is a *collection endpoint*, not the analysis surface. Intelligence lives
downstream in XCAP. Supports Qualcomm DIAG and Samsung Exynos DM; MediaTek in some builds.

Buys: automated test sequencing (unattended drive routes), multi-device campaigns, central
server and fleet management. Access model is enterprise — a supported device list with
diag provisioned via vendor cooperation, which is exactly why it clears operator IT and
procurement. Roughly five figures per seat.

### NSG — Network Signal Guru (QTRUN)

    rooted phone -> /dev/diag -> ASN.1 decode ON THE HANDSET -> rendered live on screen

Collapses the workstation step entirely. Read a full RRC Connection Reconfiguration,
expanded IE by IE, standing at the cell site. That is its signature capability.

The bigger gap: **NSG writes to the modem.** Band lock, cell lock, RAT force, measurement
config, NV access on supported devices. XCAL controls the *phone* for test sequencing;
NSG reaches into the *modem's* radio selection. For an engineer chasing one bad cell, that
is the entire job.

Costs: requires root, Qualcomm-centric, dense UI, essentially no campaign tooling or
post-processing suite. Hundreds of USD, tiered.

### Contrast

| | XCAL-Mobile | NSG |
| --- | --- | --- |
| Decode happens | Downstream, in XCAP | On-device, live |
| Modem access | Read + phone-level test control | **Read and write** |
| Device access | Supported list, vendor-provisioned | Root, self-service |
| Built for | Campaigns, benchmarking, fleets | One engineer, one phone, one cell |
| Analysis suite | Deep | Thin |
| Cost | Five figures/seat | Hundreds, tiered |
| Procurement | Clears cleanly | Chinese vendor + rooted device blocks some Western operators |

## The rest of the field

**Commercial phone-as-probe:** R&S QualiPoc Android (closest analogue, market leader in
this form factor), Keysight Nemo Handy, Infovista TEMS Pocket.

**Open source:** QCSuper (P1sec) — the current backend; SCAT (fgsect) — the alternative;
MobileInsight — most productized of the open tools; SnoopSnitch (SRLabs) — same plumbing,
security framing; G-NetTrack Pro — Android-API-level only, so no RRC/NAS, different tier
but competes for the same budget line.

**Reference tool:** Qualcomm QXDM/QCAT/APEX — licence-gated, Windows, and what customers'
RF engineers already trust. Matching its decode fidelity is table stakes.

**Boxes this undercuts:** Amarisoft UE Simbox, Keysight UXM, Anritsu MT8000A, R&S CMX500 —
and Simnovus's own UESIM. Worth being deliberate about that last one.

## iPhone

iOS gives apps no live cell data (Apple DTS: no supported low-level cellular access), so every iPhone route is
either a vendor arrangement with Apple or a modem trace taken out of a sysdiagnose after the fact.

| Tool | iPhone support | How it gets the data |
| --- | --- | --- |
| TEMS Investigation / Paragon (Infovista) | Data-service tests, logging, VoLTE SIP, RAT/band lock on some models (iPhone 8 to 12 in 22.3); iPhone 16 in 26.2, iPhone 17 series in 27.2. The free TEMS OnDevice app runs data tests only | Not published. The product description says iPhones ship with an iOS version enabled for TEMS, under an "Apple" connect licence: partner access, by all appearances |
| R&S ROMES4 with the ROMES Probe app | Claims full Qualcomm chipset logging, L1 and L3, mobility procedures | Not published |
| XCAL-iSolo (Innowireless / Accuver) | App Store, needs a licence; "DM messages and RF values", NR SCG view, PCAP saving | Not published |
| Keysight Nemo | The NATA app: FTP, HTTP, ping and GPS only; Nemo Handy lists no Apple devices | — |
| NSG, QualiPoc, G-NetTrack, Cellular-Z | Android only | — |
| CellGuard (TU Darmstadt research app, TestFlight) | Apple's Baseband profile, then a sysdiagnose shared into the app | The modem's control messages (QMI/ARI) in the system log, not the QDSS DIAG trace |
| SCAT, QCSuper, MobileInsight | No iPhone input; SCAT's wiki says `.qdss` is not supported | — |

**The sysdiagnose route, FieldTap's.** The user installs Apple's own Baseband logging profile (7 days, free,
Settings only: it cannot ship in an app), presses the sysdiagnose buttons, reproduces the problem 20 to 40 s
later and shares the archive. FieldTap rebuilds the modem's QDSS trace into a `.qmdl` and decodes RRC and NAS
with the same decoders as the Android captures. One capture measured so far: about 27 s of trace, 19 to 46 s
after the press; 92,133 log records, of which 128 call-flow events. No public tool was found that does this;
that is an absence of evidence, not proof. The trade against the licensed suites: no partner access and no
licence fee, but after the fact only, about 27 s per sysdiagnose, and the modem-encrypted NR physical-layer
records unreadable (23,764 in that capture). Details and sources:
[`research/iphone-baseband-capture.md`](research/iphone-baseband-capture.md).

Sources: TEMS Investigation 22.3 product description
(https://infocom.haradacorp.co.jp/wp/wp-content/uploads/2020/10/TEMS-Investigation-22.3-Technical-Product-Description.pdf),
TEMS newsletter November 2025 (https://www.infovista.com/products/tems-suite/mobile-network-testing/newsletter/2025/11),
TEMS OnDevice (https://apps.apple.com/us/app/tems-ondevice/id1548649639), ROMES4
(https://www.rohde-schwarz.com/us/products/test-and-measurement/network-data-collection/rs-romes4-drive-test-software_63493-8650.html),
ROMES Probe (https://apps.apple.com/app/id6445962802), XCAL-iSolo (https://apps.apple.com/us/app/xcal-isolo/id1645003816),
Nemo NATA (https://apps.apple.com/us/app/nemo-active-testing-app/id1600487632), Nemo Handy flyer
(https://www.keysight.com/us/en/assets/7018-05575/flyers/5992-2050.pdf), CellGuard (https://cellguard.seemoo.de/docs/install/),
SCAT (https://github.com/fgsect/scat/wiki/Baseband-Dumps), Apple DTS (https://developer.apple.com/forums/thread/751785).

## Where FieldTap fits

Structurally on NSG's side of the line — root, diag, decode — but currently missing three
of its four legs: no on-device UI, no write path, offline decode instead of live.

The defensible slot is **not** out-building XCAP, which is a decade of engineering. It is
that NSG's export and analysis story is weak and its procurement story is worse. A
rooted-phone capture tool with clean pcap output, real NR decode, and a Western vendor
behind it has a real niche — and it is a narrower, more honest claim than competing with
XCAL on features.

## Naming note

The opaque-acronym lane (XCAL, TEMS, NSG) is closed to a newcomer — those names carry
meaning only because their owners spent decades teaching the market. Self-explaining names
win from a standing start. "Tap" additionally names the wedge: a network tap is passive,
honest observation, and GSMTAP is literally the encapsulation emitted.

Avoid `OpenTap` — that is Keysight's open-source test automation framework. Avoid anything
containing "Diag": it is Qualcomm's word, it advertises the root dependency, and it reads
gray-area to the procurement team whose trust is the whole advantage over NSG.

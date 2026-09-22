# Cellular measurement apps: the landscape

Consolidated from four parallel research passes on 2026-09-10. Figures come from
Google Play listings, developer sites, GitHub, AppBrain-style trackers and vendor
pricing pages. Where sources disagreed the disagreement is noted; where a figure
could not be verified it says so. Install counts drift and third-party trackers
often disagree with the live Play listing, so treat them as order-of-magnitude.

---

## The one line that divides the market

**Every app that decodes layer 3 needs root or vendor cooperation. Every app that
needs neither stops at the public Android API.** Nobody in between is doing it
cheaply.

| Tier | Gets | Examples |
| --- | --- | --- |
| Public API, no root | Cell identity, RSRP/RSRQ/SINR, band, ARFCN, service state; active tests | NetMonster, Network Cell Info, LTE Discovery, CellMapper, G-NetTrack, RantCell |
| Layer 3, root | RRC, NAS, SIP decode via Qualcomm diag | Network Signal Guru, HiCellTek |
| Layer 3, vendor-provisioned or external hardware | Full diag, no user root | QualiPoc, XCAL-Mobile, TEMS Pocket, Nemo Handy (via its USB module) |
| Dead | Once did layer 3 | MobileInsight, SnoopSnitch |

None of the public-API apps export pcap or mention Wireshark.

---

## Public API tier: no root, no layer 3

| App | Installs | Rating | Price | Cloud | Notes |
| --- | --- | --- | --- | --- | --- |
| **LTE Discovery** (Simply Advanced LLC) | 1M+ | 4.0 | Free, ads, Pro and a newer Pro Plus IAP | Opt-in crowdsourced coverage and tower maps, added in a 2026 overhaul | On Play since Dec 2012; updated Aug 2026. Recent reviews angry about the overhaul removing the tower direction arrow and paywalling the map. Root only for "refresh cell radio". No pcap |
| **NetMonster** (Michal Mroček) | 5M+ | 3.8 | Free, ads, IAP for cell-location estimate | No mandatory account | Built on the open-source netmonster-core (Apache-2.0, 451 stars). Reviews object to ads added silently despite a privacy policy saying none, and to the public repo lagging the app. Weak on 5G carrier aggregation |
| **Network Cell Info** (M2Catalyst, package still `com.wilysis`) | 10M+ Lite, 100K+ Pro | 4.0 / 4.1 | Lite free with ads; Pro $1.99 plus a subscription | "Bad Signal Reporter" sends aggregated poor-coverage reports free to operators | Updated Sep 2026 |
| **CellMapper** | 1M+ | **2.3** | Free with ads; CAD $3/month premium | Account required to contribute; the crowdsourced map is the product | Lowest rating in the set. Complaints: towers placed wildly wrong, login friction, silent upload failures on road trips. Last updated Oct 2025, the stalest here |
| **Cellular-Z** (JerseyHo) | 100K+ | 3.8 | Free, ads, IAP | None advertised | Original package delisted; now `make.more.r2d2.cellular_z.play`. A public review dispute over whether it phones home |
| **SignalCheck Pro** (Blue Line Computing) | ~39K | 4.0 | $3.99 once | None | Strong notification and widget UX. Not made by Wilysis, contrary to a common mix-up |
| **G-NetTrack Pro** (Gyokov Solutions) | ~28K Pro; Lite 1M+ | 4.4 | **$14.99 or $34.99 once** (sources disagree) | None | The closest in intent to a drive-test tool: indoor and outdoor modes, routes, voice and data sequences, Bluetooth control of several phones. Logs text and KML, not pcap |

### Consumer speed and quality apps

| App | Scale | Model |
| --- | --- | --- |
| **Ookla Speedtest** | 100M+ installs, 250M+ tests/month | The free app feeds the Speedtest Intelligence data business. Ziff Davis's Connectivity segment earned **$230.7M in 2025**. **Accenture agreed to buy it for $1.2B in March 2026** |
| **Opensignal** | Tens of millions of installs | Sells crowdsourced data and benchmark awards to operators and regulators. Comlinkdata bought Tutela in 2019 and Opensignal in 2021, and unified all three as Opensignal in 2022 |
| **Tutela** | SDK in 3,000+ partner apps, 300M devices at peak | Revenue-shared with host apps, resold the aggregate. Now part of Opensignal |
| **nPerf** | 10M+ | Ads plus about $3/year ad-free; licenses an SDK and white-label apps to operators |
| **5GMARK** (Mozark) | 1M+ | Consumer front end for a B2B quality-benchmarking business |

**Corrections to claims in circulation:** Opensignal was not acquired by
"MedUX/Telcomunda", and Tutela was not acquired by Comscore. Both trace to
Comlinkdata. A 2021 "Tutela" acquisition that turns up in searches is an
unrelated compliance-software company.

---

## Layer 3 and professional tier

| Tool | Layer 3 | Root | Price | Alive |
| --- | --- | --- | --- | --- |
| **Network Signal Guru** (QTRUN) | Yes: RRC, NAS, SIP; also band and cell lock | Yes for Qualcomm and MediaTek; Samsung Exynos needs a vendor token | Free, IAP; users cite about $50/month | Yes, updated Jul 2026. 500K+ installs, 3.9 |
| **HiCellTek** | Yes: RRC, NAS, IMS | Implied (Qualcomm diag) | Free tier; Pro €22.99/month; Pro Field €249/device/month; Team and Enterprise quoted | Yes, small, solo founder |
| **QualiPoc Android** (R&S) | Yes, real-time | Vendor-managed | Quote only; a refurbished preloaded Galaxy S22+ lists around $9,250 | Yes |
| **XCAL-Mobile** (Accuver) | Yes | Diag-based, vendor-managed | Quote, licence server | Yes |
| **TEMS Pocket** (Infovista) | Likely, by lineage | Community evidence suggests diag access | Quote only | Yes |
| **Nemo Handy** (Keysight) | Via its external Nemo Diagnostic Module | **No root**, because the module does the diag access | Quote only | Yes |
| **RantCell** (MegronTech) | **No.** Its FAQ: "RantCell does not support layer 2 or layer 3 messages" | **No** | **$1,600/yr for 5 devices; $3,000/yr for 8**; Enterprise quoted | Yes |
| **MobileInsight** | Did | Yes, plus per-kernel build | Free, open source | **Dead.** Broken on Android 11+ by SELinux, per a February 2026 paper written to replace it. Last real commit 2022 |
| **SnoopSnitch** (SRLabs) | Security events | Yes | Free, GPLv3 | **Effectively dead.** Last commit 2022; users report it broken on current phones |

---

## What users actually ask for

Mined from Play reviews, XDA and ISPreview forums. Reddit blocked direct fetching,
so these lean on what search surfaced.

- **CellMapper:** tower positions wildly wrong, sign-in hidden under the
  keyboard, CAPTCHAs behind a VPN, uploads silently failing.
- **NetMonster:** ads introduced without a changelog, "open source" branding
  outrunning the public repository, 5G carrier aggregation not recognised.
- **LTE Discovery:** local log silently stops at 1,000 records; a 2026 overhaul
  that removed features paying users relied on.
- **NSG:** the deepest forum trail, because root-level features break on OS and
  root-tool updates. Band lock lost after Android 9; a "Clear Forcings" option that
  loses bands on reboot; fails under KernelSU unless root is toggled off.

**The negative finding worth keeping:** nobody in these review corpora asks for
"pcap" or "Wireshark" by name. Demand for depth shows up as requests for band
locking, better 5G and carrier-aggregation visibility, and CSV export. The
audience that wants Wireshark-grade decode is real but narrower than the
review-writing population of these apps, and should be validated directly with
target users rather than assumed from reviews.

---

## Distribution in 2026

- **Google Play:** $25 once; identity verification required for all new
  accounts; organisations need a D-U-N-S number, which can take about 28 days.
- **Developer verification.** Opened to all developers March 2026. The first
  enforcement, **30 September 2026**, covers installs from seven participating
  stores in Brazil, Indonesia, Singapore and Thailand only. **A direct APK from
  your own website is not covered** by that phase; Google intends a global rollout
  in 2027.
- **But friction is already live.** Since August 2026 an app from an unverified
  developer takes the user through an advanced flow with a **one-time 24-hour
  wait**. Not a block, but not a one-tap install.
- **Register early.** Package-name conflicts go to whichever verified developer
  has more installs. A free limited-distribution account covers up to 20 devices
  without government ID, which suits a pilot.
- **F-Droid** requires fully free software and holds about 4,500 apps. Not a
  channel for a commercial product.
- **Managed Google Play** private apps suit the real buyer, an operator or
  integrator with an enrolled fleet, and sidestep most of the above.

---

## iOS

No live measurements, but a modem trace after the fact. The earlier verdict here, that iOS is not viable for
this category outside an enterprise build, is superseded: with Apple's own Baseband logging profile a stock
iPhone's sysdiagnose carries the modem's Qualcomm DIAG trace, and FieldTap rebuilds it into a `.qmdl` and
decodes its RRC and NAS. See [`iphone-baseband-capture.md`](iphone-baseband-capture.md). What still holds for
a live app:

- Field Test Mode (`*3001#12345#*`) still works, but it is a manual screen with no
  interface, no logging and no export.
- There is no public API for RSRP, RSRQ, PCI or cell identity. App Store
  "signal" apps are speed tests or estimates.
- Jailbreak routes cover only A8 to A11 chips, which is pre-2018 hardware.
- Beware name-squatting: an App Store listing named CellMapper, not from the real
  developer, charges up to $7.99 a week. The official CellMapper iOS app is barely
  launched and shows only a map, citing Apple's restrictions.

---

## Sources

- LTE Discovery — https://play.google.com/store/apps/details?id=net.simplyadvanced.ltediscovery
- NetMonster — https://play.google.com/store/apps/details?id=cz.mroczis.netmonster ; https://github.com/mroczis/netmonster-core
- Network Cell Info — https://play.google.com/store/apps/details?id=com.wilysis.cellinfolite
- CellMapper — https://play.google.com/store/apps/details?id=cellmapper.net.cellmapper ; https://www.cellmapper.net/subscribe ; https://www.ispreview.co.uk/talk/threads/cellmapper-accuracy.37507/
- G-NetTrack — https://gyokovsolutions.com/g-nettrack/
- SignalCheck — https://play.google.com/store/apps/details?id=com.blueline.signalcheck
- Network Signal Guru — https://play.google.com/store/apps/details?id=com.qtrun.QuickTest ; https://xdaforums.com/t/network-signal-guru.4005511/
- RantCell — https://rantcell.com/FAQ.html ; https://rantcell.com/corporate-plan.html
- HiCellTek — https://hicelltek.com/en/pricing/ ; https://hicelltek.com/en/product/
- MobileInsight status — https://jisis.org/wp-content/uploads/2026/03/2026.I1.034.pdf ; https://github.com/mobile-insight/mobileinsight-core
- SnoopSnitch — https://f-droid.org/en/packages/de.srlabs.snoopsnitch/
- Nemo Handy — https://www.keysight.com/us/en/assets/7018-05575/flyers/5992-2050.pdf
- Ookla and Accenture — https://newsroom.accenture.com/news/2026/accenture-to-acquire-ookla-to-strengthen-network-intelligence-and-experience-with-data-and-ai-for-enterprises ; https://www.sec.gov/Archives/edgar/data/1084048/000108404825000007/zd-20241231.htm
- Opensignal and Tutela — https://www.rcrwireless.com/20190909/big-data-analytics/tutela-acquired-by-comlinkdata ; https://www.telecompaper.com/news/opensignal-acquired-by-tutela-owner-comlinkdata--1397184
- Developer verification — https://developer.android.com/developer-verification/guides/faq ; https://android-developers.googleblog.com/2026/03/android-developer-verification-rolling-out-to-all-developers.html
- F-Droid — https://f-droid.org/en/docs/Inclusion_Policy/ ; https://gitlab.com/fdroid/admin/-/issues/599
- iOS — https://developer.apple.com/forums/thread/751785 ; https://github.com/palera1n/palera1n ; https://www.cellmapper.net/apps ; the sysdiagnose route and its sources: [`iphone-baseband-capture.md`](iphone-baseband-capture.md)

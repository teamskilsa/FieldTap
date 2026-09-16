# Qualcomm DIAG access on the OnePlus 10 Pro (NE2215) — research findings

**Date:** 2026-09-10
**Device under test:** OnePlus 10 Pro, model NE2215, `ro.product.device=OP516FL1`, SM8450 (`ro.board.platform=taro`), Android 15 / OxygenOS, bootloader unlocked (`orange`), rooted with Magisk (`u:r:magisk:s0`), SELinux Enforcing.
**Live finding on device:** `/dev/diag` absent (ENOENT as root), no `/sys/class/diag*`, `grep -c diagchar /proc/devices` = 0.

> **Superseded on 2026-09-14. The conclusion below is wrong.**
>
> This page concludes the OnePlus 10 Pro cannot do diag capture. Diag was
> captured from this exact handset on 2026-09-14, and decoded: SIB1, SIB2-5,
> SIB24 and two Paging records out of `0xB0C0`.
>
> Everything this page establishes about the *kernel* still holds. `/dev/diag`
> really is absent, `diagchar` really is in no OxygenOS branch for this model,
> and no Magisk module can conjure it back. The error is the inference drawn
> from that: the page assumes `/dev/diag` and the diag USB interface are two
> front ends onto one `diagchar` driver, so that killing the driver kills both.
> On `taro` that is no longer true. Qualcomm moved diag into userspace --
> `/vendor/bin/diag-router`, reaching the modem over QRTR and reaching USB over
> FunctionFS -- and it runs on a stock phone. The backend was alive the whole
> time; only a USB composition exposing it was missing, and root sets that.
>
> The corrected account, with what was run and what it returned, is in
> [`../DEVICE-SETUP.md`](../DEVICE-SETUP.md). Keep this page for its kernel-source
> work, not for its verdict.

## Methodology and confidence key

This report combines three kinds of evidence, marked inline:

- **[PRIMARY — verified by this research]**: I directly fetched and read OnePlus's own published kernel source for the OnePlus 10 Pro (via the GitHub API / raw file contents) and read the relevant driver source code myself. This is the strongest evidence in this report.
- **[COMMUNITY — verified]**: content from GitHub issues, wikis, or forum threads that I was able to fetch and read in full.
- **[COMMUNITY — title/snippet only]**: forum/XDA threads that search results surfaced and whose titles/snippets are informative, but whose full content I could **not** fetch (XDA Forums and the OnePlus community site returned HTTP 403 to automated fetches in this session). These are cited but flagged as unverified in detail.
- **[VENDOR]**: content from hicelltek.com, which is itself a commercial diag-capture product vendor. Their general technical claims are plausible and consistent with other sources, but treat specific device-support claims from them with the same skepticism you'd apply to any vendor's own marketing/support copy.
- **[REASONED]**: my own inference from reading source code or from well-established OS semantics, not a single external claim. Flagged so you know it's analysis, not a citation.

---

## 1. Is diagchar/DIAG genuinely removed from recent OnePlus/OPPO builds on SM8450 and relatives?

**Short answer: yes, with high confidence for the OnePlus 10 Pro specifically, and the pattern generalizes across the current OnePlus lineup.**

### Direct evidence for the OnePlus 10 Pro (this exact device)

**[PRIMARY — verified by this research]** OnePlus publishes GPL-obligated kernel source for the 10 Pro at two public GitHub repos:
- `OnePlusOSS/android_kernel_oneplus_sm8450` (the GKI kernel proper)
- `OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8450` (out-of-tree vendor modules + devicetree)

I pulled the full recursive file tree (via `git/trees?recursive=1` on the GitHub REST API) for **every branch OnePlus has published for the 10 Pro**, and grepped for anything diag-related:

| Branch | OS version | `drivers/char/diag` / `diagchar.c` present? |
|---|---|---|
| `oneplus/sm8450_s_12.1_10_pro` | OxygenOS 12.1 / Android 12 | **No** |
| `oneplus/sm8450_t_13.0_10pro` | OxygenOS 13.0 / Android 13 | **No** |
| `oneplus/sm8450_t_13.1.0_10pro` | OxygenOS 13.1 / Android 13 | **No** |
| `oneplus/sm8450_u_14.0.0_oneplus_10pro` | OxygenOS 14 / Android 14 | **No** |
| `oneplus/sm8450_v_15.0.0_oneplus_10_pro` | OxygenOS 15 / **Android 15** (matches this device) | **No** |

Across all five branches, the only "diag" hits in tens of thousands of files are unrelated kernel subsystems that happen to share the string (`net/*/diag.c` socket-diag, s390 hypervisor diag, SCSI/Intel NIC "diag" self-test code, and `drivers/usb/gadget/function/f_diag.c` — see §2). There is no `drivers/char/diag/` directory, no `diagchar.c`, `diagchar.h`, `diagchar_core.c`, `diagfwd*.c`, and no `CONFIG_DIAG_CHAR` / `CONFIG_DIAGFWD_BRIDGE_CODE` anywhere in any defconfig or `.config` fragment in any of these branches, including the Android-15 branch (`sm8450_v_15.0.0_oneplus_10_pro`) that corresponds to the OS version this device is running.

This means the driver's **source code itself is absent from OnePlus's published tree, not merely disabled by a Kconfig flag** — you cannot `make menuconfig` your way back to it; the files to enable don't exist in what OnePlus ships. This is consistent with, and directly explains, the live finding (`grep -c diagchar /proc/devices` = 0): there is nothing to register that character device.

- Repo: https://github.com/OnePlusOSS/android_kernel_oneplus_sm8450
- Repo: https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8450

### Corroborating community reports (OnePlus, other SM8xxx generations)

**[COMMUNITY — verified]** QCSuper (a widely used open-source Qualcomm DIAG capture tool) has an open issue titled **"dev/diag not exist on oneplus 12"** (opened Dec 2024, unresolved) — the OnePlus 12 uses SM8650 (Gen 3), not SM8450, but it shows the same OEM policy persists across chipset generations, not just SM8450:
https://github.com/P1sec/QCSuper/issues/133

**[COMMUNITY — verified]** QCSuper's own README states the general rule this device falls under:

> "On Qualcomm/MSM Android-based devices bearing Linux kernel 4.14 or later (this includes roughly part of devices from Android 10 and all devices from Android 13), `/dev/diag` disappeared, as the corresponding `diagchar` module is disabled by default [in] recent AOSP/Linux kernels."

https://github.com/P1sec/QCSuper/blob/master/README.md

**[COMMUNITY — verified]** The SCAT project (another maintained Qualcomm/Samsung diag capture tool) keeps a device-support wiki. It lists many confirmed-working Samsung and Xiaomi devices but **zero OnePlus or OPPO devices** in its tested/working list — only a single Sony entry outside Samsung/Xiaomi:
https://github.com/fgsect/scat/wiki/Devices

**[COMMUNITY — title/snippet only, not independently fetched]** Multiple threads point the same direction but I could not retrieve full content (403s from xdaforums.com and community.oneplus.com to automated fetches in this session — treat as corroborating titles, not verified quotes):
- OnePlus forum request thread, title implies `/dev/diag` is absent and users are asking for it back: https://forums.oneplus.com/threads/request-dev-diag-support-on-oxygenos.317480/
- "Diagnostics missing in android 12" (OnePlus community): https://community.oneplus.com/threads/diagnostics-missing-in-android-12.1543326/
- "Oxygen OS 12 engineer mode broken?" (XDA): https://xdaforums.com/t/oxygen-os-12-engineer-mode-broken.4380973/
- "How to open diag port and unlock Engineering mode for Android 12 OOS root device only" (XDA) — title implies a workaround exists for Android 12-era OOS, i.e. implying it stopped working normally around then: https://xdaforums.com/t/how-to-open-diag-port-and-unlock-engineering-mode-for-android-12-oos-root-device-only.4533121/
- "Where to find drivers for diag mode on oneplus 11?" (XDA), and OnePlus 8 Pro DIAG-init failures reported even on LineageOS 18.1/Android 11 (`/dev/diag` present but DIAG "could not initialize"), show this has been a recurring, multi-generation OnePlus problem, not unique to the 10 Pro or to stock firmware: https://xdaforums.com/t/where-to-find-drivers-for-diag-mode-on-oneplus-11.4706051/ , https://github.com/srlabs/snoopsnitch/issues/7
- "How to enable diag mode on OnePlus 9pro coloros 12" — the thread title itself uses "ColorOS 12" for a OnePlus device, which is a good marker of the OxygenOS/ColorOS shared-codebase transition you asked about: https://community.oneplus.com/thread/1551510

### Was it ever present on this codebase?

I could not find a confirmed report of a stock, shipped-from-factory OnePlus build (post OxygenOS-12/ColorOS-merge) with a genuinely working `/dev/diag`. The earliest branch OnePlus publishes for the 10 Pro (OxygenOS 12.1, mid-2022, already past the ColorOS merge) **already lacks the driver source**, so on the balance of evidence it was likely never present on this model's shipped kernel, not just "removed later." I could not verify whether an internal/engineering (non-retail) OnePlus build ever had it — no evidence found either way; **unverified**.

### OPPO Find X5 / Realme GT2 Pro (same SM8450 platform, different OEM skin)

I found **no concrete, specific reports** (positive or negative) for `/dev/diag` on the OPPO Find X5 or Realme GT2 Pro specifically. Given they share the SM8450 "taro" platform and, per the OnePlus/OPPO codebase unification reporting below, an increasingly common ColorOS-derived software base, the same outcome is a reasonable inference but is **unverified** for these exact models.

**[COMMUNITY — verified]** Background on the codebase merger itself: OnePlus and OPPO unified the OxygenOS/ColorOS codebase starting with OxygenOS 12 (2021-2022), for engineering efficiency — the UIs remain distinct but the underlying platform code is shared: https://www.androidpolice.com/oneplus-calls-off-merger-between-oxygenos-and-coloros-but-theyll-still-share-a-codebase/

---

## 2. Does /dev/diag appear only when the diag USB function is enabled? Are the char device and the USB interface independent?

**Short answer: No, they are not independent. Both are front-ends served by the same back-end driver (diagchar / the "diag router"), and `/dev/diag` is created at kernel/module init time (boot), not lazily when the USB gadget "diag" function is selected via `sys.usb.config`. On a kernel where diagchar never initializes (this device), toggling `sys.usb.config` should not be expected to produce a functioning DIAG interface, over USB or otherwise — though see the caveat at the end of this section, because this specific device has not been empirically tested with the setprop yet.**

This is the most important question in the brief, so here is the evidence chain in full.

### How /dev/diag is actually created (historical Qualcomm source, read directly)

**[PRIMARY — verified by this research]** I fetched the historical Qualcomm/CodeAurora `diagchar_core.c` (from an older, pre-GKI `kernel/msm` tree, Android 9 branch, back when this driver was still open-source and in-tree) and read the init path directly:

```
driver->diagchar_class = class_create(THIS_MODULE, "diag");
driver->diag_dev = device_create(driver->diagchar_class, NULL, devno, ...);
...
module_init(diagchar_init);
```
https://android.googlesource.com/kernel/msm.git/+/android-9.0.0_r0.31/drivers/char/diag/diagchar_core.c

`device_create()` is called from `diagchar_init()`, which is registered via `module_init()` — i.e. **the character device node is created once, at kernel boot / module load, unconditionally**. It has nothing to do with USB gadget composition. This matches how essentially every Linux misc/char driver creates its device node.

### How the USB side works, and why it depends on the same driver

**[PRIMARY — verified by this research]** `drivers/usb/gadget/function/f_diag.c` **is** present in OnePlus's published 10 Pro kernel source, in every branch I checked (Android 12 through 15). I read the full file. It implements the raw USB gadget "diag" function (the class FF/FF/0x30 USB interface QXDM/QPST look for) and exposes this API for a caller to use:

```
struct usb_diag_ch *usb_diag_open(const char *name, void *priv,
        void (*notify)(void *, unsigned int, struct diag_request *));
EXPORT_SYMBOL(usb_diag_open);
...
EXPORT_SYMBOL(usb_diag_close);
EXPORT_SYMBOL(usb_diag_read);
EXPORT_SYMBOL(usb_diag_write);
```
https://github.com/OnePlusOSS/android_kernel_oneplus_sm8450/blob/oneplus/sm8450_v_15.0.0_oneplus_10_pro/drivers/usb/gadget/function/f_diag.c

**[REASONED]** `f_diag.c` is a *transport*, not a protocol implementation — it moves bytes over a USB bulk endpoint, but it has no idea what DIAG/QXDM protocol framing means. It sits idle until some other kernel client calls `usb_diag_open("diag", ...)` to register itself as the owner of a channel named `"diag"`. Historically, that caller **is** the diagchar/diag-router driver: on driver init, diagchar both creates `/dev/diag` for local (on-device) clients like `diag_mdlog`, *and* calls `usb_diag_open()` to bind the same internal data router to the USB gadget function, so that a PC-side tool (QXDM/QPST/QCSuper) gets the identical DIAG stream over USB. In other words: **one back-end (diagchar), two front doors** — a local chardev door and a USB door — not two independent doors.

Given that:
- `f_diag.c` (the USB transport) is still compiled into OnePlus's kernel source, but
- `diagchar`/the diag router (the only known caller of `usb_diag_open()`, and the only thing that creates `/dev/diag`) is **entirely absent** from the same source tree (§1), and
- `/proc/devices` on the live device confirms diagchar never registered,

**[REASONED]** setting `sys.usb.config` to include `diag` (e.g. `diag,adb` or the longer OnePlus composition `diag,diag_mdm,qdss,qdss_mdm,serial_cdev,dpl,rmnet,adb`) should, at best, only be able to instantiate an *empty* `f_diag` gadget function via configfs/legacy composition — with nothing registered as its channel owner, there is no DIAG protocol traffic to carry, and depending on how OnePlus's userspace `init.*.usb.rc` / configfs helper scripts gate the "diag" function string (some OEM composition scripts check for the diag service/node before even offering the option), the function may simply fail to bind at all. Either way, a working PC-side DIAG interface over USB is very unlikely to appear.

**Caveat / what's still unverified:** I have not empirically tested `setprop sys.usb.config diag,adb` (or the OnePlus long-form composition) *on this exact device* and watched `dmesg`/`lsusb` on a host PC. This is architecturally very unlikely to work given the evidence above, but it is a cheap, safe, non-destructive test and is the natural next empirical step (see the summary at the end of this document). **[COMMUNITY — corroborating, unverified in detail]**: general troubleshooting threads describe exactly this failure mode on kernel-4.14+/Android 13+ devices — `setprop sys.usb.config diag,adb` runs without error but no `/dev/diag` and no diag USB device appear, consistent with the analysis above.

---

## 3. Known ways to restore DIAG on a device like this

### Magisk modules

**[COMMUNITY — searched, weak result]** I could not find a currently-maintained, widely-used Magisk module specifically named for "enabling diag" on modern (GKI/kernel≥4.14) Qualcomm devices. What exists in this space (e.g. `evdenis/enable_eng` — a module that flips engineering build props) operates at the Android property/userspace level, not the kernel level: https://github.com/evdenis/enable_eng

Most "enable diag" guides found (hovatek, droidwin, getdroidtips, XDA) are not Magisk *modules* at all — they are just instructions to open a rooted `adb shell`/terminal (which Magisk provides root for) and run `setprop sys.usb.config diag,adb` or similar. Representative examples of the composition strings used across guides/OEMs: `diag,adb`; `diag,diag_mdm,adb`; `diag,serial_smd,rmnet_bam,adb`; `diag,serial_cdev,rmnet,dpl,qdss,adb`. https://www.hovatek.com/forum/thread-22399.html , https://droidwin.com/how-to-boot-qualcomm-device-to-diag-mode-via-adb-commands/

**[REASONED]** This is a fundamental limitation, not a tooling gap: Magisk operates as a root/overlay/SELinux-policy tool in userspace. It cannot create a missing kernel character device or resurrect a kernel driver whose source was never compiled in. No Magisk module can fix this specific device's symptom by itself. The only way a Magisk module *could* help is if it shipped a working, ABI-compatible `diagchar.ko` to `insmod`, which leads into the custom-kernel question below — I found **no evidence** anyone has published such a module for SM8450/taro.

### Custom kernels for OnePlus 10 Pro / SM8450

**[COMMUNITY — searched]** I could not find an existing, published custom kernel for the OnePlus 10 Pro that reintroduces `diagchar`/DIAG_CHAR. Community kernel-source mirrors exist (e.g. `tangalbert919/android_kernel_oneplus_sm8450`), and XDA has an active "sm8450 A13 Kernel Source Compile Issues" thread, but none of the material found mentions restoring the diag driver — discussion is about general bring-up/build issues: https://github.com/tangalbert919/android_kernel_oneplus_sm8450 , https://xdaforums.com/t/sm8450-a13-kernel-source-compile-issues.4475027/

**[REASONED]** Because the driver's source isn't in-tree at all (§1), "enabling" it isn't a defconfig checkbox — someone would have to **port/backport** `drivers/char/diag/*` from an older, compatible Qualcomm msm-kernel branch (e.g. a 4.19-era CodeAurora tree) forward into the current 5.10/5.15-based GKI kernel, including its shared-memory/SMD/QMI hooks into the modem, which have changed across kernel generations. This is a nontrivial kernel-development project, not a quick patch, and I found no evidence anyone has done it for this platform. Bootloader being unlocked makes this *possible* in principle (see §4), but "possible" and "already done by someone else" are different claims — the second is, as far as I can find, **not true yet** for this device.

### Engineering/dialer modes: `*#800#`, `*#801#`, `*#808#`, `*#8011#`

**[COMMUNITY — verified pattern across multiple sources, details unverified per-code]** OnePlus historically shipped a Qualcomm-derived "EngineerMode" diagnostic app (package `com.oneplus.engineermode`, later renamed `com.oneplus.factorymode`) reachable via these codes. In November 2017, NowSecure/security researchers disclosed this app shipped with a debuggable, insufficiently-restricted command interface reachable from any app — a real backdoor (tracked as a notable OnePlus security incident) — which is very likely *why* OnePlus has progressively locked this down since: https://www.nowsecure.com/blog/2017/11/14/oneplus-device-root-exploit-backdoor-engineermode-app-diagnostics-mode/

By OxygenOS 12+ (the ColorOS-merged codebase), multiple community reports say these codes are broken/removed for most users, with root-only workarounds circulating (e.g. editing `mnt/vendor/persist/engineermode/engineermode_config`, flipping `encrypt_app`/`encrypt_adb` to `false`, then rebooting) — **[COMMUNITY — title/snippet only]**: https://xdaforums.com/t/how-to-open-diag-port-and-unlock-engineering-mode-for-android-12-oos-root-device-only.4533121/ , https://droidwin.com/how-to-enable-diag-mode-in-oneplus-when-801-is-not-working/

**[REASONED — important distinction]** There is a real risk of conflating two different things in this space:
1. OnePlus's own **EngineerMode/FactoryMode app** — a hardware self-test tool (battery, sensors, display) that also happens to expose a USB-composition selector.
2. The **Qualcomm DIAG/QXDM protocol interface** (what QCSuper/QXDM/SCAT actually need).

Multiple droidwin/XDA guides describe using the engineering menu specifically to flip the USB composite mode to include "diag" — but per §2, on a kernel where diagchar was never compiled in, flipping that switch has no back-end driver to bind to. So even where the dialer codes still work (which itself is inconsistent across OxygenOS versions per the sources above), there is no reason to expect them to restore genuine DIAG capture on this kernel — they can at most toggle the same `sys.usb.config` property discussed in §2. **This has not been empirically tested on this exact device/build** — flagged as a candidate next step, low priority given the architectural analysis.

### OnePlus/OPPO's own logging tools (`diag_mdlog`, OEM "log kit", feedback tool)

**[VENDOR — hicelltek.com]** Per hicelltek's technical writeup, the standard `diag_mdlog` binary (which produces `.qmdl` files, a QXDM/QCAT-compatible format) "runs in the vendor SELinux domain with pre-granted access" and depends on the DIAG interface being enabled: https://hicelltek.com/en/blog/qmdl-qualcomm-diagnostic-log-format-field-guide/

**[REASONED]** `diag_mdlog` is itself a *userspace client* of `/dev/diag` (or the diag socket router in some Qualcomm architectures) — it has the identical dependency problem as any other DIAG tool. If `diagchar` never initialized on this device, `diag_mdlog` (if present at all in `/vendor/bin`) should fail the same way. **This device has not been checked for the presence/behavior of a `diag_mdlog` binary or an OEM-specific "OPLUS log"/feedback cellular-log tool** — worth a quick `find /vendor /system -iname '*diag*' -o -iname '*mdlog*'` as a cheap diagnostic, because if OnePlus ships a *different*, non-diagchar logging path for its own internal telemetry, that would be a genuinely new lead. No evidence either way was found in this research; **unverified, recommended as a concrete next step**.

### Could SELinux Enforcing alone explain the missing node?

**[REASONED, high confidence]** No. SELinux (as implemented via the Linux Security Module hooks) mediates *operations* — open, read, write, connect, etc. — on objects that already exist in the kernel's namespaces. It does not remove directory entries from `readdir()`/`lstat()` results, and it doesn't cause `stat()`/`open()` on an *existing* path to return `ENOENT`. If `/dev/diag` existed as a device node but SELinux denied access to it, the expected failure mode as root would be the entry still appearing in `ls -lZ /dev` (with its security context shown), and an `open()` attempt failing with `EACCES`/"Permission denied" — not the directory entry vanishing and `ls` reporting "No such file or directory." Background: https://source.android.com/docs/security/features/selinux

Combined with the fact that `su -c id` on this device returns `uid=0(root) context=u:r:magisk:s0` (Magisk's root domain, which is specifically designed to have broad DAC/MAC latitude for the interactive root shell), an SELinux-hidden-but-present node is implausible here. The `ENOENT` result plus `grep -c diagchar /proc/devices` = 0 together are strong, mutually-reinforcing evidence that **the device node genuinely does not exist because the driver never registered it** — not that it exists but is hidden.

### Does `setenforce 0` change anything?

**[REASONED, high confidence]** No. Per the above, SELinux isn't gating this symptom — the character device driver itself is absent from the running kernel, and no MAC policy, permissive or otherwise, can conjure a missing device node into existence. Expect `setenforce 0` to have zero effect on `/dev/diag`'s presence. (Separately, note many production OnePlus kernels resist `setenforce 0` taking effect at all on locked-down builds, though this device is already rooted via Magisk which typically can manage this — that's a secondary, unrelated point.)

---

## 4. DIAG access paths that don't need `/dev/diag`

### QMI (a different Qualcomm protocol, not a DIAG substitute)

**[COMMUNITY — verified, general kernel documentation]** QMI (Qualcomm MSM Interface) is a separate protocol from DIAG, normally exposed via `/dev/cdc-wdmX` on Linux hosts talking to external USB modems, handled in-kernel by the `qmi_wwan` driver: https://cateee.net/lkddb/web-lkddb/USB_NET_QMI_WWAN.html

**[REASONED]** QMI is what Android's own RIL/telephony stack, and apps like CellMapper / Network Signal Guru, use for *some* signal/serving-cell data (RSRP, band, cell ID) without needing DIAG at all — that's a real, independent path, but it is materially less capable than DIAG: it does not give you raw RRC/NAS message-level decode, which is what a drive-test/protocol-analysis product typically needs DIAG for. It is not a substitute for DIAG capture, only a partial alternative for coarse signal metrics.

### Qualcomm's own host-side DIAG/QDSS USB drivers (`quic-usb-drivers`)

**[PRIMARY — verified by this research, but scope-limited]** I read Qualcomm's own `quic-usb-drivers` repo. It ships four **host-PC-side** (Linux/Ubuntu/RedHat) drivers — GobiSerial, InfParser, QdssDiag, Rmnet — that let a PC talk to a Qualcomm device's DIAG/QDSS USB endpoints for firmware download, crash-dump collection, and diag/QDSS logging: https://github.com/quic/quic-usb-drivers

**[REASONED]** This is not a bypass for a phone like the 10 Pro. It's the PC-side counterpart to the exact same USB DIAG interface discussed in §2 — useful for external USB modems/M.2 cards or a phone in EDL/download mode where the modem enumerates its own independent USB descriptor set, but on an integrated-SoC smartphone like the 10 Pro, that same interface is still routed through the AP's own `diagchar`+`f_diag` chain when the phone is running normal Android. Since that chain is absent here, this driver package gives you nothing extra on this device in its current state.

### Diag over a local socket

I found **no documented, current, socket-based DIAG path for smartphone SoCs analogous to /dev/diag** (as distinct from external modem cards, which sometimes use different framing). **Unverified / not found** — flagged rather than asserted.

### Booting a different kernel/boot image — realistically, is this "the" answer?

**[REASONED]** Given the bootloader is unlocked (`orange`), this is the architecturally correct lever: you can flash a modified `boot.img`/`vendor_boot.img`. But the practical cost is real and, per the research above, nobody appears to have already paid it for this exact device:

1. **Engineering cost**: Since `diagchar` source isn't in OnePlus's tree at all (§1), "enabling" it means porting the driver forward from an older, compatible Qualcomm source tree — not flipping a Kconfig bit. This touches SMD/QMI/shared-memory internals that differ across kernel generations, so it's a genuine kernel-development effort (realistically days-to-weeks for someone experienced with Qualcomm BSPs), not a quick recompile.
2. **Stability risk**: The diag router hooks into the same modem interface (shared memory/QMI) that carries live RIL/data traffic. A hand-ported driver could destabilize cellular function, which would be actively counterproductive for a drive-test tool.
3. **Verification (AVB) and OTA**: An unlocked bootloader lets you flash unsigned images, but Magisk-based root already depends on careful boot-image patching; a from-scratch kernel changes that workflow, and any OTA will very likely overwrite a custom kernel, requiring re-patching after every update.
4. **No known existing artifact**: I found no evidence of a published, working diag-enabled kernel for the OnePlus 10 Pro / SM8450-taro. This would be a from-scratch project for your team, not a "download and flash" fix.

---

## 5. Practical recommendation

**Is the OnePlus 10 Pro on stock Android 15 a dead end for diag capture?**

Functionally, yes, for a near-term product timeline. The live diagnostic finding is corroborated by direct inspection of OnePlus's own published kernel source across all five branches they've shipped for this model (Android 12 through 15) — the `diagchar` driver's source is not present anywhere in that lineage, so this isn't a config flag you can flip or a Magisk module away; it would require a from-scratch kernel driver port with no existing prior art found for this model. Treat the OnePlus 10 Pro as **not viable for `/dev/diag`-based capture** without a dedicated (and nontrivial) kernel-engineering effort your team would be first to attempt for this device, as far as this research can tell.

**Known-good alternatives for 2025–2026, roughly ranked by practicality:**

1. **Samsung Galaxy S22/S23/S24, Snapdragon SKUs only (not Exynos/Europe units)** — best-documented, lowest-friction option found. `*#0808#` opens a native USB-mode selector that exposes DIAG **without root or bootloader unlock**, verified across many independent, long-standing community sources (not just one vendor): Samsung's own developer forum (https://forum.developer.samsung.com/t/secret-code-0808/12599), and corroborated by the SCAT project's own device-support wiki listing Samsung Galaxy S4-through-S23 Qualcomm models as working without root (https://github.com/fgsect/scat/wiki/Devices). Caveats: must confirm the specific unit is the Snapdragon SKU (check Settings → About phone → Processor), and the USB composition can reset after an OTA, requiring the code to be re-entered.
2. **Xiaomi/Redmi/POCO Snapdragon devices** — multiple independently-written, currently-active community guides for enabling `diag,diag_mdm` via root+`setprop` (e.g. a detailed, actively-discussed 2024/2025 XDA guide tested on the POCO F3): https://xdaforums.com/t/guide-how-to-enable-qualcomm-mdm-diag-mode-and-backup-and-restore-qcn-tested-on-poco-f3.4760023/ . Requires root; Xiaomi's hardening trajectory on its very newest 2025/2026 HyperOS flagships is **not verified** in this research and should be spot-checked per model before committing.
3. **Older Qualcomm Pixels (5, 5a)** — historically workable per XDA guides, but these are the last Qualcomm-modem Pixels (all newer Pixels use Tensor with no Qualcomm baseband at all, making the entire Pixel line a dead end for DIAG going forward), the specific models are aging out of availability, and enabling diag reportedly required userdebug-style builds with Play Integrity/warranty tradeoffs. Not recommended for a forward-looking product.

**Which OnePlus models still ship diagchar?** I found **no evidence any current OnePlus model does**. The pattern held across every OnePlus 10 Pro branch checked directly, and community reports place the same symptom on the OnePlus 8 Pro (even on LineageOS/Android 11), 9 Pro, 11, and 12 — spanning SM8250 through SM8650, i.e. this looks like an OEM-wide policy rather than a single-chipset quirk. Do not expect a newer or older OnePlus model to behave differently without first finding a specific, current report to the contrary.

**One more real-world path worth naming:** commercial drive-test vendors (e.g. Infovista TEMS Pocket/Paragon) don't rely on rooting retail phones at all — their datasheet describes direct agreements with handset makers (explicitly including Samsung, OnePlus, Xiaomi, Sony, Asus) and chipset vendors (Qualcomm, Samsung, Huawei) to get engineering-mode devices and firmware: https://www.infovista.com/products/tems-pocket/portable-mobile-network-testing . If this product is commercial, opening a channel with Qualcomm or OEMs for legitimate engineering firmware is a parallel path worth considering alongside picking a community-documented handset.

---

## Summary of what to try next, in order

1. **Cheap and immediate (on this exact device):** as root, try `setprop sys.usb.config diag,adb` (and separately the longer OnePlus composition `diag,diag_mdm,qdss,qdss_mdm,serial_cdev,dpl,rmnet,adb`), then re-check `ls -lZ /dev/diag`, `grep diagchar /proc/devices`, and watch `dmesg`/host-side `lsusb`/Device Manager. Architecturally this is very unlikely to produce a working interface (§2), but it's a five-minute test that closes the loop empirically rather than by inference alone.
2. **Cheap and immediate:** search this device for OEM diag tooling: `find /vendor /system -iname '*diag*' -o -iname '*mdlog*' -o -iname '*qmdl*'` — if OnePlus ships any working cellular-log capture path for its own telemetry, that's a new, unexplored lead (§3).
3. **If both of the above come back empty (expected):** stop investing further effort in this specific handset for `/dev/diag`-based capture. Acquire a Samsung Galaxy S22/S23/S24 **Snapdragon SKU** as the known-good reference device — it needs no root and has the best-corroborated, longest-standing community track record found in this research.
4. **Longer-term, only if OnePlus support is a hard product requirement:** budget a genuine kernel-engineering effort (porting `drivers/char/diag` forward into the current GKI kernel) or pursue a formal OEM/Qualcomm engineering-firmware relationship — do not expect to find an existing published fix to download.

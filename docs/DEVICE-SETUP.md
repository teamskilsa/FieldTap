# Getting a handset ready

> **On a Mac?** Read [`MACOS.md`](MACOS.md) instead. macOS needs no driver at all, so most
> of the Windows setup below does not apply, and a Mac is often the easier host.

The goal is that an engineer plugs a phone into the laptop and `fieldtap auto`
does the rest. That only works once the phone exposes its Qualcomm diag port
and Windows has a driver for it. This page is the one-time preparation per
handset model.

The detail behind every claim here, with sources, is in
[`research/windows-diag-and-device-control.md`](research/windows-diag-and-device-control.md).
Where that research could not confirm something it says so, and so does this page.

---

## 1. The laptop

Run the checker first. It reports what is missing and can fetch adb for you:

```bash
fieldtap setup --install-adb
```

| Needed | Why | Where |
| --- | --- | --- |
| Wireshark 4.0+ | It is the decoder. Without it there are no KPIs and no live view. | https://www.wireshark.org/download.html |
| adb (platform-tools) | Handset identity, diag enablement, GPS, traffic tests. | `fieldtap setup --install-adb` |
| Qualcomm USB serial driver | Makes the diag interface appear as a COM port. | Ships inside most OEM driver packages; see below |
| Python 3.9+ with `pyserial` | Reads the COM port. | `pip install -e ".[all]"` |

**The diag COM port** appears as *Qualcomm HS-USB Diagnostics 9091* (hardware ID
`USB\VID_05C6&PID_9091&MI_00`, sometimes PID `901D`). Do not match on the PID:
it changes between firmware builds and USB compositions. The reliable signature
is the USB interface descriptor **class `FF`, subclass `FF`, protocol `0x30`**,
which is what FieldTap matches on.

If no driver is available, bind **WinUSB** to that interface with
[Zadig](https://zadig.akeo.ie/) and capture with `--usb` instead of a COM port.

> **Several phones at once.** Windows gives each phone its own COM port, and the
> port carries the phone's USB serial number, which equals `ro.serialno` and the
> adb serial. FieldTap uses that to tie each COM port to the right handset, so a
> multi-phone campaign does not mix sessions up. When a phone does not expose a
> serial and more than one is attached, FieldTap refuses to guess and treats
> them as separate unnamed handsets rather than pairing them wrongly.

---

## 2. The phone

### What is required

* **A Qualcomm (Snapdragon) modem.** Exynos and MediaTek phones do not speak
  this protocol. A Galaxy S24 may be either, depending on region.
* **Root**, in almost all cases, to switch the USB composition and to read
  `/dev/diag`.
* **USB debugging** on, and this computer authorised (accept the RSA prompt).

### Enabling diag

FieldTap tries this for you at the start of a capture. It runs, as root:

```bash
setprop sys.usb.config diag,diag_mdm,qdss,qdss_mdm,serial_cdev,dpl,rmnet,adb
```

falling back to shorter compositions. The long form above is what current
OnePlus, OPPO and Realme builds expect; a shorter string is silently ignored on
some of them. Use `persist.sys.usb.config` instead to make it survive a reboot.

Changing the composition re-enumerates USB, so adb disconnects and returns after
a few seconds. FieldTap waits for the new port rather than failing.

`fieldtap disable-diag` puts the phone back to `mtp,adb` when you are done.

### Non-root paths, where they exist

| Vendor | Code | Notes |
| --- | --- | --- |
| Samsung (Snapdragon SKUs) | `*#0808#` | USB settings menu; choose a DM+ADB mode |
| Xiaomi | `*#*#13491#*#*` | Not present on every build |
| OnePlus | `*#801#` | **Dead on current OxygenOS.** Historical only |

Treat these as best-effort. The research found the OnePlus dialer code no longer
works on recent builds, so root is the dependable route.

### Root on a OnePlus, in outline

1. Unlock the bootloader (wipes the phone).
2. Patch that build's `boot.img` with Magisk, flash it, verify with `su`.
3. Confirm `/dev/diag` is readable as root.

**Carrier caveat.** Several T-Mobile OnePlus models (7T, 8, 8T, 9, 10T) resist
bootloader unlock. A 6T can be unlocked after the carrier unlock is complete.
Newer unlocked OnePlus models unlock immediately. Confirm your exact model
before promising a customer it will work.

**Magisk root is not automatically enough.** On some OnePlus 6/6T builds
`/dev/diag` stays unwritable even as root. If diag enablement succeeds but no
data flows, that is the failure you are looking at.

---

## 3. When it does not work

| Symptom | Cause | Fix |
| --- | --- | --- |
| `adb says 'unauthorized'` | RSA prompt not accepted | Unlock the phone, tick "always allow" |
| No diag port after enablement | Driver missing, or the composition was ignored | Check Device Manager; try WinUSB + `--usb` |
| Port opens, nothing arrives | Another process owns `/dev/diag` | Only one diag client is allowed at a time. Stop the OEM logger or `diag_mdlog` |
| `modem did not answer the version query` | Not the diag port (it is the modem or NMEA port) | Pick the port whose interface protocol is `0x30` |
| Capture stops when the phone is touched | Cable or re-enumeration | FieldTap ends the session tidily and still writes the report; re-plug to start a new one |

---

## 4. Device support matrix

One row so far, and it is honest about what is confirmed.

| Handset | SoC | Android | Root | Detected on | Diag capture |
| --- | --- | --- | --- | --- | --- |
| OnePlus 10 Pro (NE2215, OP516FL1) | SM8450 Snapdragon 8 Gen 1, platform `taro` | 15 (`15.0.0.901(EX01)`) | Unlocked; root needed, Magisk booted temporarily | macOS: yes. Windows: **never enumerated at all** | **Yes, with root**, over USB. 2026-09-14 |
| Samsung Galaxy S22/S23/S24, **Snapdragon SKUs only** | Snapdragon | - | **Not required** | - | Reported yes, via `*#0808#`. Untested by us |
| Xiaomi / Redmi / POCO, Snapdragon | Snapdragon | - | Required | - | Reported yes. Untested by us |

The Windows column is the interesting one: the same phone and cable that
macOS enumerates immediately produced no USB event whatsoever on a Windows 11
laptop that had never enumerated any handset. Try a Mac before spending time
on Windows drivers.

### The OnePlus finding, corrected on the handset (2026-09-14)

**This section said diag capture was impossible on this phone. It is not.** The
kernel half of the old finding still holds: there is no `/dev/diag` on the
device, `diagchar` is in no OxygenOS branch for the 10 Pro, and no amount of
root creates it. What the earlier analysis missed is that on this platform
**diag no longer goes through `diagchar` at all.**

Qualcomm moved diag into userspace for `taro` and later. `/vendor/bin/diag-router`
runs as the `system` user from boot (`vendor.qti.diag.rc`), and reaches the modem
over QRTR rather than a character device. The USB side is FunctionFS: init mounts
`/dev/ffs-diag`, `-diag-1` and `-diag-2`, `diag-router` holds `ep0`, `ep1` and
`ep2` open on them, and `vendor.usb.diag.func.name` is `ffs`. So the diag backend
is present and running on a stock phone; nothing is missing but a USB composition
that exposes it.

**What actually works, confirmed on the handset:**

1. Root. The bootloader is already unlocked; a Magisk-patched `boot.img` started
   once with `fastboot boot` is enough and writes nothing.
2. `su -c 'setprop sys.usb.config diag,adb'`. Shell alone cannot: Android refuses
   the property to an unprivileged caller. The gadget then carries `ffs.diag`
   plus `ffs.adb` as `22d9:276c`, and the Mac sees interface 0 as class
   `ff/ff/30` with two endpoints -- the Qualcomm diag signature.
3. `fieldtap capture --usb --vid 0x22d9 --pid 0x276c --interface 0`: 4,416 log
   records in 40 s with 0 CRC errors. QCSuper `--usb-modem` reads the same port
   and returns the modem build (`MPSS.DE.2.0-00906-WAIPIO_GEN_PACK-1.15816.289`).

**QCSuper's `--adb` mode still cannot work here,** and would fail even with root:
it reads `/dev/diag`, which genuinely does not exist. Only the USB path works.

**The phone can also log to its own storage.** `/vendor/bin/diag_mdlog -f MASK -o
DIR` talks to `diag-router` through libdiag and writes qmdl with no computer
attached. A mask file is a sequence of HDLC-framed log-config commands, which
`fieldtap` can already build. Note the output is qmdl2 with QSR4-compressed F3
messages; the RRC/NAS log packets inside it are ordinary and decode after their
8-byte envelope is stripped.

**Consequence for the product:** the OnePlus 10 Pro is usable for diag capture,
at the cost of root. That cost is the real objection, not the chipset -- a rooted
handset is hard to justify to an operator's security team. The Samsung Snapdragon
route is still the more interesting one precisely because it is reported to need
**no root and no bootloader unlock**, just a dialer code, and is still worth
buying one to confirm.

The earlier analysis is kept at [`research/oneplus-10-pro-diag.md`](research/oneplus-10-pro-diag.md);
read it with this correction in hand, because its conclusion is wrong.

## 5. Recording what worked

Every capture writes `session.json` with the handset model, Android build,
baseband, modem build and the transport used. That file is how a support matrix
gets built: after a successful session on a new model, add a row to the device
table with what the sidecar recorded.

Nothing in this repository has been run against a handset yet. The first person
to do so should expect to correct this page, and should.

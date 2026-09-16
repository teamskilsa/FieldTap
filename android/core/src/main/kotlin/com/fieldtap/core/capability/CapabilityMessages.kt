package com.fieldtap.core.capability

/**
 * The plain-English sentences the Capability screen and the export show, kept in `:core` for testability,
 * the way `com.fieldtap.core.probe.ProbeNotes` is. The screen adds only structural strings (headers,
 * button labels); every verdict/finding sentence is produced here.
 *
 * Honesty is the feature (capability spec §0): the copy never implies 5gto6G FieldTap decodes signalling.
 * Layer-3 capability is about whether the DEVICE has a diag path, for the laptop-over-USB tool — the only
 * mention of decoding is the disclaimer that the app does **not** decode. No sentence names RRC, NAS or
 * SIB as something this app does.
 *
 * Owner: workstream `capability-core`.
 */
object CapabilityMessages {
    // ---- Tier lines (the tiered "What 5gto6G FieldTap can capture on this phone" verdict) ----

    /** Tier 1 — public-API measurements, always available. The hero lede on the Capability screen. */
    fun tier1(): String =
        "Measures serving-cell RSRP, RSRQ and SINR, band, ARFCN and service state, and records a " +
            "session — on any phone, no root."

    /**
     * Tier 1's short form for the tiered-verdict row, so the Public-API row does not repeat the hero lede ([tier1]) word
     * for word inside the same viewport: the row names what it measures; the hero carries the full confident sentence.
     */
    fun tier1Short(): String =
        "Serving-cell RSRP, RSRQ and SINR, plus band, ARFCN and service state."

    /** Tier 2 — push cell updates, which need the Phone permission. The app works fully without it. */
    fun tier2(phoneGranted: Boolean): String =
        if (phoneGranted) {
            "Instant cell updates are on: the Phone permission is granted, so cell changes push immediately."
        } else {
            "Push cell updates need the Phone permission (Instant cell updates); the app works fully without it."
        }

    /**
     * Tier 3 — layer-3 signalling. [l3] is [CapabilityVerdict.layer3]'s answer; [probe] is null before the
     * root check. The honest per-phone sentence, never implying the app decodes.
     */
    fun tier3(l3: Layer3OnDevice, root: RootSignals, probe: RootProbeResult?): String = when (l3) {
        Layer3OnDevice.POSSIBLE -> LAYER3_POSSIBLE
        Layer3OnDevice.NOT_POSSIBLE ->
            if (probe != null && probe.suStatus == SuStatus.GRANTED && probe.isRoot) {
                rootedNotPossibleSentence(probe)
            } else {
                "$LAYER3_NO_ROOT ${RootDetector.CAVEAT}"
            }
        Layer3OnDevice.UNKNOWN -> when {
            probe == null -> looksRootedSentence(root)
            probe.suStatus == SuStatus.DENIED -> SU_DENIED
            probe.suStatus == SuStatus.TIMED_OUT -> SU_TIMED_OUT
            probe.suStatus == SuStatus.GRANTED && probe.isRoot -> ROOTED_DIAG_UNKNOWN
            else -> SU_ERROR
        }
    }

    /** The RootProbeResult message: describes the "Check with root" outcome in one plain sentence. */
    fun rootProbeMessage(root: RootSignals, probe: RootProbeResult, usb: UsbDebugState): String =
        when (probe.suStatus) {
            SuStatus.GRANTED ->
                if (!probe.isRoot) {
                    SU_DENIED
                } else {
                    when (probe.layer3) {
                        Layer3OnDevice.POSSIBLE -> LAYER3_POSSIBLE
                        Layer3OnDevice.NOT_POSSIBLE -> "${rootedNotPossibleSentence(probe)} ${usbDebuggingLine(usb)}"
                        Layer3OnDevice.UNKNOWN -> ROOTED_DIAG_UNKNOWN
                    }
                }
            SuStatus.DENIED -> SU_DENIED
            SuStatus.TIMED_OUT -> SU_TIMED_OUT
            SuStatus.NOT_PRESENT -> SU_NOT_PRESENT
            SuStatus.ERROR -> SU_ERROR
        }

    /**
     * The laptop-path line for the verdict's `laptopPath` field: whether USB debugging is on. Shown when
     * layer-3 is NOT_POSSIBLE/UNKNOWN.
     */
    fun laptopPath(usb: UsbDebugState): String = usbDebuggingLine(usb)

    /** Always shown in the USB section: why USB debugging matters for the laptop path. */
    fun whyUsbMatters(): String =
        "FieldTap on a laptop captures diag over ADB, so USB debugging must be on for that path."

    /**
     * The ordered [CapabilityReport.notes]: root summary, then USB, then the cellular readout
     * (Phone-permission state, precise-location + location-services state, SIM state, mock-location app
     * set and whether this build accepts mock fixes) — one plain sentence each, the `ProbeNotes` pattern.
     */
    fun notes(report: CapabilityReport): List<String> = buildList {
        add(rootSummary(report.root, report.rootProbe))
        add("${whyUsbMatters()} ${usbDebuggingLine(report.usb)}")
        add(phonePermissionNote(report.cellular.readPhoneStateGranted))
        add(locationNote(report.cellular.preciseLocationGranted, report.cellular.locationServicesEnabled))
        add(simNote(report.cellular.simReady))
        add(mockLocationNote(report.cellular.mockLocationAppSet, report.cellular.buildAcceptsMockLocations))
    }

    /** The strongest passive tell, named for the "looks rooted" sentence. */
    fun strongestSignal(root: RootSignals): String = when {
        "com.topjohnwu.magisk" in root.rootManagerPackages -> "Magisk is installed"
        "me.weishu.kernelsu" in root.rootManagerPackages -> "KernelSU is installed"
        "eu.chainfire.supersu" in root.rootManagerPackages -> "SuperSU is installed"
        root.rootManagerPackages.isNotEmpty() -> "a root manager is installed"
        root.suBinariesPresent.isNotEmpty() -> "a su binary is present"
        root.writableSystemPaths.isNotEmpty() -> "the system partition is writable"
        root.buildTagsTestKeys -> "the build is signed with test keys"
        root.debuggable -> "the build is debuggable"
        root.secureOff -> "ro.secure is off"
        else -> "root signals were found"
    }

    private fun rootedNotPossibleSentence(probe: RootProbeResult): String =
        "Layer-3 capture is not possible on this phone: ${noDiagReasonClause(probe)}. $CAPTURE_ON_LAPTOP"

    /**
     * The shared reason clause for a rooted phone that still cannot do on-device layer-3, reused by both
     * [rootedNotPossibleSentence] and [onDeviceLayer3Reason] so their wording can never drift.
     */
    private fun noDiagReasonClause(probe: RootProbeResult): String =
        if (probe.diagDevice == DiagDevice.PERMISSION_DENIED) {
            "it is rooted and has a /dev/diag node, but SELinux blocks access to it"
        } else {
            val kernelClause =
                if (probe.kernelDiag == KernelConfigProbe.DIAG_ABSENT) ", and the kernel config reports no diag support" else ""
            "it is rooted, but its kernel has no diag device (/dev/diag is absent$kernelClause)"
        }

    // ---- Deep diagnostics copy (deep-root-spec §3, §5). Kept in :core so it is tested. ----

    /**
     * The `<reason>` for the on-device layer-3 sub-verdict, after a "Run diagnostics" run folded [probe].
     * Reuses [noDiagReasonClause] for the rooted-but-no-diag case, so it stays verbatim-compatible with
     * [rootedNotPossibleSentence]. Never names RRC/NAS/SIB and never implies this app decodes signalling.
     */
    fun onDeviceLayer3Reason(probe: RootProbeResult): String = when (probe.layer3) {
        Layer3OnDevice.POSSIBLE -> "it is rooted and has a usable diag device (/dev/diag)"
        Layer3OnDevice.NOT_POSSIBLE ->
            if (probe.suStatus == SuStatus.GRANTED && probe.isRoot) {
                noDiagReasonClause(probe)
            } else {
                "no working root was found on this phone, so on-device diag is not available"
            }
        Layer3OnDevice.UNKNOWN -> when (probe.suStatus) {
            SuStatus.DENIED -> "root access was not granted, so the diag device could not be tested"
            SuStatus.TIMED_OUT -> "the superuser prompt was not answered in time, so the diag device was not tested"
            SuStatus.ERROR -> "the root check could not be completed, so the diag device was not tested"
            SuStatus.GRANTED -> "it is rooted, but whether it has a usable diag device could not be confirmed"
            SuStatus.NOT_PRESENT -> "no su was found to run, so this phone has no working root"
        }
    }

    /** The `<reason>` before any deep run: from the passive confidence and the unchanged rule's [outcome]. */
    fun onDeviceLayer3ReasonPassive(root: RootSignals, outcome: Layer3OnDevice): String = when (outcome) {
        Layer3OnDevice.UNKNOWN ->
            "this phone looks rooted (${strongestSignal(root)}), but its diag device has not been tested yet — tap Run diagnostics"
        Layer3OnDevice.NOT_POSSIBLE -> "no root path was found, so on-device diag is not available on this phone"
        Layer3OnDevice.POSSIBLE -> "it is rooted and has a usable diag device (/dev/diag)"
    }

    /** The laptop-over-USB path offered whenever on-device layer-3 is not viable. */
    fun laptopOverUsbPath(): String = "Use 5gto6G FieldTap on a laptop with this phone connected over USB."

    /**
     * The one plain-language consequence sentence for a [SelinuxAssessment]: what the SELinux [mode] means
     * for an app's own path to the diag device. Nothing is ever changed — this only describes.
     */
    fun selinuxConsequence(mode: SelinuxMode, blocksAppDiagPath: Boolean): String = when (mode) {
        SelinuxMode.ENFORCING ->
            if (blocksAppDiagPath) {
                "SELinux is enforcing, which normally blocks an app's own path to the diag device even on a rooted phone."
            } else {
                "SELinux is enforcing, but the diag device was readable as root, so access is not blocked here."
            }
        SelinuxMode.PERMISSIVE -> "SELinux is permissive, so it does not block an app's path to the diag device."
        SelinuxMode.DISABLED -> "SELinux is disabled, so it does not block an app's path to the diag device."
        SelinuxMode.UNKNOWN -> "The SELinux mode could not be read, so its effect on a diag path is unknown."
    }

    private fun looksRootedSentence(root: RootSignals): String =
        "This phone looks rooted (${strongestSignal(root)}). Tap Check with root to test whether it has a " +
            "usable diag device."

    private fun usbDebuggingLine(usb: UsbDebugState): String {
        val core = if (usb.adbEnabled) {
            "USB debugging is on, so the laptop tool can capture over ADB."
        } else {
            "Turn on USB debugging (Settings ▸ Developer options) so the laptop tool can capture over ADB."
        }
        return if (!usb.developerOptionsEnabled) "Developer options are off. $core" else core
    }

    private fun rootSummary(root: RootSignals, probe: RootProbeResult?): String {
        if (probe != null) {
            return when {
                probe.suStatus == SuStatus.GRANTED && probe.isRoot ->
                    "The root check confirmed working root on this phone."
                probe.suStatus == SuStatus.TIMED_OUT ->
                    "The superuser prompt was not answered, so root was not confirmed. ${RootDetector.CAVEAT}"
                probe.suStatus == SuStatus.NOT_PRESENT ->
                    "No su was found when the check ran, so this phone has no working root. ${RootDetector.CAVEAT}"
                probe.suStatus == SuStatus.ERROR ->
                    "The root check could not be completed. ${RootDetector.CAVEAT}"
                else ->
                    "Root access was not granted when the check ran. ${RootDetector.CAVEAT}"
            }
        }
        return when (root.confidence) {
            RootConfidence.HIGH -> "This phone looks rooted (${strongestSignal(root)})."
            RootConfidence.MEDIUM -> "This phone may be rootable (${strongestSignal(root)})."
            RootConfidence.LOW -> "A weak root signal was seen (${strongestSignal(root)}). ${RootDetector.CAVEAT}"
            RootConfidence.NONE -> "No root was detected. ${RootDetector.CAVEAT}"
        }
    }

    private fun phonePermissionNote(granted: Boolean): String =
        if (granted) {
            "The Phone permission is granted, so cell updates can push instantly."
        } else {
            "The Phone permission is not granted, so cell updates are not pushed (the app still measures)."
        }

    private fun locationNote(precise: Boolean, servicesOn: Boolean): String {
        val loc = if (precise) "Precise location is granted" else "Precise location is not granted"
        val svc = if (servicesOn) "location services are on" else "location services are off"
        return "$loc, and $svc."
    }

    private fun simNote(ready: Boolean): String =
        if (ready) "A SIM is ready." else "No SIM is ready, so there may be no serving cell."

    private fun mockLocationNote(mockSet: Boolean, buildAccepts: Boolean): String {
        val mock = if (mockSet) "A mock-location app is set" else "No mock-location app is set"
        val build = if (buildAccepts) "this build accepts mock location fixes" else "this build rejects mock location fixes"
        return "$mock, and $build."
    }

    // ---- The fixed sentences (worded exactly per the capability spec §3.6) ----

    private const val CAPTURE_ON_LAPTOP =
        "Capture layer-3 signalling with 5gto6G FieldTap on a laptop with this phone connected over USB."

    private const val LAYER3_POSSIBLE =
        "This phone is rooted and has a diag device (/dev/diag), so layer-3 signalling capture is possible " +
            "with a diag tool. 5gto6G FieldTap itself does not decode signalling."

    private const val LAYER3_NO_ROOT =
        "Layer-3 capture needs root and a diag device, and no root was detected. Use 5gto6G FieldTap on a " +
            "laptop with this phone connected over USB."

    private const val SU_DENIED = "Root access was not granted, so the diag device could not be tested."

    private const val SU_TIMED_OUT =
        "The superuser prompt was not answered in time, so the diag device was not tested."

    private const val SU_NOT_PRESENT = "No su was found to run, so this phone has no working root."

    private const val SU_ERROR = "The root check could not be completed, so the diag device was not tested."

    private const val ROOTED_DIAG_UNKNOWN =
        "This phone is rooted, but whether it has a usable diag device could not be confirmed."
}

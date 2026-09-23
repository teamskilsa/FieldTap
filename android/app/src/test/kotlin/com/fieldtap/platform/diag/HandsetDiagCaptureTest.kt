package com.fieldtap.platform.diag

import com.fieldtap.diag.CaptureProfile
import org.junit.Assert.assertEquals
import org.junit.Test

class HandsetDiagCaptureTest {

    @Test
    fun theSignallingMaskKeepsTheNameItAlwaysHad() {
        // A phone that captured before profiles existed has this file; the default profile still owns it.
        assertEquals("/data/local/tmp/fieldtap-signalling.cfg", HandsetDiagCapture.maskPath(CaptureProfile.SIGNALLING))
    }

    @Test
    fun everyProfileHasAMaskFileOfItsOwn() {
        // The logger reads whatever file it is pointed at. Sharing one name between profiles would let an
        // engineering capture run on the signalling mask a previous start left behind if the write failed.
        val paths = CaptureProfile.entries.map { HandsetDiagCapture.maskPath(it) }
        assertEquals(paths.size, paths.toSet().size)
        assertEquals("/data/local/tmp/fieldtap-engineering.cfg", HandsetDiagCapture.maskPath(CaptureProfile.ENGINEERING))
        assertEquals("/data/local/tmp/fieldtap-l2.cfg", HandsetDiagCapture.maskPath(CaptureProfile.L2))
    }
}

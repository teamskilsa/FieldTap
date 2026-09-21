package com.fieldtap.ui.theme

import com.fieldtap.core.export.SessionKml
import org.junit.Assert.assertEquals
import org.junit.Test

/** The shared map colours its dots on the same RSRP lines the app draws its bars on. */
class SessionKmlScaleTest {

    @Test
    fun theMapAndTheAppAgreeOnWhereRsrpChangesLevel() {
        val app = SignalScale.RSRP_THRESHOLDS
        assertEquals(app.excellentAtLeast, SessionKml.EXCELLENT_AT_LEAST)
        assertEquals(app.goodAtLeast, SessionKml.GOOD_AT_LEAST)
        assertEquals(app.fairAtLeast, SessionKml.FAIR_AT_LEAST)
    }
}

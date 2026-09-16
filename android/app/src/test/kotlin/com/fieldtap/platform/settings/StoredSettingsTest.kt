package com.fieldtap.platform.settings

import com.fieldtap.core.settings.AppSettings
import com.fieldtap.core.settings.AppSettingsCodec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class StoredSettingsTest {

    @Test
    fun theFirstReadGeneratesAnInstallIdAndAsksToStoreIt() {
        val decoded = StoredSettings.decode(null) { "0b9d4a52-4d3e-4f59-9d53-2f0c5b0f7a11" }

        assertEquals("0b9d4a52-4d3e-4f59-9d53-2f0c5b0f7a11", decoded.settings.installId)
        assertNull(decoded.settings.consent)
        val repaired = assertNotNullText(decoded.repairedText)
        // Reading the stored text back gives the same settings and needs no further repair.
        val again = StoredSettings.decode(repaired) { "a-different-id" }
        assertEquals(decoded.settings, again.settings)
        assertNull(again.repairedText)
    }

    @Test
    fun storedSettingsNeedNoRepair() {
        val stored = AppSettings(installId = "3f1c2b8e-7a4d-4c55-8f0e-6b7d9a1c2e33", testsDefaultOn = true)

        val decoded = StoredSettings.decode(AppSettingsCodec.encode(stored)) { "never-used" }

        assertEquals(stored, decoded.settings)
        assertNull(decoded.repairedText)
    }

    @Test
    fun corruptTextGetsANewInstallIdThatIsStored() {
        val decoded = StoredSettings.decode("{not json") { "5c2a7e1b-0d4f-4a8e-b6c3-9e1f2d3a4b55" }

        assertEquals("5c2a7e1b-0d4f-4a8e-b6c3-9e1f2d3a4b55", decoded.settings.installId)
        assertNull(decoded.settings.consent)
        assertNotNull(decoded.repairedText)
    }

    private fun assertNotNullText(text: String?): String {
        assertNotNull("a generated install id must be stored", text)
        return text!!
    }
}

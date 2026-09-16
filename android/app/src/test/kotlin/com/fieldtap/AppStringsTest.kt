package com.fieldtap

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Test
import org.w3c.dom.Element

class AppStringsTest {

    @Test
    fun appNameAndLimitsStatementAreVerbatim() {
        val strings = readStrings(File("src/main/res/values/strings.xml"))

        assertEquals("5gto6G FieldTap", strings["app_name"])
        assertEquals(LIMITS_STATEMENT, strings["limits_statement"])
    }

    private fun readStrings(file: File): Map<String, String> {
        val nodes = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(file)
            .getElementsByTagName("string")
        return (0 until nodes.length)
            .map { nodes.item(it) as Element }
            .associate { it.getAttribute("name") to it.textContent }
    }

    private companion object {
        const val LIMITS_STATEMENT =
            "Reads what Android exposes: cell identity, RSRP/RSRQ/SINR, band, ARFCN, service state, " +
                "plus ping and download tests. That needs no root, and it is all this app does " +
                "until you turn on signalling capture. Signalling capture reads RRC and NAS from " +
                "the modem itself and needs a rooted phone; it is off unless you switch it on. " +
                "Neither mode can lock bands or cells or scan operators."
    }
}

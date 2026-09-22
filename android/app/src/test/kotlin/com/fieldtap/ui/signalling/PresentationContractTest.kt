package com.fieldtap.ui.signalling

import com.fieldtap.diag.CallFlow
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.AssumptionViolatedException
import org.junit.Test

/**
 * Contract v1 (ios/Contract/CONTRACT.md): the ladder the iPhone app draws is this presentation's, string for string.
 * The rows per filter, lanes and procedure groups of the iPhone trace are written the way
 * ios/Contract/tools/PresDump.kt writes them and compared byte for byte with `presentation-golden.json`.
 *
 * Both files are capture-derived and never committed; Gradle passes FT_CONTRACT_DIR and FT_IPHONE_QMDL in
 * (build.gradle.kts). Without them the test skips; with FT_REQUIRE_FIXTURES=1 it fails instead.
 */
class PresentationContractTest {

    private fun file(what: String, path: String?): File = path?.let(::File)?.takeIf { it.isFile } ?: run {
        val message = "contract fixture missing: $what"
        if (System.getProperty("ft.require") == "1") fail("$message (FT_REQUIRE_FIXTURES=1)")
        throw AssumptionViolatedException(message)
    }

    @Test
    fun theIphoneLadderIsTheGolden() {
        val golden = file("presentation-golden.json (FT_CONTRACT_DIR)", System.getProperty("ft.contract")?.let { "$it/presentation-golden.json" })
        val qmdl = file("iphone-recovered.qmdl (FT_IPHONE_QMDL)", System.getProperty("ft.iphoneQmdl"))
        val want = golden.readText().lines()
        val got = dump(CallFlow.read(qmdl.readBytes())).lines()
        // Report the first differing line rather than two 48 KB strings.
        val at = want.indices.firstOrNull { it >= got.size || want[it] != got[it] }
        if (at != null) fail("presentation-golden.json: line ${at + 1} differs\n  golden: ${want[at]}\n  kotlin: ${got.getOrNull(at)}")
        assertEquals("line count", want.size, got.size)
    }

    // A port of PresDump.kt's output; the goldens were written by it, so any drift fails this test.

    private fun q(s: String?): String = if (s == null) "null" else buildString {
        append('"')
        for (c in s) when (c) {
            '"' -> append("\\\""); '\\' -> append("\\\\"); '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t")
            else -> if (c < ' ') append("\\u%04x".format(c.code)) else append(c)
        }
        append('"')
    }

    private fun dump(flow: CallFlow.Flow): String {
        val p = CallFlowPresentation
        val sb = StringBuilder("{\n")
        for (filter in FlowFilter.values()) {
            sb.append("\"rows${filter}\":[\n")
            sb.append(p.rows(flow, filter).joinToString(",\n") { r ->
                when (r) {
                    is LadderRow.Move ->
                        "{\"type\":\"move\",\"key\":${q(r.key)},\"move\":\"${r.step.move}\",\"to\":${q(p.shortCell(r.step.to))}," +
                            "\"band\":${q(p.band(r.step.to))},\"downlink\":${q(p.downlinkMhz(r.step.to))}}"
                    is LadderRow.ProcedureStart ->
                        "{\"type\":\"procedure\",\"key\":${q(r.key)},\"name\":${q(r.procedure.name)},\"outcome\":\"${r.procedure.outcome}\"," +
                            "\"duration\":${q(p.duration(r.procedure.durationMs))}}"
                    is LadderRow.Message ->
                        "{\"type\":\"message\",\"key\":${q(r.key)},\"name\":${q(r.event.name)},\"count\":${r.count},\"mixed\":${r.mixed}," +
                            "\"cells\":${q(p.cellsOf(r))},\"cellCount\":${p.cellCount(r)},\"since\":${q(p.sinceStart(r.event.sinceStartMs))}," +
                            "\"gap\":${p.gap(flow.events, r.event.index)?.let { q(p.duration(it)) } ?: "null"}}"
                }
            })
            sb.append("\n],\n")
        }
        val lanes = p.lanes(flow)
        sb.append("\"lanes\":{\"phone\":${q(lanes.phone)},\"ran\":${q(lanes.ran)},\"core\":${q(lanes.core)}},\n")
        sb.append("\"procedureGroups\":[\n" + p.procedureGroups(flow).joinToString(",\n") { g ->
            "{\"name\":${q(g.name)},\"layer\":\"${g.layer}\",\"n\":${g.items.size},\"succeeded\":${g.succeeded},\"failed\":${g.failed}," +
                "\"unanswered\":${g.unanswered},\"median\":${g.medianMs?.let { q(p.duration(it)) } ?: "null"}}"
        } + "\n]\n}\n")
        return sb.toString()
    }
}

package com.fieldtap.diag

import java.io.File
import java.lang.reflect.InvocationTargetException
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.AssumptionViolatedException
import org.junit.Test

/**
 * Contract v1 (ios/Contract/CONTRACT.md): the golden JSON the iPhone app is held to is exactly what these decoders
 * produce, byte for byte apart from the value of `source.file`, for the iPhone trace, the QDSS attach window and
 * both OnePlus captures.
 *
 * The goldens and the iPhone qmdls are capture-derived and never committed, so Gradle passes their paths in from
 * FT_CONTRACT_DIR, FT_IPHONE_QMDL and FT_FIXTURES (build.gradle.kts). Without them these tests skip; with
 * FT_REQUIRE_FIXTURES=1 a missing file fails them instead, so a skip never stands in for a real run.
 *
 * The JSON is written by ios/Contract/tools/GoldenDump.kt, the tool that made the goldens, compiled into this source
 * set rather than ported, so the check and the goldens cannot drift apart. It is found by reflection so the module
 * still builds in a checkout without ios/.
 */
class ContractGoldenTest {

    private val required = System.getProperty("ft.require") == "1"

    private fun missing(what: String): Nothing {
        val message = "contract fixture missing: $what"
        if (required) fail("$message (FT_REQUIRE_FIXTURES=1)")
        throw AssumptionViolatedException(message)
    }

    private fun file(what: String, path: String?): File = path?.let(::File)?.takeIf { it.isFile } ?: missing(what)

    private fun contract(name: String) = file("$name (FT_CONTRACT_DIR)", System.getProperty("ft.contract")?.let { "$it/$name" })

    private fun resource(name: String) = File(javaClass.getResource(name)!!.toURI())

    /** GoldenDump's `main(in.qmdl, outDir)`. */
    private val goldenDump by lazy {
        try {
            Class.forName("com.fieldtap.diag.GoldenDumpKt").getMethod("main", Array<String>::class.java)
        } catch (e: ReflectiveOperationException) {
            null
        }
    }

    /** `source.file` names the input; it is the one value allowed to differ. */
    private fun normalised(json: String) = SOURCE_FILE.replace(json, "\"source\":{\"file\":\"\"")

    private fun assertGolden(qmdl: File, expected: File) {
        val dump = goldenDump ?: missing("ios/Contract/tools/GoldenDump.kt (compiled in by the contractTools task)")
        val out = Files.createTempDirectory("ft-contract").toFile()
        try {
            try {
                dump.invoke(null, arrayOf(qmdl.path, out.path))
            } catch (e: InvocationTargetException) {
                throw e.targetException
            }
            val want = normalised(expected.readText()).lines()
            val got = normalised(File(out, "callflow-golden.json").readText()).lines()
            // Report the first differing line rather than two 75 KB strings.
            val at = want.indices.firstOrNull { it >= got.size || want[it] != got[it] }
            if (at != null) fail("${expected.name}: line ${at + 1} differs\n  golden: ${want[at]}\n  kotlin: ${got.getOrNull(at)}")
            assertEquals("${expected.name}: line count", want.size, got.size)
        } finally {
            out.deleteRecursively()
        }
    }

    @Test
    fun theIphoneTraceGivesTheGolden() =
        assertGolden(file("iphone-recovered.qmdl (FT_IPHONE_QMDL)", System.getProperty("ft.iphoneQmdl")), contract("callflow-golden.json"))

    @Test
    fun theQdssAttachWindowGivesItsGolden() = assertGolden(
        file("qdss-attach4/expected/attach4.qmdl (FT_FIXTURES)", System.getProperty("ft.fixtures")?.let { "$it/qdss-attach4/expected/attach4.qmdl" }),
        contract("callflow-attach4.json"),
    )

    @Test
    fun theOnePlusRegistrationGivesItsGolden() =
        assertGolden(resource("/oneplus-5g-registration.qmdl"), contract("oneplus-5g-registration.json"))

    @Test
    fun theOnePlusServiceRequestGivesItsGolden() =
        assertGolden(resource("/oneplus-callbox-service-request.qmdl"), contract("oneplus-callbox-service-request.json"))

    private companion object {
        val SOURCE_FILE = Regex("\"source\":\\{\"file\":\"(?:[^\"\\\\]|\\\\.)*\"")
    }
}

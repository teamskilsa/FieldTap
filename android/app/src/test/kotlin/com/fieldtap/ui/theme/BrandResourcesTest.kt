package com.fieldtap.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import java.io.File
import java.util.Locale
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.math.hypot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * The window theme, the splash screen and the launcher icon are XML resources; the Compose theme is
 * Kotlin. These tests keep the two identical, and keep the launcher mark inside the adaptive icon's safe
 * zone. Paths are relative to the module directory, where Gradle runs unit tests.
 */
class BrandResourcesTest {
    private val colors: Map<String, String> by lazy { readColors(File("src/main/res/values/colors.xml")) }

    @Test
    fun windowAndSplashColoursEqualTheComposeSurfaces() {
        assertEquals(hex(FieldTapColorSchemes.Dark.surface), colors["window_background_dark"])
        assertEquals(hex(FieldTapColorSchemes.Dark.primary), colors["brand_primary_dark"])
    }

    @Test
    fun theWindowIsDarkEvenWhenThePhoneIsLight() {
        // The app always draws the dark scheme (MainActivity forces it). A light window under it would
        // flash before the first frame on every phone set to light mode.
        val light = java.io.File("src/main/res/values/themes.xml").readText()
        assertTrue(light.contains("@color/window_background_dark"))
        assertFalse(light.contains("@color/window_background_light"))
    }

    @Test
    fun launcherColoursEqualBrandColors() {
        assertEquals(hex(BrandColors.GradientStart), colors["brand_gradient_start"])
        assertEquals(hex(BrandColors.GradientEnd), colors["brand_gradient_end"])
        assertEquals(hex(BrandColors.MarkBars), colors["brand_mark_bars"])
        assertEquals(hex(BrandColors.MarkAccent), colors["brand_mark_accent"])
    }

    @Test
    fun brandMarkStaysInsideTheAdaptiveIconSafeZone() {
        val g = BrandMarkGeometry
        assertEquals(g.BAR_COUNT, g.BAR_HEIGHTS.size)
        for (i in 0 until g.BAR_COUNT) {
            val left = g.FIRST_BAR_X + i * g.BAR_PITCH
            val right = left + g.BAR_WIDTH
            val top = g.BASELINE_Y - g.BAR_HEIGHTS[i]
            val corners = listOf(left to top, right to top, left to g.BASELINE_Y, right to g.BASELINE_Y)
            for ((x, y) in corners) {
                val distance = hypot((x - g.CENTRE).toDouble(), (y - g.CENTRE).toDouble())
                assertTrue("bar $i corner ($x, $y) is $distance from the centre", distance <= g.SAFE_RADIUS)
            }
        }
    }

    @Test
    fun theSixthBarLeapsHigherThanTheRhythmOfTheFirstFive() {
        val h = BrandMarkGeometry.BAR_HEIGHTS
        val step = h[1] - h[0]
        for (i in 1 until 5) assertEquals(step, h[i] - h[i - 1], 0f)
        assertTrue(h[5] - h[4] > step)
    }

    private fun hex(color: Color): String = String.format(Locale.ROOT, "#%06X", color.toArgb() and 0xFFFFFF)

    private fun readColors(file: File): Map<String, String> {
        val nodes = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file).getElementsByTagName("color")
        return (0 until nodes.length)
            .map { nodes.item(it) as Element }
            .associate { it.getAttribute("name") to it.textContent.trim().uppercase(Locale.ROOT) }
    }
}

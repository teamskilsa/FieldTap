package com.fieldtap.data

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class CaptureStoreTest {
    @get:Rule
    val temp = TemporaryFolder()

    private fun store() = CaptureStore(temp.newFolder("signalling"))

    private fun source(bytes: Int = 64): File =
        temp.newFile("scratch-${System.nanoTime()}.qmdl").apply { writeBytes(ByteArray(bytes) { 7 }) }

    @Test
    fun aSavedCaptureIsListedWithItsCounts() {
        val store = store()
        val saved = store.save(source(128), startedUtcMs = 1_789_050_600_000L, records = 169, messages = 12, rejects = 3)

        assertNotNull(saved)
        assertEquals(169, saved!!.records)
        assertEquals(12, saved.messages)
        assertEquals(3, saved.rejects)
        assertEquals(128L, saved.bytes)
        assertTrue(saved.hasSignalling)
        assertEquals(listOf(saved.name), store.list().map { it.name })
    }

    @Test
    fun theNameIsTheUtcTimeItStarted() {
        // 1 789 050 600 000 ms is 2026-09-10T14:30:00Z.
        val saved = store().save(source(), 1_789_050_600_000L, 1, 1, 0)!!
        assertEquals("20260910-143000", saved.name)
    }

    @Test
    fun theSourceIsMovedNotLeftBehind() {
        val store = store()
        val scratch = source()
        store.save(scratch, 1_789_050_600_000L, 1, 0, 0)
        assertFalse("the scratch file is gone", scratch.exists())
    }

    @Test
    fun capturesComeBackNewestFirst() {
        val store = store()
        store.save(source(), 1_789_050_600_000L, 1, 0, 0)
        store.save(source(), 1_789_050_900_000L, 1, 0, 0)
        store.save(source(), 1_789_050_300_000L, 1, 0, 0)

        assertEquals(
            listOf(1_789_050_900_000L, 1_789_050_600_000L, 1_789_050_300_000L),
            store.list().map { it.startedUtcMs },
        )
    }

    @Test
    fun twoCapturesInTheSameSecondBothSurvive() {
        val store = store()
        val first = store.save(source(), 1_789_050_600_000L, 1, 0, 0)!!
        val second = store.save(source(), 1_789_050_600_400L, 1, 0, 0)!!

        assertEquals("20260910-143000", first.name)
        assertEquals("the second is suffixed, not written over the first", "20260910-143000-2", second.name)
        assertEquals(2, store.list().size)
    }

    @Test
    fun anEmptyOrMissingSourceSavesNothing() {
        val store = store()
        assertNull(store.save(temp.newFile("empty.qmdl"), 1L, 0, 0, 0))
        assertNull(store.save(File(temp.root, "absent.qmdl"), 1L, 0, 0, 0))
        assertTrue(store.list().isEmpty())
    }

    @Test
    fun aCaptureWithNoSummaryIsStillListed() {
        val store = store()
        val saved = store.save(source(), 1_789_050_600_000L, 169, 12, 3)!!
        // The counts are recomputed when it is opened; losing them must not lose the capture.
        assertTrue(File(File(temp.root, "signalling/${saved.name}"), CaptureStore.SUMMARY).delete())

        val again = store.find(saved.name)
        assertNotNull(again)
        assertEquals(0, again!!.records)
        assertTrue(store.qmdl(saved.name)!!.isFile)
    }

    @Test
    fun aDirectoryWithNoCaptureIsNotListed() {
        val store = store()
        File(temp.root, "signalling/20260910-143000").mkdirs()
        assertTrue(store.list().isEmpty())
        assertNull(store.find("20260910-143000"))
        assertNull(store.qmdl("20260910-143000"))
    }

    @Test
    fun deletingRemovesItAndIsSafeToRepeat() {
        val store = store()
        val saved = store.save(source(), 1_789_050_600_000L, 1, 0, 0)!!
        assertTrue(store.delete(saved.name))
        assertTrue(store.list().isEmpty())
        assertTrue("deleting what is gone is not a failure", store.delete(saved.name))
    }
}

package com.fieldtap.ui.sessions

import com.fieldtap.data.SavedCapture
import com.fieldtap.ui.common.TestData
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The Recordings list: drives and signalling captures in one list, newest first.
 *
 * Owner: workstream `ui-session`.
 */
class RecordingsTest {

    private fun state(
        sessions: List<com.fieldtap.app.SessionSummary> = emptyList(),
        captures: List<SavedCapture> = emptyList(),
    ) = SessionsUiState(loading = false, sessions = sessions, storage = null, captures = captures)

    private fun capture(name: String, startedUtcMs: Long) =
        SavedCapture(name = name, startedUtcMs = startedUtcMs, bytes = 1_000, records = 10, messages = 2, rejects = 0)

    @Test
    fun itInterleavesDrivesAndCapturesByWhenTheyStarted() {
        val recordings = recordingsOf(
            state(
                sessions = listOf(
                    TestData.summary("20260910-150000_B").copy(startedUtcMs = 3_000),
                    TestData.summary("20260910-143000_A").copy(startedUtcMs = 1_000),
                ),
                captures = listOf(capture("20260910-1440", 2_000), capture("20260910-1600", 4_000)),
            ),
        )

        assertEquals(
            listOf("capture:20260910-1600", "drive:20260910-150000_B", "capture:20260910-1440", "drive:20260910-143000_A"),
            recordings.map { it.key() },
        )
    }

    @Test
    fun aDriveWithNoStartTimeStaysAtTheFront() {
        // session.json unreadable: it has nothing to sort by, and sinking it to 1970 would bury the one
        // recording most likely to need attention.
        val recordings = recordingsOf(
            state(
                sessions = listOf(TestData.summary("20260910-143000_A").copy(startedUtcMs = null)),
                captures = listOf(capture("20260910-1440", 2_000)),
            ),
        )

        assertEquals(listOf("drive:20260910-143000_A", "capture:20260910-1440"), recordings.map { it.key() })
    }

    @Test
    fun aDriveAndACaptureSharingANameAreStillTwoRows() {
        val recordings = recordingsOf(
            state(
                sessions = listOf(TestData.summary("20260910-143000").copy(startedUtcMs = 1_000)),
                captures = listOf(capture("20260910-143000", 1_000)),
            ),
        )

        assertEquals(2, recordings.size)
        assertEquals(2, recordings.map { it.key() }.toSet().size)
    }

    @Test
    fun aPhoneWithNoRootHasDrivesOnly() {
        val recordings = recordingsOf(state(sessions = listOf(TestData.summary())))

        assertEquals(1, recordings.size)
        assertEquals(listOf("drive:" + TestData.DIR), recordings.map { it.key() })
    }
}

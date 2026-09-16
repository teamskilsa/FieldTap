package com.fieldtap.ui.signalling

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.fieldtap.data.CaptureStore
import com.fieldtap.data.SavedCapture
import com.fieldtap.diag.SignallingEntry
import com.fieldtap.diag.SignallingReader
import com.fieldtap.platform.diag.DiagCaptureResult
import com.fieldtap.platform.diag.HandsetDiagCapture
import com.fieldtap.platform.diag.RootShell
import java.io.File
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Everything the signalling screen draws. */
data class SignallingUiState(
    val capturing: Boolean = false,
    /** A capture or a decode is in flight; the buttons wait for it. */
    val busy: Boolean = false,
    /** How many captures this phone has kept, for the line pointing at Recordings. */
    val keptCount: Int = 0,
    /**
     * The capture just saved, until the screen has opened it. A finished capture goes straight to its call
     * flow: reading it is the whole point of taking it, and a screen that only said "saved" made the user
     * hunt for what they had just recorded.
     */
    val justSaved: String? = null,
    val message: String? = null,
    val failed: Boolean = false,
)

/** One capture, opened. */
data class CaptureDetailUiState(
    val capture: SavedCapture? = null,
    val entries: List<SignallingEntry> = emptyList(),
    /** Log records that made no call-flow line, almost all of them RRC. */
    val otherRecords: Int = 0,
    val loading: Boolean = true,
    val failed: Boolean = false,
)

/**
 * Drives [HandsetDiagCapture] and reads what it wrote.
 *
 * Capture and decode both run off the main thread: a capture is a `su` round trip and a decode walks a
 * multi-megabyte file, and neither belongs on the frame clock.
 *
 * The capture file is kept after decoding rather than deleted, because it is the half the phone cannot
 * read — RRC — and the only way to get at that is to hand the file to Wireshark or `fieldtap report`.
 *
 * Owner: workstream `diag-on-handset`.
 */
class SignallingViewModel(
    private val scratchDir: File,
    private val store: CaptureStore,
) : ViewModel() {

    private val capture = HandsetDiagCapture()
    private val _state = MutableStateFlow(SignallingUiState())
    val state: StateFlow<SignallingUiState> = _state.asStateFlow()
    private var job: Job? = null
    private var startedUtcMs: Long = 0

    init {
        refresh()
    }

    /** Re-counts the kept captures, for example after one is saved or deleted. */
    fun refresh() {
        viewModelScope.launch {
            val count = withContext(Dispatchers.IO) { store.list().size }
            _state.value = _state.value.copy(keptCount = count)
        }
    }

    /** The screen has opened [justSaved]; it must not open it again on the next recomposition. */
    fun consumeJustSaved() {
        if (_state.value.justSaved != null) _state.value = _state.value.copy(justSaved = null)
    }

    fun start() {
        if (job?.isActive == true) return
        job = viewModelScope.launch {
            _state.value = _state.value.copy(busy = true, message = null, failed = false)
            when (val result = capture.start()) {
                is DiagCaptureResult.Started -> {
                    startedUtcMs = System.currentTimeMillis()
                    _state.value = _state.value.copy(
                        capturing = true,
                        busy = false,
                        message = "Recording. Make a call, or move until the phone changes cell.",
                    )
                }

                // "Did not grant it" sent the user looking in Magisk for a refusal, when there was no Magisk
                // running at all: root started with `fastboot boot` is gone after any restart.
                is DiagCaptureResult.NoRoot -> fail(
                    when (result.why) {
                        RootShell.Root.NO_SU ->
                            "Root is not active on this phone: there is no su. Root started with fastboot boot is lost on every restart."
                        RootShell.Root.DENIED -> "Magisk refused FieldTap. Allow it in Magisk, under Superuser."
                        RootShell.Root.TIMED_OUT -> "su did not answer. Is a Magisk prompt waiting on screen?"
                        RootShell.Root.GRANTED -> "Root was granted but the check did not see it."
                    },
                )

                DiagCaptureResult.NoLogger -> fail("This phone's modem does not expose signalling.")

                is DiagCaptureResult.Failed -> fail(result.reason)
                is DiagCaptureResult.Stopped -> fail("the logger stopped before it started")
            }
        }
    }

    fun stop() {
        if (job?.isActive == true) return
        job = viewModelScope.launch {
            _state.value = _state.value.copy(busy = true, message = "Reading…")
            capture.stop()
            scratchDir.mkdirs()
            val scratch = File(scratchDir, SCRATCH_NAME)
            val file = capture.collect(scratch)
            if (file == null) {
                _state.value = _state.value.copy(
                    capturing = false,
                    busy = false,
                    failed = true,
                    message = "Nothing was captured.",
                )
                return@launch
            }
            val saved = withContext(Dispatchers.IO) {
                val summary = try {
                    SignallingReader.read(file.readBytes())
                } catch (e: IOException) {
                    null
                }
                if (summary == null) {
                    null
                } else {
                    store.save(
                        source = file,
                        startedUtcMs = startedUtcMs.takeIf { it > 0 } ?: System.currentTimeMillis(),
                        records = summary.records,
                        messages = summary.entries.size,
                        rejects = summary.rejects.size,
                    )
                }
            }
            if (saved == null) {
                _state.value = _state.value.copy(
                    capturing = false, busy = false, failed = true,
                    message = "Could not read the capture.",
                )
                return@launch
            }
            _state.value = _state.value.copy(
                capturing = false,
                busy = false,
                failed = false,
                message = summaryLine(saved),
                justSaved = saved.name,
                keptCount = withContext(Dispatchers.IO) { store.list().size },
            )
        }
    }

    /** Forgets a kept capture and its file. */
    fun delete(name: String) {
        viewModelScope.launch {
            withContext(Dispatchers.IO) { store.delete(name) }
            refresh()
        }
    }

    private fun fail(reason: String) {
        _state.value = _state.value.copy(capturing = false, busy = false, failed = true, message = reason)
    }

    private fun summaryLine(saved: SavedCapture): String = when {
        saved.rejects > 0 -> "${saved.messages} messages, ${saved.rejects} rejected"
        saved.messages > 0 -> "${saved.messages} messages"
        else -> "Nothing was signalling"
    }

    companion object {
        /** Where a capture lands before it is kept; under `cache/exports/` so sharing works from there too. */
        const val SCRATCH_NAME: String = "signalling.qmdl"
        const val MIME: String = "application/octet-stream"
    }
}

/**
 * One kept capture, opened.
 *
 * The flow is decoded from the `.qmdl` each time rather than from anything stored beside it: the file is
 * what goes to Wireshark, and a summary that drifted from it would be worse than a moment's wait.
 */
class CaptureDetailViewModel(
    private val store: CaptureStore,
    private val name: String,
) : ViewModel() {

    private val _state = MutableStateFlow(CaptureDetailUiState())
    val state: StateFlow<CaptureDetailUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            val capture = withContext(Dispatchers.IO) { store.find(name) }
            val file = withContext(Dispatchers.IO) { store.qmdl(name) }
            if (capture == null || file == null) {
                _state.value = CaptureDetailUiState(loading = false, failed = true)
                return@launch
            }
            val summary = withContext(Dispatchers.IO) {
                try {
                    SignallingReader.read(file.readBytes())
                } catch (e: IOException) {
                    null
                } catch (e: OutOfMemoryError) {
                    // A capture larger than the heap is a real possibility on a long recording.
                    null
                }
            }
            _state.value = if (summary == null) {
                CaptureDetailUiState(capture = capture, loading = false, failed = true)
            } else {
                CaptureDetailUiState(
                    capture = capture,
                    entries = summary.entries,
                    otherRecords = summary.records - summary.entries.size,
                    loading = false,
                    failed = false,
                )
            }
        }
    }

    /** The raw capture, for sharing. */
    fun file(): File? = store.qmdl(name)
}

package com.fieldtap.ui.common

import android.content.ClipData
import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.fieldtap.app.AppGraph
import java.io.File
import java.io.IOException

/**
 * A `ViewModelProvider.Factory` that builds a view model from the [AppGraph]
 * (`viewModelFactory { initializer { create(graph) } }`). Every screen's view model takes only the graph
 * (plus saved-state arguments), so tests pass a fake graph.
 *
 * The factory builds exactly one type: asking it for a class the built view model is not an instance of
 * throws [IllegalArgumentException], so a wrong `viewModel<T>()` call fails loudly instead of casting.
 *
 * Owner: workstream `ui-session`.
 */
fun <VM : ViewModel> graphViewModelFactory(graph: AppGraph, create: (AppGraph) -> VM): ViewModelProvider.Factory =
    GraphViewModelFactory(graph, create)

private class GraphViewModelFactory<VM : ViewModel>(
    private val graph: AppGraph,
    private val build: (AppGraph) -> VM,
) : ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        val viewModel = build(graph)
        require(modelClass.isInstance(viewModel)) {
            "This factory builds ${viewModel.javaClass.name}, which is not a ${modelClass.name}"
        }
        // android.jar marks Class.cast nullable; after the instance check it never returns null here.
        return requireNotNull(modelClass.cast(viewModel))
    }
}

/**
 * Shares a file from `<cacheDir>/exports/` through the app's FileProvider with `ACTION_SEND` and a
 * chooser, granting read permission only. Never shares a session directory file directly.
 *
 * Owner: workstream `ui-session`.
 */
object FileSharer {
    /** The only cache subdirectory `res/xml/file_paths.xml` exposes. */
    const val EXPORTS_DIR: String = "exports"

    /** The MIME type of an export zip. */
    const val ZIP_MIME_TYPE: String = "application/zip"

    /** The MIME type of a session map; Google Earth and My Maps register for it. */
    const val KML_MIME_TYPE: String = "application/vnd.google-earth.kml+xml"

    /** Matches the manifest's `${applicationId}.fileprovider`. */
    fun authority(context: Context): String = context.packageName + ".fileprovider"

    /**
     * Opens the system chooser to send [file] as [mimeType], with [subject] and optional [text] (for example
     * the zip's SHA-256). The receiving app gets read access to this one URI only.
     *
     * @throws IllegalArgumentException when [file] is not an existing file inside `<cacheDir>/exports/`.
     * @throws android.content.ActivityNotFoundException when Android has no chooser to show.
     */
    fun share(context: Context, file: File, mimeType: String, subject: String, text: String?) {
        require(isShareable(context.cacheDir, file)) { "Only files inside cache/$EXPORTS_DIR can be shared, not ${file.name}" }
        val uri = FileProvider.getUriForFile(context, authority(context), file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, subject)
            if (text != null) putExtra(Intent.EXTRA_TEXT, text)
            clipData = ClipData.newRawUri(subject, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(send, subject)
        if (context.findActivity() == null) chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(chooser)
    }

    /**
     * True when [file] is an existing regular file inside `<cacheDir>/exports/` (at any depth) after
     * resolving `..` and symbolic links, so nothing from a session directory can be shared by a crafted path.
     */
    fun isShareable(cacheDir: File, file: File): Boolean {
        val (exports, candidate) = try {
            File(cacheDir, EXPORTS_DIR).canonicalFile to file.canonicalFile
        } catch (e: IOException) {
            return false
        } catch (e: SecurityException) {
            return false
        }
        if (!candidate.isFile) return false
        var parent = candidate.parentFile
        while (parent != null) {
            if (parent == exports) return true
            parent = parent.parentFile
        }
        return false
    }
}

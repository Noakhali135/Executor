package com.executor.executor

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Base64
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Storage Access Framework support.
 *
 * A tree granted with ACTION_OPEN_DOCUMENT_TREE survives reboots and app
 * updates, needs no storage permission, and is exempt from Android 11+ scoped
 * storage restrictions. That makes it the correct way to work on a real project
 * folder (e.g. Download/rou_is-Full-Project) instead of asking for
 * "All files access".
 *
 * Because the rest of the app is built on `dart:io`, granted trees are
 * presented to Dart as a virtual directory:
 *
 *     /devrunner-saf/<treeId>/<relative path...>
 *
 * [SafFile] and [SafDirectory] make that path behave like `java.io.File`, so
 * the scanner, exporter and GitHub push code work unchanged.
 */
class SafWorkspace(private val activity: Activity) {

    companion object {
        const val VIRTUAL_ROOT = "/devrunner-saf"
        private const val REQUEST_OPEN_TREE = 0x5AF1
        private const val PREFS = "devrunner_saf"
        private const val KEY_TREES = "granted_trees"
    }

    private var pendingResult: MethodChannel.Result? = null

    private val context: Context get() = activity.applicationContext

    // ---------------------------------------------------------------- pick ----

    fun pickDirectory(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "A folder picker is already open", null)
            return
        }
        pendingResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                )
                // Ask the system picker to preselect a sensible location.
                putExtra("android.provider.extra.INITIAL_URI", Uri.parse("content://com.android.externalstorage.documents/root/primary"))
            }
            activity.startActivityForResult(intent, REQUEST_OPEN_TREE)
        } catch (e: Exception) {
            pendingResult = null
            result.error("no_picker", e.message ?: "Could not open the folder picker", null)
        }
    }

    /** Called from MainActivity.onActivityResult. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_OPEN_TREE) return
        val result = pendingResult
        pendingResult = null

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result?.success(null)
            return
        }

        try {
            // Persist across reboots: this is what makes the grant "stay"
            // instead of expiring when the app process dies.
            val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            context.contentResolver.takePersistableUriPermission(uri, flags)

            val treeId = DocumentsContract.getTreeDocumentId(uri)
            rememberTree(treeId, uri.toString())

            result?.success(
                mapOf(
                    "treeId" to treeId,
                    "virtualPath" to "$VIRTUAL_ROOT/${encodeTreeId(treeId)}",
                    "displayPath" to friendlyPath(treeId)
                )
            )
        } catch (e: Exception) {
            result?.error("grant_failed", e.message ?: "Could not persist folder access", null)
        }
    }

    // ------------------------------------------------------------- registry ----

    private fun prefs() = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun rememberTree(treeId: String, uri: String) {
        val all = prefs().getStringSet(KEY_TREES, mutableSetOf())?.toMutableSet() ?: mutableSetOf()
        all.add("$treeId|$uri")
        prefs().edit().putStringSet(KEY_TREES, all).apply()
    }

    private fun knownTrees(): List<Pair<String, Uri>> {
        val all = prefs().getStringSet(KEY_TREES, emptySet()) ?: emptySet()
        return all.mapNotNull { entry ->
            val idx = entry.indexOf('|')
            if (idx <= 0) null else entry.substring(0, idx) to Uri.parse(entry.substring(idx + 1))
        }
    }

    fun listTrees(): List<Map<String, Any>> =
        knownTrees().mapNotNull { (treeId, uri) ->
            val file = DocumentFile.fromTreeUri(context, uri) ?: return@mapNotNull null
            mapOf(
                "treeId" to treeId,
                "virtualPath" to "$VIRTUAL_ROOT/${encodeTreeId(treeId)}",
                "uri" to uri.toString(),
                "displayPath" to friendlyPath(treeId),
                "name" to (file.name ?: treeId)
            )
        }

    fun forgetTree(treeId: String) {
        val entry = knownTrees().firstOrNull { it.first == treeId } ?: return
        try {
            context.contentResolver.releasePersistableUriPermission(
                entry.second,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        } catch (_: Exception) {
        }
        val remaining = knownTrees().filter { it.first != treeId }
            .map { "${it.first}|${it.second}" }.toSet()
        prefs().edit().putStringSet(KEY_TREES, remaining).apply()
    }

    /**
     * Encodes a tree id into a single URL-safe path segment.
     *
     * Tree ids are documents ids and may contain `/`
     * (`primary:Download/rou_is-Full-Project`), so using them verbatim inside a
     * virtual path made every lookup after the first slash fail. Base64url with
     * padding stripped keeps the virtual path a valid, unambiguous segment.
     */
    private fun encodeTreeId(treeId: String): String =
        Base64.encodeToString(
            treeId.toByteArray(Charsets.UTF_8),
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
        )

    private fun decodeTreeId(segment: String): String? = try {
        String(
            Base64.decode(segment, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING),
            Charsets.UTF_8
        )
    } catch (_: Exception) {
        null
    }

    /** Turns `primary:Download/project` into `Download/project`. */
    private fun friendlyPath(treeId: String): String {
        return if (treeId.startsWith("primary:")) treeId.removePrefix("primary:")
        else treeId
    }

    // ----------------------------------------------------------- resolution ----

    /** Resolves a virtual path to a DocumentFile, or null when not granted. */
    fun resolve(virtualPath: String): DocumentFile? {
        if (!virtualPath.startsWith("$VIRTUAL_ROOT/")) return null
        val rest = virtualPath.removePrefix("$VIRTUAL_ROOT/")
        val segment = rest.substringBefore('/')
        val relative = rest.substringAfter('/', "")
        val treeId = decodeTreeId(segment) ?: return null

        val uri = knownTrees().firstOrNull { it.first == treeId }?.second ?: return null
        var current = DocumentFile.fromTreeUri(context, uri) ?: return null
        if (relative.isEmpty()) return current

        for (segment in relative.split('/')) {
            if (segment.isEmpty() || segment == "." || segment == "..") return null
            val next = current.findFile(segment) ?: return null
            current = next
        }
        return current
    }

    /**
     * Lists a whole SAF tree as flat entries.
     *
     * Returned `path` values are virtual, so the Dart side sees ordinary paths.
     */
    fun listTree(virtualPath: String, maxFiles: Int): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        val root = resolve(virtualPath) ?: return out

        fun walk(dir: DocumentFile, prefix: String, depth: Int) {
            if (out.size >= maxFiles || depth > 32) return
            val children = try {
                dir.listFiles()
            } catch (_: Exception) {
                return
            }
            for (child in children) {
                if (out.size >= maxFiles) return
                val path = if (prefix.isEmpty()) "${virtualPath}/${child.name}" else "$prefix/${child.name}"
                if (child.isDirectory) {
                    walk(child, path, depth + 1)
                } else {
                    out.add(
                        mapOf(
                            "path" to path,
                            "size" to child.length(),
                            "isDirectory" to 0
                        )
                    )
                }
            }
        }

        if (root.isDirectory) walk(root, "", 0)
        return out
    }

    /** Direct children only, for the explorer tree. */
    fun listChildren(virtualPath: String): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        val dir = resolve(virtualPath) ?: return out
        if (!dir.isDirectory) return out

        val children = try { dir.listFiles() } catch (_: Exception) { return out }
        for (child in children) {
            val name = child.name ?: continue
            val path = if (virtualPath.endsWith("/")) "$virtualPath$name" else "$virtualPath/$name"
            out.add(
                mapOf(
                    "path" to path,
                    "name" to name,
                    "isDirectory" to if (child.isDirectory) 1 else 0,
                    "size" to child.length()
                )
            )
        }
        return out
    }

    /** Creates a directory (and missing parents) inside a granted tree. */
    fun createDirectory(virtualPath: String): Boolean {
        resolveOrCreateDirectory(virtualPath)?.let { return true }
        return false
    }

    /** Deletes a file or an empty/recursive directory. */
    fun deletePath(virtualPath: String): Boolean {
        val doc = resolve(virtualPath) ?: return false
        return try {
            doc.delete()
        } catch (_: Exception) {
            false
        }
    }

    /** Reads a single SAF file by virtual path. */
    fun readFile(virtualPath: String): ByteArray? {
        val doc = resolve(virtualPath) ?: return null
        return try {
            context.contentResolver.openInputStream(doc.uri)?.use { it.readBytes() }
        } catch (_: Exception) {
            null
        }
    }

    /** Writes bytes to a SAF file, creating it when missing. */
    fun writeFile(virtualPath: String, bytes: ByteArray): Boolean {
        val parentPath = virtualPath.substringBeforeLast('/', "")
        val name = virtualPath.substringAfterLast('/')
        if (name.isEmpty()) return false

        val parentVirtual = if (parentPath.isEmpty()) VIRTUAL_ROOT else parentPath
        val parent = resolveOrCreateDirectory(parentVirtual) ?: return false
        val existing = parent.findFile(name)
        // "text/plain" keeps the original name; application/octet-stream makes
        // some providers append a .bin extension.
        val target = existing ?: parent.createFile("text/plain", name) ?: return false

        return try {
            context.contentResolver.openOutputStream(target.uri, "wt")?.use {
                it.write(bytes)
                it.flush()
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun resolveOrCreateDirectory(virtualPath: String): DocumentFile? {
        resolve(virtualPath)?.let { return it }
        if (!virtualPath.startsWith("$VIRTUAL_ROOT/")) return null

        val rest = virtualPath.removePrefix("$VIRTUAL_ROOT/")
        val segment = rest.substringBefore('/')
        val relative = rest.substringAfter('/', "")
        val treeId = decodeTreeId(segment) ?: return null
        val uri = knownTrees().firstOrNull { it.first == treeId }?.second ?: return null

        var current = DocumentFile.fromTreeUri(context, uri) ?: return null
        if (relative.isEmpty()) return current

        for (segment in relative.split('/')) {
            if (segment.isEmpty()) continue
            current = current.findFile(segment)
                ?: current.createDirectory(segment)
                ?: return null
        }
        return current
    }

    /** Convenience for Dart: is this virtual path granted and readable? */
    fun describe(virtualPath: String): Map<String, Any>? {
        val doc = resolve(virtualPath) ?: return null
        return mapOf(
            "name" to (doc.name ?: ""),
            "isDirectory" to if (doc.isDirectory) 1 else 0,
            "size" to doc.length()
        )
    }

}

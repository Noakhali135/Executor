package com.executor.executor

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Base64
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
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
 * [resolve] turns such a path back into a DocumentFile, so the scanner,
 * exporter and GitHub push code work unchanged.
 */
class SafWorkspace(private val activity: Activity) {

    companion object {
        /**
         * Directories that are never worth pushing. Matches
         * `kIgnoredDirectoryNames` in `workspace_probe.dart`.
         */
        private val IGNORED_DIRS = setOf(
            ".git", ".dart_tool", "build", "node_modules", ".gradle", ".idea",
            ".vscode", "__pycache__", ".venv", "venv", "Pods", ".next", ".cache"
        )

        private const val CACHE_LIMIT = 20000

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

    /**
     * File path -> DocumentFile, filled by the tree walk.
     *
     * The walk already holds a DocumentFile for every entry, but it used to be
     * thrown away and every later operation (hashing, reading) re-derived it
     * from the path with `findFile()` per segment. Each of those is a provider
     * query that lists the whole parent directory, so hashing a project cost
     * one directory listing per file per level. Caching turns that back into
     * the single listing the walk already paid for.
     *
     * Entries are dropped by [invalidateCache] on write/delete/create, and the
     * cache is bounded so a huge project cannot pin memory.
     */
    private val documentCache = HashMap<String, DocumentFile>()
    private val documentCacheLock = Any()

    private fun remember(path: String, doc: DocumentFile) {
        synchronized(documentCacheLock) {
            if (documentCache.size >= CACHE_LIMIT) documentCache.clear()
            documentCache[path] = doc
        }
    }

    private fun recall(path: String): DocumentFile? =
        synchronized(documentCacheLock) { documentCache[path] }

    /** Forgets cached handles below [path] after the tree changed. */
    private fun invalidateCache(path: String) {
        synchronized(documentCacheLock) {
            val prefix = if (path.endsWith("/")) path else "$path/"
            documentCache.keys.removeAll { it == path || it.startsWith(prefix) }
        }
    }

    @Volatile
    private var cancelled = false

    fun resetCancellation() {
        cancelled = false
    }

    fun cancel() {
        cancelled = true
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

        // Fast path: the tree walk already handed us this exact handle.
        recall(virtualPath)?.let { return it }

        val rest = virtualPath.removePrefix("$VIRTUAL_ROOT/")
        val segment = rest.substringBefore('/')
        val relative = rest.substringAfter('/', "")
        val treeId = decodeTreeId(segment) ?: return null

        val uri = knownTrees().firstOrNull { it.first == treeId }?.second ?: return null
        var current = DocumentFile.fromTreeUri(context, uri) ?: return null
        if (relative.isEmpty()) return current

        val parts = relative.split('/').filter { it.isNotEmpty() }
        for ((index, part) in parts.withIndex()) {
            if (part == "." || part == "..") return null
            // Cache keys are the full virtual path (that is what the walk
            // stored), so rebuild it as we descend. A hit here skips a
            // findFile() - and findFile() lists the entire parent directory.
            val key = "$VIRTUAL_ROOT/$segment/" + parts.subList(0, index + 1).joinToString("/")
            val next = recall(key) ?: current.findFile(part) ?: return null
            current = next
        }
        return current
    }

    /**
     * Lists a whole SAF tree as flat entries.
     *
     * Returned `path` values are virtual, so the Dart side sees ordinary paths.
     */
    /**
     * Every file below [virtualPath].
     *
     * Two things keep a real Flutter project from killing the app: directories
     * that are never pushable (`build`, `.dart_tool`, `.git`, ...) are skipped
     * before they are opened, and [onProgress] reports a heartbeat so the UI can
     * show that work is happening. [cancelled] is checked per directory so a
     * cancelled scan finishes promptly instead of walking everything.
     */
    fun listTree(
        virtualPath: String,
        maxFiles: Int,
        onProgress: (scanned: Int, dirs: Int) -> Unit = { _, _ -> }
    ): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        val root = resolve(virtualPath) ?: return out
        var dirs = 0

        fun walk(dir: DocumentFile, prefix: String, depth: Int) {
            if (out.size >= maxFiles || depth > 32 || cancelled) return
            dirs++
            // One callback per directory, not per file: cheap to marshal.
            if (dirs % 25 == 0) onProgress(out.size, dirs)

            val children = try {
                dir.listFiles()
            } catch (_: Exception) {
                return
            }
            for (child in children) {
                if (out.size >= maxFiles || cancelled) return
                val name = child.name ?: continue
                val path = if (prefix.isEmpty()) "${virtualPath}/${name}" else "$prefix/${name}"
                if (child.isDirectory) {
                    if (name in IGNORED_DIRS) continue
                    remember(path, child)
                    walk(child, path, depth + 1)
                } else {
                    // length() is a ContentProvider query per file, and so is
                    // every later lookup of this path. Report "unknown" size and
                    // keep the handle the walk already has.
                    remember(path, child)
                    out.add(
                        mapOf<String, Any>(
                            "path" to path,
                            "size" to -1,
                            "isDirectory" to false
                        )
                    )
                }
            }
        }

        if (root.isDirectory) walk(root, "", 0)
        onProgress(out.size, dirs)
        return out
    }

    /**
     * Git blob SHA-1 for each path, computed natively.
     *
     * Hashing used to pull every file's bytes across the platform channel only
     * to throw them away, which dominated both time and peak memory on a real
     * project. Streaming through MessageDigest here keeps nothing in memory.
     */
    fun hashFiles(
        paths: List<String>,
        onProgress: (done: Int, total: Int) -> Unit = { _, _ -> }
    ): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>(paths.size)
        for ((index, path) in paths.withIndex()) {
            if (cancelled) break
            val file = resolve(path)
            // "" means "could not hash"; the Dart side treats it as changed.
            val sha = if (file == null || !file.isFile) {
                ""
            } else {
                try {
                    blobSha(file) ?: ""
                } catch (_: Exception) {
                    ""
                }
            }
            out.add(mapOf<String, Any>("path" to path, "sha" to sha))
            // Report every file: the UI bar is otherwise dead for the whole
            // hashing pass, which is the longest phase on a large project.
            if (index % 5 == 0 || index == paths.lastIndex) {
                onProgress(index + 1, paths.size)
            }
        }
        onProgress(out.size, paths.size)
        return out
    }

    /**
     * Git's object id for a file: sha1("blob <len>\u0000" + content).
     *
     * Falls back to a buffered stream when the provider does not support
     * seeking or reporting a length.
     */
    private fun blobSha(file: DocumentFile): String? {
        val uri = file.uri
        val declared = file.length()

        // Git's id is sha1("blob <len>\0" + content), so the length must be
        // right. Rather than trusting the provider (some report -1 or 0) and
        // possibly re-reading the whole file to recover, measure while hashing
        // and fix the header from the buffer if it disagreed.
        val buffer = java.io.ByteArrayOutputStream()
        var actual = 0L
        val opened = context.contentResolver.openInputStream(uri) ?: return null
        opened.use { input ->
            val chunk = ByteArray(64 * 1024)
            while (true) {
                if (cancelled) return null
                val read = input.read(chunk)
                if (read <= 0) break
                buffer.write(chunk, 0, read)
                actual += read
            }
        }

        val length = if (declared >= 0 && declared == actual) declared else actual
        val digest = java.security.MessageDigest.getInstance("SHA-1")
        digest.update("blob $length\u0000".toByteArray(Charsets.UTF_8))
        digest.update(buffer.toByteArray())
        buffer.reset()
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    fun listChildren(virtualPath: String): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        val dir = resolve(virtualPath) ?: return out
        if (!dir.isDirectory) return out

        val children = try { dir.listFiles() } catch (_: Exception) { return out }
        for (child in children) {
            val name = child.name ?: continue
            val path = if (virtualPath.endsWith("/")) "$virtualPath$name" else "$virtualPath/$name"
            // Explicit <String, Any>: the prefix "path"/"name" match String but
            // the 1/0 and length values would otherwise widen the value type.
            out.add(
                mapOf<String, Any>(
                    "path" to path,
                    "name" to name,
                    "isDirectory" to child.isDirectory,
                    "size" to child.length()
                )
            )
        }
        return out
    }

    /** Creates a directory (and missing parents) inside a granted tree. */
    fun createDirectory(virtualPath: String): Boolean {
        val created = resolveOrCreateDirectory(virtualPath)?.let { true } ?: false
        if (created) invalidateCache(virtualPath.substringBeforeLast('/', ""))
        return created
    }

    /** Deletes a file or an empty/recursive directory. */
    fun deletePath(virtualPath: String): Boolean {
        val doc = resolve(virtualPath) ?: return false
        val deleted = try {
            doc.delete()
        } catch (_: Exception) {
            false
        }
        if (deleted) invalidateCache(virtualPath)
        return deleted
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

        val written = try {
            context.contentResolver.openOutputStream(target.uri, "wt")?.use {
                it.write(bytes)
                it.flush()
            }
            true
        } catch (_: Exception) {
            false
        }
        // A provider may replace the document on write; drop stale handles.
        if (written) invalidateCache(virtualPath)
        return written
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
        // Booleans, not 0/1: the Dart side reads these as `bool?`.
        return mapOf<String, Any>(
            "name" to (doc.name ?: ""),
            "isDirectory" to doc.isDirectory,
            "size" to doc.length()
        )
    }

}

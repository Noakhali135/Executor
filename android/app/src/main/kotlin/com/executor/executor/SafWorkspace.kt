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

        /**
         * Extensions a ContentProvider appends when the MIME type disagrees with
         * the file name. Older builds created files as `text/plain`, so
         * `main.py` landed on disk as `main.py.txt`; those files must still be
         * found and replaced rather than duplicated as `main (1).py.txt`.
         */
        private val PROVIDER_APPENDED_EXTENSIONS = listOf(".txt", ".bin")

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
    ): Map<String, Any> {
        val files = ArrayList<Map<String, Any>>()
        val errors = ArrayList<String>()
        var dirs = 0
        var unreadable = 0

        // A null root means the grant is gone or the folder was moved. That is
        // not "this folder is empty", so say which one it is.
        val root = resolve(virtualPath)
        if (root == null) {
            return mapOf(
                "files" to files,
                "dirs" to 0,
                "unreadable" to 1,
                "errors" to listOf(
                    "The folder could not be opened. Its grant may have been " +
                        "revoked - pick it again with \"Pick a folder\"."
                )
            )
        }
        if (!root.isDirectory) {
            return mapOf(
                "files" to files,
                "dirs" to 0,
                "unreadable" to 1,
                "errors" to listOf("The selected item is a file, not a folder.")
            )
        }

        fun walk(dir: DocumentFile, prefix: String, depth: Int) {
            if (files.size >= maxFiles || depth > 32 || cancelled) return
            dirs++
            // One callback per directory, not per file: cheap to marshal.
            if (dirs % 25 == 0) onProgress(files.size, dirs)

            val children = try {
                dir.listFiles()
            } catch (e: Exception) {
                // Swallowing this used to turn a permission problem into
                // "the folder contains no readable files", which sent the user
                // looking for a problem that was not there.
                unreadable++
                if (errors.size < 5) {
                    val where = if (prefix.isEmpty()) virtualPath else prefix
                    errors.add("Could not read ${where.removePrefix("$VIRTUAL_ROOT/")}: " +
                        (e.message ?: e.javaClass.simpleName))
                }
                return
            }

            for (child in children) {
                if (files.size >= maxFiles || cancelled) return
                val name = child.name ?: continue
                val path = if (prefix.isEmpty()) "${virtualPath}/${name}" else "$prefix/${name}"
                if (child.isDirectory) {
                    // Checked before recursing, so node_modules/build cost one
                    // entry here instead of thousands of provider queries.
                    if (name in IGNORED_DIRS) continue
                    remember(path, child)
                    walk(child, path, depth + 1)
                } else {
                    // length() is a ContentProvider query per file, and so is
                    // every later lookup of this path. Report "unknown" size and
                    // keep the handle the walk already has.
                    remember(path, child)
                    files.add(
                        mapOf<String, Any>(
                            "path" to path,
                            "size" to -1,
                            "isDirectory" to false
                        )
                    )
                }
            }
        }

        walk(root, "", 0)
        onProgress(files.size, dirs)
        return mapOf(
            "files" to files,
            "dirs" to dirs,
            "unreadable" to unreadable,
            "errors" to errors
        )
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
        val parentPath = virtualPath.substringBeforeLast('/', "")
        val name = virtualPath.substringAfterLast('/')
        val doc = resolve(virtualPath) ?: run {
            val parentVirtual = if (parentPath.isEmpty()) VIRTUAL_ROOT else parentPath
            val parent = resolve(parentVirtual) ?: return false
            findChild(parent, name) ?: return false
        }
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

    /**
     * MIME type for a file, chosen so the provider keeps the name you asked for.
     *
     * This matters more than it looks. `DocumentFile.createFile("text/plain",
     * "main.py")` does not create `main.py`: the provider appends an extension
     * for the MIME type, so the file becomes `main.py.txt`. The display name is
     * the thing that must win, so the MIME is derived from the name.
     */
    private fun mimeFor(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
        "py" -> "text/x-python"
        "js" -> "application/javascript"
        "mjs", "cjs" -> "application/javascript"
        "ts" -> "application/typescript"
        "tsx" -> "application/typescript"
        "jsx" -> "application/javascript"
        "json" -> "application/json"
        "kt", "kts" -> "text/x-kotlin"
        "java" -> "text/x-java-source"
        "dart" -> "text/x-dart"
        "yaml", "yml" -> "text/yaml"
        "toml", "ini" -> "text/plain"
        "md" -> "text/markdown"
        "xml" -> "text/xml"
        "html", "htm" -> "text/html"
        "css" -> "text/css"
        "csv" -> "text/csv"
        "sh" -> "application/x-sh"
        "gradle" -> "text/x-gradle"
        "txt", "text", "log", "" -> "text/plain"
        else -> "application/octet-stream"
    }

    /**
     * Finds an existing child by name, tolerating a provider-mangled name.
     *
     * `findFile` is an exact match. A file written by an earlier build may be
     * stored as `main.py.txt`, and an exact match misses it - which is how a
     * re-run created `main (1).py` instead of overwriting the file.
     */
    private fun findChild(parent: DocumentFile, name: String): DocumentFile? {
        // Exact name first: a real `main.py` always wins over a leftover.
        parent.findFile(name)?.let { return it }

        val children = try {
            parent.listFiles()
        } catch (_: Exception) {
            return null
        }
        // Only the suffixes a provider itself appends are treated as the same
        // file. Accepting any `name.*` would redirect a write onto a genuine
        // `main.py.bak` and silently destroy it.
        return children
            .filter { child ->
                val childName = child.name ?: return@filter false
                child.isFile && PROVIDER_APPENDED_EXTENSIONS.any { childName == "$name$it" }
            }
            .minByOrNull { it.name?.length ?: Int.MAX_VALUE }
    }

    /**
     * Writes bytes to a SAF file, replacing its contents when it exists.
     *
     * Resolution order for the existing file is deliberate:
     *
     *  1. by document id, which cannot be fooled by name mangling;
     *  2. by exact name;
     *  3. anything in the folder whose id prefix matches the name, which is how
     *     a file written by an earlier build survives as `main.py.txt` - it is
     *     overwritten in place instead of producing `main (1).py.txt`;
     *  4. create it, with the right MIME so the name is not mangled again.
     */
    fun writeFile(virtualPath: String, bytes: ByteArray): Boolean {
        val parentPath = virtualPath.substringBeforeLast('/', "")
        val name = virtualPath.substringAfterLast('/')
        if (name.isEmpty()) return false

        val parentVirtual = if (parentPath.isEmpty()) VIRTUAL_ROOT else parentPath
        val parent = resolveOrCreateDirectory(parentVirtual) ?: return false

        // Existing file, by id, by exact name, or by the mangled name an older
        // build produced. `val`, because a captured local cannot rely on the
        // smart cast a `var` would need.
        val target: DocumentFile = resolve(virtualPath)
            ?: findChild(parent, name)
            // Create with a name-derived MIME so the provider does not append
            // ".txt" to "main.py".
            ?: parent.createFile(mimeFor(name), name)
            ?: return false

        // "wt" truncates. Without it a shorter body would leave the tail of the
        // previous, longer file behind.
        val written = try {
            val stream = context.contentResolver.openOutputStream(target.uri, "wt")
            if (stream == null) {
                false
            } else {
                stream.use {
                    it.write(bytes)
                    it.flush()
                }
                true
            }
        } catch (_: Exception) {
            false
        }

        // Writing may replace the document, so a cached handle can go stale.
        invalidateCache(virtualPath)
        if (!written) return false

        // A wrong extension cannot be renamed through DocumentFile, but it can
        // be renamed through DocumentsContract - and a file that came back as
        // "main.py.txt" would be invisible to the next write without it.
        renameIfProviderMangled(target, name)
        return true
    }

    /** Renames `main.py.txt` back to `main.py` when the provider added a suffix. */
    private fun renameIfProviderMangled(doc: DocumentFile, desired: String) {
        val actual = doc.name ?: return
        if (actual == desired) return
        // Only correct the specific damage a provider adds ("main.py" became
        // "main.py.txt"). A file the user genuinely named differently is left
        // alone, so this can never clobber an unrelated file.
        if (PROVIDER_APPENDED_EXTENSIONS.none { actual == "$desired$it" }) return
        try {
            DocumentsContract.renameDocument(context.contentResolver, doc.uri, desired)
        } catch (_: Exception) {
            // Not fatal: the content is correct, only the name is longer.
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
        // Booleans, not 0/1: the Dart side reads these as `bool?`.
        return mapOf<String, Any>(
            "name" to (doc.name ?: ""),
            "isDirectory" to doc.isDirectory,
            "size" to doc.length()
        )
    }

}

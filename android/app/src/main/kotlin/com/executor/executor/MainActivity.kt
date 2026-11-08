package com.executor.executor

import android.content.ContentUris
import android.content.Intent
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Single FlutterActivity.
 *
 * The previous version of this project also contained a stray file named
 * "(invalid)" in the app source set which declared a second
 * `object GlobalScope` in this package. Because that file was compiled too,
 * the app failed to build/run with "redeclaration of GlobalScope". It has been
 * removed; this is now the only class in the package.
 *
 * Besides diagnostics, this exposes a MediaStore reader. On Android 11+ scoped
 * storage can expose a folder's *name* to `dart:io` while denying access to the
 * files inside it (e.g. anything under Download that the app did not create).
 * MediaStore indexes those files, so this is the only way to read them without
 * "All files access".
 */
class MainActivity : FlutterActivity() {

    private val channelName = "devrunner/native"

    private lateinit var saf: SafWorkspace

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        saf = SafWorkspace(this)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // The SAF picker resolves through here before Flutter sees anything.
        if (::saf.isInitialized) saf.onActivityResult(requestCode, resultCode, data)
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "sdkInt" -> result.success(Build.VERSION.SDK_INT)

                    "isWithinRoot" -> {
                        val root = call.argument<String>("root")
                        val target = call.argument<String>("target")
                        if (root == null || target == null) {
                            result.error("bad_args", "root and target are required", null)
                        } else {
                            result.success(isWithinRoot(root, target))
                        }
                    }

                    "listMediaStoreFiles" -> {
                        val path = call.argument<String>("path")
                        val maxFiles = call.argument<Int>("maxFiles") ?: 5000
                        if (path == null) {
                            result.error("bad_args", "path is required", null)
                        } else {
                            result.success(listFiles(path, maxFiles))
                        }
                    }

                    "readMediaStoreFile" -> {
                        val id = call.argument<Number>("id")?.toLong()
                        if (id == null) {
                            result.error("bad_args", "id is required", null)
                        } else {
                            val bytes = readFile(id)
                            if (bytes == null) {
                                result.error("not_found", "Could not read media item $id", null)
                            } else {
                                result.success(bytes)
                            }
                        }
                    }

                    // ---- Storage Access Framework -----------------------
                    "pickDirectory" -> saf.pickDirectory(result)

                    "listGrantedTrees" -> result.success(saf.listTrees())

                    "forgetTree" -> {
                        val treeId = call.argument<String>("treeId")
                        if (treeId == null) {
                            result.error("bad_args", "treeId is required", null)
                        } else {
                            saf.forgetTree(treeId)
                            result.success(true)
                        }
                    }

                    "listSafFiles" -> {
                        val path = call.argument<String>("path")
                        val maxFiles = call.argument<Int>("maxFiles") ?: 5000
                        if (path == null) {
                            result.error("bad_args", "path is required", null)
                        } else {
                            result.success(saf.listTree(path, maxFiles))
                        }
                    }

                    "readSafFile" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path is required", null)
                        } else {
                            val bytes = saf.readFile(path)
                            if (bytes == null) {
                                result.error("not_found", "Could not read $path", null)
                            } else {
                                result.success(bytes)
                            }
                        }
                    }

                    "writeSafFile" -> {
                        val path = call.argument<String>("path")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (path == null || bytes == null) {
                            result.error("bad_args", "path and bytes are required", null)
                        } else {
                            result.success(saf.writeFile(path, bytes))
                        }
                    }

                    "listSafChildren" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path is required", null)
                        } else {
                            result.success(saf.listChildren(path))
                        }
                    }

                    "createSafDirectory" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path is required", null)
                        } else {
                            result.success(saf.createDirectory(path))
                        }
                    }

                    "deleteSafPath" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path is required", null)
                        } else {
                            result.success(saf.deletePath(path))
                        }
                    }

                    "safDescribe" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path is required", null)
                        } else {
                            result.success(saf.describe(path))
                        }
                    }

                    else -> result.notImplemented()
                }
            } catch (e: SecurityException) {
                result.error("permission_denied", e.message ?: "Permission denied", null)
            } catch (e: Exception) {
                result.error("failure", e.message ?: e.toString(), null)
            }
        }
    }

    /** True when [target] is a strict descendant of [root] after canonicalising. */
    private fun isWithinRoot(root: String, target: String): Boolean {
        return try {
            val rootFile = File(root).canonicalFile
            val targetFile = File(target).canonicalFile
            targetFile.path.startsWith(rootFile.path + File.separator)
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Lists files below [absolutePath] using MediaStore.
     *
     * Directories are deliberately *not* expanded here: MediaStore returns a
     * flat list, so the caller gets every file under the folder in one pass.
     */
    private fun listFiles(absolutePath: String, maxFiles: Int): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return out

        val normalized = absolutePath.trimEnd('/')

        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DATA,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.DISPLAY_NAME
        )

        // Match the folder and everything below it.
        val selection = "${MediaStore.Files.FileColumns.DATA} LIKE ?"
        val args = arrayOf("$normalized/%")

        val uri = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)

        contentResolver.query(
            uri,
            projection,
            selection,
            args,
            "${MediaStore.Files.FileColumns.DATA} ASC"
        )?.use { cursor ->
            val idIdx = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val dataIdx = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATA)
            val sizeIdx = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)

            while (cursor.moveToNext() && out.size < maxFiles) {
                val data = cursor.getString(dataIdx) ?: continue
                out.add(
                    mapOf(
                        "path" to data,
                        "id" to cursor.getLong(idIdx),
                        "size" to cursor.getLong(sizeIdx),
                        "isDirectory" to 0
                    )
                )
            }
        }
        return out
    }

    /** Reads the bytes of one media item. */
    private fun readFile(id: Long): ByteArray? {
        return try {
            val uri = ContentUris.withAppendedId(
                MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
                id
            )
            contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (_: Exception) {
            null
        }
    }
}

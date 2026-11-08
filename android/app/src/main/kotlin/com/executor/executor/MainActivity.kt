package com.executor.executor

import android.content.Intent
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
 * Folder access is handled entirely by [SafWorkspace] (Storage Access
 * Framework). No storage permission is requested, and files outside a granted
 * folder are never touched.
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
                    "isWithinRoot" -> {
                        val root = call.argument<String>("root")
                        val target = call.argument<String>("target")
                        if (root == null || target == null) {
                            result.error("bad_args", "root and target are required", null)
                        } else {
                            result.success(isWithinRoot(root, target))
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
}

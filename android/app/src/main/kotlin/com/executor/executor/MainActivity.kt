package com.executor.executor

import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

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

    /**
     * SAF work runs here, never on the UI thread.
     *
     * Walking a real project means thousands of DocumentFile calls, each a
     * ContentProvider round trip. On the main thread that tripped Android's
     * "app not responding" watchdog and the process was killed mid-push.
     */
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private var progressSink: EventChannel.EventSink? = null

    /** Throttled scan progress; the UI needs a heartbeat, not every file. */
    private fun emitProgress(scanned: Int, dirs: Int) {
        main.post {
            progressSink?.success(mapOf("type" to "scan", "scanned" to scanned, "dirs" to dirs))
        }
    }

    private fun emitHashProgress(done: Int, total: Int) {
        main.post {
            progressSink?.success(mapOf("type" to "hash", "done" to done, "total" to total))
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        saf = SafWorkspace(this)
    }

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }

    /**
     * Runs [work] on the worker thread and reports back on the UI thread.
     *
     * `MethodChannel.Result` may only be touched on the main thread, hence the
     * post back. Any cancellation request is cleared first so one cancelled
     * operation cannot poison the next one.
     */
    private fun runAsync(result: MethodChannel.Result, work: () -> Any?) {
        saf.resetCancellation()
        worker.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: SecurityException) {
                main.post { result.error("permission_denied", e.message ?: "Permission denied", null) }
            } catch (e: Exception) {
                main.post { result.error("failure", e.message ?: e.toString(), null) }
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // The SAF picker resolves through here before Flutter sees anything.
        if (::saf.isInitialized) saf.onActivityResult(requestCode, resultCode, data)
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "devrunner/saf_progress"
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                progressSink = events
            }

            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    // ---- Storage Access Framework -----------------------
                    "pickDirectory" -> saf.pickDirectory(result)

                    "listGrantedTrees" -> runAsync(result) { saf.listTrees() }

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
                            runAsync(result) {
                                saf.listTree(path, maxFiles) { scanned, dirs ->
                                    emitProgress(scanned, dirs)
                                }
                            }
                        }
                    }

                    "hashSafFiles" -> {
                        val paths = call.argument<List<String>>("paths")
                        if (paths == null) {
                            result.error("bad_args", "paths is required", null)
                        } else {
                            runAsync(result) {
                                saf.hashFiles(paths) { done, total ->
                                    emitHashProgress(done, total)
                                }
                            }
                        }
                    }

                    "cancelSafOp" -> {
                        saf.cancel()
                        result.success(true)
                    }

                    "readSafFile" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path is required", null)
                        } else {
                            runAsync(result) {
                                saf.readFile(path)
                                    ?: throw IllegalStateException("Could not read $path")
                            }
                        }
                    }

                    "writeSafFile" -> {
                        val path = call.argument<String>("path")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (path == null || bytes == null) {
                            result.error("bad_args", "path and bytes are required", null)
                        } else {
                            runAsync(result) { saf.writeFile(path, bytes) }
                        }
                    }

                    "listSafChildren" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path is required", null)
                        } else {
                            runAsync(result) { saf.listChildren(path) }
                        }
                    }

                    "createSafDirectory" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path is required", null)
                        } else {
                            runAsync(result) { saf.createDirectory(path) }
                        }
                    }

                    "deleteSafPath" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path is required", null)
                        } else {
                            runAsync(result) { saf.deletePath(path) }
                        }
                    }

                    "safDescribe" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path is required", null)
                        } else {
                            runAsync(result) { saf.describe(path) }
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
}

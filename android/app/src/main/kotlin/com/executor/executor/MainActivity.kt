package com.executor.executor

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
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Lightweight diagnostics + a hard guarantee that the HTML preview only
        // ever serves files from inside the selected workspace. The Dart side
        // enforces this as well; this is defence in depth for the native layer.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "devrunner/native"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isWithinRoot" -> {
                    val root = call.argument<String>("root")
                    val target = call.argument<String>("target")
                    if (root == null || target == null) {
                        result.error("bad_args", "root and target are required", null)
                        return@setMethodCallHandler
                    }
                    result.success(isWithinRoot(root, target))
                }
                else -> result.notImplemented()
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

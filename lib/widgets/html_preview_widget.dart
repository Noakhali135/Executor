import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';
import '../services/path_guard.dart';

/// Renders an HTML file in a WebView.
///
/// The page is served from a loopback-only HTTP server so that relative
/// `./style.css` / `./app.js` references resolve. That server is deliberately
/// locked down:
///
///  * bound to `InternetAddress.loopbackIPv4` only (never 0.0.0.0),
///  * every request must carry a loopback `Host` header, which defeats DNS
///    rebinding attacks from other apps / browsers on the device,
///  * `..` segments and any path resolving outside the file's directory are
///    rejected with 403,
///  * no `Access-Control-Allow-Origin` wildcard is sent,
///  * unsaved editor content is served for the entry document.
class HtmlPreviewWidget extends StatefulWidget {
  final String htmlContent;
  final String baseDir;
  final String fileName;

  const HtmlPreviewWidget({
    super.key,
    required this.htmlContent,
    required this.baseDir,
    required this.fileName,
  });

  @override
  State<HtmlPreviewWidget> createState() => _HtmlPreviewWidgetState();
}

class _HtmlPreviewWidgetState extends State<HtmlPreviewWidget> {
  HttpServer? _localServer;
  int? _serverPort;
  /// Created eagerly in the field initializer: a `late final` assigned inside
  /// initState would throw `LateInitializationError` from build(), _reloadPage
  /// or the copy button if anything read it before that assignment ran.
  final WebViewController _webViewController = WebViewController();
  bool _isLoadingWeb = true;

  @override
  void initState() {
    super.initState();
    _initWebViewController();
    _startLocalServerAndLoad();
  }

  void _initWebViewController() {
    _webViewController
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF070B14))
      ..setNavigationDelegate(
        NavigationDelegate(
          // Block navigation away from the loopback preview (e.g. a link in the
          // previewed page silently replacing the app view).
          onNavigationRequest: (NavigationRequest request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.prevent;
            if (uri.scheme == 'http' && _isLoopbackHost(uri.host)) {
              return NavigationDecision.navigate;
            }
            if (uri.scheme == 'about' || uri.scheme == 'data') {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
          onPageStarted: (String url) {
            if (mounted) setState(() => _isLoadingWeb = true);
          },
          onPageFinished: (String url) {
            if (mounted) setState(() => _isLoadingWeb = false);
          },
          onWebResourceError: (WebResourceError error) {
            if (mounted) setState(() => _isLoadingWeb = false);
          },
        ),
      );
  }

  static bool _isLoopbackHost(String host) =>
      host == '127.0.0.1' || host == 'localhost' || host == '::1';

  bool _hasLoopbackHostHeader(HttpRequest request) {
    final host = request.headers.value(HttpHeaders.hostHeader);
    if (host == null) return false;
    final hostOnly = host.startsWith('[')
        ? host.substring(0, host.indexOf(']') + 1)
        : host.split(':').first;
    return _isLoopbackHost(hostOnly.replaceAll('[', '').replaceAll(']', ''));
  }

  Future<void> _startLocalServerAndLoad() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _localServer = server;
      _serverPort = server.port;

      final root = PathGuard.normalizeRoot(widget.baseDir);

      server.listen((HttpRequest request) async {
        try {
          // Reject requests whose Host header is not loopback (DNS rebinding).
          if (!_hasLoopbackHostHeader(request)) {
            request.response.statusCode = HttpStatus.forbidden;
            request.response.write('Forbidden');
            await request.response.close();
            return;
          }

          if (request.method != 'GET' && request.method != 'HEAD') {
            request.response.statusCode = HttpStatus.methodNotAllowed;
            await request.response.close();
            return;
          }

          final rawPath = Uri.decodeComponent(
            request.uri.path.replaceFirst(RegExp(r'^/+'), ''),
          );

          // Traversal attempts are refused outright.
          if (PathGuard.containsTraversal(rawPath)) {
            request.response.statusCode = HttpStatus.forbidden;
            request.response.write('Forbidden: path traversal');
            await request.response.close();
            return;
          }

          final isEntryDocument = rawPath.isEmpty || rawPath == widget.fileName;

          // Serve the live editor buffer for the entry document so unsaved
          // edits are visible in the preview.
          if (isEntryDocument) {
            request.response.headers.set(
              HttpHeaders.contentTypeHeader,
              'text/html; charset=utf-8',
            );
            request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
            request.response.write(widget.htmlContent);
            await request.response.close();
            return;
          }

          final targetPath = p.normalize(p.join(root, rawPath));
          if (!PathGuard.isInside(root, targetPath)) {
            request.response.statusCode = HttpStatus.forbidden;
            request.response.write('Forbidden: outside preview directory');
            await request.response.close();
            return;
          }

          final file = File(targetPath);
          if (await file.exists()) {
            request.response.headers.set(
              HttpHeaders.contentTypeHeader,
              _contentTypeFor(file.path),
            );
            request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
            await file.openRead().pipe(request.response);
          } else {
            request.response.statusCode = HttpStatus.notFound;
            request.response.write('Not found');
            await request.response.close();
          }
        } catch (_) {
          try {
            request.response.statusCode = HttpStatus.internalServerError;
            await request.response.close();
          } catch (_) {}
        }
      });

      final localUrl = 'http://127.0.0.1:${server.port}/';
      await _webViewController.loadRequest(Uri.parse(localUrl));
      if (mounted) setState(() {});
    } catch (_) {
      await _webViewController.loadHtmlString(widget.htmlContent);
      if (mounted) setState(() {});
    }
  }

  static String _contentTypeFor(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.html':
      case '.htm':
        return 'text/html; charset=utf-8';
      case '.css':
        return 'text/css; charset=utf-8';
      case '.js':
      case '.mjs':
        return 'application/javascript; charset=utf-8';
      case '.json':
        return 'application/json; charset=utf-8';
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.gif':
        return 'image/gif';
      case '.svg':
        return 'image/svg+xml';
      case '.webp':
        return 'image/webp';
      case '.ico':
        return 'image/x-icon';
      case '.woff':
        return 'font/woff';
      case '.woff2':
        return 'font/woff2';
      case '.txt':
      case '.md':
        return 'text/plain; charset=utf-8';
      default:
        return 'application/octet-stream';
    }
  }

  @override
  void didUpdateWidget(covariant HtmlPreviewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.htmlContent != widget.htmlContent) {
      _reloadPage();
    }
  }

  @override
  void dispose() {
    _localServer?.close(force: true);
    super.dispose();
  }

  void _copyServerUrl() {
    if (_serverPort == null) return;
    final url = 'http://127.0.0.1:$_serverPort/';
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied: $url'),
        backgroundColor: const Color(0xFF10B981),
        duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _reloadPage() {
    if (_serverPort != null) {
      _webViewController.reload();
    } else {
      _webViewController.loadHtmlString(widget.htmlContent);
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayUrl = _serverPort != null
        ? 'http://127.0.0.1:$_serverPort/${widget.fileName}'
        : 'about:blank';

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: const BoxDecoration(
            color: Color(0xFF0F1523),
            border: Border(bottom: BorderSide(color: Color(0xFF1E293B))),
          ),
          child: Row(
            children: [
              const Icon(Icons.language_rounded, size: 15, color: Color(0xFF38BDF8)),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF070B14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF1E293B)),
                  ),
                  child: Text(
                    displayUrl,
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              InkWell(
                onTap: _reloadPage,
                borderRadius: BorderRadius.circular(6),
                child: const Padding(
                  padding: EdgeInsets.all(5),
                  child: Icon(Icons.refresh_rounded, size: 16, color: Color(0xFFCBD5E1)),
                ),
              ),
              InkWell(
                onTap: _copyServerUrl,
                borderRadius: BorderRadius.circular(6),
                child: const Padding(
                  padding: EdgeInsets.all(5),
                  child: Icon(Icons.copy_rounded, size: 15, color: Color(0xFFCBD5E1)),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              WebViewWidget(controller: _webViewController),
              if (_isLoadingWeb)
                const Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF818CF8),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

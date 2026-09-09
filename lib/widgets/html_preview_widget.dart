import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';

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
  late final WebViewController _webViewController;
  bool _isLoadingWeb = true;

  @override
  void initState() {
    super.initState();
    _initWebViewController();
    _startLocalServerAndLoad();
  }

  void _initWebViewController() {
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF070B14))
      ..setNavigationDelegate(
        NavigationDelegate(
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

  Future<void> _startLocalServerAndLoad() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _localServer = server;
      _serverPort = server.port;

      server.listen((HttpRequest request) async {
        final rawPath = Uri.decodeComponent(request.uri.path.replaceFirst(RegExp(r'^/+'), ''));
        final targetPath = rawPath.isEmpty
            ? p.join(widget.baseDir, widget.fileName)
            : p.join(widget.baseDir, rawPath);

        final file = File(targetPath);
        if (await file.exists()) {
          final ext = p.extension(file.path).toLowerCase();
          String contentType = 'application/octet-stream';
          if (ext == '.html' || ext == '.htm') contentType = 'text/html; charset=utf-8';
          else if (ext == '.css') contentType = 'text/css; charset=utf-8';
          else if (ext == '.js') contentType = 'application/javascript; charset=utf-8';
          else if (ext == '.json') contentType = 'application/json; charset=utf-8';
          else if (ext == '.png') contentType = 'image/png';
          else if (ext == '.jpg' || ext == '.jpeg') contentType = 'image/jpeg';
          else if (ext == '.gif') contentType = 'image/gif';
          else if (ext == '.svg') contentType = 'image/svg+xml';
          else if (ext == '.webp') contentType = 'image/webp';

          request.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
          request.response.headers.set('Access-Control-Allow-Origin', '*');
          await file.openRead().pipe(request.response);
        } else {
          request.response.statusCode = HttpStatus.notFound;
          request.response.write('Not found: $rawPath');
          await request.response.close();
        }
      });

      final localUrl = 'http://127.0.0.1:${server.port}/${widget.fileName}';
      await _webViewController.loadRequest(Uri.parse(localUrl));
      if (mounted) setState(() {});
    } catch (_) {
      await _webViewController.loadHtmlString(widget.htmlContent);
      if (mounted) setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant HtmlPreviewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.htmlContent != widget.htmlContent || oldWidget.fileName != widget.fileName) {
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
    final url = 'http://127.0.0.1:$_serverPort/${widget.fileName}';
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
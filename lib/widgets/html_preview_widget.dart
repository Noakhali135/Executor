import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/path_guard.dart';
import '../services/workspace_fs.dart';

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
  final VoidCallback? onExitFullscreen;

  const HtmlPreviewWidget({
    super.key,
    required this.htmlContent,
    required this.baseDir,
    required this.fileName,
    this.onExitFullscreen,
  });

  @override
  State<HtmlPreviewWidget> createState() => _HtmlPreviewWidgetState();
}

class _HtmlPreviewWidgetState extends State<HtmlPreviewWidget> {
  static const int _maxDiagnosticLines = 1200;
  static const String _diagnosticChannelName = 'ExecutorPreviewDiagnostics';
  static final RegExp _diagnosticUrlPattern = RegExp(
    r'''(?:(?:https?|file|content)://|(?:blob|data|javascript):)[^\s"'<>]+''',
    caseSensitive: false,
  );

  final Queue<String> _diagnosticLines = ListQueue<String>();
  final WebViewController _webViewController = WebViewController();
  HttpServer? _localServer;
  int? _serverPort;
  int _droppedDiagnosticLines = 0;
  DateTime? _pageStartedAt;
  String? _lastObservedUrl;
  int _lastProgressLogged = -1;
  bool _isLoadingWeb = true;

  @override
  void initState() {
    super.initState();
    _record('INFO', 'preview session created');
    unawaited(_initializePreview());
  }

  Future<void> _initializePreview() async {
    try {
      await _initWebViewController();
      _record('INFO', 'WebView configured: JavaScript=unrestricted, canvas=white');
    } catch (error, stackTrace) {
      _record('ERROR', 'WebView navigation setup failed: $error; stack=$stackTrace');
      return;
    }
    if (!mounted) return;
    await _startLocalServerAndLoad();
  }

  Future<void> _initWebViewController() async {
    try {
      await _webViewController.setJavaScriptMode(JavaScriptMode.unrestricted);
    } catch (error, stackTrace) {
      _record('ERROR', 'setting JavaScript mode failed: $error; $stackTrace');
    }
    try {
      await _webViewController.setBackgroundColor(Colors.white);
    } catch (error, stackTrace) {
      _record('WARN', 'setting WebView canvas failed: $error; $stackTrace');
    }
    try {
      await _webViewController.addJavaScriptChannel(
        _diagnosticChannelName,
        onMessageReceived: _onPageDiagnosticMessage,
      );
      _record('INFO', 'JavaScript diagnostic channel installed');
    } catch (error, stackTrace) {
      _record('WARN', 'JavaScript diagnostic channel failed: $error; $stackTrace');
    }
    try {
      await _webViewController.setOnConsoleMessage(_onConsoleMessage);
      _record('INFO', 'JavaScript console capture installed');
    } catch (error, stackTrace) {
      _record('WARN', 'JavaScript console capture failed: $error; $stackTrace');
    }
    await _webViewController.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (NavigationRequest request) {
          final uri = Uri.tryParse(request.url);
          if (uri == null) {
            _record(
              'WARN',
              'navigation prevented: malformed URL main=${request.isMainFrame}',
            );
            return NavigationDecision.prevent;
          }

          final isLoopbackHttp =
              uri.scheme == 'http' && _isLoopbackHost(uri.host);
          final isEmbeddedWebDocument =
              uri.scheme == 'http' ||
              uri.scheme == 'https' ||
              uri.scheme == 'about' ||
              uri.scheme == 'data';
          final allowed = request.isMainFrame
              ? isLoopbackHttp || uri.scheme == 'about' || uri.scheme == 'data'
              : isEmbeddedWebDocument;
          final frame = request.isMainFrame ? 'main-frame' : 'subframe';
          final decision = allowed ? 'allowed' : 'blocked';
          _record(
            allowed ? 'INFO' : 'WARN',
            'navigation $frame $decision ${_safeUrl(request.url)}',
          );
          return allowed ? NavigationDecision.navigate : NavigationDecision.prevent;
        },
        onPageStarted: (String url) {
          _pageStartedAt = DateTime.now();
          _lastObservedUrl = url;
          _record('INFO', 'page started ${_safeUrl(url)}');
          if (mounted) setState(() => _isLoadingWeb = true);
        },
        onPageFinished: (String url) {
          final elapsed = _pageStartedAt == null
              ? 'unknown'
              : '${DateTime.now().difference(_pageStartedAt!).inMilliseconds}ms';
          _pageStartedAt = null;
          _lastObservedUrl = url;
          _record('INFO', 'page finished ${_safeUrl(url)} elapsed=$elapsed');
          if (mounted) setState(() => _isLoadingWeb = false);
          unawaited(_capturePageSnapshot());
        },
        onProgress: (int progress) {
          if (progress != _lastProgressLogged &&
              (progress == 0 || progress == 100 || progress % 20 == 0)) {
            _lastProgressLogged = progress;
            _record('INFO', 'WebView load progress=$progress%');
          }
        },
        onUrlChange: (UrlChange change) {
          final url = change.url;
          if (url == null) return;
          _lastObservedUrl = url;
          _record('INFO', 'WebView URL changed ${_safeUrl(url)}');
        },
        onWebResourceError: (WebResourceError error) {
          _record(
            'ERROR',
            'WebResourceError code=${error.errorCode} type=${error.errorType} '
                'mainFrame=${error.isForMainFrame} '
                'url=${_safeUrl(error.url ?? '(no URL)')} '
                'description=${error.description}',
          );
          if (error.isForMainFrame != false && mounted) {
            setState(() => _isLoadingWeb = false);
          }
        },
        onHttpError: (HttpResponseError error) {
          final response = error.response;
          final requestUri = response?.uri ?? error.request?.uri;
          final status = response?.statusCode?.toString() ?? 'unknown';
          final resource = requestUri == null
              ? '(no URL)'
              : _safeUrl(requestUri.toString());
          var contentType = '(unknown)';
          if (response != null) {
            for (final header in response.headers.entries) {
              if (header.key.toLowerCase() == 'content-type') {
                contentType = header.value;
                break;
              }
            }
          }
          _record(
            'ERROR',
            'HTTP error status=$status url=$resource contentType=$contentType',
          );
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

  void _record(String level, String message) {
    final now = DateTime.now();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    final timestamp =
        '${twoDigits(now.hour)}:${twoDigits(now.minute)}:${twoDigits(now.second)}';
    final sanitized = _sanitizeDiagnosticText(message);
    final singleLine = sanitized.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    final limited = singleLine.length > 1800
        ? '${singleLine.substring(0, 1800)} [line truncated]'
        : singleLine;
    if (_diagnosticLines.length >= _maxDiagnosticLines) {
      _diagnosticLines.removeFirst();
      _droppedDiagnosticLines++;
    }
    _diagnosticLines.addLast('[$timestamp] $level $limited');
  }

  String _sanitizeDiagnosticText(String message) {
    var sanitized = message;
    for (final root in {widget.baseDir, PathGuard.normalizeRoot(widget.baseDir)}) {
      if (root.length > 1) sanitized = sanitized.replaceAll(root, '<workspace>');
    }
    sanitized = sanitized.replaceAllMapped(_diagnosticUrlPattern, (match) {
      return _safeUrl(match.group(0)!);
    });
    return sanitized;
  }

  String _safeUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return raw.split('?').first.split('#').first;
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'data' || scheme == 'blob' || scheme == 'javascript') {
      return '$scheme:(content omitted)';
    }
    if (scheme == 'file' || scheme == 'content') {
      return '$scheme:(local path omitted)';
    }
    if (!uri.hasAuthority) {
      if (scheme.isEmpty) return uri.path;
      return scheme == 'about' ? 'about:${uri.path}' : '$scheme:(value omitted)';
    }
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://$host$port${uri.path}';
  }

  String _diagnosticReport() {
    final workspaceType = WorkspaceFs.isSaf(widget.baseDir)
        ? 'SAF virtual workspace'
        : 'ordinary filesystem workspace';
    final previewUri = _previewUri;
    final previewUrl = previewUri == null
        ? '(server not running)'
        : _safeUrl(previewUri.toString());
    final lastUrl = _lastObservedUrl == null
        ? '(none)'
        : _safeUrl(_lastObservedUrl!);
    final runtimeVersion = Platform.version.split(' ').first;
    final htmlBytes = utf8.encode(widget.htmlContent).length;
    final networkPolicy = Platform.isAndroid
        ? 'Android INTERNET permission; system-trusted HTTPS; cleartext allowed only to loopback'
        : 'Android network security config is not active on ${Platform.operatingSystem}';
    final externalHttpPolicy = Platform.isAndroid
        ? 'cleartext HTTP blocked except loopback'
        : 'OS-specific policy; not assessed by this Android config';
    final lines = <String>[
      'HTML Render diagnostic report',
      'Captured: ${DateTime.now().toIso8601String()}',
      'OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'Dart runtime: $runtimeVersion',
      'Entry file: ${widget.fileName}',
      'Workspace type: $workspaceType (full local path omitted)',
      'Preview URL: $previewUrl',
      'Last observed URL: $lastUrl',
      'HTML size: $htmlBytes UTF-8 bytes; content is not included',
      'WebView: JavaScript unrestricted; canvas white; console capture installed before load; DOM snapshot/error hooks injected after page finish',
      'Network policy: $networkPolicy',
      'External HTTP resources: $externalHttpPolicy',
      'Log buffer: ${_diagnosticLines.length} lines retained (each capped at 1800 characters); $_droppedDiagnosticLines older lines dropped',
      'Privacy: HTML source, cookies and request bodies are not intentionally dumped. Recognized URLs omit queries/fragments; workspace paths and local file URLs are redacted. Page title/console/error text may still contain project data or secrets; review before sharing.',
      'Logs are in memory only and are lost when the preview route closes.',
      '--- chronological events ---',
      ..._diagnosticLines,
    ];
    return lines.join('\n');
  }

  void _onConsoleMessage(JavaScriptConsoleMessage message) {
    final levelText = message.level.toString();
    final lowerLevel = levelText.toLowerCase();
    final level = lowerLevel.contains('error')
        ? 'ERROR'
        : lowerLevel.contains('warning')
        ? 'WARN'
        : 'INFO';
    _record('JS-$level', 'console[$levelText] ${message.message}');
  }

  void _onPageDiagnosticMessage(JavaScriptMessage message) {
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map) {
        _record('JS-INFO', 'page diagnostic ${message.message}');
        return;
      }
      final kind = decoded['kind']?.toString() ?? 'unknown';
      if (kind == 'snapshot') {
        _record(
          'INFO',
          'DOM snapshot url=${decoded['url']} title=${decoded['title']} '
              'ua=${decoded['userAgent']} compat=${decoded['compatMode']} '
              'ready=${decoded['readyState']} online=${decoded['online']} '
              'viewport=${decoded['viewport']} visual=${decoded['visualViewport']} '
              'dpr=${decoded['devicePixelRatio']} screen=${decoded['screen']} '
              'viewportMeta=${decoded['viewportMeta']} document=${decoded['documentSize']} '
              'bodySize=${decoded['bodySize']} prefersDark=${decoded['prefersDark']} '
              'htmlBg=${decoded['htmlBackground']} htmlColor=${decoded['htmlColor']} '
              'htmlFont=${decoded['htmlFont']} bodyBg=${decoded['bodyBackground']} '
              'bodyColor=${decoded['bodyColor']} bodyFont=${decoded['bodyFont']} '
              'bodyDisplay=${decoded['bodyDisplay']} bodyMargin=${decoded['bodyMargin']} '
              'bodyPosition=${decoded['bodyPosition']} '
              'fonts=${decoded['fontStatus']}/${decoded['fontFaceCount']} '
              'references=${decoded['referenceCount']} stylesheets=${decoded['stylesheetCount']} '
              'resources=${decoded['resourceCount']}',
        );
        _recordSnapshotList(decoded['references'], 'DOM reference');
        _recordSnapshotList(decoded['stylesheets'], 'stylesheet');
        _recordSnapshotList(decoded['resources'], 'resource timing');
      } else if (kind == 'resource-error') {
        _record(
          'ERROR',
          'DOM resource error tag=${decoded['tag']} url=${decoded['url']}',
        );
      } else if (kind == 'script-error') {
        _record(
          'ERROR',
          'JavaScript runtime error message=${decoded['message']} '
              'source=${decoded['source']} line=${decoded['line']} '
              'column=${decoded['column']} stack=${decoded['stack']}',
        );
      } else if (kind == 'unhandled-rejection') {
        _record('ERROR', 'JavaScript unhandled rejection: ${decoded['reason']}');
      } else {
        _record('JS-INFO', 'page diagnostic kind=$kind data=$decoded');
      }
    } catch (error) {
      _record('WARN', 'could not parse page diagnostic: $error; ${message.message}');
    }
  }

  void _recordSnapshotList(Object? value, String label) {
    if (value is! List) return;
    for (final item in value) {
      if (item is Map) {
        _record(
          'INFO',
          '$label ${item.entries.map((entry) => '${entry.key}=${entry.value}').join(' ')}',
        );
      }
    }
  }

  Future<void> _capturePageSnapshot() async {
    const script = r'''(() => {
      const clean = (value) => {
        try {
          const url = new URL(value, window.location.href);
          if (['data:', 'blob:', 'javascript:'].includes(url.protocol)) {
            return `${url.protocol}(content omitted)`;
          }
          if (['file:', 'content:'].includes(url.protocol)) {
            return `${url.protocol}(local path omitted)`;
          }
          if (url.origin === 'null') return `${url.protocol}(value omitted)`;
          return url.origin + url.pathname;
        } catch (_) {
          return String(value || '').split(/[?#]/, 1)[0];
        }
      };
      const post = (value) =>
        ExecutorPreviewDiagnostics.postMessage(JSON.stringify(value));
      const references = Array.from(document.querySelectorAll(
        'link[href],script[src],img[src],iframe[src],source[src],audio[src],video[src]'
      )).slice(0, 120).map((element) => {
        const tag = element.tagName.toLowerCase();
        let loaded = null;
        if (tag === 'img') loaded = element.complete && element.naturalWidth > 0;
        if (tag === 'link' && element.rel.toLowerCase().includes('stylesheet')) {
          loaded = Boolean(element.sheet);
        }
        return {
          tag: tag,
          url: clean(element.href || element.src || element.poster || ''),
          loaded: loaded
        };
      });
      const resources = performance.getEntriesByType('resource').slice(-160).map((entry) => ({
        initiator: entry.initiatorType,
        url: clean(entry.name),
        durationMs: Math.round(entry.duration),
        transferSize: entry.transferSize,
        decodedBodySize: entry.decodedBodySize,
        responseStatus: typeof entry.responseStatus === 'number' ? entry.responseStatus : null
      }));
      const htmlElement = document.documentElement;
      const bodyElement = document.body;
      const htmlStyle = getComputedStyle(htmlElement);
      const bodyStyle = bodyElement ? getComputedStyle(bodyElement) : null;
      const viewportMeta = document.querySelector('meta[name="viewport"]');
      const visualViewport = window.visualViewport;
      post({
        kind: 'snapshot',
        url: clean(window.location.href),
        title: document.title,
        userAgent: navigator.userAgent,
        compatMode: document.compatMode,
        readyState: document.readyState,
        online: navigator.onLine,
        prefersDark: window.matchMedia('(prefers-color-scheme: dark)').matches,
        viewport: `${window.innerWidth}x${window.innerHeight}`,
        visualViewport: visualViewport
          ? `${Math.round(visualViewport.width)}x${Math.round(visualViewport.height)} scale=${visualViewport.scale}`
          : '(unavailable)',
        devicePixelRatio: window.devicePixelRatio,
        screen: `${screen.width}x${screen.height}`,
        viewportMeta: viewportMeta ? viewportMeta.content : '(none)',
        documentSize: `${htmlElement.scrollWidth}x${htmlElement.scrollHeight}`,
        bodySize: bodyElement
          ? `${bodyElement.scrollWidth}x${bodyElement.scrollHeight}`
          : '(no body)',
        htmlBackground: htmlStyle.backgroundColor,
        htmlColor: htmlStyle.color,
        htmlFont: `${htmlStyle.fontFamily} ${htmlStyle.fontSize}`,
        bodyBackground: bodyStyle ? bodyStyle.backgroundColor : '(no body)',
        bodyColor: bodyStyle ? bodyStyle.color : '(no body)',
        bodyFont: bodyStyle ? `${bodyStyle.fontFamily} ${bodyStyle.fontSize}` : '(no body)',
        bodyDisplay: bodyStyle ? bodyStyle.display : '(no body)',
        bodyMargin: bodyStyle ? bodyStyle.margin : '(no body)',
        bodyPosition: bodyStyle ? bodyStyle.position : '(no body)',
        fontStatus: document.fonts ? document.fonts.status : '(unavailable)',
        fontFaceCount: document.fonts ? document.fonts.size : 0,
        referenceCount: document.querySelectorAll(
          'link[href],script[src],img[src],iframe[src],source[src],audio[src],video[src]'
        ).length,
        references: references,
        stylesheetCount: document.styleSheets.length,
        stylesheets: Array.from(document.styleSheets).slice(0, 80).map((sheet) => {
          let ruleCount = null;
          let ruleReadError = '';
          try {
            ruleCount = sheet.cssRules.length;
          } catch (error) {
            ruleReadError = error.name || 'unavailable';
          }
          return {
            url: sheet.href ? clean(sheet.href) : '(inline stylesheet)',
            disabled: sheet.disabled,
            media: sheet.media ? sheet.media.mediaText : '',
            ruleCount: ruleCount,
            ruleReadError: ruleReadError
          };
        }),
        resourceCount: performance.getEntriesByType('resource').length,
        resources: resources
      });
      window.addEventListener('error', (event) => {
        const target = event.target;
        if (target && target !== window) {
          post({
            kind: 'resource-error',
            tag: target.tagName || '(unknown)',
            url: clean(target.src || target.href || '')
          });
        } else {
          post({
            kind: 'script-error',
            message: event.message || '(no message)',
            source: clean(event.filename || ''),
            line: event.lineno || 0,
            column: event.colno || 0,
            stack: event.error && event.error.stack
              ? String(event.error.stack).slice(0, 1200)
              : ''
          });
        }
      }, true);
      window.addEventListener('unhandledrejection', (event) => {
        post({ kind: 'unhandled-rejection', reason: String(event.reason) });
      });
    })();''';
    try {
      await _webViewController.runJavaScript(script);
      _record('INFO', 'page resource/style snapshot and runtime error hooks injected');
    } catch (error) {
      _record('WARN', 'page snapshot injection failed: $error');
    }
  }

  Future<void> _startLocalServerAndLoad() async {
    _record(
      'INFO',
      'entry=${widget.fileName} workspace=' +
          (WorkspaceFs.isSaf(widget.baseDir) ? 'SAF' : 'filesystem') +
          ' htmlBytes=${utf8.encode(widget.htmlContent).length}',
    );
    _record(
      'INFO',
      Platform.isAndroid
          ? 'Android network policy: INTERNET permission is declared; HTTPS uses system trust; external cleartext HTTP is blocked; loopback HTTP is allowed'
          : 'Android network security config is inactive on ${Platform.operatingSystem}; OS-specific network policy applies',
    );

    HttpServer? server;
    String? localUrl;
    try {
      final boundServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      if (!mounted) {
        await boundServer.close(force: true);
        return;
      }
      server = boundServer;
      _localServer = boundServer;
      _serverPort = boundServer.port;
      final root = PathGuard.normalizeRoot(widget.baseDir);
      boundServer.listen(
        (HttpRequest request) {
          unawaited(_servePreviewRequest(request, root));
        },
        onError: (Object error, StackTrace stackTrace) {
          _record('ERROR', 'HTTP server stream error: $error; $stackTrace');
        },
      );

      localUrl = 'http://127.0.0.1:${boundServer.port}/';
      _record(
        'INFO',
        'loopback server listening at $localUrl rootType=${WorkspaceFs.isSaf(root) ? 'SAF' : 'filesystem'}',
      );
    } catch (error, stackTrace) {
      await server?.close(force: true);
      _localServer = null;
      _serverPort = null;
      _record('ERROR', 'loopback server startup failed: $error; $stackTrace');
    }

    if (localUrl == null) {
      _record(
        'WARN',
        'loading HTML string fallback without a local asset server; relative local assets cannot be served',
      );
      try {
        await _webViewController.loadHtmlString(widget.htmlContent);
      } catch (error, stackTrace) {
        _record('ERROR', 'HTML string fallback failed: $error; $stackTrace');
      }
      if (mounted) setState(() {});
      return;
    }

    try {
      _record('INFO', 'calling WebView loadRequest for ${_safeUrl(localUrl)}');
      await _webViewController.loadRequest(Uri.parse(localUrl));
      _record('INFO', 'WebView loadRequest returned without a platform exception');
    } catch (error, stackTrace) {
      _record(
        'ERROR',
        'local URL loadRequest threw: $error; $stackTrace; retry with baseUrl',
      );
      try {
        await _webViewController.loadHtmlString(
          widget.htmlContent,
          baseUrl: localUrl,
        );
        _record('INFO', 'HTML string retry loaded with loopback baseUrl');
      } catch (fallbackError, fallbackStackTrace) {
        _record(
          'ERROR',
          'HTML string retry failed: $fallbackError; $fallbackStackTrace',
        );
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _servePreviewRequest(HttpRequest request, String root) async {
    final startedAt = DateTime.now();
    final requestPath = request.uri.path.isEmpty ? '/' : request.uri.path;
    final host = request.headers.value(HttpHeaders.hostHeader) ?? '(missing)';
    final accept = request.headers.value(HttpHeaders.acceptHeader) ?? '(missing)';
    final userAgent = request.headers.value(HttpHeaders.userAgentHeader) ?? '(missing)';
    final referer = request.headers.value(HttpHeaders.refererHeader);
    _record(
      'INFO',
      'local request ${request.method} $requestPath host=$host queryPresent=${request.uri.hasQuery} '
          'accept=$accept userAgent=$userAgent referer=${referer == null ? '(none)' : _safeUrl(referer)}',
    );

    try {
      if (!_hasLoopbackHostHeader(request)) {
        await _respondPreviewText(
          request,
          HttpStatus.forbidden,
          'Forbidden',
          startedAt: startedAt,
          reason: 'non-loopback Host header',
        );
        return;
      }

      if (request.method != 'GET' && request.method != 'HEAD') {
        request.response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        await _respondPreviewText(
          request,
          HttpStatus.methodNotAllowed,
          'Method not allowed',
          startedAt: startedAt,
          reason: 'unsupported method',
        );
        return;
      }

      // Decode each URL path segment once. This supports Unicode, spaces and
      // literal percent signs without accidentally decoding a filename twice.
      final encodedPath = request.uri.path;
      final decodedPath = encodedPath.isEmpty || encodedPath == '/'
          ? ''
          : request.uri.pathSegments.join('/').replaceAll('\\', '/');
      if (PathGuard.containsTraversal(decodedPath)) {
        await _respondPreviewText(
          request,
          HttpStatus.forbidden,
          'Forbidden: path traversal',
          startedAt: startedAt,
          reason: 'traversal segment',
        );
        return;
      }

      final rawPath = decodedPath
          .split('/')
          .where((segment) => segment != '.')
          .join('/');
      if (rawPath.isNotEmpty) {
        final pathProblem = PathGuard.validateRelativePath(rawPath);
        final isProtected = rawPath
            .split('/')
            .any((segment) => segment == '.git' || segment == '.backup');
        if (pathProblem != null || isProtected) {
          await _respondPreviewText(
            request,
            HttpStatus.forbidden,
            'Forbidden: invalid preview path',
            startedAt: startedAt,
            reason: pathProblem ?? 'protected workspace path',
          );
          return;
        }
      }

      final isEntryDocument = rawPath.isEmpty || rawPath == widget.fileName;
      if (isEntryDocument) {
        final bytes = utf8.encode(widget.htmlContent);
        _setAssetHeaders(request.response, widget.fileName, length: bytes.length);
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'text/html; charset=utf-8',
        );
        if (request.method != 'HEAD') request.response.add(bytes);
        await request.response.close();
        _recordLocalResponse(
          request,
          HttpStatus.ok,
          'text/html; charset=utf-8',
          bytes.length,
          startedAt,
          source: 'live editor buffer',
        );
        return;
      }

      final isSafRoot = WorkspaceFs.isSaf(root);
      final targetPath = isSafRoot
          ? p.posix.normalize(p.posix.join(root, rawPath))
          : p.normalize(p.join(root, rawPath));
      if (!PathGuard.isInside(root, targetPath)) {
        await _respondPreviewText(
          request,
          HttpStatus.forbidden,
          'Forbidden: outside preview directory',
          startedAt: startedAt,
          reason: 'normalized target escaped preview root',
        );
        return;
      }

      if (WorkspaceFs.isSaf(targetPath)) {
        if (request.method == 'HEAD') {
          final exists = await WorkspaceFs.exists(targetPath);
          if (!exists || await WorkspaceFs.isDirectory(targetPath)) {
            await _respondPreviewText(
              request,
              HttpStatus.notFound,
              'Not found',
              startedAt: startedAt,
              reason: 'SAF file missing or is a directory',
            );
            return;
          }
          final length = await WorkspaceFs.length(targetPath);
          final contentType = _contentTypeFor(targetPath);
          _setAssetHeaders(request.response, targetPath, length: length);
          await request.response.close();
          _recordLocalResponse(
            request,
            HttpStatus.ok,
            contentType,
            length,
            startedAt,
            source: 'SAF HEAD',
          );
          return;
        }

        final bytes = await WorkspaceFs.readBytes(targetPath);
        if (bytes == null) {
          await _respondPreviewText(
            request,
            HttpStatus.notFound,
            'Not found',
            startedAt: startedAt,
            reason: 'WorkspaceFs could not read SAF asset',
          );
          return;
        }
        final contentType = _contentTypeFor(targetPath);
        _setAssetHeaders(request.response, targetPath, length: bytes.length);
        request.response.add(bytes);
        await request.response.close();
        _recordLocalResponse(
          request,
          HttpStatus.ok,
          contentType,
          bytes.length,
          startedAt,
          source: 'SAF bytes',
        );
        return;
      }

      final targetFile = File(targetPath);
      if (!await targetFile.exists()) {
        await _respondPreviewText(
          request,
          HttpStatus.notFound,
          'Not found',
          startedAt: startedAt,
          reason: 'filesystem asset does not exist',
        );
        return;
      }
      if (await Directory(targetPath).exists()) {
        await _respondPreviewText(
          request,
          HttpStatus.notFound,
          'Not found',
          startedAt: startedAt,
          reason: 'requested path is a directory',
        );
        return;
      }

      final rootRealPath = await Directory(root).resolveSymbolicLinks();
      final targetRealPath = await targetFile.resolveSymbolicLinks();
      if (!PathGuard.isInside(rootRealPath, targetRealPath)) {
        await _respondPreviewText(
          request,
          HttpStatus.forbidden,
          'Forbidden: outside preview directory',
          startedAt: startedAt,
          reason: 'symlink target escaped preview root',
        );
        return;
      }

      final file = File(targetRealPath);
      final length = await file.length();
      final contentType = _contentTypeFor(file.path);
      _setAssetHeaders(request.response, file.path, length: length);
      if (request.method == 'HEAD') {
        await request.response.close();
      } else {
        await file.openRead().pipe(request.response);
      }
      _recordLocalResponse(
        request,
        HttpStatus.ok,
        contentType,
        length,
        startedAt,
        source: 'filesystem stream',
      );
    } catch (error, stackTrace) {
      _record(
        'ERROR',
        'local request exception method=${request.method} path=$requestPath '
            'error=$error stack=$stackTrace',
      );
      try {
        await _respondPreviewText(
          request,
          HttpStatus.internalServerError,
          'Preview asset read failed',
          startedAt: startedAt,
          reason: 'exception while resolving or streaming asset',
        );
      } catch (responseError, responseStackTrace) {
        _record(
          'ERROR',
          'could not send local error response: $responseError; $responseStackTrace',
        );
      }
    }
  }

  void _setAssetHeaders(
    HttpResponse response,
    String path, {
    required int length,
  }) {
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      _contentTypeFor(path),
    );
    if (length >= 0) {
      response.headers.set(HttpHeaders.contentLengthHeader, length);
    }
  }

  Future<void> _respondPreviewText(
    HttpRequest request,
    int statusCode,
    String body, {
    required DateTime startedAt,
    required String reason,
  }) async {
    request.response.statusCode = statusCode;
    request.response.headers.set(
      HttpHeaders.contentTypeHeader,
      'text/plain; charset=utf-8',
    );
    if (request.method != 'HEAD') request.response.write(body);
    await request.response.close();
    _recordLocalResponse(
      request,
      statusCode,
      'text/plain; charset=utf-8',
      request.method == 'HEAD' ? 0 : utf8.encode(body).length,
      startedAt,
      source: reason,
    );
  }

  void _recordLocalResponse(
    HttpRequest request,
    int statusCode,
    String contentType,
    int bytes,
    DateTime startedAt, {
    required String source,
  }) {
    final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
    final byteCount = bytes < 0 ? 'unknown' : bytes.toString();
    _record(
      statusCode >= 400 ? 'WARN' : 'INFO',
      'local response ${request.method} ${request.uri.path} status=$statusCode '
          'type=$contentType bytes=$byteCount elapsed=${elapsed}ms source=$source',
    );
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
      case '.cjs':
      case '.jsx':
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
      case '.avif':
        return 'image/avif';
      case '.bmp':
        return 'image/bmp';
      case '.ico':
        return 'image/x-icon';
      case '.woff':
        return 'font/woff';
      case '.woff2':
        return 'font/woff2';
      case '.ttf':
        return 'font/ttf';
      case '.otf':
        return 'font/otf';
      case '.eot':
        return 'application/vnd.ms-fontobject';
      case '.wasm':
        return 'application/wasm';
      case '.webmanifest':
        return 'application/manifest+json';
      case '.map':
        return 'application/json; charset=utf-8';
      case '.xml':
        return 'application/xml; charset=utf-8';
      case '.pdf':
        return 'application/pdf';
      case '.mp4':
        return 'video/mp4';
      case '.webm':
        return 'video/webm';
      case '.mp3':
        return 'audio/mpeg';
      case '.ogg':
        return 'audio/ogg';
      case '.wav':
        return 'audio/wav';
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
      _record('INFO', 'widget received new HTML content; refreshing preview');
      unawaited(_reloadPage());
    }
  }

  @override
  void dispose() {
    _localServer?.close(force: true);
    super.dispose();
  }

  Uri? get _previewUri {
    final port = _serverPort;
    if (port == null) return null;
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      // Match the exact loopback URL used by the embedded WebView.
      path: '/',
    );
  }

  Future<void> _showDiagnostics() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final report = _diagnosticReport();
          return AlertDialog(
            backgroundColor: const Color(0xFF0F1523),
            title: const Row(
              children: [
                Icon(Icons.bug_report_outlined, color: Color(0xFFFBBF24)),
                SizedBox(width: 8),
                Text('Render diagnostics'),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.sizeOf(context).height * 0.62,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Copy the report and paste it here. Review page console lines before sharing; they may contain project data.',
                    style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF070B14),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFF334155)),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          report,
                          style: const TextStyle(
                            color: Color(0xFFE2E8F0),
                            fontFamily: 'monospace',
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  _diagnosticLines.clear();
                  _droppedDiagnosticLines = 0;
                  _record('INFO', 'diagnostic buffer cleared; reloading page');
                  unawaited(_reloadPage());
                  setDialogState(() {});
                },
                child: const Text('Clear & reload'),
              ),
              TextButton(
                onPressed: () => setDialogState(() {}),
                child: const Text('Refresh log'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  _record('INFO', 'diagnostic report copy requested');
                  try {
                    await Clipboard.setData(
                      ClipboardData(text: _diagnosticReport()),
                    );
                    _record('INFO', 'diagnostic report copied to clipboard');
                    if (mounted) {
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        const SnackBar(
                          content: Text('Render diagnostic report copied'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  } catch (error, stackTrace) {
                    _record('ERROR', 'copying diagnostic report failed: $error; $stackTrace');
                    if (mounted) {
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        const SnackBar(
                          content: Text('Could not copy render diagnostics'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  }
                  if (dialogContext.mounted) setDialogState(() {});
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('Copy all'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _copyServerUrl() async {
    final uri = _previewUri;
    if (uri == null) return;
    _record('INFO', 'preview URL copied ${_safeUrl(uri.toString())}');
    await Clipboard.setData(ClipboardData(text: uri.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied: $uri'),
        backgroundColor: const Color(0xFF10B981),
        duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _openInBrowser() async {
    final uri = _previewUri;
    if (uri == null) {
      _showBrowserError('The local preview server is not ready yet.');
      return;
    }

    _record('INFO', 'external browser launch requested ${_safeUrl(uri.toString())}');
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      _record('INFO', 'external browser launch result=$opened');
      if (!opened) _showBrowserError('Could not open the preview in a browser.');
    } catch (error, stackTrace) {
      _record('ERROR', 'external browser launch failed: $error; $stackTrace');
      _showBrowserError('Could not open the preview in a browser.');
    }
  }

  void _showBrowserError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFDC2626),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _reloadPage() async {
    _record('INFO', 'refresh requested');
    try {
      if (_serverPort != null) {
        await _webViewController.reload();
      } else {
        _record('WARN', 'no local server; refreshing HTML string without local assets');
        await _webViewController.loadHtmlString(widget.htmlContent);
      }
    } catch (error, stackTrace) {
      _record('ERROR', 'refresh failed: $error; $stackTrace');
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayUrl = _previewUri?.toString() ?? 'Starting local preview…';

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
              Tooltip(
                message: 'Render diagnostics (${_diagnosticLines.length} events)',
                child: InkWell(
                  onTap: _showDiagnostics,
                  borderRadius: BorderRadius.circular(6),
                  child: const Padding(
                    padding: EdgeInsets.all(5),
                    child: Icon(
                      Icons.bug_report_outlined,
                      size: 16,
                      color: Color(0xFFFBBF24),
                    ),
                  ),
                ),
              ),
              InkWell(
                onTap: _reloadPage,
                borderRadius: BorderRadius.circular(6),
                child: const Padding(
                  padding: EdgeInsets.all(5),
                  child: Icon(Icons.refresh_rounded, size: 16, color: Color(0xFFCBD5E1)),
                ),
              ),
              Tooltip(
                message: 'Open in browser',
                child: InkWell(
                  onTap: _openInBrowser,
                  borderRadius: BorderRadius.circular(6),
                  child: const Padding(
                    padding: EdgeInsets.all(5),
                    child: Icon(
                      Icons.open_in_browser_rounded,
                      size: 17,
                      color: Color(0xFFCBD5E1),
                    ),
                  ),
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
              if (widget.onExitFullscreen != null)
                Tooltip(
                  message: 'Back to editor',
                  child: InkWell(
                    onTap: widget.onExitFullscreen,
                    borderRadius: BorderRadius.circular(6),
                    child: const Padding(
                      padding: EdgeInsets.all(5),
                      child: Icon(
                        Icons.fullscreen_exit_rounded,
                        size: 18,
                        color: Color(0xFFCBD5E1),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: Colors.white,
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
        ),
      ],
    );
  }
}


/// Full-window route for an HTML preview. It covers the editor chrome while
/// retaining the operating system's status and navigation bars.
class HtmlPreviewScreen extends StatefulWidget {
  final String htmlContent;
  final String baseDir;
  final String fileName;

  const HtmlPreviewScreen({
    super.key,
    required this.htmlContent,
    required this.baseDir,
    required this.fileName,
  });

  @override
  State<HtmlPreviewScreen> createState() => _HtmlPreviewScreenState();
}

class _HtmlPreviewScreenState extends State<HtmlPreviewScreen> {
  @override
  void initState() {
    super.initState();
    // Keep Android's status and navigation bars visible in the full-screen
    // preview; SafeArea below keeps the preview controls clear of both.
    if (Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = HtmlPreviewWidget(
      htmlContent: widget.htmlContent,
      baseDir: widget.baseDir,
      fileName: widget.fileName,
      onExitFullscreen: () => Navigator.of(context).pop(),
    );

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      body: SafeArea(child: preview),
    );
  }
}

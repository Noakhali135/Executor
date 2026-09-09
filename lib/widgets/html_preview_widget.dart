import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

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
  bool _isStartingServer = false;

  @override
  void dispose() {
    _localServer?.close(force: true);
    super.dispose();
  }

  Future<void> _startLocalServer() async {
    if (_localServer != null) return;
    setState(() => _isStartingServer = true);

    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _localServer = server;
      _serverPort = server.port;

      server.listen((HttpRequest request) async {
        final reqPath = request.uri.path.replaceFirst(RegExp(r'^/+'), '');
        final targetPath = reqPath.isEmpty
            ? p.join(widget.baseDir, widget.fileName)
            : p.join(widget.baseDir, reqPath);

        final file = File(targetPath);
        if (await file.exists()) {
          final ext = p.extension(file.path).toLowerCase();
          String contentType = 'text/plain';
          if (ext == '.html' || ext == '.htm') contentType = 'text/html; charset=utf-8';
          else if (ext == '.css') contentType = 'text/css';
          else if (ext == '.js') contentType = 'application/javascript';
          else if (ext == '.png') contentType = 'image/png';
          else if (ext == '.jpg' || ext == '.jpeg') contentType = 'image/jpeg';
          else if (ext == '.svg') contentType = 'image/svg+xml';
          else if (ext == '.json') contentType = 'application/json';

          request.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
          await file.openRead().pipe(request.response);
        } else {
          request.response.statusCode = HttpStatus.notFound;
          request.response.write('File not found: $reqPath');
          await request.response.close();
        }
      });

      if (mounted) {
        setState(() => _isStartingServer = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isStartingServer = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start local server: $e')),
        );
      }
    }
  }

  void _copyServerUrl() {
    if (_serverPort == null) return;
    final url = 'http://127.0.0.1:$_serverPort/${widget.fileName}';
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied: $url'),
        backgroundColor: const Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Color _parseCssColor(String? value) {
    if (value == null) return Colors.white;
    final v = value.trim().toLowerCase();
    if (v == 'black' || v == '#000' || v == '#000000') return Colors.black;
    if (v == 'white' || v == '#fff' || v == '#ffffff') return Colors.white;
    if (v == 'red') return Colors.red;
    if (v == 'blue') return Colors.blue;
    if (v == 'green') return Colors.green;
    if (v == 'yellow') return Colors.amber;
    if (v == 'cyan') return Colors.cyan;
    if (v == 'gray' || v == 'grey') return Colors.grey;
    if (v.startsWith('#')) {
      final hex = v.replaceFirst('#', '');
      if (hex.length == 6) {
        final intVal = int.tryParse('FF$hex', radix: 16);
        if (intVal != null) return Color(intVal);
      } else if (hex.length == 3) {
        final r = hex[0];
        final g = hex[1];
        final b = hex[2];
        final intVal = int.tryParse('FF$r$r$g$g$b$b', radix: 16);
        if (intVal != null) return Color(intVal);
      }
    }
    return Colors.white;
  }

  List<Widget> _renderHtml(String rawHtml) {
    final widgets = <Widget>[];

    Color pageBg = const Color(0xFF070B14);
    Color pageText = const Color(0xFFE2E8F0);

    final bodyBgMatch = RegExp(r'<body[^>]*style="[^"]*background(?:-color)?:\s*([^";]+)', caseSensitive: false).firstMatch(rawHtml);
    if (bodyBgMatch != null) {
      pageBg = _parseCssColor(bodyBgMatch.group(1));
    }

    final bodyColorMatch = RegExp(r'<body[^>]*style="[^"]*color:\s*([^";]+)', caseSensitive: false).firstMatch(rawHtml);
    if (bodyColorMatch != null) {
      pageText = _parseCssColor(bodyColorMatch.group(1));
    }

    final bodyContentMatch = RegExp(r'<body[^>]*>([\s\S]*?)<\/body>', caseSensitive: false).firstMatch(rawHtml);
    final content = bodyContentMatch != null ? bodyContentMatch.group(1)! : rawHtml;

    final titleMatch = RegExp(r'<title[^>]*>([\s\S]*?)<\/title>', caseSensitive: false).firstMatch(rawHtml);
    if (titleMatch != null) {
      widgets.add(
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.3),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF1E293B)),
          ),
          child: Row(
            children: [
              const Icon(Icons.tab_rounded, size: 14, color: Color(0xFF818CF8)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  titleMatch.group(1)!.trim(),
                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11.5, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final tagRegex = RegExp(
      r'<(h[1-6]|p|hr|pre|code|blockquote|ul|ol|li|button|a|img|table|div)[^>]*>([\s\S]*?)<\/\1>|<(hr|img|input)[^>]*\/?>',
      caseSensitive: false,
    );

    final matches = tagRegex.allMatches(content);

    if (matches.isEmpty) {
      final cleanText = content.replaceAll(RegExp(r'<[^>]*>'), '').trim();
      widgets.add(
        Text(
          cleanText.isEmpty ? '(Empty HTML Document)' : cleanText,
          style: TextStyle(color: pageText, fontSize: 14),
        ),
      );
      return widgets;
    }

    for (final m in matches) {
      final full = m.group(0) ?? '';
      final tag = (m.group(1) ?? m.group(3) ?? '').toLowerCase();
      final inner = m.group(2) ?? '';

      final inlineStripped = inner.replaceAll(RegExp(r'<[^>]*>'), '').trim();

      if (tag == 'h1') {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Text(inlineStripped, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: pageText)),
        ));
      } else if (tag == 'h2') {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 6.0),
          child: Text(inlineStripped, style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: pageText)),
        ));
      } else if (tag == 'h3') {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 5.0),
          child: Text(inlineStripped, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: pageText)),
        ));
      } else if (tag.startsWith('h')) {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 4.0),
          child: Text(inlineStripped, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: pageText)),
        ));
      } else if (tag == 'p') {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 4.0),
          child: Text(inlineStripped, style: TextStyle(fontSize: 13.5, height: 1.4, color: pageText)),
        ));
      } else if (tag == 'hr') {
        widgets.add(const Divider(color: Color(0xFF334155), height: 16));
      } else if (tag == 'pre' || tag == 'code') {
        widgets.add(Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6.0),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF1E293B)),
          ),
          child: Text(
            inlineStripped,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFF38BDF8)),
          ),
        ));
      } else if (tag == 'blockquote') {
        widgets.add(Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: Color(0xFF6366F1), width: 3)),
          ),
          child: Text(
            inlineStripped,
            style: const TextStyle(fontStyle: FontStyle.italic, color: Color(0xFF94A3B8), fontSize: 13),
          ),
        ));
      } else if (tag == 'li') {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.5, horizontal: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('• ', style: TextStyle(color: Color(0xFF818CF8), fontSize: 14, fontWeight: FontWeight.bold)),
              Expanded(
                child: Text(inlineStripped, style: TextStyle(fontSize: 13, color: pageText)),
              ),
            ],
          ),
        ));
      } else if (tag == 'button') {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 6.0),
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6366F1),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Button clicked: "$inlineStripped"'), duration: const Duration(seconds: 1)),
              );
            },
            child: Text(inlineStripped),
          ),
        ));
      } else if (tag == 'a') {
        final hrefMatch = RegExp(r'href="([^"]*)"', caseSensitive: false).firstMatch(full);
        final href = hrefMatch?.group(1) ?? '#';
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 4.0),
          child: InkWell(
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Link: $href'), duration: const Duration(seconds: 1)),
              );
            },
            child: Text(
              inlineStripped.isEmpty ? href : inlineStripped,
              style: const TextStyle(color: Color(0xFF38BDF8), decoration: TextDecoration.underline, fontSize: 13),
            ),
          ),
        ));
      } else if (tag == 'img') {
        final srcMatch = RegExp(r'src="([^"]*)"', caseSensitive: false).firstMatch(full);
        final src = srcMatch?.group(1);
        if (src != null && src.isNotEmpty) {
          if (src.startsWith('http://') || src.startsWith('https://')) {
            widgets.add(Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(src, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 36)),
              ),
            ));
          } else {
            final localImagePath = p.join(widget.baseDir, src);
            final imgFile = File(localImagePath);
            if (imgFile.existsSync()) {
              widgets.add(Padding(
                padding: const EdgeInsets.symmetric(vertical: 6.0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(imgFile),
                ),
              ));
            }
          }
        }
      } else if (tag == 'table') {
        widgets.add(Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF1E293B)),
          ),
          child: Text(inlineStripped, style: TextStyle(color: pageText, fontSize: 12.5)),
        ));
      } else {
        if (inlineStripped.isNotEmpty) {
          widgets.add(Padding(
            padding: const EdgeInsets.symmetric(vertical: 3.0),
            child: Text(inlineStripped, style: TextStyle(fontSize: 13, color: pageText)),
          ));
        }
      }
    }

    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(
            color: Color(0xFF0F1523),
            border: Border(bottom: BorderSide(color: Color(0xFF1E293B))),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.play_circle_outline_rounded, size: 16, color: Color(0xFF10B981)),
                  const SizedBox(width: 6),
                  Text(
                    _serverPort == null ? 'Render Engine: Native HTML' : 'Live: 127.0.0.1:$_serverPort',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  if (_serverPort == null)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                      onPressed: _isStartingServer ? null : _startLocalServer,
                      icon: const Icon(Icons.router_rounded, size: 13, color: Colors.white),
                      label: _isStartingServer
                          ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Run Server', style: TextStyle(color: Colors.white, fontSize: 11.5)),
                    )
                  else
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                      onPressed: _copyServerUrl,
                      icon: const Icon(Icons.copy_rounded, size: 13, color: Colors.white),
                      label: const Text('Copy URL', style: TextStyle(color: Colors.white, fontSize: 11.5)),
                    ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: const Color(0xFF070B14),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _renderHtml(widget.htmlContent),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
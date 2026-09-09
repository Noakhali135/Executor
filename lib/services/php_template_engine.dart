import 'dart:convert';

class PhpTemplateEngine {
  static String render({
    required String phpCode,
    String defaultTitle = 'PHP Preview',
  }) {
    if (phpCode.trim().isEmpty) {
      return '<html><body style="background:#070B14;color:#94A3B8;font-family:sans-serif;padding:20px;">// PHP script is empty</body></html>';
    }

    final variables = <String, dynamic>{};
    final arrays = <String, List<String>>{};

    final strVarRegex = RegExp(r'''\$([a-zA-Z0-9_]+)\s*=\s*(["'])([\s\S]*?)\2\s*;''');
    for (final m in strVarRegex.allMatches(phpCode)) {
      final name = m.group(1)!;
      final val = m.group(3)!;
      variables[name] = val;
    }

    final numVarRegex = RegExp(r'''\$([a-zA-Z0-9_]+)\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*;''');
    for (final m in numVarRegex.allMatches(phpCode)) {
      final name = m.group(1)!;
      final val = m.group(2)!;
      variables[name] = val;
    }

    final arrayRegex = RegExp(r'''\$([a-zA-Z0-9_]+)\s*=\s*\[([\s\S]*?)\]\s*;''');
    for (final m in arrayRegex.allMatches(phpCode)) {
      final name = m.group(1)!;
      final rawItems = m.group(2)!;
      final items = <String>[];
      final itemMatch = RegExp(r'''(["'])(.*?)\1''').allMatches(rawItems);
      for (final im in itemMatch) {
        items.add(im.group(2)!);
      }
      arrays[name] = items;
    }

    String htmlPart = '';
    final docTypeIndex = phpCode.indexOf('<!DOCTYPE');
    final htmlTagIndex = phpCode.indexOf('<html');

    if (docTypeIndex != -1) {
      htmlPart = phpCode.substring(docTypeIndex);
    } else if (htmlTagIndex != -1) {
      htmlPart = phpCode.substring(htmlTagIndex);
    } else {
      final firstTag = phpCode.indexOf(RegExp(r'<[a-zA-Z]+'));
      if (firstTag != -1) {
        htmlPart = phpCode.substring(firstTag);
      } else {
        htmlPart = '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"></head>
<body style="background:#070B14;color:#E2E8F0;font-family:monospace;padding:20px;">
  <pre style="white-space:pre-wrap;">${_escape(phpCode)}</pre>
</body>
</html>''';
      }
    }

    final loopRegex = RegExp(
      r'''<\?php\s+foreach\s*\(\$([a-zA-Z0-9_]+)\s+as\s+\$([a-zA-Z0-9_]+)\)\s*:\s*\?>([\s\S]*?)<\?php\s+endforeach;\s*\?>''',
      caseSensitive: false,
    );

    htmlPart = htmlPart.replaceAllMapped(loopRegex, (m) {
      final arrName = m.group(1)!;
      final valVar = m.group(2)!;
      final template = m.group(3)!;

      final list = arrays[arrName] ?? [];
      if (list.isEmpty) return '';

      final buffer = StringBuffer();
      for (final item in list) {
        var unrolled = template;
        unrolled = unrolled.replaceAll(RegExp(r'<\?=(?:\s*escape_html\()?\$' + valVar + r'(?:\))?\s*\?>'), item);
        unrolled = unrolled.replaceAll(RegExp(r'<\?php\s+echo(?:\s+escape_html\()?\$' + valVar + r'(?:\))?\s*;\s*\?>'), item);
        buffer.write(unrolled);
      }
      return buffer.toString();
    });

    final ifElseRegex = RegExp(
      r'''<\?php\s+if\s*\((.*?)\)\s*:\s*\?>([\s\S]*?)<\?php\s+else\s*:\s*\?>([\s\S]*?)<\?php\s+endif;\s*\?>''',
      caseSensitive: false,
    );
    htmlPart = htmlPart.replaceAllMapped(ifElseRegex, (m) {
      final condition = m.group(1)!.trim();
      final ifBody = m.group(2)!;
      final elseBody = m.group(3)!;

      bool isTrue = false;
      final varMatch = RegExp(r'\$([a-zA-Z0-9_]+)').firstMatch(condition);
      if (varMatch != null) {
        final varName = varMatch.group(1)!;
        if (variables.containsKey(varName)) {
          final val = variables[varName]?.toString().trim();
          isTrue = val != null && val.isNotEmpty && val != '0' && val != 'false';
        }
      }

      return isTrue ? ifBody : elseBody;
    });

    final ifSimpleRegex = RegExp(
      r'''<\?php\s+if\s*\((.*?)\)\s*:\s*\?>([\s\S]*?)<\?php\s+endif;\s*\?>''',
      caseSensitive: false,
    );
    htmlPart = htmlPart.replaceAllMapped(ifSimpleRegex, (m) {
      final condition = m.group(1)!.trim();
      final ifBody = m.group(2)!;

      bool isTrue = false;
      final varMatch = RegExp(r'\$([a-zA-Z0-9_]+)').firstMatch(condition);
      if (varMatch != null) {
        final varName = varMatch.group(1)!;
        if (variables.containsKey(varName)) {
          final val = variables[varName]?.toString().trim();
          isTrue = val != null && val.isNotEmpty && val != '0' && val != 'false';
        }
      }

      return isTrue ? ifBody : '';
    });

    htmlPart = htmlPart.replaceAll(RegExp(r'<\?php\s+echo\s+date\("Y"\)\s*;\s*\?>', caseSensitive: false), DateTime.now().year.toString());
    htmlPart = htmlPart.replaceAll(RegExp(r'<\?=\s*date\("Y"\)\s*\?>', caseSensitive: false), DateTime.now().year.toString());

    final echoVarRegex = RegExp(
      r'''<\?(?:php\s+echo|=)(?:\s+escape_html\()?\$([a-zA-Z0-9_]+)(?:\))?\s*;?\s*\?>''',
      caseSensitive: false,
    );
    htmlPart = htmlPart.replaceAllMapped(echoVarRegex, (m) {
      final name = m.group(1)!;
      if (variables.containsKey(name)) {
        return variables[name]?.toString() ?? '';
      }
      return '';
    });

    htmlPart = htmlPart.replaceAll(RegExp(r'<\?php[\s\S]*?\?>'), '');
    htmlPart = htmlPart.replaceAll(RegExp(r'<\?=[\s\S]*?\?>'), '');

    return htmlPart;
  }

  static String _escape(String text) {
    return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  }
}
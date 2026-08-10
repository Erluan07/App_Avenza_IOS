/// Parser mínimo de WKT1 (OGC / ESRI) — el formato en que ArcGIS Pro escribe
/// el CRS dentro del `/Measure` de un GeoPDF.
///
/// No valida el WKT: solo lo convierte en un árbol navegable
/// `PROJCS["nombre", GEOGCS[...], PROJECTION[...], PARAMETER[...], ...]`.
library;

class WktNode {
  WktNode(this.keyword, this.args);

  /// `PROJCS`, `GEOGCS`, `DATUM`, `SPHEROID`, `PARAMETER`, …
  final String keyword;

  /// Cada argumento es un `String` (literal entrecomillado), un `double`
  /// (número) o un [WktNode] anidado.
  final List<Object> args;

  /// Primer argumento textual: por convención WKT, el nombre del elemento.
  String? get name {
    for (final arg in args) {
      if (arg is String) return arg;
    }
    return null;
  }

  Iterable<WktNode> get children => args.whereType<WktNode>();

  Iterable<double> get numbers => args.whereType<double>();

  /// Primer hijo con esa palabra clave (comparación sin distinguir mayúsculas).
  WktNode? child(String keyword) {
    final target = keyword.toUpperCase();
    for (final node in children) {
      if (node.keyword.toUpperCase() == target) return node;
    }
    return null;
  }

  Iterable<WktNode> childrenNamed(String keyword) {
    final target = keyword.toUpperCase();
    return children.where((n) => n.keyword.toUpperCase() == target);
  }

  /// Busca en todo el subárbol, no solo en los hijos directos.
  WktNode? find(String keyword) {
    final target = keyword.toUpperCase();
    if (this.keyword.toUpperCase() == target) return this;
    for (final node in children) {
      final hit = node.find(keyword);
      if (hit != null) return hit;
    }
    return null;
  }

  @override
  String toString() => '$keyword[${args.length} args]';
}

class WktParseException implements Exception {
  WktParseException(this.message);

  final String message;

  @override
  String toString() => 'WktParseException: $message';
}

/// Devuelve el nodo raíz, o `null` si el texto no es WKT reconocible.
WktNode? parseWkt(String? text) {
  if (text == null) return null;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;

  try {
    final parser = _WktParser(trimmed);
    final node = parser.parseNode();
    return node;
  } on WktParseException {
    return null;
  } on RangeError {
    return null;
  }
}

class _WktParser {
  _WktParser(this.text);

  final String text;
  int pos = 0;

  bool get atEnd => pos >= text.length;

  void skipWhitespace() {
    while (!atEnd && text.codeUnitAt(pos) <= 0x20) {
      pos++;
    }
  }

  WktNode parseNode() {
    skipWhitespace();
    final keyword = _readKeyword();
    if (keyword.isEmpty) throw WktParseException('Se esperaba una palabra clave');

    skipWhitespace();
    if (atEnd) return WktNode(keyword, const []);

    final open = text[pos];
    // WKT admite corchetes o paréntesis; ArcGIS usa corchetes.
    if (open != '[' && open != '(') return WktNode(keyword, const []);
    final close = open == '[' ? ']' : ')';
    pos++;

    final args = <Object>[];
    while (true) {
      skipWhitespace();
      if (atEnd) throw WktParseException('WKT truncado en "$keyword"');

      final ch = text[pos];
      if (ch == close) {
        pos++;
        break;
      }
      if (ch == ',') {
        pos++;
        continue;
      }
      if (ch == '"') {
        args.add(_readQuotedString());
        continue;
      }
      if (_isNumberStart(ch)) {
        final number = _tryReadNumber();
        if (number != null) {
          args.add(number);
          continue;
        }
      }
      // Cualquier otra cosa es un nodo anidado.
      args.add(parseNode());
    }

    return WktNode(keyword, args);
  }

  String _readKeyword() {
    final start = pos;
    while (!atEnd) {
      final c = text.codeUnitAt(pos);
      final isAlpha = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
      final isDigit = c >= 0x30 && c <= 0x39;
      if (isAlpha || isDigit || c == 0x5F) {
        pos++;
      } else {
        break;
      }
    }
    return text.substring(start, pos);
  }

  String _readQuotedString() {
    pos++; // consume la comilla de apertura
    final buffer = StringBuffer();
    while (!atEnd) {
      final ch = text[pos];
      if (ch == '"') {
        // Dos comillas seguidas escapan una comilla literal.
        if (pos + 1 < text.length && text[pos + 1] == '"') {
          buffer.write('"');
          pos += 2;
          continue;
        }
        pos++;
        break;
      }
      buffer.write(ch);
      pos++;
    }
    return buffer.toString();
  }

  bool _isNumberStart(String ch) {
    final c = ch.codeUnitAt(0);
    return (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E;
  }

  double? _tryReadNumber() {
    final start = pos;
    if (!atEnd && (text[pos] == '-' || text[pos] == '+')) pos++;
    var sawDigit = false;

    while (!atEnd) {
      final c = text.codeUnitAt(pos);
      if (c >= 0x30 && c <= 0x39) {
        sawDigit = true;
        pos++;
      } else if (c == 0x2E) {
        pos++;
      } else if ((c == 0x45 || c == 0x65) && sawDigit) {
        // exponente
        pos++;
        if (!atEnd && (text[pos] == '-' || text[pos] == '+')) pos++;
      } else {
        break;
      }
    }

    final literal = text.substring(start, pos);
    final value = double.tryParse(literal);
    if (value == null || !sawDigit) {
      pos = start;
      return null;
    }
    return value;
  }
}

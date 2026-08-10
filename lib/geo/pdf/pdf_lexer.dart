/// Tokenizer y parser de objetos PDF (ISO 32000-1, §7.2 y §7.3).
///
/// Trabaja directo sobre los bytes del archivo: los PDF no son texto y
/// decodificarlos a String rompe los streams binarios.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'pdf_object.dart';

class PdfLexer {
  PdfLexer(this.bytes, {this.pos = 0, this.resolveLength});

  final Uint8List bytes;
  int pos;

  /// Resuelve un `/Length` indirecto. El lexer por sí solo no puede: necesita
  /// la tabla xref del documento. Si es `null` o falla, se busca `endstream`.
  final int? Function(PdfRef ref)? resolveLength;

  bool get atEnd => pos >= bytes.length;

  // -------------------------------------------------------------------------
  // Clases de caracteres (§7.2.2)
  // -------------------------------------------------------------------------

  static bool isWhitespace(int c) =>
      c == 0x00 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D || c == 0x20;

  static bool isDelimiter(int c) =>
      c == 0x28 || // (
      c == 0x29 || // )
      c == 0x3C || // <
      c == 0x3E || // >
      c == 0x5B || // [
      c == 0x5D || // ]
      c == 0x7B || // {
      c == 0x7D || // }
      c == 0x2F || // /
      c == 0x25; //  %

  static bool isRegular(int c) => !isWhitespace(c) && !isDelimiter(c);

  static bool isDigit(int c) => c >= 0x30 && c <= 0x39;

  // -------------------------------------------------------------------------
  // Navegación
  // -------------------------------------------------------------------------

  void skipWhitespace() {
    while (!atEnd) {
      final c = bytes[pos];
      if (isWhitespace(c)) {
        pos++;
      } else if (c == 0x25) {
        // comentario: hasta fin de línea
        while (!atEnd && bytes[pos] != 0x0A && bytes[pos] != 0x0D) {
          pos++;
        }
      } else {
        return;
      }
    }
  }

  /// Lee una secuencia de caracteres regulares (una palabra clave como
  /// `obj`, `stream`, `xref`, `trailer`).
  String readToken() {
    skipWhitespace();
    final start = pos;
    while (!atEnd && isRegular(bytes[pos])) {
      pos++;
    }
    return latin1.decode(bytes.sublist(start, pos), allowInvalid: true);
  }

  /// Mira la siguiente palabra clave sin consumirla.
  String peekToken() {
    final save = pos;
    final token = readToken();
    pos = save;
    return token;
  }

  bool tryReadKeyword(String keyword) {
    final save = pos;
    if (readToken() == keyword) return true;
    pos = save;
    return false;
  }

  void expectKeyword(String keyword) {
    final save = pos;
    final token = readToken();
    if (token != keyword) {
      throw PdfSyntaxException("Se esperaba '$keyword' y vino '$token'", save);
    }
  }

  // -------------------------------------------------------------------------
  // Parseo de objetos
  // -------------------------------------------------------------------------

  PdfObject parseObject() {
    skipWhitespace();
    if (atEnd) throw PdfSyntaxException('Fin de archivo inesperado', pos);

    final c = bytes[pos];
    switch (c) {
      case 0x2F: // /
        return _parseName();
      case 0x28: // (
        return _parseLiteralString();
      case 0x5B: // [
        return _parseArray();
      case 0x3C: // <
        if (pos + 1 < bytes.length && bytes[pos + 1] == 0x3C) {
          return _parseDictOrStream();
        }
        return _parseHexString();
      case 0x5D: // ]
      case 0x3E: // >
      case 0x29: // )
        throw PdfSyntaxException(
            'Delimitador de cierre inesperado: ${String.fromCharCode(c)}', pos);
    }

    if (isDigit(c) || c == 0x2B || c == 0x2D || c == 0x2E) {
      return _parseNumberOrRef();
    }

    return _parseKeyword();
  }

  PdfObject _parseKeyword() {
    final start = pos;
    final token = readToken();
    switch (token) {
      case 'true':
        return const PdfBool(true);
      case 'false':
        return const PdfBool(false);
      case 'null':
        return const PdfNull();
    }
    if (token.isEmpty) {
      // Byte no reconocible: avanzamos para no colgarnos en un bucle.
      pos = start + 1;
      throw PdfSyntaxException('Byte inesperado: ${bytes[start]}', start);
    }
    // Palabra clave desconocida (PDF ligeramente malformado): la tratamos como
    // null en lugar de abortar toda la lectura.
    return const PdfNull();
  }

  PdfName _parseName() {
    pos++; // consume '/'
    final out = <int>[];
    while (!atEnd && isRegular(bytes[pos])) {
      var c = bytes[pos++];
      if (c == 0x23 && pos + 1 < bytes.length) {
        final h1 = _hexValue(bytes[pos]);
        final h2 = _hexValue(bytes[pos + 1]);
        if (h1 >= 0 && h2 >= 0) {
          c = (h1 << 4) | h2;
          pos += 2;
        }
      }
      out.add(c);
    }
    return PdfName(latin1.decode(out, allowInvalid: true));
  }

  PdfString _parseLiteralString() {
    pos++; // consume '('
    final out = <int>[];
    var depth = 1;

    while (!atEnd) {
      var c = bytes[pos++];

      if (c == 0x5C) {
        // barra invertida
        if (atEnd) break;
        c = bytes[pos++];
        switch (c) {
          case 0x6E:
            out.add(0x0A); // \n
          case 0x72:
            out.add(0x0D); // \r
          case 0x74:
            out.add(0x09); // \t
          case 0x62:
            out.add(0x08); // \b
          case 0x66:
            out.add(0x0C); // \f
          case 0x28:
          case 0x29:
          case 0x5C:
            out.add(c);
          case 0x0D:
            // continuación de línea: \CRLF o \CR
            if (!atEnd && bytes[pos] == 0x0A) pos++;
          case 0x0A:
            break; // continuación de línea
          default:
            if (c >= 0x30 && c <= 0x37) {
              // escape octal de hasta 3 dígitos
              var value = c - 0x30;
              for (var i = 0; i < 2 && !atEnd; i++) {
                final d = bytes[pos];
                if (d < 0x30 || d > 0x37) break;
                value = value * 8 + (d - 0x30);
                pos++;
              }
              out.add(value & 0xFF);
            } else {
              out.add(c);
            }
        }
        continue;
      }

      if (c == 0x28) {
        depth++;
        out.add(c);
      } else if (c == 0x29) {
        depth--;
        if (depth == 0) break;
        out.add(c);
      } else {
        out.add(c);
      }
    }

    return PdfString(Uint8List.fromList(out));
  }

  PdfString _parseHexString() {
    pos++; // consume '<'
    final out = <int>[];
    var high = -1;

    while (!atEnd) {
      final c = bytes[pos++];
      if (c == 0x3E) break; // '>'
      final v = _hexValue(c);
      if (v < 0) continue; // espacios en blanco y basura
      if (high < 0) {
        high = v;
      } else {
        out.add((high << 4) | v);
        high = -1;
      }
    }
    if (high >= 0) out.add(high << 4); // dígito impar → se rellena con 0

    return PdfString(Uint8List.fromList(out));
  }

  PdfArray _parseArray() {
    pos++; // consume '['
    final items = <PdfObject>[];

    while (true) {
      skipWhitespace();
      if (atEnd) break;
      if (bytes[pos] == 0x5D) {
        pos++; // consume ']'
        break;
      }
      try {
        items.add(parseObject());
      } on PdfSyntaxException {
        // Elemento corrupto: lo saltamos y seguimos con el resto del array.
        break;
      }
    }

    return PdfArray(items);
  }

  PdfObject _parseDictOrStream() {
    final dict = _parseDict();

    final save = pos;
    skipWhitespace();
    if (!_matchesAt(pos, 'stream')) {
      pos = save;
      return dict;
    }

    pos += 'stream'.length;
    // Tras 'stream' debe venir CRLF o LF (§7.3.8.1).
    if (!atEnd && bytes[pos] == 0x0D) pos++;
    if (!atEnd && bytes[pos] == 0x0A) pos++;

    final dataStart = pos;
    final length = _resolveStreamLength(dict);

    int dataEnd;
    if (length != null &&
        length >= 0 &&
        dataStart + length <= bytes.length &&
        _endstreamFollows(dataStart + length)) {
      dataEnd = dataStart + length;
    } else {
      // /Length ausente, indirecto no resoluble, o simplemente mal: buscamos
      // el 'endstream' literal. Es lento pero salva PDFs mal generados.
      final found = _findEndstream(dataStart);
      dataEnd = found ?? bytes.length;
    }

    final raw = Uint8List.sublistView(bytes, dataStart, dataEnd);
    pos = dataEnd;
    skipWhitespace();
    tryReadKeyword('endstream');

    return PdfStream(dict, raw);
  }

  PdfDict _parseDict() {
    pos += 2; // consume '<<'
    final entries = <String, PdfObject>{};

    while (true) {
      skipWhitespace();
      if (atEnd) break;
      if (bytes[pos] == 0x3E) {
        if (pos + 1 < bytes.length && bytes[pos + 1] == 0x3E) {
          pos += 2; // consume '>>'
          break;
        }
        pos++; // '>' suelto: lo ignoramos
        continue;
      }
      if (bytes[pos] != 0x2F) {
        // Clave que no es un nombre: diccionario malformado. Intentamos
        // consumir un objeto para avanzar y seguimos.
        try {
          parseObject();
        } on PdfSyntaxException {
          break;
        }
        continue;
      }

      final key = _parseName().value;
      try {
        entries[key] = parseObject();
      } on PdfSyntaxException {
        entries[key] = const PdfNull();
        break;
      }
    }

    return PdfDict(entries);
  }

  PdfObject _parseNumberOrRef() {
    final (value, isInteger) = _readNumber();

    if (isInteger && value >= 0) {
      // Puede ser el inicio de una referencia indirecta: `num gen R`.
      final save = pos;
      skipWhitespace();
      if (!atEnd && isDigit(bytes[pos])) {
        final (gen, genIsInt) = _readNumber();
        if (genIsInt && gen >= 0) {
          skipWhitespace();
          if (!atEnd &&
              bytes[pos] == 0x52 && // 'R'
              (pos + 1 >= bytes.length || !isRegular(bytes[pos + 1]))) {
            pos++;
            return PdfRef(value.toInt(), gen.toInt());
          }
        }
      }
      pos = save;
    }

    return PdfNumber(value);
  }

  (num, bool) _readNumber() {
    skipWhitespace();
    final start = pos;
    var isInteger = true;

    if (!atEnd && (bytes[pos] == 0x2B || bytes[pos] == 0x2D)) pos++;
    while (!atEnd) {
      final c = bytes[pos];
      if (isDigit(c)) {
        pos++;
      } else if (c == 0x2E) {
        isInteger = false;
        pos++;
      } else if (c == 0x2B || c == 0x2D) {
        // Signo interno: aparece en números malformados tipo `1-2`. Lo
        // consumimos para no atascarnos.
        pos++;
      } else {
        break;
      }
    }

    final text = latin1.decode(bytes.sublist(start, pos), allowInvalid: true);
    if (text.isEmpty || text == '-' || text == '+' || text == '.') {
      throw PdfSyntaxException('Número inválido: "$text"', start);
    }

    if (isInteger) {
      final parsed = int.tryParse(text);
      if (parsed != null) return (parsed, true);
    }
    final parsed = double.tryParse(text);
    if (parsed == null) {
      throw PdfSyntaxException('Número inválido: "$text"', start);
    }
    return (parsed, false);
  }

  // -------------------------------------------------------------------------
  // Auxiliares de stream
  // -------------------------------------------------------------------------

  int? _resolveStreamLength(PdfDict dict) {
    final raw = dict['Length'];
    if (raw is PdfNumber) return raw.asInt;
    if (raw is PdfRef) return resolveLength?.call(raw);
    return null;
  }

  /// Verifica que en [at] (tras espacios) venga `endstream`, para validar un
  /// `/Length` antes de confiar en él.
  bool _endstreamFollows(int at) {
    var i = at;
    var skipped = 0;
    while (i < bytes.length && isWhitespace(bytes[i]) && skipped < 4) {
      i++;
      skipped++;
    }
    return _matchesAt(i, 'endstream');
  }

  int? _findEndstream(int from) {
    const needle = 'endstream';
    for (var i = from; i <= bytes.length - needle.length; i++) {
      if (bytes[i] == 0x65 && _matchesAt(i, needle)) {
        // Recortamos el EOL que precede a 'endstream' y que no es parte de
        // los datos (§7.3.8.1).
        var end = i;
        if (end > from && bytes[end - 1] == 0x0A) end--;
        if (end > from && bytes[end - 1] == 0x0D) end--;
        return end;
      }
    }
    return null;
  }

  bool _matchesAt(int at, String literal) {
    if (at + literal.length > bytes.length) return false;
    for (var i = 0; i < literal.length; i++) {
      if (bytes[at + i] != literal.codeUnitAt(i)) return false;
    }
    return true;
  }

  static int _hexValue(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    return -1;
  }
}

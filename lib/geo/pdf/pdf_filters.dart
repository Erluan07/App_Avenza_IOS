/// Filtros de stream de PDF (ISO 32000-1, §7.4) y predictores (§7.4.4.4).
///
/// Solo se implementan los que aparecen en la práctica en exportaciones de
/// ArcGIS Pro: FlateDecode (con predictores PNG/TIFF), ASCIIHex y ASCII85.
/// Los filtros de imagen (DCT, JPX, CCITT) se dejan sin decodificar: no nos
/// interesan, porque el rasterizado de la página lo hace PDFium, no nosotros.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'pdf_object.dart';

/// Filtros que no decodificamos pero que tampoco son un error: son datos de
/// imagen que este lector nunca necesita inspeccionar.
const Set<String> kImageFilters = {
  'DCTDecode',
  'JPXDecode',
  'CCITTFaxDecode',
  'JBIG2Decode',
};

class PdfFilterException implements Exception {
  PdfFilterException(this.message);

  final String message;

  @override
  String toString() => 'PdfFilterException: $message';
}

/// Aplica un único filtro. [parms] ya debe venir con las referencias resueltas.
Uint8List applyFilter(String name, Uint8List data, PdfDict? parms) {
  switch (name) {
    case 'FlateDecode':
    case 'Fl':
      return _applyPredictor(_inflate(data), parms);
    case 'LZWDecode':
    case 'LZW':
      final early = (parms?['EarlyChange'] as PdfNumber?)?.asInt ?? 1;
      return _applyPredictor(_lzwDecode(data, early), parms);
    case 'ASCIIHexDecode':
    case 'AHx':
      return _asciiHexDecode(data);
    case 'ASCII85Decode':
    case 'A85':
      return _ascii85Decode(data);
    case 'RunLengthDecode':
    case 'RL':
      return _runLengthDecode(data);
    default:
      if (kImageFilters.contains(name)) return data;
      throw PdfFilterException('Filtro no soportado: /$name');
  }
}

// ---------------------------------------------------------------------------
// Flate
// ---------------------------------------------------------------------------

/// zlib primero; si el productor omitió la cabecera zlib (pasa con algunos
/// generadores), reintenta como deflate crudo. Como último recurso reintenta
/// saltando bytes basura iniciales, que es el modo de fallo típico de un PDF
/// levemente corrupto.
Uint8List _inflate(Uint8List data) {
  if (data.isEmpty) return Uint8List(0);

  try {
    return Uint8List.fromList(const ZLibDecoder().decodeBytes(data));
  } catch (_) {
    // sigue
  }
  try {
    // Sin cabecera zlib: deflate crudo.
    return Uint8List.fromList(Inflate(data).getBytes());
  } catch (_) {
    // sigue
  }
  for (var skip = 1; skip <= 2 && skip < data.length; skip++) {
    try {
      return Uint8List.fromList(
        const ZLibDecoder().decodeBytes(data.sublist(skip)),
      );
    } catch (_) {
      // sigue
    }
  }
  throw PdfFilterException('No se pudo descomprimir el stream FlateDecode');
}

// ---------------------------------------------------------------------------
// Predictores
// ---------------------------------------------------------------------------

Uint8List _applyPredictor(Uint8List data, PdfDict? parms) {
  if (parms == null) return data;
  final predictor = (parms['Predictor'] as PdfNumber?)?.asInt ?? 1;
  if (predictor <= 1) return data;

  final colors = (parms['Colors'] as PdfNumber?)?.asInt ?? 1;
  final bpc = (parms['BitsPerComponent'] as PdfNumber?)?.asInt ?? 8;
  final columns = (parms['Columns'] as PdfNumber?)?.asInt ?? 1;

  if (predictor == 2) return _undoTiffPredictor(data, colors, bpc, columns);
  return _undoPngPredictor(data, colors, bpc, columns);
}

/// Deshace los predictores PNG (valores 10..15). Cada fila del stream viene
/// precedida por un byte con el tipo de filtro aplicado a esa fila.
Uint8List _undoPngPredictor(
  Uint8List data,
  int colors,
  int bitsPerComponent,
  int columns,
) {
  final bpp = ((colors * bitsPerComponent) / 8).ceil().clamp(1, 1 << 20);
  final rowLength = ((colors * bitsPerComponent * columns) / 8).ceil();

  final out = BytesBuilder(copy: false);
  var prev = Uint8List(rowLength);
  var pos = 0;

  while (pos + 1 <= data.length - 1) {
    final filterType = data[pos++];
    final available = data.length - pos;
    if (available <= 0) break;
    final take = available < rowLength ? available : rowLength;
    final row = Uint8List(rowLength);
    row.setRange(0, take, data, pos);
    pos += take;

    switch (filterType) {
      case 0: // None
        break;
      case 1: // Sub
        for (var i = bpp; i < rowLength; i++) {
          row[i] = (row[i] + row[i - bpp]) & 0xFF;
        }
      case 2: // Up
        for (var i = 0; i < rowLength; i++) {
          row[i] = (row[i] + prev[i]) & 0xFF;
        }
      case 3: // Average
        for (var i = 0; i < rowLength; i++) {
          final left = i >= bpp ? row[i - bpp] : 0;
          row[i] = (row[i] + ((left + prev[i]) >> 1)) & 0xFF;
        }
      case 4: // Paeth
        for (var i = 0; i < rowLength; i++) {
          final a = i >= bpp ? row[i - bpp] : 0;
          final b = prev[i];
          final c = i >= bpp ? prev[i - bpp] : 0;
          row[i] = (row[i] + _paeth(a, b, c)) & 0xFF;
        }
      default:
        throw PdfFilterException('Predictor PNG desconocido: $filterType');
    }

    out.add(row);
    prev = row;
  }

  return out.toBytes();
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

Uint8List _undoTiffPredictor(
  Uint8List data,
  int colors,
  int bitsPerComponent,
  int columns,
) {
  if (bitsPerComponent != 8) {
    // Los xref streams siempre son de 8 bits; otros casos no nos hacen falta.
    return data;
  }
  final rowLength = colors * columns;
  final out = Uint8List.fromList(data);
  for (var rowStart = 0; rowStart + rowLength <= out.length;
      rowStart += rowLength) {
    for (var i = colors; i < rowLength; i++) {
      out[rowStart + i] = (out[rowStart + i] + out[rowStart + i - colors]) & 0xFF;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Filtros ASCII y RunLength
// ---------------------------------------------------------------------------

Uint8List _asciiHexDecode(Uint8List data) {
  final out = BytesBuilder(copy: false);
  var high = -1;
  for (final c in data) {
    if (c == 0x3E) break; // '>' fin de datos
    final v = _hexValue(c);
    if (v < 0) continue; // espacios en blanco
    if (high < 0) {
      high = v;
    } else {
      out.addByte((high << 4) | v);
      high = -1;
    }
  }
  if (high >= 0) out.addByte(high << 4); // dígito impar: se rellena con 0
  return out.toBytes();
}

int _hexValue(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
}

Uint8List _ascii85Decode(Uint8List data) {
  final out = BytesBuilder(copy: false);
  final group = <int>[];
  var i = 0;

  // Prefijo opcional '<~'
  if (data.length >= 2 && data[0] == 0x3C && data[1] == 0x7E) i = 2;

  for (; i < data.length; i++) {
    final c = data[i];
    if (c == 0x7E) break; // '~>' fin de datos
    if (c <= 0x20 || c == 0) continue; // espacios en blanco
    if (c == 0x7A && group.isEmpty) {
      // 'z' abrevia un grupo de cuatro ceros
      out.add(const [0, 0, 0, 0]);
      continue;
    }
    if (c < 0x21 || c > 0x75) {
      throw PdfFilterException('Carácter inválido en ASCII85: $c');
    }
    group.add(c - 0x21);
    if (group.length == 5) {
      _emitAscii85Group(out, group, 4);
      group.clear();
    }
  }

  if (group.isNotEmpty) {
    final n = group.length - 1;
    while (group.length < 5) {
      group.add(84); // rellena con 'u'
    }
    _emitAscii85Group(out, group, n);
  }
  return out.toBytes();
}

void _emitAscii85Group(BytesBuilder out, List<int> group, int count) {
  var value = 0;
  for (final g in group) {
    value = value * 85 + g;
  }
  final bytes = [
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ];
  out.add(bytes.take(count).toList());
}

Uint8List _runLengthDecode(Uint8List data) {
  final out = BytesBuilder(copy: false);
  var i = 0;
  while (i < data.length) {
    final len = data[i++];
    if (len == 128) break; // EOD
    if (len < 128) {
      final count = len + 1;
      if (i + count > data.length) break;
      out.add(data.sublist(i, i + count));
      i += count;
    } else {
      if (i >= data.length) break;
      final b = data[i++];
      out.add(List<int>.filled(257 - len, b));
    }
  }
  return out.toBytes();
}

// ---------------------------------------------------------------------------
// LZW
// ---------------------------------------------------------------------------

Uint8List _lzwDecode(Uint8List data, int earlyChange) {
  final out = BytesBuilder(copy: false);
  var dict = <List<int>>[];

  void resetDict() {
    dict = List<List<int>>.generate(256, (i) => <int>[i])
      ..add(<int>[]) // 256: clear
      ..add(<int>[]); // 257: EOD
  }

  resetDict();
  var codeWidth = 9;
  var bitBuffer = 0;
  var bitCount = 0;
  List<int>? previous;

  for (final byte in data) {
    bitBuffer = (bitBuffer << 8) | byte;
    bitCount += 8;

    while (bitCount >= codeWidth) {
      final code = (bitBuffer >> (bitCount - codeWidth)) & ((1 << codeWidth) - 1);
      bitCount -= codeWidth;

      if (code == 256) {
        resetDict();
        codeWidth = 9;
        previous = null;
        continue;
      }
      if (code == 257) return out.toBytes();

      List<int> entry;
      if (code < dict.length) {
        entry = dict[code];
        if (previous != null) dict.add([...previous, entry.first]);
      } else if (previous != null) {
        entry = [...previous, previous.first];
        dict.add(entry);
      } else {
        throw PdfFilterException('Código LZW inválido: $code');
      }

      out.add(entry);
      previous = entry;

      final limit = dict.length + earlyChange;
      if (limit >= 512 && codeWidth == 9) {
        codeWidth = 10;
      } else if (limit >= 1024 && codeWidth == 10) {
        codeWidth = 11;
      } else if (limit >= 2048 && codeWidth == 11) {
        codeWidth = 12;
      }
    }
  }

  return out.toBytes();
}

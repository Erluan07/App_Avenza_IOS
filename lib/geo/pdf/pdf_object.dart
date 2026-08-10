/// Modelo de objetos del formato PDF (ISO 32000-1, §7.3).
///
/// Dart puro a propósito: nada de este archivo importa Flutter, para poder
/// testear el parser con `dart test` sin levantar un emulador.
library;

import 'dart:convert';
import 'dart:typed_data';

sealed class PdfObject {
  const PdfObject();
}

class PdfNull extends PdfObject {
  const PdfNull();

  @override
  String toString() => 'null';
}

class PdfBool extends PdfObject {
  const PdfBool(this.value);

  final bool value;

  @override
  String toString() => '$value';
}

class PdfNumber extends PdfObject {
  const PdfNumber(this.value);

  final num value;

  double get asDouble => value.toDouble();
  int get asInt => value.toInt();

  @override
  String toString() => '$value';
}

class PdfString extends PdfObject {
  const PdfString(this.bytes);

  final Uint8List bytes;

  /// Decodifica según §7.9.2.2: UTF-16BE si trae BOM, si no PDFDocEncoding
  /// (aproximada con Latin-1, suficiente para los nombres de viewport que
  /// escribe ArcGIS Pro).
  String get asText {
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      final codes = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        codes.add((bytes[i] << 8) | bytes[i + 1]);
      }
      return String.fromCharCodes(codes);
    }
    return latin1.decode(bytes, allowInvalid: true);
  }

  @override
  String toString() => '($asText)';
}

class PdfName extends PdfObject {
  const PdfName(this.value);

  final String value;

  @override
  bool operator ==(Object other) => other is PdfName && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '/$value';
}

class PdfArray extends PdfObject {
  const PdfArray(this.items);

  final List<PdfObject> items;

  int get length => items.length;
  PdfObject operator [](int i) => items[i];

  @override
  String toString() => '[${items.join(' ')}]';
}

class PdfDict extends PdfObject {
  const PdfDict(this.entries);

  final Map<String, PdfObject> entries;

  PdfObject? operator [](String key) => entries[key];
  bool has(String key) => entries.containsKey(key);

  @override
  String toString() =>
      '<<${entries.entries.map((e) => '/${e.key} ${e.value}').join(' ')}>>';
}

/// Un stream: diccionario + bytes crudos (todavía sin aplicar `/Filter`).
///
/// El decodificado vive en [PdfDocument.streamData], porque puede requerir
/// resolver referencias indirectas (`/Length`, `/DecodeParms`).
class PdfStream extends PdfObject {
  const PdfStream(this.dict, this.rawBytes);

  final PdfDict dict;
  final Uint8List rawBytes;

  @override
  String toString() => '$dict stream(${rawBytes.length} bytes)';
}

/// Referencia indirecta: `12 0 R`.
class PdfRef extends PdfObject {
  const PdfRef(this.objectNumber, this.generation);

  final int objectNumber;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is PdfRef &&
      other.objectNumber == objectNumber &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(objectNumber, generation);

  @override
  String toString() => '$objectNumber $generation R';
}

class PdfSyntaxException implements Exception {
  PdfSyntaxException(this.message, [this.offset]);

  final String message;
  final int? offset;

  @override
  String toString() =>
      'PdfSyntaxException: $message${offset != null ? ' (offset $offset)' : ''}';
}

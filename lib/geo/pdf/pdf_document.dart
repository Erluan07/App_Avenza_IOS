/// Lectura de la estructura de un archivo PDF: tabla de referencias cruzadas,
/// resolución de objetos indirectos, object streams y árbol de páginas.
///
/// ArcGIS Pro exporta PDF 1.7 con **xref streams** y **object streams
/// comprimidos**, así que buscar `/Measure` a mano por el archivo no alcanza:
/// el diccionario casi siempre está dentro de un stream Flate.
library;

import 'dart:typed_data';

import 'pdf_filters.dart';
import 'pdf_lexer.dart';
import 'pdf_object.dart';

class PdfEncryptedException implements Exception {
  @override
  String toString() =>
      'PdfEncryptedException: el PDF está cifrado y no se puede leer su '
      'georreferencia sin la contraseña.';
}

sealed class _XrefEntry {
  const _XrefEntry();
}

class _XrefOffset extends _XrefEntry {
  const _XrefOffset(this.offset, this.generation);

  final int offset;
  final int generation;
}

class _XrefInObjStm extends _XrefEntry {
  const _XrefInObjStm(this.streamNumber, this.indexInStream);

  final int streamNumber;
  final int indexInStream;
}

/// Una página del documento, con los atributos heredables ya fusionados.
class PdfPage {
  const PdfPage({
    required this.index,
    required this.dict,
    required this.mediaBox,
    this.cropBox,
    this.rotate = 0,
    this.viewports,
  });

  /// Índice 0-based dentro del documento.
  final int index;
  final PdfDict dict;

  /// `[x0, y0, x1, y1]` en puntos PDF, origen abajo-izquierda.
  final List<double> mediaBox;
  final List<double>? cropBox;
  final int rotate;

  /// Contenido de `/VP`: los viewports georreferenciados, si los hay.
  final PdfArray? viewports;

  double get widthPt => (mediaBox[2] - mediaBox[0]).abs();
  double get heightPt => (mediaBox[3] - mediaBox[1]).abs();
}

class PdfDocument {
  PdfDocument._(this.bytes);

  final Uint8List bytes;

  final Map<int, _XrefEntry> _xref = {};
  final Map<int, PdfObject> _objectCache = {};
  final Map<int, Map<int, PdfObject>> _objStmCache = {};
  final Set<int> _resolvingLength = {};

  PdfDict? _trailer;
  bool _rebuilt = false;

  PdfDict? get trailer => _trailer;

  /// Lee la estructura del PDF. Si la tabla xref está rota o incompleta,
  /// reconstruye barriendo el archivo en busca de cabeceras `N G obj`.
  static PdfDocument parse(Uint8List bytes) {
    final doc = PdfDocument._(bytes);

    try {
      doc._parseXrefChain();
    } catch (_) {
      doc._xref.clear();
      doc._trailer = null;
    }

    if (doc._xref.isEmpty || doc.catalog == null) {
      doc._rebuildByScan();
    }

    if (doc._trailer?['Encrypt'] != null) throw PdfEncryptedException();

    return doc;
  }

  // -------------------------------------------------------------------------
  // Resolución de objetos
  // -------------------------------------------------------------------------

  /// Sigue referencias indirectas hasta llegar a un objeto directo.
  PdfObject? resolve(PdfObject? obj) {
    var current = obj;
    var hops = 0;
    while (current is PdfRef) {
      if (++hops > 32) return null; // cadena circular
      current = object(current.objectNumber);
    }
    return current;
  }

  /// Resuelve y castea, devolviendo `null` si el tipo no coincide.
  T? resolveAs<T extends PdfObject>(PdfObject? obj) {
    final r = resolve(obj);
    return r is T ? r : null;
  }

  double? resolveNumber(PdfObject? obj) => resolveAs<PdfNumber>(obj)?.asDouble;

  PdfObject? object(int number) {
    final cached = _objectCache[number];
    if (cached != null) return cached;

    var entry = _xref[number];

    // Offset ausente o inválido: reconstruimos una sola vez y reintentamos.
    if (entry == null && !_rebuilt) {
      _rebuildByScan();
      entry = _xref[number];
    }
    if (entry == null) return null;

    PdfObject? parsed;
    switch (entry) {
      case _XrefOffset(:final offset):
        parsed = _parseIndirectAt(offset, expectedNumber: number);
        if (parsed == null && !_rebuilt) {
          _rebuildByScan();
          final retry = _xref[number];
          if (retry is _XrefOffset) {
            parsed = _parseIndirectAt(retry.offset, expectedNumber: number);
          }
        }
      case _XrefInObjStm(:final streamNumber):
        parsed = _loadObjectStream(streamNumber)[number];
    }

    if (parsed != null) _objectCache[number] = parsed;
    return parsed;
  }

  /// Devuelve los bytes de un stream con todos sus `/Filter` aplicados.
  Uint8List streamData(PdfStream stream) {
    final filterObj = resolve(stream.dict['Filter']);
    if (filterObj == null || filterObj is PdfNull) return stream.rawBytes;

    final filters = <String>[];
    if (filterObj is PdfName) {
      filters.add(filterObj.value);
    } else if (filterObj is PdfArray) {
      for (final f in filterObj.items) {
        final name = resolveAs<PdfName>(f);
        if (name != null) filters.add(name.value);
      }
    }

    final parmsObj = resolve(stream.dict['DecodeParms']) ??
        resolve(stream.dict['DP']);
    final parms = <PdfDict?>[];
    if (parmsObj is PdfDict) {
      parms.add(parmsObj);
    } else if (parmsObj is PdfArray) {
      for (final p in parmsObj.items) {
        parms.add(resolveAs<PdfDict>(p));
      }
    }

    var data = stream.rawBytes;
    for (var i = 0; i < filters.length; i++) {
      final parm = i < parms.length ? parms[i] : null;
      data = applyFilter(filters[i], data, _resolveParms(parm));
    }
    return data;
  }

  /// Los `/DecodeParms` pueden traer valores indirectos; los aplanamos antes
  /// de pasarlos al filtro, que trabaja en Dart puro sin acceso al documento.
  PdfDict? _resolveParms(PdfDict? parms) {
    if (parms == null) return null;
    return PdfDict({
      for (final e in parms.entries.entries) e.key: resolve(e.value) ?? const PdfNull(),
    });
  }

  // -------------------------------------------------------------------------
  // Catálogo y páginas
  // -------------------------------------------------------------------------

  PdfDict? get catalog {
    final root = resolveAs<PdfDict>(_trailer?['Root']);
    if (root != null) return root;

    // Trailer sin /Root utilizable: buscamos el catálogo por barrido.
    for (final number in _xref.keys.toList()) {
      final obj = resolveAs<PdfDict>(object(number));
      if (obj != null && (obj['Type'] as PdfName?)?.value == 'Catalog') {
        return obj;
      }
    }
    return null;
  }

  /// Recorre el árbol de páginas fusionando los atributos heredables
  /// (`/MediaBox`, `/CropBox`, `/Rotate`) desde los nodos ancestros.
  List<PdfPage> get pages {
    final pagesRoot = resolveAs<PdfDict>(catalog?['Pages']);
    final out = <PdfPage>[];
    if (pagesRoot == null) {
      // Sin árbol de páginas: barremos por /Type /Page.
      for (final number in _xref.keys.toList()) {
        final obj = resolveAs<PdfDict>(object(number));
        if (obj != null && (obj['Type'] as PdfName?)?.value == 'Page') {
          out.add(_buildPage(obj, out.length, const {}));
        }
      }
      return out;
    }

    final visited = <PdfDict>{};

    void walk(PdfDict node, Map<String, PdfObject> inherited, int depth) {
      if (depth > 64 || !visited.add(node)) return;

      final merged = Map<String, PdfObject>.from(inherited);
      for (final key in const ['MediaBox', 'CropBox', 'Rotate', 'Resources']) {
        final value = node[key];
        if (value != null) merged[key] = value;
      }

      final type = (node['Type'] as PdfName?)?.value;
      final kids = resolveAs<PdfArray>(node['Kids']);

      if (type == 'Page' || (kids == null && node.has('Contents'))) {
        out.add(_buildPage(node, out.length, merged));
        return;
      }

      if (kids != null) {
        for (final kid in kids.items) {
          final kidDict = resolveAs<PdfDict>(kid);
          if (kidDict != null) walk(kidDict, merged, depth + 1);
        }
      }
    }

    walk(pagesRoot, const {}, 0);
    return out;
  }

  PdfPage _buildPage(
    PdfDict dict,
    int index,
    Map<String, PdfObject> inherited,
  ) {
    PdfObject? attr(String key) => dict[key] ?? inherited[key];

    final mediaBox = _rectangle(attr('MediaBox')) ??
        const [0.0, 0.0, 612.0, 792.0]; // Carta, por defecto
    final cropBox = _rectangle(attr('CropBox'));
    final rotate = resolveNumber(attr('Rotate'))?.toInt() ?? 0;

    return PdfPage(
      index: index,
      dict: dict,
      mediaBox: mediaBox,
      cropBox: cropBox,
      rotate: ((rotate % 360) + 360) % 360,
      viewports: resolveAs<PdfArray>(dict['VP']),
    );
  }

  /// Normaliza un rectángulo PDF a `[minX, minY, maxX, maxY]`: el formato
  /// permite las esquinas en cualquier orden (§7.9.5).
  List<double>? _rectangle(PdfObject? obj) {
    final arr = resolveAs<PdfArray>(obj);
    if (arr == null || arr.length < 4) return null;
    final v = <double>[];
    for (var i = 0; i < 4; i++) {
      final n = resolveNumber(arr[i]);
      if (n == null) return null;
      v.add(n);
    }
    return [
      v[0] < v[2] ? v[0] : v[2],
      v[1] < v[3] ? v[1] : v[3],
      v[0] < v[2] ? v[2] : v[0],
      v[1] < v[3] ? v[3] : v[1],
    ];
  }

  // -------------------------------------------------------------------------
  // Tabla de referencias cruzadas
  // -------------------------------------------------------------------------

  PdfLexer _lexerAt(int offset, [Uint8List? source]) => PdfLexer(
        source ?? bytes,
        pos: offset,
        resolveLength: _resolveLengthRef,
      );

  int? _resolveLengthRef(PdfRef ref) {
    // Guarda contra un /Length que apunte (directa o indirectamente) al propio
    // objeto que estamos parseando.
    if (!_resolvingLength.add(ref.objectNumber)) return null;
    try {
      return resolveAs<PdfNumber>(object(ref.objectNumber))?.asInt;
    } catch (_) {
      return null;
    } finally {
      _resolvingLength.remove(ref.objectNumber);
    }
  }

  void _parseXrefChain() {
    final start = _findStartXref();
    if (start == null) throw PdfSyntaxException('No se encontró startxref');

    final pending = <int>[start];
    final visited = <int>{};

    while (pending.isNotEmpty) {
      final offset = pending.removeAt(0);
      if (offset < 0 || offset >= bytes.length || !visited.add(offset)) {
        continue;
      }

      final trailerDict = _parseXrefSectionAt(offset);
      if (trailerDict == null) continue;

      // El trailer más nuevo manda (es el primero que visitamos).
      _trailer ??= trailerDict;

      // Los PDF híbridos tienen tabla clásica + xref stream con los objetos
      // comprimidos; hay que leer ambos.
      final xrefStm = resolveAs<PdfNumber>(trailerDict['XRefStm'])?.asInt;
      if (xrefStm != null) pending.add(xrefStm);

      final prev = resolveAs<PdfNumber>(trailerDict['Prev'])?.asInt;
      if (prev != null) pending.add(prev);
    }

    if (_trailer == null) throw PdfSyntaxException('No se encontró el trailer');
  }

  /// Devuelve el trailer de la sección, o `null` si no se pudo leer.
  PdfDict? _parseXrefSectionAt(int offset) {
    final lexer = _lexerAt(offset);
    lexer.skipWhitespace();

    if (lexer.peekToken() == 'xref') {
      lexer.readToken();
      return _parseClassicXref(lexer);
    }
    return _parseXrefStream(offset);
  }

  PdfDict? _parseClassicXref(PdfLexer lexer) {
    while (true) {
      lexer.skipWhitespace();
      if (lexer.atEnd) return null;

      if (lexer.peekToken() == 'trailer') {
        lexer.readToken();
        final obj = lexer.parseObject();
        return obj is PdfDict ? obj : null;
      }

      final startTok = lexer.readToken();
      final countTok = lexer.readToken();
      final sectionStart = int.tryParse(startTok);
      final count = int.tryParse(countTok);
      if (sectionStart == null || count == null || count < 0) return null;

      for (var i = 0; i < count; i++) {
        final offsetTok = lexer.readToken();
        final genTok = lexer.readToken();
        final typeTok = lexer.readToken();

        final entryOffset = int.tryParse(offsetTok);
        final generation = int.tryParse(genTok) ?? 0;
        if (entryOffset == null) return null;

        final number = sectionStart + i;
        // 'n' = en uso, 'f' = libre. Las entradas ya cargadas por una sección
        // más nueva no se pisan.
        if (typeTok == 'n' && !_xref.containsKey(number)) {
          _xref[number] = _XrefOffset(entryOffset, generation);
        }
      }
    }
  }

  PdfDict? _parseXrefStream(int offset) {
    final obj = _parseIndirectAt(offset);
    if (obj is! PdfStream) return null;

    final dict = obj.dict;
    if ((dict['Type'] as PdfName?)?.value != 'XRef') return null;

    final Uint8List data;
    try {
      data = streamData(obj);
    } catch (_) {
      return null;
    }

    final wArray = resolveAs<PdfArray>(dict['W']);
    if (wArray == null || wArray.length < 3) return null;
    final widths = [
      for (final w in wArray.items) resolveNumber(w)?.toInt() ?? 0,
    ];

    final size = resolveAs<PdfNumber>(dict['Size'])?.asInt ?? 0;
    final indexArray = resolveAs<PdfArray>(dict['Index']);
    final ranges = <(int, int)>[];
    if (indexArray != null) {
      for (var i = 0; i + 1 < indexArray.length; i += 2) {
        ranges.add((
          resolveNumber(indexArray[i])?.toInt() ?? 0,
          resolveNumber(indexArray[i + 1])?.toInt() ?? 0,
        ));
      }
    } else {
      ranges.add((0, size));
    }

    final rowLength = widths.fold<int>(0, (a, b) => a + b);
    if (rowLength <= 0) return null;

    var cursor = 0;
    for (final (rangeStart, rangeCount) in ranges) {
      for (var i = 0; i < rangeCount; i++) {
        if (cursor + rowLength > data.length) break;

        final fields = <int>[];
        for (final width in widths) {
          var value = 0;
          for (var b = 0; b < width; b++) {
            value = (value << 8) | data[cursor++];
          }
          fields.add(value);
        }

        // /W [0 ...] significa que el tipo se omite y vale 1 (§7.5.8.2).
        final type = widths[0] == 0 ? 1 : fields[0];
        final f2 = fields.length > 1 ? fields[1] : 0;
        final f3 = fields.length > 2 ? fields[2] : 0;
        final number = rangeStart + i;

        if (_xref.containsKey(number)) continue;
        if (type == 1) {
          _xref[number] = _XrefOffset(f2, f3);
        } else if (type == 2) {
          _xref[number] = _XrefInObjStm(f2, f3);
        }
        // type == 0 → entrada libre, se ignora
      }
    }

    return dict;
  }

  int? _findStartXref() {
    const needle = 'startxref';
    final from = bytes.length > 4096 ? bytes.length - 4096 : 0;
    for (var i = bytes.length - needle.length; i >= from; i--) {
      if (_matchesAt(i, needle)) {
        final lexer = _lexerAt(i + needle.length);
        return int.tryParse(lexer.readToken());
      }
    }
    return null;
  }

  PdfObject? _parseIndirectAt(int offset, {int? expectedNumber}) {
    if (offset < 0 || offset >= bytes.length) return null;

    final lexer = _lexerAt(offset);
    final numberTok = lexer.readToken();
    lexer.readToken(); // generación
    if (lexer.readToken() != 'obj') return null;

    final number = int.tryParse(numberTok);
    if (number == null) return null;
    if (expectedNumber != null && number != expectedNumber) return null;

    try {
      return lexer.parseObject();
    } on PdfSyntaxException {
      return null;
    }
  }

  Map<int, PdfObject> _loadObjectStream(int streamNumber) {
    final cached = _objStmCache[streamNumber];
    if (cached != null) return cached;

    final result = <int, PdfObject>{};
    // Se registra antes de llenarlo para cortar recursión si un objeto del
    // stream referencia al propio stream.
    _objStmCache[streamNumber] = result;

    final entry = _xref[streamNumber];
    if (entry is! _XrefOffset) return result;

    final stream = _parseIndirectAt(entry.offset, expectedNumber: streamNumber);
    if (stream is! PdfStream) return result;

    final Uint8List data;
    try {
      data = streamData(stream);
    } catch (_) {
      return result;
    }

    final count = resolveAs<PdfNumber>(stream.dict['N'])?.asInt ?? 0;
    final first = resolveAs<PdfNumber>(stream.dict['First'])?.asInt ?? 0;

    // Cabecera: N pares "numeroDeObjeto desplazamiento".
    final header = PdfLexer(data);
    final pairs = <(int, int)>[];
    for (var i = 0; i < count; i++) {
      final objNumber = int.tryParse(header.readToken());
      final objOffset = int.tryParse(header.readToken());
      if (objNumber == null || objOffset == null) break;
      pairs.add((objNumber, objOffset));
    }

    for (final (objNumber, objOffset) in pairs) {
      final at = first + objOffset;
      if (at < 0 || at >= data.length) continue;
      try {
        result[objNumber] = PdfLexer(data, pos: at).parseObject();
      } on PdfSyntaxException {
        // Un objeto ilegible no invalida el resto del stream.
      }
    }

    return result;
  }

  // -------------------------------------------------------------------------
  // Reconstrucción por barrido
  // -------------------------------------------------------------------------

  /// Último recurso cuando la xref está rota: recorre el archivo buscando
  /// cabeceras `N G obj` y arma la tabla desde cero.
  void _rebuildByScan() {
    _rebuilt = true;
    _objectCache.clear();
    _objStmCache.clear();

    final found = <int, _XrefOffset>{};

    for (var i = 0; i + 3 <= bytes.length; i++) {
      // Busca 'obj' precedido por "<numero> <generacion> ".
      if (bytes[i] != 0x6F || !_matchesAt(i, 'obj')) continue;
      if (i + 3 < bytes.length && PdfLexer.isRegular(bytes[i + 3])) continue;

      var j = i - 1;
      while (j >= 0 && PdfLexer.isWhitespace(bytes[j])) {
        j--;
      }
      final genEnd = j + 1;
      while (j >= 0 && PdfLexer.isDigit(bytes[j])) {
        j--;
      }
      final genStart = j + 1;
      if (genStart == genEnd) continue;

      while (j >= 0 && PdfLexer.isWhitespace(bytes[j])) {
        j--;
      }
      final numEnd = j + 1;
      while (j >= 0 && PdfLexer.isDigit(bytes[j])) {
        j--;
      }
      final numStart = j + 1;
      if (numStart == numEnd) continue;

      final number = int.tryParse(
        String.fromCharCodes(bytes.sublist(numStart, numEnd)),
      );
      final generation = int.tryParse(
        String.fromCharCodes(bytes.sublist(genStart, genEnd)),
      );
      if (number == null || generation == null) continue;

      // Gana la definición más tardía: en un PDF con actualizaciones
      // incrementales, la última versión del objeto es la vigente.
      found[number] = _XrefOffset(numStart, generation);
    }

    _xref
      ..clear()
      ..addAll(found);

    // Los objetos comprimidos no aparecen en el barrido: hay que expandir
    // cada /Type /ObjStm y registrar lo que contiene.
    for (final number in found.keys.toList()) {
      final obj = _parseIndirectAt(found[number]!.offset, expectedNumber: number);
      if (obj is! PdfStream) continue;
      if ((obj.dict['Type'] as PdfName?)?.value != 'ObjStm') continue;

      for (final inner in _loadObjectStream(number).keys) {
        if (inner == number) continue; // un ObjStm no puede contenerse a sí mismo
        // El índice no se usa: _loadObjectStream devuelve un mapa por número
        // de objeto, no por posición.
        _xref.putIfAbsent(inner, () => _XrefInObjStm(number, 0));
      }
    }

    _trailer ??= _findTrailerByScan();
  }

  PdfDict? _findTrailerByScan() {
    const needle = 'trailer';
    for (var i = bytes.length - needle.length; i >= 0; i--) {
      if (!_matchesAt(i, needle)) continue;
      final lexer = _lexerAt(i + needle.length);
      try {
        final obj = lexer.parseObject();
        if (obj is PdfDict && obj.has('Root')) return obj;
      } on PdfSyntaxException {
        // seguimos buscando hacia atrás
      }
    }

    // Sin trailer: fabricamos uno apuntando al catálogo que encontremos.
    for (final number in _xref.keys.toList()) {
      final obj = resolveAs<PdfDict>(object(number));
      if (obj != null && (obj['Type'] as PdfName?)?.value == 'Catalog') {
        return PdfDict({'Root': PdfRef(number, 0)});
      }
    }
    return null;
  }

  bool _matchesAt(int at, String literal) {
    if (at < 0 || at + literal.length > bytes.length) return false;
    for (var i = 0; i < literal.length; i++) {
      if (bytes[at + i] != literal.codeUnitAt(i)) return false;
    }
    return true;
  }
}

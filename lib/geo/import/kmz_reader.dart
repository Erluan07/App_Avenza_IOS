/// Lectura de archivos KMZ.
///
/// Un KMZ es un ZIP que contiene un KML y, opcionalmente, la multimedia que
/// este referencia.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'kml_import_models.dart';
import 'kml_reader.dart';

/// Resultado de abrir un KMZ: sus capas más los archivos que traía dentro.
class KmzImportResult {
  const KmzImportResult({required this.data, this.media = const {}});

  final KmlImportResult data;

  /// Archivos del ZIP indexados por su ruta interna, para poder resolver las
  /// imágenes que los globos referencian.
  final Map<String, Uint8List> media;
}

class KmzReader {
  const KmzReader();

  /// Abre un KMZ. Si los bytes son un KML suelto, también los acepta.
  KmzImportResult read(Uint8List bytes) {
    if (!_looksLikeZip(bytes)) {
      // KML sin comprimir: es habitual que la gente comparta el .kml directo.
      return KmzImportResult(data: const KmlReader().read(_decode(bytes)));
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw FormatException('No se pudo abrir el KMZ: $e');
    }

    final media = <String, Uint8List>{};
    ArchiveFile? kmlFile;

    for (final file in archive.files) {
      if (!file.isFile) continue;

      final name = file.name;
      if (name.toLowerCase().endsWith('.kml')) {
        // Se prefiere `doc.kml` en la raíz, que es la convención; si no está,
        // sirve el primer .kml que aparezca.
        final isPreferred = name.toLowerCase() == 'doc.kml';
        if (kmlFile == null || isPreferred) kmlFile = file;
        continue;
      }

      final content = file.content;
      if (content is List<int>) {
        media[name] = Uint8List.fromList(content);
      }
    }

    if (kmlFile == null) {
      throw const FormatException(
        'El KMZ no contiene ningún archivo .kml dentro.',
      );
    }

    final content = kmlFile.content;
    if (content is! List<int>) {
      throw const FormatException('El KML del KMZ está vacío.');
    }

    return KmzImportResult(
      data: const KmlReader().read(_decode(Uint8List.fromList(content))),
      media: media,
    );
  }

  /// Los ZIP empiezan por `PK\x03\x04`.
  bool _looksLikeZip(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4B &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04;

  /// Decodifica el XML.
  ///
  /// Se intenta UTF-8 primero y se cae a Latin-1 si falla: hay generadores
  /// antiguos que escriben el KML en ISO-8859-1, y ahí la decodificación
  /// estricta reventaría con los acentos.
  String _decode(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes, allowInvalid: true);
    }
  }
}

/// Busca en el ZIP el archivo que corresponde a una referencia del globo.
///
/// Las rutas en el HTML pueden venir relativas (`files/foto.jpg`), con `./`
/// delante, o con la ruta cambiada de mayúsculas, así que se prueban varias
/// formas antes de rendirse.
Uint8List? resolveMedia(Map<String, Uint8List> media, String reference) {
  final cleaned = reference
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'^\./'), '')
      .trim();

  final direct = media[cleaned];
  if (direct != null) return direct;

  final lower = cleaned.toLowerCase();
  for (final entry in media.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }

  // Último intento: comparar solo el nombre del archivo, ignorando carpetas.
  final baseName = lower.split('/').last;
  for (final entry in media.entries) {
    if (entry.key.toLowerCase().split('/').last == baseName) {
      return entry.value;
    }
  }

  return null;
}

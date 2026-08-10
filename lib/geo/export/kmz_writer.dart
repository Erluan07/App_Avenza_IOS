/// Empaquetado del KMZ.
///
/// Un KMZ es un ZIP con `doc.kml` en la raíz y los archivos auxiliares
/// colgando de él. No lleva compresión especial ni cabeceras propias.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'kml_model.dart';
import 'kml_writer.dart';

class KmzBuildResult {
  const KmzBuildResult({
    required this.bytes,
    required this.placemarkCount,
    required this.mediaCount,
  });

  final Uint8List bytes;
  final int placemarkCount;
  final int mediaCount;

  int get sizeBytes => bytes.length;
}

/// Construye el KMZ en memoria.
///
/// Recibe los archivos ya leídos en lugar de rutas para no depender de
/// `dart:io`: así se testea sin tocar el disco. El precio es que la
/// multimedia pasa por memoria, algo a vigilar con videos largos.
KmzBuildResult buildKmz({
  required KmlDocument document,
  Map<String, List<int>> media = const {},
}) {
  final archive = Archive();

  final kml = utf8.encode(buildKml(document));
  // El nombre `doc.kml` es el que buscan los visores al abrir un KMZ.
  archive.addFile(ArchiveFile('doc.kml', kml.length, kml));

  for (final entry in media.entries) {
    archive.addFile(
      ArchiveFile('files/${entry.key}', entry.value.length, entry.value),
    );
  }

  final encoded = ZipEncoder().encode(archive);
  if (encoded == null) {
    throw StateError('No se pudo comprimir el KMZ');
  }

  return KmzBuildResult(
    bytes: Uint8List.fromList(encoded),
    placemarkCount: document.placemarkCount,
    mediaCount: media.length,
  );
}

/// Deja un nombre utilizable dentro del ZIP y en cualquier sistema de
/// archivos: sin separadores de ruta ni caracteres que Windows rechaza.
String sanitizeFileName(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned.isEmpty ? 'sin_nombre' : cleaned;
}

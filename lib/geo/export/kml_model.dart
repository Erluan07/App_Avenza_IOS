/// Modelo de entrada del exportador KML.
///
/// Deliberadamente independiente de la base de datos: así el generador se
/// testea con datos armados a mano y no depende de drift ni de Flutter.
library;

import '../geometry/geometry.dart';

/// Referencia a un archivo que viaja dentro del KMZ.
class KmlMedia {
  const KmlMedia({
    required this.fileName,
    required this.isImage,
    this.caption,
  });

  /// Nombre dentro de la carpeta `files/` del KMZ.
  final String fileName;

  /// Las imágenes se incrustan en el globo; el resto solo se enlaza, porque
  /// Google Earth no reproduce video embebido de forma fiable.
  final bool isImage;

  final String? caption;

  String get path => 'files/$fileName';
}

class KmlPlacemark {
  const KmlPlacemark({
    required this.name,
    required this.geometry,
    this.description,
    this.attributes = const {},
    this.media = const [],
    this.timestamp,
  });

  final String name;
  final Geometry geometry;
  final String? description;

  /// Atributos del elemento. Se muestran como tabla en el globo y además se
  /// emiten como `ExtendedData`, que es lo que leen las herramientas SIG.
  final Map<String, Object?> attributes;

  final List<KmlMedia> media;
  final DateTime? timestamp;
}

class KmlFolder {
  const KmlFolder({
    required this.name,
    required this.placemarks,
    this.color = 0xFFE53935,
    this.description,
  });

  final String name;
  final List<KmlPlacemark> placemarks;

  /// Color ARGB. El generador lo convierte al orden que usa KML.
  final int color;

  final String? description;
}

class KmlDocument {
  const KmlDocument({
    required this.name,
    required this.folders,
    this.description,
  });

  final String name;
  final String? description;
  final List<KmlFolder> folders;

  bool get isEmpty => folders.every((f) => f.placemarks.isEmpty);

  int get placemarkCount =>
      folders.fold(0, (total, folder) => total + folder.placemarks.length);
}

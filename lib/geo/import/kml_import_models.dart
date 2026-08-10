/// Modelo de lo que se extrae de un KML/KMZ importado.
library;

import '../geometry/geometry.dart';

/// Un elemento leído del KML.
class ImportedFeature {
  const ImportedFeature({
    required this.name,
    required this.geometry,
    this.description,
    this.attributes = const {},
    this.imageNames = const [],
    this.timestamp,
  });

  final String name;
  final Geometry geometry;
  final String? description;

  /// Valores de `ExtendedData`, más lo que se haya podido sacar del globo.
  final Map<String, String> attributes;

  /// Nombres de archivo referenciados desde el globo (`<img src="...">`).
  /// Solo tienen contenido si el KMZ los traía empaquetados.
  final List<String> imageNames;

  final DateTime? timestamp;
}

/// Grupo de elementos del mismo tipo de geometría.
///
/// Se agrupa por tipo porque una capa de la app tiene un único tipo, igual que
/// un shapefile, mientras que una carpeta KML puede mezclarlos.
class ImportedLayer {
  const ImportedLayer({
    required this.name,
    required this.geometryType,
    required this.features,
    this.color,
  });

  final String name;
  final GeometryType geometryType;
  final List<ImportedFeature> features;

  /// Color ARGB deducido de los estilos del KML. `null` si no traía.
  final int? color;
}

class KmlImportResult {
  const KmlImportResult({
    required this.layers,
    this.documentName,
    this.warnings = const [],
  });

  final List<ImportedLayer> layers;
  final String? documentName;

  /// Cosas que el archivo traía y no se pudieron importar (enlaces de red,
  /// superposiciones de imagen, agujeros de polígonos…). Se informan en lugar
  /// de descartarlas en silencio.
  final List<String> warnings;

  bool get isEmpty => layers.every((l) => l.features.isEmpty);

  int get featureCount =>
      layers.fold(0, (total, layer) => total + layer.features.length);
}

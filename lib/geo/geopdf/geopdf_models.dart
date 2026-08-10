/// Modelo de lo que se extrae de un GeoPDF, tal cual viene en el archivo.
///
/// Esto es solo *lectura cruda*: convertir esto en una transformación usable
/// (resolver el CRS, ajustar la afín) es trabajo de `lib/geo/transform`.
library;

import '../geometry/primitives.dart';

/// Cómo viene declarado un sistema de coordenadas dentro del `/Measure`.
class CrsSpec {
  const CrsSpec({this.epsg, this.wkt, this.type});

  /// Código EPSG, si el productor lo escribió (`/EPSG`).
  final int? epsg;

  /// WKT del CRS (`/WKT`). Es lo que suele escribir ArcGIS Pro.
  final String? wkt;

  /// `GEOGCS` o `PROJCS`, según `/Type`.
  final String? type;

  bool get isEmpty => epsg == null && (wkt == null || wkt!.trim().isEmpty);

  /// Nombre legible del CRS, sacado del primer literal del WKT.
  String? get displayName {
    final w = wkt;
    if (w == null) return epsg != null ? 'EPSG:$epsg' : null;
    final match = RegExp(r'^\s*\w+\s*\[\s*"([^"]+)"').firstMatch(w);
    return match?.group(1) ?? (epsg != null ? 'EPSG:$epsg' : null);
  }

  @override
  String toString() => 'CrsSpec(${displayName ?? '?'}, epsg: $epsg)';
}

/// El diccionario `/Measure` de subtipo `/GEO` (ISO 32000-1, §8.8.3).
class GeoMeasure {
  const GeoMeasure({
    required this.lpts,
    required this.gpts,
    required this.bounds,
    this.gcs,
    this.pcs,
    this.preferredDisplayUnits,
  });

  /// Puntos en el **cuadrado unitario** `[0..1]` relativo al `/BBox` del
  /// viewport. Ojo: no son puntos de página.
  final List<Point2> lpts;

  /// Coordenadas geográficas correspondientes a [lpts], en el CRS de [gcs].
  /// El PDF las guarda en orden **latitud, longitud**.
  final List<LatLon> gpts;

  /// Polígono, en cuadrado unitario, donde la georreferencia es válida.
  final List<Point2> bounds;

  final CrsSpec? gcs;
  final CrsSpec? pcs;

  /// `/PDU`: unidades preferidas de despliegue (distancia, área, ángulo).
  final List<String>? preferredDisplayUnits;

  /// Necesitamos al menos 3 pares no colineales para resolver una afín.
  bool get isUsable =>
      lpts.length == gpts.length &&
      lpts.length >= 3 &&
      gpts.every((p) => p.isValid);

  @override
  String toString() =>
      'GeoMeasure(${lpts.length} puntos, gcs: $gcs, pcs: $pcs)';
}

/// Un viewport georreferenciado de una página (`/VP`).
class GeoPdfViewport {
  const GeoPdfViewport({
    required this.bbox,
    required this.measure,
    this.name,
  });

  /// `[x0, y0, x1, y1]` en puntos de página PDF, **tal como viene en el
  /// archivo**, sin normalizar a mínimos y máximos.
  ///
  /// El orden importa y no se puede ordenar: define hacia dónde crecen los ejes
  /// del cuadrado unitario en el que están los `LPTS`. Hay productores que
  /// escriben `y0 > y1` para indicar que el origen del cuadrado está arriba;
  /// normalizarlo voltea el mapa de norte a sur.
  final List<double> bbox;

  final GeoMeasure measure;
  final String? name;

  /// Los lados pueden venir en orden invertido, así que se toma el valor
  /// absoluto.
  double get widthPt => (bbox[2] - bbox[0]).abs();
  double get heightPt => (bbox[3] - bbox[1]).abs();

  /// Recorrido con signo de cada eje, que es lo que hace falta para situar los
  /// `LPTS` sobre la página.
  double get spanX => bbox[2] - bbox[0];
  double get spanY => bbox[3] - bbox[1];

  /// `[minX, minY, maxX, maxY]`, para recortar la imagen. Aquí sí interesa el
  /// rectángulo, no su orientación.
  List<double> get normalizedBbox => [
        bbox[0] < bbox[2] ? bbox[0] : bbox[2],
        bbox[1] < bbox[3] ? bbox[1] : bbox[3],
        bbox[0] < bbox[2] ? bbox[2] : bbox[0],
        bbox[1] < bbox[3] ? bbox[3] : bbox[1],
      ];

  /// Área en puntos², para elegir el viewport principal cuando hay varios
  /// (un layout de ArcGIS puede traer mapas de localización además del
  /// principal).
  double get areaPt2 => widthPt * heightPt;
}

/// Motivo por el que una página no se pudo georreferenciar.
enum GeoPdfIssue {
  /// La página no tiene `/VP` ni ninguna otra georreferencia.
  sinGeorreferencia,

  /// Georreferencia en formato TerraGo `/LGIDict` (ArcMap antiguo), que este
  /// lector todavía no soporta.
  formatoLgiDict,

  /// Hay `/VP` pero el `/Measure` está incompleto o es inconsistente.
  measureInvalido,
}

class GeoPdfPageInfo {
  const GeoPdfPageInfo({
    required this.index,
    required this.mediaBox,
    required this.rotate,
    required this.viewports,
    this.issue,
  });

  final int index;

  /// `[minX, minY, maxX, maxY]` en puntos PDF.
  final List<double> mediaBox;

  /// Rotación de la página en grados (0, 90, 180 o 270).
  final int rotate;

  final List<GeoPdfViewport> viewports;
  final GeoPdfIssue? issue;

  double get widthPt => mediaBox[2] - mediaBox[0];
  double get heightPt => mediaBox[3] - mediaBox[1];

  bool get isGeoreferenced => viewports.isNotEmpty;

  /// El viewport más grande: en un layout de ArcGIS Pro con varios marcos,
  /// el mapa principal es el que ocupa más superficie.
  GeoPdfViewport? get primaryViewport {
    if (viewports.isEmpty) return null;
    return viewports.reduce((a, b) => a.areaPt2 >= b.areaPt2 ? a : b);
  }
}

class GeoPdfDocumentInfo {
  const GeoPdfDocumentInfo({required this.pages});

  final List<GeoPdfPageInfo> pages;

  int get pageCount => pages.length;

  bool get hasAnyGeoreference => pages.any((p) => p.isGeoreferenced);

  /// Primera página georreferenciada, que es la que la app abre por defecto.
  GeoPdfPageInfo? get firstGeoreferencedPage {
    for (final page in pages) {
      if (page.isGeoreferenced) return page;
    }
    return null;
  }
}

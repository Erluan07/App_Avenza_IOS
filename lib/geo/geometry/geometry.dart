/// Geometrías capturadas en campo.
///
/// La serialización sigue el orden de GeoJSON (**longitud, latitud**), al revés
/// que los GPTS del PDF (latitud, longitud). Concentrar esa inversión aquí
/// evita tener que recordarla en cada sitio.
library;

import '../measure/geodesy.dart';
import 'primitives.dart';

enum GeometryType { point, line, polygon }

sealed class Geometry {
  const Geometry();

  GeometryType get type;

  /// Todos los vértices, en orden.
  List<LatLon> get vertices;

  /// Longitud en metros: 0 para un punto, longitud del trazado para una línea,
  /// perímetro para un polígono.
  double get lengthMeters;

  /// Área en metros cuadrados. Solo los polígonos tienen área.
  double get areaMeters2;

  LatLon get centroid;

  GeoBounds get bounds => GeoBounds.fromPoints(vertices);

  Map<String, dynamic> toJson();

  static Geometry? fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    final coordinates = json['coordinates'] as List?;
    if (coordinates == null) return null;

    switch (type) {
      case 'Point':
        final position = _readPosition(coordinates);
        return position == null ? null : PointGeometry(position);

      case 'LineString':
        final points = _readPositions(coordinates);
        return points.length < 2 ? null : LineGeometry(points);

      case 'Polygon':
        // GeoJSON envuelve los anillos en un nivel extra de array.
        if (coordinates.isEmpty) return null;
        final ring = _readPositions(coordinates.first as List);
        return ring.length < 3 ? null : PolygonGeometry(ring);
    }
    return null;
  }

  static LatLon? _readPosition(List<dynamic> pair) {
    if (pair.length < 2) return null;
    final lon = (pair[0] as num?)?.toDouble();
    final lat = (pair[1] as num?)?.toDouble();
    if (lon == null || lat == null) return null;
    return LatLon(lat, lon);
  }

  static List<LatLon> _readPositions(List<dynamic> list) => [
        for (final item in list)
          if (item is List)
            if (_readPosition(item) case final p?) p,
      ];

  static List<double> _writePosition(LatLon p) => [p.longitude, p.latitude];
}

class PointGeometry extends Geometry {
  const PointGeometry(this.position);

  final LatLon position;

  @override
  GeometryType get type => GeometryType.point;

  @override
  List<LatLon> get vertices => [position];

  @override
  double get lengthMeters => 0;

  @override
  double get areaMeters2 => 0;

  @override
  LatLon get centroid => position;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'Point',
        'coordinates': Geometry._writePosition(position),
      };
}

class LineGeometry extends Geometry {
  const LineGeometry(this.points);

  final List<LatLon> points;

  @override
  GeometryType get type => GeometryType.line;

  @override
  List<LatLon> get vertices => points;

  @override
  double get lengthMeters => pathLength(points);

  @override
  double get areaMeters2 => 0;

  @override
  LatLon get centroid => _averageOf(points);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'LineString',
        'coordinates': [for (final p in points) Geometry._writePosition(p)],
      };
}

class PolygonGeometry extends Geometry {
  const PolygonGeometry(this.ring);

  /// Anillo exterior. Se guarda abierto; al serializar se cierra, como pide
  /// GeoJSON.
  final List<LatLon> ring;

  @override
  GeometryType get type => GeometryType.polygon;

  @override
  List<LatLon> get vertices => ring;

  /// Para un polígono, "longitud" es el perímetro.
  @override
  double get lengthMeters => ringPerimeter(ring);

  @override
  double get areaMeters2 => ringArea(ring);

  @override
  LatLon get centroid => _averageOf(ring);

  @override
  Map<String, dynamic> toJson() {
    final closed = [...ring, if (ring.isNotEmpty) ring.first];
    return {
      'type': 'Polygon',
      'coordinates': [
        [for (final p in closed) Geometry._writePosition(p)],
      ],
    };
  }
}

/// Centro promedio de los vértices.
///
/// No es el centroide geométrico real, pero para etiquetar y encuadrar en el
/// mapa es lo adecuado: siempre cae dentro del conjunto de puntos y no se
/// dispara con polígonos cóncavos.
LatLon _averageOf(List<LatLon> points) {
  if (points.isEmpty) return const LatLon(0, 0);
  var lat = 0.0;
  var lon = 0.0;
  for (final p in points) {
    lat += p.latitude;
    lon += p.longitude;
  }
  return LatLon(lat / points.length, lon / points.length);
}

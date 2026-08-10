/// Primitivas geométricas compartidas por todo `lib/geo`.
///
/// Se distingue a propósito entre coordenadas **planares** ([Point2]: página
/// PDF, píxeles, o un CRS proyectado) y coordenadas **geográficas** ([LatLon]),
/// para que el compilador impida mezclarlas por accidente — que es la fuente
/// número uno de bugs en este tipo de código.
library;

import 'dart:math' as math;

class Point2 {
  const Point2(this.x, this.y);

  final double x;
  final double y;

  Point2 operator +(Point2 other) => Point2(x + other.x, y + other.y);
  Point2 operator -(Point2 other) => Point2(x - other.x, y - other.y);
  Point2 operator *(double k) => Point2(x * k, y * k);

  double distanceTo(Point2 other) =>
      math.sqrt(math.pow(x - other.x, 2) + math.pow(y - other.y, 2));

  @override
  bool operator ==(Object other) =>
      other is Point2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Point2($x, $y)';
}

class LatLon {
  const LatLon(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  bool get isValid =>
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180 &&
      !latitude.isNaN &&
      !longitude.isNaN;

  @override
  bool operator ==(Object other) =>
      other is LatLon &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  String toString() =>
      'LatLon(${latitude.toStringAsFixed(7)}, ${longitude.toStringAsFixed(7)})';
}

/// Caja envolvente en coordenadas geográficas.
class GeoBounds {
  const GeoBounds({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  factory GeoBounds.fromPoints(Iterable<LatLon> points) {
    var south = double.infinity;
    var west = double.infinity;
    var north = double.negativeInfinity;
    var east = double.negativeInfinity;

    for (final p in points) {
      if (p.latitude < south) south = p.latitude;
      if (p.latitude > north) north = p.latitude;
      if (p.longitude < west) west = p.longitude;
      if (p.longitude > east) east = p.longitude;
    }

    return GeoBounds(south: south, west: west, north: north, east: east);
  }

  final double south;
  final double west;
  final double north;
  final double east;

  LatLon get center => LatLon((south + north) / 2, (west + east) / 2);

  bool get isValid =>
      south.isFinite && west.isFinite && north.isFinite && east.isFinite;

  @override
  String toString() => 'GeoBounds(S$south W$west N$north E$east)';
}

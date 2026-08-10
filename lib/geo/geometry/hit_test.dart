/// Detección de qué geometría cae bajo un toque.
///
/// Trabaja en un plano local alrededor del punto tocado: a la escala de un
/// dedo (decenas de metros) la curvatura terrestre es irrelevante, y hacerlo
/// plano evita cientos de cálculos geodésicos por toque.
library;

import 'dart:math' as math;

import 'geometry.dart';
import 'primitives.dart';

/// Metros por grado de latitud. Constante a efectos prácticos.
const double _metersPerDegreeLat = 111320.0;

/// Proyecta a metros relativos a [origin].
///
/// La escala en longitud depende de la latitud: un grado mide 111 km en el
/// ecuador y se estrecha hacia los polos.
Point2 _toLocalMeters(LatLon point, LatLon origin) {
  const latScale = _metersPerDegreeLat;
  final lonScale =
      _metersPerDegreeLat * math.cos(origin.latitude * math.pi / 180);
  return Point2(
    (point.longitude - origin.longitude) * lonScale,
    (point.latitude - origin.latitude) * latScale,
  );
}

/// Distancia de un punto a un segmento, en el plano local.
double _distanceToSegment(Point2 p, Point2 a, Point2 b) {
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  final lengthSquared = dx * dx + dy * dy;

  // Segmento degenerado: el "segmento" es en realidad un punto.
  if (lengthSquared == 0) return p.distanceTo(a);

  // Proyección escalar acotada al segmento.
  var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared;
  t = t.clamp(0.0, 1.0);

  return p.distanceTo(Point2(a.x + t * dx, a.y + t * dy));
}

/// Distancia en metros de [tap] a una polilínea. `double.infinity` si no hay
/// segmentos.
double distanceToPolyline(List<LatLon> points, LatLon tap) {
  if (points.isEmpty) return double.infinity;

  final origin = tap;
  final local = [for (final p in points) _toLocalMeters(p, origin)];
  const zero = Point2(0, 0);

  if (local.length == 1) return zero.distanceTo(local.first);

  var best = double.infinity;
  for (var i = 1; i < local.length; i++) {
    final d = _distanceToSegment(zero, local[i - 1], local[i]);
    if (d < best) best = d;
  }
  return best;
}

/// `true` si [tap] cae dentro del anillo, por el método del número de cruces.
bool isInsideRing(List<LatLon> ring, LatLon tap) {
  if (ring.length < 3) return false;

  final local = [for (final p in ring) _toLocalMeters(p, tap)];
  var inside = false;

  // Se cuenta cuántas veces un rayo horizontal desde el origen cruza el
  // contorno: impar significa dentro.
  for (var i = 0, j = local.length - 1; i < local.length; j = i++) {
    final a = local[i];
    final b = local[j];

    final crossesRay = (a.y > 0) != (b.y > 0);
    if (!crossesRay) continue;

    final xIntersection = a.x + (0 - a.y) / (b.y - a.y) * (b.x - a.x);
    if (xIntersection > 0) inside = !inside;
  }

  return inside;
}

/// Distancia efectiva en metros de [tap] a [geometry], o `null` si no la
/// alcanza dentro de [toleranceMeters].
///
/// Un polígono tocado por dentro devuelve 0: así gana frente a una línea que
/// pase cerca, que es lo que el usuario espera al tocar el relleno.
double? hitDistance(
  Geometry geometry,
  LatLon tap, {
  required double toleranceMeters,
}) {
  final distance = switch (geometry) {
    PointGeometry(:final position) =>
      distanceToPolyline([position], tap),
    LineGeometry(:final points) => distanceToPolyline(points, tap),
    PolygonGeometry(:final ring) => isInsideRing(ring, tap)
        ? 0.0
        : distanceToPolyline([...ring, if (ring.isNotEmpty) ring.first], tap),
  };

  return distance <= toleranceMeters ? distance : null;
}

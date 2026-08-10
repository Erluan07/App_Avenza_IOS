/// Distancias y áreas sobre el elipsoide WGS84.
///
/// Nada de esto se puede calcular con geometría plana sobre lat/lon: un grado
/// de longitud mide 111 km en el ecuador y 0 en el polo. Estas funciones son
/// las que respaldan la herramienta de medición de la app.
library;

import 'dart:math' as math;

import '../geometry/primitives.dart';

/// Semieje mayor WGS84, en metros.
const double kWgs84SemiMajorAxis = 6378137.0;

/// Aplanamiento WGS84.
const double kWgs84Flattening = 1 / 298.257223563;

/// Radio autálico WGS84: la esfera con la misma superficie que el elipsoide.
/// Usarlo en el cálculo de área deja el error por debajo del ~0,1 %.
const double kWgs84AuthalicRadius = 6371007.181;

/// Radio medio, para haversine.
const double kEarthMeanRadius = 6371008.8;

double _rad(double degrees) => degrees * math.pi / 180.0;

/// Distancia por círculo máximo. Rápida, con error de hasta ~0,5 % por
/// suponer la Tierra esférica.
double haversineDistance(LatLon a, LatLon b) {
  final dLat = _rad(b.latitude - a.latitude);
  final dLon = _rad(b.longitude - a.longitude);
  final lat1 = _rad(a.latitude);
  final lat2 = _rad(b.latitude);

  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * kEarthMeanRadius * math.asin(math.min(1.0, math.sqrt(h)));
}

/// Distancia geodésica por el método inverso de Vincenty: precisión
/// milimétrica sobre el elipsoide.
///
/// En puntos casi antipodales el algoritmo no converge; ahí cae a haversine,
/// que en ese caso es de sobra (no es un escenario de trabajo de campo).
double vincentyDistance(LatLon p1, LatLon p2) {
  if (p1.latitude == p2.latitude && p1.longitude == p2.longitude) return 0;

  const a = kWgs84SemiMajorAxis;
  const f = kWgs84Flattening;
  const b = (1 - f) * a;

  final l = _rad(p2.longitude - p1.longitude);
  final u1 = math.atan((1 - f) * math.tan(_rad(p1.latitude)));
  final u2 = math.atan((1 - f) * math.tan(_rad(p2.latitude)));
  final sinU1 = math.sin(u1);
  final cosU1 = math.cos(u1);
  final sinU2 = math.sin(u2);
  final cosU2 = math.cos(u2);

  var lambda = l;
  var sinSigma = 0.0;
  var cosSigma = 0.0;
  var sigma = 0.0;
  var cosSqAlpha = 0.0;
  var cos2SigmaM = 0.0;
  var converged = false;

  for (var i = 0; i < 200; i++) {
    final sinLambda = math.sin(lambda);
    final cosLambda = math.cos(lambda);

    final term1 = cosU2 * sinLambda;
    final term2 = cosU1 * sinU2 - sinU1 * cosU2 * cosLambda;
    sinSigma = math.sqrt(term1 * term1 + term2 * term2);
    if (sinSigma == 0) return 0; // puntos coincidentes

    cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda;
    sigma = math.atan2(sinSigma, cosSigma);

    final sinAlpha = cosU1 * cosU2 * sinLambda / sinSigma;
    cosSqAlpha = 1 - sinAlpha * sinAlpha;
    // cosSqAlpha == 0 sobre la línea ecuatorial.
    cos2SigmaM =
        cosSqAlpha != 0 ? cosSigma - 2 * sinU1 * sinU2 / cosSqAlpha : 0.0;

    final c = f / 16 * cosSqAlpha * (4 + f * (4 - 3 * cosSqAlpha));
    final lambdaPrev = lambda;
    lambda = l +
        (1 - c) *
            f *
            sinAlpha *
            (sigma +
                c *
                    sinSigma *
                    (cos2SigmaM +
                        c * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)));

    if ((lambda - lambdaPrev).abs() < 1e-12) {
      converged = true;
      break;
    }
  }

  if (!converged) return haversineDistance(p1, p2);

  final uSq = cosSqAlpha * (a * a - b * b) / (b * b);
  final aCoef =
      1 + uSq / 16384 * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)));
  final bCoef = uSq / 1024 * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)));

  final deltaSigma = bCoef *
      sinSigma *
      (cos2SigmaM +
          bCoef /
              4 *
              (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM) -
                  bCoef /
                      6 *
                      cos2SigmaM *
                      (-3 + 4 * sinSigma * sinSigma) *
                      (-3 + 4 * cos2SigmaM * cos2SigmaM)));

  return b * aCoef * (sigma - deltaSigma);
}

/// Longitud total de una polilínea, en metros.
double pathLength(List<LatLon> points) {
  if (points.length < 2) return 0;
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    total += vincentyDistance(points[i - 1], points[i]);
  }
  return total;
}

/// Área de un polígono, en metros cuadrados.
///
/// Fórmula del exceso esférico sobre el radio autálico de WGS84. El error
/// frente al cálculo elipsoidal exacto queda en torno al 0,1 %, muy por debajo
/// de la incertidumbre del GPS de un teléfono.
///
/// El anillo puede venir cerrado o abierto; los agujeros no se contemplan.
double ringArea(List<LatLon> ring) {
  final points = _openRing(ring);
  if (points.length < 3) return 0;

  var total = 0.0;
  for (var i = 0; i < points.length; i++) {
    final p1 = points[i];
    final p2 = points[(i + 1) % points.length];
    total += _rad(p2.longitude - p1.longitude) *
        (2 + math.sin(_rad(p1.latitude)) + math.sin(_rad(p2.latitude)));
  }

  return (total * kWgs84AuthalicRadius * kWgs84AuthalicRadius / 2).abs();
}

/// Perímetro de un polígono, en metros (cierra el anillo automáticamente).
double ringPerimeter(List<LatLon> ring) {
  final points = _openRing(ring);
  if (points.length < 2) return 0;
  return pathLength([...points, points.first]);
}

List<LatLon> _openRing(List<LatLon> ring) {
  if (ring.length >= 2 && ring.first == ring.last) {
    return ring.sublist(0, ring.length - 1);
  }
  return ring;
}

/// Rumbo inicial de `from` a `to`, en grados desde el norte (0–360).
double initialBearing(LatLon from, LatLon to) {
  final lat1 = _rad(from.latitude);
  final lat2 = _rad(to.latitude);
  final dLon = _rad(to.longitude - from.longitude);

  final y = math.sin(dLon) * math.cos(lat2);
  final x = math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(dLon);

  final bearing = math.atan2(y, x) * 180 / math.pi;
  return (bearing + 360) % 360;
}

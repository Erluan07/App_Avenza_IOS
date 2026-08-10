/// Transformación afín 2D y su ajuste por mínimos cuadrados.
///
/// Es el corazón de la georreferencia: relaciona el espacio de la página PDF
/// con el espacio de coordenadas proyectadas. Esa relación *es* exactamente
/// afín, porque el layout de ArcGIS dibuja el mapa como un plano lineal de
/// coordenadas proyectadas.
library;

import 'dart:math' as math;

import '../geometry/primitives.dart';

/// ```
/// x' = a·x + b·y + c
/// y' = d·x + e·y + f
/// ```
class Affine2D {
  const Affine2D(this.a, this.b, this.c, this.d, this.e, this.f);

  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final double f;

  static const Affine2D identity = Affine2D(1, 0, 0, 0, 1, 0);

  Point2 apply(Point2 p) => Point2(
        a * p.x + b * p.y + c,
        d * p.x + e * p.y + f,
      );

  double get determinant => a * e - b * d;

  /// `null` si la transformación es degenerada (puntos de control colineales).
  Affine2D? invert() {
    final det = determinant;
    if (det.abs() < 1e-15) return null;
    return Affine2D(
      e / det,
      -b / det,
      (b * f - c * e) / det,
      -d / det,
      a / det,
      (c * d - a * f) / det,
    );
  }

  /// Escala media del mapeo, en unidades destino por unidad origen.
  /// Sirve para estimar la escala del mapa (p. ej. metros por punto PDF).
  double get meanScale {
    final sx = math.sqrt(a * a + d * d);
    final sy = math.sqrt(b * b + e * e);
    return (sx + sy) / 2;
  }

  /// Rotación implícita en radianes. En un layout north-up debería rondar 0.
  double get rotationRadians => math.atan2(d, a);

  @override
  String toString() =>
      'Affine2D(a:$a b:$b c:$c d:$d e:$e f:$f)';
}

/// Resultado de ajustar una afín, con sus residuos — que son la medida real
/// de si la georreferencia es confiable.
class AffineFit {
  const AffineFit({
    required this.transform,
    required this.rmsError,
    required this.maxError,
    required this.pointCount,
  });

  final Affine2D transform;

  /// Error cuadrático medio en unidades del espacio destino.
  final double rmsError;

  /// Peor residuo individual, en unidades del espacio destino.
  final double maxError;

  final int pointCount;

  @override
  String toString() =>
      'AffineFit($pointCount pts, rms: ${rmsError.toStringAsFixed(4)}, '
      'max: ${maxError.toStringAsFixed(4)})';
}

/// Ajusta la afín que mejor lleva [from] a [to] por mínimos cuadrados.
///
/// Con 3 puntos no colineales el ajuste es exacto; con más, minimiza el error
/// (ArcGIS suele escribir las 4 esquinas del marco de datos).
///
/// Devuelve `null` si hay menos de 3 pares o si los puntos origen son
/// colineales, en cuyo caso el sistema es indeterminado.
AffineFit? fitAffine(List<Point2> from, List<Point2> to) {
  if (from.length != to.length || from.length < 3) return null;

  final n = from.length;
  var sxx = 0.0, sxy = 0.0, syy = 0.0, sx = 0.0, sy = 0.0;
  var sxX = 0.0, syX = 0.0, sX = 0.0;
  var sxY = 0.0, syY = 0.0, sY = 0.0;

  for (var i = 0; i < n; i++) {
    final p = from[i];
    final q = to[i];
    sxx += p.x * p.x;
    sxy += p.x * p.y;
    syy += p.y * p.y;
    sx += p.x;
    sy += p.y;

    sxX += p.x * q.x;
    syX += p.y * q.x;
    sX += q.x;

    sxY += p.x * q.y;
    syY += p.y * q.y;
    sY += q.y;
  }

  // Las ecuaciones normales comparten la misma matriz para x' e y'.
  final matrix = <List<double>>[
    [sxx, sxy, sx],
    [sxy, syy, sy],
    [sx, sy, n.toDouble()],
  ];

  final abc = _solve3x3(matrix, [sxX, syX, sX]);
  final def = _solve3x3(matrix, [sxY, syY, sY]);
  if (abc == null || def == null) return null;

  final transform = Affine2D(abc[0], abc[1], abc[2], def[0], def[1], def[2]);

  var sumSquares = 0.0;
  var maxError = 0.0;
  for (var i = 0; i < n; i++) {
    final predicted = transform.apply(from[i]);
    final error = predicted.distanceTo(to[i]);
    sumSquares += error * error;
    if (error > maxError) maxError = error;
  }

  return AffineFit(
    transform: transform,
    rmsError: math.sqrt(sumSquares / n),
    maxError: maxError,
    pointCount: n,
  );
}

/// Eliminación gaussiana con pivoteo parcial. `null` si el sistema es singular.
List<double>? _solve3x3(List<List<double>> matrix, List<double> rhs) {
  final m = [
    for (var i = 0; i < 3; i++) [...matrix[i], rhs[i]],
  ];

  for (var col = 0; col < 3; col++) {
    var pivot = col;
    for (var row = col + 1; row < 3; row++) {
      if (m[row][col].abs() > m[pivot][col].abs()) pivot = row;
    }
    if (m[pivot][col].abs() < 1e-12) return null;

    if (pivot != col) {
      final tmp = m[pivot];
      m[pivot] = m[col];
      m[col] = tmp;
    }

    for (var row = 0; row < 3; row++) {
      if (row == col) continue;
      final factor = m[row][col] / m[col][col];
      if (factor == 0) continue;
      for (var k = col; k < 4; k++) {
        m[row][k] -= factor * m[col][k];
      }
    }
  }

  final out = <double>[];
  for (var i = 0; i < 3; i++) {
    final value = m[i][3] / m[i][i];
    if (!value.isFinite) return null;
    out.add(value);
  }
  return out;
}

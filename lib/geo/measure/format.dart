/// Formateo de distancias y áreas para mostrar en pantalla.
///
/// Dart puro: se testea sin Flutter junto con el resto de `lib/geo`.
library;

/// Distancia en metros → texto legible.
///
/// Por debajo de 1 km se muestra en metros, porque es la escala a la que se
/// trabaja en campo; por encima, en kilómetros.
String formatDistance(double meters) {
  if (!meters.isFinite || meters < 0) return '—';
  if (meters < 1) return '${(meters * 100).round()} cm';
  if (meters < 1000) {
    // Un decimal por debajo de 100 m: ahí la precisión del GPS todavía lo
    // justifica. Por encima, sobra.
    return meters < 100
        ? '${meters.toStringAsFixed(1)} m'
        : '${meters.round()} m';
  }
  return '${(meters / 1000).toStringAsFixed(meters < 10000 ? 2 : 1)} km';
}

/// Área en metros cuadrados → texto legible.
///
/// Incluye hectáreas porque es la unidad en que se habla de predios y parcelas,
/// que es el caso de uso habitual de esta app.
String formatArea(double squareMeters) {
  if (!squareMeters.isFinite || squareMeters < 0) return '—';
  if (squareMeters < 10000) return '${squareMeters.round()} m²';

  final hectares = squareMeters / 10000;
  if (hectares < 100) return '${hectares.toStringAsFixed(2)} ha';
  if (hectares < 10000) return '${hectares.toStringAsFixed(1)} ha';

  return '${(squareMeters / 1000000).toStringAsFixed(2)} km²';
}

/// Coordenada en grados decimales, con la precisión justa.
///
/// Siete decimales son ~1 cm: más allá es ruido, y menos pierde información
/// que el GPS sí aporta.
String formatLatLon(double degrees) => degrees.toStringAsFixed(7);

/// Coordenada en grados, minutos y segundos.
String formatDms(double degrees, {required bool isLatitude}) {
  if (!degrees.isFinite) return '—';

  final hemisphere = isLatitude
      ? (degrees >= 0 ? 'N' : 'S')
      : (degrees >= 0 ? 'E' : 'W');

  final absolute = degrees.abs();
  final d = absolute.floor();
  final minutesFull = (absolute - d) * 60;
  final m = minutesFull.floor();
  final s = (minutesFull - m) * 60;

  return "$d° $m' ${s.toStringAsFixed(1)}\" $hemisphere";
}

/// Precisión del GPS con su interpretación, para que el número signifique algo.
String formatAccuracy(double meters) {
  if (!meters.isFinite || meters <= 0) return 'Sin dato';
  final value = meters < 10 ? meters.toStringAsFixed(1) : meters.round().toString();
  final quality = meters <= 10
      ? 'buena'
      : meters <= 30
          ? 'aceptable'
          : 'baja';
  return '±$value m ($quality)';
}

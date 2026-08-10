/// Metadatos de una foto tomada en campo y su composición como texto.
///
/// Dart puro: la composición del sello es la parte que conviene testear, y así
/// se hace sin Flutter ni cámara.
library;

import '../geometry/primitives.dart';
import '../measure/format.dart';

class PhotoMetadata {
  const PhotoMetadata({
    this.capturedAt,
    this.position,
    this.accuracyMeters,
    this.elevationMeters,
    this.headingDegrees,
    this.note,
  });

  final DateTime? capturedAt;
  final LatLon? position;
  final double? accuracyMeters;
  final double? elevationMeters;

  /// Rumbo de la cámara en grados desde el norte.
  final double? headingDegrees;

  /// Texto libre extra (por ejemplo el nombre del proyecto).
  final String? note;

  bool get hasAnything =>
      capturedAt != null ||
      position != null ||
      headingDegrees != null ||
      (note?.isNotEmpty ?? false);

  bool get hasPosition => position != null;
}

/// Punto cardinal abreviado a partir de un rumbo en grados.
///
/// En campo "NE" se entiende de un vistazo; "48°" hay que pensarlo.
String cardinalPoint(double degrees) {
  const points = ['N', 'NE', 'E', 'SE', 'S', 'SO', 'O', 'NO'];
  final normalized = ((degrees % 360) + 360) % 360;
  // Cada sector cubre 45°, centrado en su punto: el +22,5 desplaza el borde.
  final index = ((normalized + 22.5) ~/ 45) % 8;
  return points[index];
}

/// Fecha y hora del sello, en formato corto y sin depender de `intl`.
String formatStampTimestamp(DateTime moment) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(moment.day)}/${two(moment.month)}/${moment.year} '
      '${two(moment.hour)}:${two(moment.minute)}';
}

/// Separador entre los datos de una misma línea del sello.
///
/// **No puede ser `|`.** El `drawString` de `package:image` parte el texto con
/// `RegExp(r"[\n|\r]")`, y esa clase de caracteres incluye el pipe literal
/// —seguramente se quiso escribir `[\n\r]`—, así que un `|` en el texto lo
/// rompe en varias líneas que se salen del panel.
const String kStampSeparator = '   -   ';

/// Rumbo con su punto cardinal, tal como va en el sello.
///
/// Sin el símbolo `°` a propósito: el sello se dibuja con una fuente de mapa
/// de bits que solo trae ASCII imprimible, y los caracteres que no existen se
/// pierden dejando un hueco. Por eso el sello se limita a ese repertorio.
String _headingLabel(double degrees) =>
    'rumbo ${cardinalPoint(degrees)} ${degrees.round()}';

/// Líneas del sello que se dibuja sobre la foto.
///
/// Se devuelve una lista en vez de un bloque de texto para que el dibujante
/// controle el interlineado y pueda resaltar la primera línea.
List<String> buildStampLines(PhotoMetadata metadata) {
  final lines = <String>[];

  if (metadata.capturedAt != null) {
    lines.add(formatStampTimestamp(metadata.capturedAt!));
  }

  final position = metadata.position;
  if (position != null) {
    lines.add(
      '${formatLatLon(position.latitude)}, '
      '${formatLatLon(position.longitude)}',
    );

    // Precisión, altitud y rumbo van juntos en una línea: por separado
    // ocuparían media foto.
    final details = <String>[
      if (metadata.accuracyMeters != null)
        '+-${metadata.accuracyMeters!.round()} m',
      if (metadata.elevationMeters != null)
        'alt ${metadata.elevationMeters!.round()} m',
      if (metadata.headingDegrees != null)
        _headingLabel(metadata.headingDegrees!),
    ];
    if (details.isNotEmpty) lines.add(details.join(kStampSeparator));
  } else if (metadata.headingDegrees != null) {
    lines.add(_headingLabel(metadata.headingDegrees!));
  }

  final note = metadata.note?.trim();
  if (note != null && note.isNotEmpty) lines.add(note);

  return lines;
}

/// Convierte grados decimales a los tres racionales que pide el EXIF GPS
/// (grados, minutos, segundos), cada uno como par numerador/denominador.
///
/// Los segundos se guardan con precisión de 1/1000 para no perder metros.
List<List<int>> degreesToExifRational(double degrees) {
  final absolute = degrees.abs();
  final d = absolute.floor();
  final minutesFull = (absolute - d) * 60;
  final m = minutesFull.floor();
  final seconds = (minutesFull - m) * 60;

  return [
    [d, 1],
    [m, 1],
    [(seconds * 1000).round(), 1000],
  ];
}

/// Referencia hemisférica que acompaña a la coordenada en EXIF.
String exifLatitudeRef(double latitude) => latitude >= 0 ? 'N' : 'S';
String exifLongitudeRef(double longitude) => longitude >= 0 ? 'E' : 'W';

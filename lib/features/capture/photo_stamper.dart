/// Estampado de fecha, coordenadas y rumbo sobre las fotos, más escritura de
/// los mismos datos como EXIF.
///
/// Son dos mecanismos con propósitos distintos y por eso se hacen los dos:
/// - El **sello visible** sobrevive a cualquier cosa: capturas de pantalla,
///   impresiones, fotos reenviadas por mensajería. Es lo que hace que la foto
///   valga como evidencia de campo.
/// - El **EXIF** es legible por máquinas (Google Photos, QGIS, Lightroom), pero
///   se pierde en cuanto la imagen se reencoda.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../geo/photo/photo_metadata.dart';

/// Resultado del proceso, con los bytes ya listos para guardar.
class StampedPhoto {
  const StampedPhoto({
    required this.bytes,
    required this.stamped,
    required this.exifWritten,
  });

  final Uint8List bytes;

  /// Se dibujó el sello. `false` si no había metadatos o la imagen no se pudo
  /// decodificar.
  final bool stamped;

  final bool exifWritten;
}

/// Punto de entrada del estampado para `Isolate.run`.
///
/// Es una función de nivel superior a propósito: un closure declarado dentro de
/// un `State` puede arrastrar `this`, que no es transferible entre isolates y
/// hace fallar el envío.
StampedPhoto stampPhoto(Uint8List bytes, PhotoMetadata metadata) =>
    const PhotoStamper().process(bytes: bytes, metadata: metadata);

/// Ancho máximo de la foto guardada, en píxeles.
///
/// Una foto de móvil moderna ronda los 4000 px y pesa varios MB. Para
/// documentación de campo 2560 px es de sobra, y mantiene manejables tanto el
/// KMZ como el ZIP de fotos, que si no llegan a cientos de MB.
const int kMaxPhotoWidth = 2560;

/// Calidad JPEG de salida.
const int kJpegQuality = 88;

class PhotoStamper {
  const PhotoStamper();

  /// Devuelve la foto con el sello dibujado y el EXIF escrito.
  ///
  /// Ante cualquier fallo devuelve los bytes originales: perder la foto por no
  /// poder estamparla sería mucho peor que quedarse sin sello.
  StampedPhoto process({
    required Uint8List bytes,
    required PhotoMetadata metadata,
    bool drawStamp = true,
  }) {
    img.Image? image;
    try {
      image = img.decodeImage(bytes);
    } catch (_) {
      image = null;
    }
    if (image == null) {
      return StampedPhoto(bytes: bytes, stamped: false, exifWritten: false);
    }

    // `decodeImage` ya aplica la orientación EXIF, así que lo que sigue trabaja
    // sobre la imagen tal como se ve.
    if (image.width > kMaxPhotoWidth) {
      image = img.copyResize(
        image,
        width: kMaxPhotoWidth,
        interpolation: img.Interpolation.average,
      );
    }

    final lines = buildStampLines(metadata);
    final shouldStamp = drawStamp && lines.isNotEmpty;
    if (shouldStamp) _drawStamp(image, lines);

    final exifWritten = _writeExif(image, metadata);

    try {
      return StampedPhoto(
        bytes: img.encodeJpg(image, quality: kJpegQuality),
        stamped: shouldStamp,
        exifWritten: exifWritten,
      );
    } catch (_) {
      // Reintento sin EXIF: el sello ya está dibujado en los píxeles y es lo
      // que de verdad importa conservar, así que se prefiere una foto sellada
      // sin metadatos legibles por máquina a no tener nada.
      try {
        image.exif = img.ExifData();
        return StampedPhoto(
          bytes: img.encodeJpg(image, quality: kJpegQuality),
          stamped: shouldStamp,
          exifWritten: false,
        );
      } catch (_) {
        return StampedPhoto(bytes: bytes, stamped: false, exifWritten: false);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Sello visible
  // ---------------------------------------------------------------------------

  /// Dibuja el sello abajo a la izquierda.
  ///
  /// El paquete `image` solo trae fuentes de mapa de bits en tres tamaños
  /// fijos, así que a 2560 px de ancho hasta la mayor se vería diminuta. Por
  /// eso el sello se dibuja aparte a su tamaño natural y se compone escalado:
  /// así ocupa una fracción constante del ancho, sea cual sea la resolución.
  void _drawStamp(img.Image image, List<String> lines) {
    final font = img.arial48;

    const paddingX = 16;
    const paddingY = 12;
    const lineGap = 6;
    final lineHeight = font.lineHeight + lineGap;

    var textWidth = 0;
    for (final line in lines) {
      final width = _measure(font, line);
      if (width > textWidth) textWidth = width;
    }

    final panelWidth = textWidth + paddingX * 2;
    final panelHeight = lineHeight * lines.length + paddingY * 2 - lineGap;

    final panel = img.Image(
      width: panelWidth,
      height: panelHeight,
      numChannels: 4,
    );

    // Fondo oscuro translúcido: legible tanto sobre cielo claro como sobre
    // terreno oscuro, que es lo habitual en una foto de campo.
    //
    // Dos detalles que hay que respetar, comprobados a base de que el fondo no
    // aparecía y el texto quedaba flotando sobre la foto:
    //
    // - **Sin `radius`.** El relleno con esquinas redondeadas de `image` deja
    //   el píxel en alfa 0, es decir no pinta nada. Las esquinas van rectas.
    // - **`alphaBlend: false`.** El panel nace transparente (0,0,0,0); con la
    //   mezcla activada, el negro se combina contra ese vacío y se anula. Sin
    //   mezcla el píxel conserva su alfa, y es `compositeImage` quien lo funde
    //   con la foto, que es lo que se busca.
    img.fillRect(
      panel,
      x1: 0,
      y1: 0,
      x2: panelWidth - 1,
      y2: panelHeight - 1,
      color: img.ColorRgba8(0, 0, 0, 175),
      alphaBlend: false,
    );

    // Franja de color a la izquierda: identifica el sello de un vistazo y evita
    // confundirlo con el reloj de la cámara del sistema.
    img.fillRect(
      panel,
      x1: 0,
      y1: 0,
      x2: 5,
      y2: panelHeight - 1,
      color: img.ColorRgba8(232, 89, 12, 255),
      alphaBlend: false,
    );

    for (var i = 0; i < lines.length; i++) {
      img.drawString(
        panel,
        lines[i],
        font: font,
        x: paddingX,
        y: paddingY + i * lineHeight,
        color: img.ColorRgba8(255, 255, 255, 255),
      );
    }

    // El sello ocupa ~46 % del ancho de la foto, con un techo para que en
    // fotos muy anchas no se estire de más.
    final targetWidth =
        (image.width * 0.46).round().clamp(240, panelWidth * 3);
    final scale = targetWidth / panelWidth;
    final targetHeight = (panelHeight * scale).round();

    final margin = (image.width * 0.025).round();

    img.compositeImage(
      image,
      panel,
      dstX: margin,
      dstY: image.height - targetHeight - margin,
      dstW: targetWidth,
      dstH: targetHeight,
    );
  }

  /// Ancho en píxeles que ocupa una cadena con esa fuente.
  ///
  /// Replica la medición de `drawString`, que **descarta** los caracteres sin
  /// glifo en lugar de reservarles espacio. Estimarlos de otra forma
  /// desalinearía el panel respecto del texto que acaba dibujándose.
  int _measure(img.BitmapFont font, String text) {
    var width = 0;
    for (final code in text.codeUnits) {
      final glyph = font.characters[code];
      if (glyph == null) continue;
      width += glyph.xAdvance;
    }
    return width;
  }

  // ---------------------------------------------------------------------------
  // EXIF
  // ---------------------------------------------------------------------------

  bool _writeExif(img.Image image, PhotoMetadata metadata) {
    try {
      // Se descarta el EXIF que traiga la cámara y se empieza de cero.
      //
      // Una foto real llega con MakerNote propietario, miniatura embebida y
      // perfiles de color; al reencodar, cualquiera de esos bloques puede
      // hacer fallar al codificador. Para cartografía no aportan nada, y
      // conservarlos era la diferencia entre el test (imagen sintética, sin
      // EXIF) y el fallo en el teléfono.
      final exif = img.ExifData();
      image.exif = exif;

      final capturedAt = metadata.capturedAt;
      if (capturedAt != null) {
        // El formato del EXIF es "AAAA:MM:DD HH:MM:SS", con dos puntos también
        // en la fecha.
        final stamp = _exifDateTime(capturedAt);
        exif.imageIfd['DateTime'] = stamp;
        exif.exifIfd['DateTimeOriginal'] = stamp;
        exif.exifIfd['DateTimeDigitized'] = stamp;
      }

      final position = metadata.position;
      final heading = metadata.headingDegrees;
      if (position == null && heading == null) return true;

      final gps = exif.gpsIfd;

      if (position != null) {
        gps[0x0001] = img.IfdValueAscii(exifLatitudeRef(position.latitude));
        gps[0x0002] = _rationals(degreesToExifRational(position.latitude));
        gps[0x0003] = img.IfdValueAscii(exifLongitudeRef(position.longitude));
        gps[0x0004] = _rationals(degreesToExifRational(position.longitude));

        final elevation = metadata.elevationMeters;
        if (elevation != null) {
          // 0 = sobre el nivel del mar, 1 = bajo. El valor va siempre positivo.
          gps[0x0005] = img.IfdByteValue(elevation >= 0 ? 0 : 1);
          gps[0x0006] =
              img.IfdValueRational((elevation.abs() * 100).round(), 100);
        }

        if (capturedAt != null) {
          // La hora GPS va siempre en UTC, por definición del estándar.
          final utc = capturedAt.toUtc();
          gps[0x0007] = _rationals([
            [utc.hour, 1],
            [utc.minute, 1],
            [utc.second, 1],
          ]);
          gps[0x001D] = img.IfdValueAscii(
            '${utc.year}:'
            '${utc.month.toString().padLeft(2, '0')}:'
            '${utc.day.toString().padLeft(2, '0')}',
          );
        }
      }

      if (heading != null) {
        // 'M' = magnético, que es lo que da la brújula del teléfono. Decir 'T'
        // (verdadero) sería mentir: falta la declinación magnética del lugar.
        gps[0x0010] = img.IfdValueAscii('M');
        gps[0x0011] = img.IfdValueRational((heading * 100).round(), 100);
      }

      return true;
    } catch (_) {
      // Un EXIF que no se pudo escribir no invalida la foto ni el sello.
      return false;
    }
  }

  /// Empaqueta pares numerador/denominador como una lista de racionales EXIF.
  ///
  /// Hay que construir el [IfdValue] explícitamente: el setter de `IfdDirectory`
  /// deduce el tipo consultando `exifImageTags`, y los tags GPS viven en un
  /// mapa aparte (`exifGpsTags`). Al no encontrarlos, descarta el valor **en
  /// silencio** y el EXIF se queda vacío.
  img.IfdValue _rationals(List<List<int>> values) => img.IfdValueRational.list([
        // `Rational` no se exporta desde `package:image/image.dart`, así que no
        // se puede nombrar el tipo. Se crea cada uno con el constructor de un
        // solo par y se concatenan sus listas.
        for (final pair in values)
          ...img.IfdValueRational(pair[0], pair[1]).value,
      ]);

  String _exifDateTime(DateTime moment) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${moment.year}:${two(moment.month)}:${two(moment.day)} '
        '${two(moment.hour)}:${two(moment.minute)}:${two(moment.second)}';
  }
}

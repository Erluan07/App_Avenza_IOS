/// Tests del estampado real: se genera una imagen, se procesa y se vuelve a
/// leer para comprobar que el sello y el EXIF sobrevivieron al reencodado.
///
/// `PhotoStamper` no importa Flutter, así que corre con `dart test`.
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'package:avenza_para_pobres/features/capture/photo_stamper.dart';
import 'package:avenza_para_pobres/geo/geometry/primitives.dart';
import 'package:avenza_para_pobres/geo/photo/photo_metadata.dart';

/// JPEG sintético de color plano, para poder detectar el sello por contraste.
Uint8List syntheticJpeg({int width = 1200, int height = 900}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 200, 200));
  return img.encodeJpg(image, quality: 90);
}

/// Proporción de píxeles oscurecidos en el cuadrante inferior izquierdo, que
/// es donde va el sello.
///
/// Se mide por región y no por un píxel concreto: el panel tiene esquinas
/// redondeadas y su tamaño depende del texto, así que un punto exacto es
/// frágil sin verificar nada más.
double darkFractionBottomLeft(img.Image image) {
  const x0 = 0;
  final x1 = image.width ~/ 2;
  final y0 = (image.height * 0.75).round();
  final y1 = image.height;

  var dark = 0;
  var total = 0;
  for (var y = y0; y < y1; y += 2) {
    for (var x = x0; x < x1; x += 2) {
      total++;
      // El fondo sintético es gris 190; el panel del sello lo baja bastante.
      if (image.getPixel(x, y).r < 150) dark++;
    }
  }
  return total == 0 ? 0 : dark / total;
}

final _metadata = PhotoMetadata(
  capturedAt: DateTime(2026, 7, 24, 9, 5),
  position: const LatLon(6.2402649, -75.5354646),
  accuracyMeters: 4.2,
  elevationMeters: 1495,
  headingDegrees: 48,
);

void main() {
  const stamper = PhotoStamper();

  group('Procesado', () {
    test('devuelve un JPEG válido', () {
      final result = stamper.process(
        bytes: syntheticJpeg(),
        metadata: _metadata,
      );

      expect(result.stamped, isTrue);
      final decoded = img.decodeImage(result.bytes);
      expect(decoded, isNotNull);
      expect(decoded!.width, 1200);
    });

    test('el sello oscurece la esquina inferior izquierda', () {
      final result = stamper.process(
        bytes: syntheticJpeg(),
        metadata: _metadata,
      );
      final decoded = img.decodeImage(result.bytes)!;

      // La imagen de partida es gris plano. Donde cae el sello, el panel
      // translúcido oscuro tiene que haber bajado la luminancia.
      expect(darkFractionBottomLeft(decoded), greaterThan(0.15));
      // Y la esquina opuesta debe seguir intacta.
      expect(decoded.getPixel(decoded.width - 40, 40).r, greaterThan(150));
    });

    test('sin metadatos no dibuja nada', () {
      final original = syntheticJpeg();
      final result = stamper.process(
        bytes: original,
        metadata: const PhotoMetadata(),
      );

      expect(result.stamped, isFalse);
      final decoded = img.decodeImage(result.bytes)!;
      // La zona donde iría el sello queda con el gris original.
      expect(darkFractionBottomLeft(decoded), lessThan(0.02));
    });

    test('se puede pedir el EXIF sin el sello visible', () {
      final result = stamper.process(
        bytes: syntheticJpeg(),
        metadata: _metadata,
        drawStamp: false,
      );

      expect(result.stamped, isFalse);
      expect(result.exifWritten, isTrue);
    });

    test('unos bytes que no son imagen se devuelven intactos', () {
      final basura = Uint8List.fromList([1, 2, 3, 4, 5]);
      final result = stamper.process(bytes: basura, metadata: _metadata);

      // Perder la foto por no poder estamparla sería peor que no estamparla.
      expect(result.bytes, basura);
      expect(result.stamped, isFalse);
    });

    test('las fotos grandes se reducen al máximo configurado', () {
      final result = stamper.process(
        bytes: syntheticJpeg(width: 4000, height: 3000),
        metadata: _metadata,
      );

      final decoded = img.decodeImage(result.bytes)!;
      expect(decoded.width, kMaxPhotoWidth);
      // La proporción se mantiene.
      expect(decoded.height, closeTo(kMaxPhotoWidth * 3 / 4, 2));
    });

    test('una foto ya pequeña no se amplía', () {
      final result = stamper.process(
        bytes: syntheticJpeg(width: 800, height: 600),
        metadata: _metadata,
      );

      expect(img.decodeImage(result.bytes)!.width, 800);
    });
  });

  group('Fotos con EXIF heredado', () {
    /// Imita lo que entrega una cámara real: EXIF previo con marca, modelo,
    /// orientación y un bloque binario propietario tipo MakerNote.
    ///
    /// Es justo lo que no cubría la imagen sintética, y la diferencia entre
    /// que los tests pasaran y que fallara en el teléfono.
    Uint8List cameraLikeJpeg() {
      final image = img.Image(width: 1600, height: 1200);
      img.fill(image, color: img.ColorRgb8(190, 190, 190));

      final exif = image.exif;
      exif.imageIfd['Make'] = img.IfdValueAscii('ACME');
      exif.imageIfd['Model'] = img.IfdValueAscii('Camara 9000');
      exif.imageIfd['Orientation'] = img.IfdValueShort(6);
      exif.imageIfd['Software'] = img.IfdValueAscii('Firmware 1.2.3');
      exif.exifIfd['MakerNote'] = img.IfdValueUndefined.list(
        List<int>.generate(256, (i) => i % 256),
      );
      exif.exifIfd['UserComment'] = img.IfdValueAscii('comentario previo');

      return img.encodeJpg(image, quality: 92);
    }

    test('se procesa sin fallar', () {
      final result = stamper.process(
        bytes: cameraLikeJpeg(),
        metadata: _metadata,
      );

      expect(result.stamped, isTrue);
      expect(img.decodeImage(result.bytes), isNotNull);
    });

    test('el EXIF de la cámara se descarta y queda solo el nuestro', () {
      final result = stamper.process(
        bytes: cameraLikeJpeg(),
        metadata: _metadata,
      );
      final exif = img.decodeJpg(result.bytes)!.exif;

      // El MakerNote propietario es lo que puede hacer fallar al codificador.
      expect(exif.exifIfd['MakerNote'], isNull);
      expect(exif.imageIfd['Make'], isNull);
      // Y las coordenadas nuestras sí están.
      expect(exif.gpsIfd[0x0002], isNotNull);
    });

    test('el sello se dibuja igual', () {
      final result = stamper.process(
        bytes: cameraLikeJpeg(),
        metadata: _metadata,
      );
      final decoded = img.decodeImage(result.bytes)!;
      expect(darkFractionBottomLeft(decoded), greaterThan(0.15));
    });
  });

  group('Ejecución en isolate', () {
    // Es la ruta que usa la app de verdad. Si el closure arrastrara algo no
    // transferible, `Isolate.run` fallaría y el formulario se quedaría
    // colgado en "Sellando…", que es justo el fallo que esto previene.
    test('stampPhoto cruza la frontera del isolate', () async {
      final bytes = syntheticJpeg();
      final metadata = _metadata;

      final result = await Isolate.run(() => stampPhoto(bytes, metadata));

      expect(result.stamped, isTrue);
      expect(result.exifWritten, isTrue);
      expect(img.decodeImage(result.bytes), isNotNull);
    });

    test('el resultado devuelto conserva el sello', () async {
      final bytes = syntheticJpeg();
      final metadata = _metadata;

      final result = await Isolate.run(() => stampPhoto(bytes, metadata));
      final decoded = img.decodeImage(result.bytes)!;

      expect(darkFractionBottomLeft(decoded), greaterThan(0.15));
    });
  });

  group('EXIF escrito', () {
    test('las coordenadas se releen desde el archivo', () {
      final result = stamper.process(
        bytes: syntheticJpeg(),
        metadata: _metadata,
      );
      expect(result.exifWritten, isTrue);

      final gps = img.decodeJpg(result.bytes)!.exif.gpsIfd;

      expect(gps[0x0001]?.toData(), isNotNull); // referencia de latitud
      expect(gps[0x0002], isNotNull); // latitud
      expect(gps[0x0004], isNotNull); // longitud

      // Se reconstruye la latitud desde los tres racionales para confirmar que
      // se guardó el valor correcto y no una escala equivocada.
      final latitude = gps[0x0002]!;
      final grados = latitude.toRational(0);
      final minutos = latitude.toRational(1);
      final segundos = latitude.toRational(2);

      final reconstruida = grados.toDouble() +
          minutos.toDouble() / 60 +
          segundos.toDouble() / 3600;

      expect(reconstruida, closeTo(6.2402649, 0.00001));
    });

    test('el rumbo se guarda como magnético', () {
      final result = stamper.process(
        bytes: syntheticJpeg(),
        metadata: _metadata,
      );
      final gps = img.decodeJpg(result.bytes)!.exif.gpsIfd;

      // 'M' y no 'T': la brújula del teléfono da rumbo magnético, y decir que
      // es verdadero sería mentir sin aplicar la declinación del lugar.
      expect(gps[0x0010]?.toString(), contains('M'));
      expect(gps[0x0011]!.toRational(0).toDouble(), closeTo(48, 0.01));
    });

    test('sin posición no se inventan coordenadas', () {
      final result = stamper.process(
        bytes: syntheticJpeg(),
        metadata: PhotoMetadata(capturedAt: DateTime(2026, 7, 24)),
      );

      final gps = img.decodeJpg(result.bytes)!.exif.gpsIfd;
      expect(gps[0x0002], isNull);
      expect(gps[0x0004], isNull);
    });
  });
}

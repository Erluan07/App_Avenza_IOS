/// Tests de los metadatos de foto y la composición del sello.
library;

import 'package:test/test.dart';

import 'package:avenza_para_pobres/geo/geometry/primitives.dart';
import 'package:avenza_para_pobres/geo/photo/photo_metadata.dart';

void main() {
  group('Punto cardinal', () {
    test('los rumbos exactos dan su punto', () {
      expect(cardinalPoint(0), 'N');
      expect(cardinalPoint(90), 'E');
      expect(cardinalPoint(180), 'S');
      expect(cardinalPoint(270), 'O');
    });

    test('cada sector cubre 45 grados centrados en su punto', () {
      // El norte va de 337,5° a 22,5°, no de 0° a 45°.
      expect(cardinalPoint(22), 'N');
      expect(cardinalPoint(23), 'NE');
      expect(cardinalPoint(350), 'N');
    });

    test('normaliza rumbos fuera de rango', () {
      expect(cardinalPoint(360), 'N');
      expect(cardinalPoint(450), 'E');
      expect(cardinalPoint(-90), 'O');
    });
  });

  group('Sello', () {
    test('sin metadatos no hay nada que dibujar', () {
      expect(buildStampLines(const PhotoMetadata()), isEmpty);
      expect(const PhotoMetadata().hasAnything, isFalse);
    });

    test('la fecha va primero y en formato corto', () {
      final lines = buildStampLines(
        PhotoMetadata(capturedAt: DateTime(2026, 7, 24, 9, 5)),
      );
      expect(lines.first, '24/07/2026 09:05');
    });

    test('las coordenadas y los detalles van en líneas separadas', () {
      final lines = buildStampLines(
        PhotoMetadata(
          capturedAt: DateTime(2026, 7, 24, 9, 5),
          position: const LatLon(6.2402649, -75.5354646),
          accuracyMeters: 4.2,
          elevationMeters: 1495,
          headingDegrees: 48,
        ),
      );

      expect(lines, hasLength(3));
      expect(lines[1], '6.2402649, -75.5354646');
      // Precisión, altitud y rumbo comparten línea para no ocupar media foto.
      expect(lines[2], contains('+-4 m'));
      expect(lines[2], contains('alt 1495 m'));
      expect(lines[2], contains('rumbo NE 48'));
    });

    test('sin posición pero con rumbo, el rumbo igual aparece', () {
      final lines = buildStampLines(
        const PhotoMetadata(headingDegrees: 180),
      );
      expect(lines, hasLength(1));
      expect(lines.first, 'rumbo S 180');
    });

    test('la nota se agrega al final', () {
      final lines = buildStampLines(
        const PhotoMetadata(
          position: LatLon(6.24, -75.53),
          note: 'Quebrada La Iguaná',
        ),
      );
      expect(lines.last, 'Quebrada La Iguaná');
    });

    test('una nota en blanco no genera línea', () {
      final lines = buildStampLines(
        const PhotoMetadata(position: LatLon(6.24, -75.53), note: '   '),
      );
      expect(lines, hasLength(1));
    });
  });

  group('Repertorio de caracteres', () {
    test('el sello se limita a ASCII imprimible', () {
      // La fuente de mapa de bits con la que se dibuja solo trae ASCII: los
      // caracteres que no existen se pierden y dejan un hueco. Pasó con `°` y
      // con `·`, y solo se vio al mirar la imagen generada.
      final lines = buildStampLines(
        PhotoMetadata(
          capturedAt: DateTime(2026, 7, 24, 9, 5),
          position: const LatLon(6.2402649, -75.5354646),
          accuracyMeters: 4.2,
          elevationMeters: 1495,
          headingDegrees: 48,
        ),
      );

      expect(lines, isNotEmpty);
      for (final line in lines) {
        for (final code in line.codeUnits) {
          expect(
            code,
            inInclusiveRange(0x20, 0x7E),
            reason: 'La línea "$line" trae un carácter fuera de ASCII '
                'imprimible (code $code) que la fuente no puede dibujar.',
          );
        }
      }
    });

    test('ninguna línea trae caracteres que partan el texto', () {
      // `drawString` parte por `RegExp(r"[\n|\r]")`, y esa clase incluye el
      // pipe literal. Un `|` en el sello lo rompe en varias líneas que se
      // salen del panel.
      final lines = buildStampLines(
        PhotoMetadata(
          capturedAt: DateTime(2026, 7, 24, 9, 5),
          position: const LatLon(6.24, -75.53),
          accuracyMeters: 4.2,
          elevationMeters: 1495,
          headingDegrees: 48,
          note: 'nota de prueba',
        ),
      );

      for (final line in lines) {
        expect(line, isNot(contains('|')));
        expect(line, isNot(contains('\n')));
        expect(line, isNot(contains('\r')));
      }
      expect(kStampSeparator, isNot(contains('|')));
    });

    test('el rumbo se entiende sin el símbolo de grados', () {
      final lines = buildStampLines(
        const PhotoMetadata(headingDegrees: 48),
      );
      expect(lines.single, 'rumbo NE 48');
    });
  });

  group('EXIF', () {
    test('convierte grados decimales a grados/minutos/segundos', () {
      // 6.2402649° = 6° 14' 24,95"
      final rational = degreesToExifRational(6.2402649);

      expect(rational, hasLength(3));
      expect(rational[0], [6, 1]);
      expect(rational[1], [14, 1]);
      // Los segundos se guardan en milésimas para no perder metros.
      expect(rational[2][1], 1000);
      expect(rational[2][0] / 1000, closeTo(24.95, 0.01));
    });

    test('el signo no viaja en la coordenada sino en la referencia', () {
      // EXIF guarda el valor absoluto; el hemisferio va aparte.
      final negativa = degreesToExifRational(-75.5354646);
      expect(negativa[0], [75, 1]);

      expect(exifLatitudeRef(6.24), 'N');
      expect(exifLatitudeRef(-6.24), 'S');
      expect(exifLongitudeRef(75.53), 'E');
      expect(exifLongitudeRef(-75.53), 'W');
    });

    test('el cero se considera hemisferio positivo', () {
      expect(exifLatitudeRef(0), 'N');
      expect(exifLongitudeRef(0), 'E');
    });

    test('una coordenada entera no arrastra minutos ni segundos', () {
      final rational = degreesToExifRational(45);
      expect(rational[0], [45, 1]);
      expect(rational[1], [0, 1]);
      expect(rational[2], [0, 1000]);
    });
  });
}

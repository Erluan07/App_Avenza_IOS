/// Tests de la detección de toques sobre geometrías.
library;

import 'package:test/test.dart';

import 'package:avenza_para_pobres/geo/geometry/geometry.dart';
import 'package:avenza_para_pobres/geo/geometry/hit_test.dart';
import 'package:avenza_para_pobres/geo/geometry/primitives.dart';

/// Cuadrado de ~110 m de lado.
const _ring = [
  LatLon(6.240, -75.535),
  LatLon(6.240, -75.534),
  LatLon(6.241, -75.534),
  LatLon(6.241, -75.535),
];

void main() {
  group('Distancia a polilínea', () {
    test('un punto sobre la línea da cero', () {
      const linea = [LatLon(6.240, -75.535), LatLon(6.240, -75.534)];
      expect(
        distanceToPolyline(linea, const LatLon(6.240, -75.5345)),
        lessThan(1),
      );
    });

    test('mide la perpendicular, no la distancia a los extremos', () {
      // Punto justo al norte del centro del segmento.
      const linea = [LatLon(6.240, -75.535), LatLon(6.240, -75.534)];
      final distancia =
          distanceToPolyline(linea, const LatLon(6.2405, -75.5345));

      // 0,0005° de latitud son unos 55 m.
      expect(distancia, closeTo(55, 3));
    });

    test('más allá del extremo mide hasta el vértice', () {
      const linea = [LatLon(6.240, -75.535), LatLon(6.240, -75.534)];
      // Muy al oeste del primer vértice.
      final distancia =
          distanceToPolyline(linea, const LatLon(6.240, -75.536));
      expect(distancia, closeTo(110, 6));
    });

    test('una lista vacía no rompe', () {
      expect(distanceToPolyline(const [], const LatLon(0, 0)),
          double.infinity);
    });

    test('un solo punto se mide como punto', () {
      expect(
        distanceToPolyline(const [LatLon(6.240, -75.535)],
            const LatLon(6.240, -75.535)),
        closeTo(0, 0.001),
      );
    });
  });

  group('Dentro del anillo', () {
    test('el centro está dentro', () {
      expect(isInsideRing(_ring, const LatLon(6.2405, -75.5345)), isTrue);
    });

    test('un punto claramente fuera no cuenta', () {
      expect(isInsideRing(_ring, const LatLon(6.250, -75.520)), isFalse);
      expect(isInsideRing(_ring, const LatLon(6.239, -75.5345)), isFalse);
    });

    test('un anillo degenerado no encierra nada', () {
      expect(
        isInsideRing(const [LatLon(0, 0), LatLon(0, 1)], const LatLon(0, 0.5)),
        isFalse,
      );
    });
  });

  group('Impacto sobre geometrías', () {
    test('un punto se detecta dentro de la tolerancia', () {
      const punto = PointGeometry(LatLon(6.240, -75.535));

      expect(
        hitDistance(punto, const LatLon(6.2400, -75.5350),
            toleranceMeters: 20),
        isNotNull,
      );
      // A ~110 m, fuera de una tolerancia de 20 m.
      expect(
        hitDistance(punto, const LatLon(6.241, -75.535),
            toleranceMeters: 20),
        isNull,
      );
    });

    test('el relleno del polígono cuenta como impacto directo', () {
      const poligono = PolygonGeometry(_ring);
      // Tocar dentro debe ganar frente a cualquier borde cercano.
      expect(
        hitDistance(poligono, const LatLon(6.2405, -75.5345),
            toleranceMeters: 5),
        0,
      );
    });

    test('el borde del polígono se detecta desde fuera', () {
      const poligono = PolygonGeometry(_ring);
      // Unos 11 m al sur del borde inferior.
      final distancia = hitDistance(
        poligono,
        const LatLon(6.2399, -75.5345),
        toleranceMeters: 30,
      );

      expect(distancia, isNotNull);
      expect(distancia, greaterThan(0));
    });

    test('la tolerancia se respeta', () {
      const linea = LineGeometry([
        LatLon(6.240, -75.535),
        LatLon(6.240, -75.534),
      ]);

      expect(
        hitDistance(linea, const LatLon(6.2405, -75.5345),
            toleranceMeters: 100),
        isNotNull,
      );
      expect(
        hitDistance(linea, const LatLon(6.2405, -75.5345),
            toleranceMeters: 10),
        isNull,
      );
    });
  });
}

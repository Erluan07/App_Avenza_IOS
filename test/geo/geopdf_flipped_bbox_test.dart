/// Tests de GeoPDF con el `/BBox` del viewport invertido en el eje Y.
///
/// Es el caso de `Abr10_santo_domingo.pdf`, exportado por ArcGIS Pro con
/// `y0 > y1`. Normalizar ese rectángulo a mínimos y máximos volteaba el mapa
/// de norte a sur, y el resultado se veía en espejo.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'package:avenza_para_pobres/geo/geometry/primitives.dart';
import 'package:avenza_para_pobres/geo/geopdf/geopdf_models.dart';
import 'package:avenza_para_pobres/geo/geopdf/geopdf_reader.dart';
import 'package:avenza_para_pobres/geo/transform/georeference.dart';

/// Viewport con el eje Y invertido, con los valores reales del archivo.
GeoPdfViewport flippedViewport() => const GeoPdfViewport(
      bbox: [42.48183, 1467.06951, 2170.65326, 42.49918],
      measure: GeoMeasure(
        lpts: [Point2(0, 1), Point2(0, 0), Point2(1, 0), Point2(1, 1)],
        gpts: [
          LatLon(6.29022, -75.54755),
          LatLon(6.30385, -75.54762),
          LatLon(6.30395, -75.52727),
          LatLon(6.29032, -75.5272),
        ],
        bounds: [Point2(0, 1), Point2(0, 0), Point2(1, 0), Point2(1, 1)],
      ),
    );

/// El mismo mapa con el `/BBox` en orden normal, como lo escribe la mayoría.
GeoPdfViewport uprightViewport() => const GeoPdfViewport(
      bbox: [42.48183, 42.49918, 2170.65326, 1467.06951],
      measure: GeoMeasure(
        lpts: [Point2(0, 0), Point2(0, 1), Point2(1, 1), Point2(1, 0)],
        gpts: [
          LatLon(6.29022, -75.54755),
          LatLon(6.30385, -75.54762),
          LatLon(6.30395, -75.52727),
          LatLon(6.29032, -75.5272),
        ],
        bounds: [Point2(0, 0), Point2(0, 1), Point2(1, 1), Point2(1, 0)],
      ),
    );

void main() {
  group('Viewport con BBox invertido', () {
    test('conserva el orden de las esquinas tal como viene', () {
      final viewport = flippedViewport();
      // Sin normalizar: el orden define hacia dónde crece el cuadrado unitario.
      expect(viewport.bbox[1], 1467.06951);
      expect(viewport.bbox[3], 42.49918);
      expect(viewport.spanY, lessThan(0));
    });

    test('las dimensiones se reportan en positivo', () {
      final viewport = flippedViewport();
      expect(viewport.widthPt, closeTo(2128.17, 0.01));
      expect(viewport.heightPt, closeTo(1424.57, 0.01));
      // Si el área saliera negativa, al elegir entre varios viewports se
      // preferiría el mapa de localización en vez del principal.
      expect(viewport.areaPt2, greaterThan(0));
    });

    test('el rectángulo normalizado sí queda ordenado', () {
      final normalized = flippedViewport().normalizedBbox;
      expect(normalized[0], lessThan(normalized[2]));
      expect(normalized[1], lessThan(normalized[3]));
    });
  });

  group('Orientación del mapa', () {
    test('el norte queda arriba en la página', () {
      final georeference = GeoReference.fromViewport(flippedViewport())!;

      // Dos puntos de la misma columna, uno abajo y otro arriba de la página.
      final abajo = georeference.pageToLatLon(const Point2(1100, 100));
      final arriba = georeference.pageToLatLon(const Point2(1100, 1400));

      expect(
        arriba.latitude,
        greaterThan(abajo.latitude),
        reason: 'Con el norte abajo, el mapa se ve volteado.',
      );
    });

    test('el este queda a la derecha', () {
      final georeference = GeoReference.fromViewport(flippedViewport())!;

      final izquierda = georeference.pageToLatLon(const Point2(100, 700));
      final derecha = georeference.pageToLatLon(const Point2(2100, 700));

      expect(derecha.longitude, greaterThan(izquierda.longitude));
    });

    test('no hay reflexión: la transformación conserva la orientación', () {
      final georeference = GeoReference.fromViewport(flippedViewport())!;

      // Un determinante negativo en la afín significa espejado. La página
      // tiene Y hacia arriba igual que el CRS proyectado, así que debe ser
      // positivo.
      expect(
        georeference.pageToTarget.determinant,
        greaterThan(0),
        reason: 'La afín refleja el mapa.',
      );
    });

    test('da el mismo resultado que el BBox en orden normal', () {
      // Los dos viewports describen el mismo mapa, escrito de dos formas.
      final flipped = GeoReference.fromViewport(flippedViewport())!;
      final upright = GeoReference.fromViewport(uprightViewport())!;

      for (final page in [
        const Point2(200, 200),
        const Point2(1100, 700),
        const Point2(2000, 1400),
      ]) {
        final a = flipped.pageToLatLon(page);
        final b = upright.pageToLatLon(page);
        expect(a.latitude, closeTo(b.latitude, 1e-9));
        expect(a.longitude, closeTo(b.longitude, 1e-9));
      }
    });

    test('el ajuste es exacto, sin residuos', () {
      final georeference = GeoReference.fromViewport(flippedViewport())!;
      // Cuatro puntos de control coplanares: si la interpretación del BBox
      // fuera la equivocada, el ajuste no cerraría.
      expect(georeference.rmsError, lessThan(1));
      expect(georeference.controlPointCount, 4);
    });
  });

  group('Archivo real', () {
    final file = File('Pruebas/Abr10_santo_domingo.pdf');

    test(
      'Abr10_santo_domingo.pdf se lee con el norte arriba',
      () {
        final info = GeoPdfReader.read(file.readAsBytesSync());
        final page = info.firstGeoreferencedPage;
        expect(page, isNotNull);

        // El layout trae dos viewports; se elige el de mayor superficie, que
        // es el mapa principal y no el de localización.
        final viewport = page!.primaryViewport!;
        expect(viewport.name, 'Layers');

        final georeference = GeoReference.fromViewport(viewport)!;
        final bbox = georeference.bbox;
        final centroX = (bbox[0] + bbox[2]) / 2;

        final abajo = georeference.pageToLatLon(Point2(centroX, bbox[1] + 50));
        final arriba = georeference.pageToLatLon(Point2(centroX, bbox[3] - 50));

        expect(arriba.latitude, greaterThan(abajo.latitude));
        expect(georeference.pageToTarget.determinant, greaterThan(0));
      },
      skip: file.existsSync()
          ? false
          : 'Falta Pruebas/Abr10_santo_domingo.pdf',
    );
  });
}

/// Test de integración contra un GeoPDF real exportado desde ArcGIS Pro.
///
/// Es el test que de verdad importa: fija el comportamiento frente a un
/// archivo de producción, no frente a un PDF sintético hecho a medida del
/// parser. Los valores esperados salen del contenido crudo del archivo.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'package:avenza_para_pobres/geo/geometry/primitives.dart';
import 'package:avenza_para_pobres/geo/geopdf/geopdf_reader.dart';
import 'package:avenza_para_pobres/geo/measure/geodesy.dart';
import 'package:avenza_para_pobres/geo/pdf/pdf_document.dart';
import 'package:avenza_para_pobres/geo/transform/georeference.dart';
import 'package:avenza_para_pobres/geo/transform/page_raster.dart';

File? _locateFixture() {
  for (final path in ['Layout.pdf', 'test/fixtures/Layout.pdf']) {
    final file = File(path);
    if (file.existsSync()) return file;
  }
  return null;
}

void main() {
  final fixture = _locateFixture();

  group(
    'Layout.pdf (ArcGIS Pro, MAGNA-SIRGAS 2018)',
    () {
      late GeoReference georeference;
      late PdfDocument document;

      setUpAll(() {
        final bytes = fixture!.readAsBytesSync();
        document = PdfDocument.parse(bytes);
        final info = GeoPdfReader.readDocument(document);
        georeference =
            GeoReference.fromViewport(info.pages.first.primaryViewport!)!;
      });

      test('lee la estructura del PDF 1.7 con xref stream', () {
        // El archivo usa tabla de referencias cruzadas en stream y object
        // streams comprimidos: si esto falla, el lector de bajo nivel se rompió.
        expect(document.trailer, isNotNull);
        expect(document.catalog, isNotNull);
        expect(document.pages, hasLength(1));
      });

      test('encuentra el viewport georreferenciado', () {
        final info = GeoPdfReader.readDocument(document);
        final page = info.pages.first;

        expect(page.isGeoreferenced, isTrue);
        expect(page.issue, isNull);
        expect(page.viewports, hasLength(1));
        expect(page.viewports.first.name, 'Map');
        expect(page.rotate, 0);
      });

      test('decodifica el nombre UTF-16BE del viewport', () {
        final info = GeoPdfReader.readDocument(document);
        // Viene como (þÿ\0M\0a\0p): con BOM y dos bytes por carácter.
        expect(info.pages.first.viewports.first.name, 'Map');
      });

      test('lee los cuatro puntos de control', () {
        final info = GeoPdfReader.readDocument(document);
        final measure = info.pages.first.viewports.first.measure;

        expect(measure.lpts, hasLength(4));
        expect(measure.gpts, hasLength(4));
        expect(measure.isUsable, isTrue);

        // LPTS(0,1) es la esquina superior izquierda del BBox.
        expect(measure.lpts.first.x, 0);
        expect(measure.lpts.first.y, 1);
        expect(measure.gpts.first.latitude, closeTo(6.25815, 1e-9));
        expect(measure.gpts.first.longitude, closeTo(-75.54704, 1e-9));
      });

      test('clasifica el CRS por su contenido, no por la clave', () {
        // ArcGIS Pro escribe el sistema PROYECTADO bajo /GCS y omite /PCS.
        // Fiarse de la clave llevaría a interpretar los GPTS (lat/lon) como
        // coordenadas proyectadas y devolver coordenadas absurdas.
        final info = GeoPdfReader.readDocument(document);
        final measure = info.pages.first.viewports.first.measure;

        expect(measure.pcs, isNull);
        expect(measure.gcs, isNotNull);
        expect(measure.gcs!.type, 'PROJCS');

        expect(georeference.mode, GeoReferenceMode.proyectado);
        expect(georeference.crsName, 'MAGNA-SIRGAS_2018_Origen-Nacional');
      });

      test('el ajuste afín es preciso a nivel centimétrico', () {
        expect(georeference.controlPointCount, 4);
        // Residuo dominado por el redondeo de los GPTS a 5 decimales.
        expect(georeference.rmsError, lessThan(0.5));
        expect(georeference.maxError, lessThan(0.5));
      });

      test('no reporta problemas de datum con MAGNA-SIRGAS', () {
        expect(georeference.datumShiftMissing, isFalse);
        expect(georeference.projectedCrsUnresolved, isFalse);
        expect(georeference.isReliable, isTrue);
      });

      test('reproduce los puntos de control declarados en el archivo', () {
        final info = GeoPdfReader.readDocument(document);
        final viewport = info.pages.first.viewports.first;
        final bbox = viewport.bbox;
        final measure = viewport.measure;

        for (var i = 0; i < measure.lpts.length; i++) {
          final l = measure.lpts[i];
          final page = Point2(
            bbox[0] + l.x * (bbox[2] - bbox[0]),
            bbox[1] + l.y * (bbox[3] - bbox[1]),
          );
          final error =
              vincentyDistance(measure.gpts[i], georeference.pageToLatLon(page));
          expect(error, lessThan(0.5), reason: 'punto de control $i');
        }
      });

      test('la conversión de ida y vuelta es exacta', () {
        for (final corner in georeference.cornersLatLon) {
          final page = georeference.latLonToPage(corner);
          expect(page, isNotNull);
          final back = georeference.pageToLatLon(page!);
          expect(vincentyDistance(corner, back), lessThan(0.001));
        }
      });

      test('la cobertura y la escala son coherentes', () {
        final coverage = georeference.coverage;

        expect(coverage.south, closeTo(6.2224, 0.001));
        expect(coverage.north, closeTo(6.2582, 0.001));
        expect(coverage.west, closeTo(-75.5485, 0.001));
        expect(coverage.east, closeTo(-75.5224, 0.001));

        // Una A4 a ~4,6 m por punto da del orden de 1:13.000.
        expect(georeference.scaleDenominator, closeTo(12955, 500));
        expect(georeference.metersPerPagePoint, closeTo(4.57, 0.2));
      });

      test('sobrevive al viaje por JSON para cachearse en la base de datos', () {
        final restored =
            GeoReference.fromJsonString(georeference.toJsonString());
        expect(restored, isNotNull);

        const page = Point2(300, 400);
        final original = georeference.pageToLatLon(page);
        final roundTripped = restored!.pageToLatLon(page);

        expect(vincentyDistance(original, roundTripped), lessThan(0.001));
        expect(restored.crsName, georeference.crsName);
        expect(restored.mode, georeference.mode);
      });

      test('los píxeles de la imagen rasterizada caen donde deben', () {
        // Es la cadena que usa el visor: píxel de la imagen -> punto de página
        // -> lat/lon. Se simula un render a 2400 px de lado mayor.
        final info = GeoPdfReader.readDocument(document);
        final page = info.pages.first;
        final viewport = page.viewports.first;

        const longSide = 2400.0;
        final scale = longSide / page.heightPt; // la A4 es más alta que ancha
        final raster = PageRasterMapping(
          mediaBox: page.mediaBox,
          rotate: page.rotate,
          imageWidth: page.widthPt * scale,
          imageHeight: longSide,
        );
        final mapping = GeoRasterMapping(
          raster: raster,
          georeference: georeference,
        );

        // Cada punto de control declarado debe caer en su píxel y volver.
        final bbox = viewport.bbox;
        final measure = viewport.measure;
        for (var i = 0; i < measure.lpts.length; i++) {
          final l = measure.lpts[i];
          final pagePoint = Point2(
            bbox[0] + l.x * (bbox[2] - bbox[0]),
            bbox[1] + l.y * (bbox[3] - bbox[1]),
          );
          final pixel = raster.pageToPixel(pagePoint);

          // El píxel debe caer dentro de la imagen...
          expect(pixel.x, inInclusiveRange(-1, raster.imageWidth + 1));
          expect(pixel.y, inInclusiveRange(-1, raster.imageHeight + 1));

          // ...y su lat/lon coincidir con la coordenada declarada.
          final error =
              vincentyDistance(measure.gpts[i], mapping.pixelToLatLon(pixel));
          expect(error, lessThan(0.5), reason: 'punto de control $i');
        }
      });

      test('la esquina superior izquierda de la imagen es el noroeste', () {
        // Sin rotación, el píxel (0,0) es la esquina noroeste del mapa. Si esto
        // falla, la imagen saldría espejada o girada sobre el terreno.
        final info = GeoPdfReader.readDocument(document);
        final page = info.pages.first;

        final raster = PageRasterMapping(
          mediaBox: page.mediaBox,
          rotate: page.rotate,
          imageWidth: 800,
          imageHeight: 1131,
        );
        final mapping = GeoRasterMapping(
          raster: raster,
          georeference: georeference,
        );

        final topLeft = mapping.pixelToLatLon(const Point2(0, 0));
        final bottomRight = mapping.pixelToLatLon(const Point2(800, 1131));

        expect(topLeft.latitude, greaterThan(bottomRight.latitude));
        expect(topLeft.longitude, lessThan(bottomRight.longitude));
      });
    },
    skip: fixture == null
        ? 'Falta Layout.pdf en la raíz del proyecto o en test/fixtures/'
        : null,
  );
}

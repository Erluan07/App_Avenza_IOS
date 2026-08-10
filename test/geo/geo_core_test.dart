/// Tests del núcleo geoespacial. Todo Dart puro: corren con `dart test`.
library;

import 'package:test/test.dart';

import 'package:avenza_para_pobres/geo/crs/crs_resolver.dart';
import 'package:avenza_para_pobres/geo/crs/wkt_parser.dart';
import 'package:avenza_para_pobres/geo/crs/wkt_to_proj4.dart';
import 'package:avenza_para_pobres/geo/geometry/primitives.dart';
import 'package:avenza_para_pobres/geo/measure/geodesy.dart';
import 'package:avenza_para_pobres/geo/transform/affine.dart';
import 'package:avenza_para_pobres/geo/transform/page_raster.dart';

/// WKT real, tal cual lo escribe ArcGIS Pro (tomado de Layout.pdf).
const String kMagnaSirgasWkt =
    'PROJCS["MAGNA-SIRGAS_2018_Origen-Nacional",'
    'GEOGCS["MAGNA-SIRGAS_2018",'
    'DATUM["Marco_Geocentrico_Nacional_de_Referencia_2018",'
    'SPHEROID["GRS_1980",6378137.0,298.257222101]],'
    'PRIMEM["Greenwich",0.0],'
    'UNIT["Degree",0.0174532925199433]],'
    'PROJECTION["Transverse_Mercator"],'
    'PARAMETER["False_Easting",5000000.0],'
    'PARAMETER["False_Northing",2000000.0],'
    'PARAMETER["Central_Meridian",-73.0],'
    'PARAMETER["Scale_Factor",0.9992],'
    'PARAMETER["Latitude_Of_Origin",4.0],'
    'UNIT["Meter",1.0]]';

void main() {
  group('Afín', () {
    test('reproduce exactamente una transformación conocida', () {
      const expected = Affine2D(2, 0, 100, 0, -3, 50);
      final from = [
        const Point2(0, 0),
        const Point2(10, 0),
        const Point2(0, 10),
        const Point2(10, 10),
      ];
      final to = [for (final p in from) expected.apply(p)];

      final fit = fitAffine(from, to);
      expect(fit, isNotNull);
      expect(fit!.rmsError, lessThan(1e-9));
      expect(fit.transform.a, closeTo(2, 1e-9));
      expect(fit.transform.e, closeTo(-3, 1e-9));
      expect(fit.transform.c, closeTo(100, 1e-9));
      expect(fit.transform.f, closeTo(50, 1e-9));
    });

    test('la inversa deshace la transformación', () {
      const transform = Affine2D(1.5, 0.3, 20, -0.2, 2.1, -5);
      final inverse = transform.invert();
      expect(inverse, isNotNull);

      const original = Point2(37, -12);
      final back = inverse!.apply(transform.apply(original));
      expect(back.x, closeTo(original.x, 1e-9));
      expect(back.y, closeTo(original.y, 1e-9));
    });

    test('rechaza puntos de control colineales', () {
      final collinear = [
        const Point2(0, 0),
        const Point2(1, 1),
        const Point2(2, 2),
      ];
      expect(fitAffine(collinear, collinear), isNull);
    });

    test('con menos de 3 puntos no hay solución', () {
      expect(
        fitAffine([const Point2(0, 0)], [const Point2(1, 1)]),
        isNull,
      );
    });
  });

  group('WKT', () {
    test('parsea la estructura anidada de ArcGIS', () {
      final root = parseWkt(kMagnaSirgasWkt);
      expect(root, isNotNull);
      expect(root!.keyword, 'PROJCS');
      expect(root.name, 'MAGNA-SIRGAS_2018_Origen-Nacional');
      expect(root.child('GEOGCS')?.name, 'MAGNA-SIRGAS_2018');
      expect(root.child('PROJECTION')?.name, 'Transverse_Mercator');
      expect(root.childrenNamed('PARAMETER').length, 5);
    });

    test('traduce a proj4 con todos los parámetros', () {
      final conversion = wktToProj4(kMagnaSirgasWkt);
      expect(conversion, isNotNull);
      expect(conversion!.isGeographic, isFalse);

      final definition = conversion.definition;
      expect(definition, contains('+proj=tmerc'));
      expect(definition, contains('+lat_0=4'));
      expect(definition, contains('+lon_0=-73'));
      expect(definition, contains('+k_0=0.9992'));
      expect(definition, contains('+x_0=5000000'));
      expect(definition, contains('+y_0=2000000'));
      expect(definition, contains('+a=6378137'));
      expect(definition, contains('+rf=298.257222101'));
      expect(definition, contains('+units=m'));
    });

    test('MAGNA-SIRGAS no dispara aviso de datum', () {
      final conversion = wktToProj4(kMagnaSirgasWkt);
      // Es un datum geocéntrico: equivale a WGS84 a efectos prácticos, así que
      // no debe alarmar al usuario.
      expect(conversion!.datumShiftMissing, isFalse);
      expect(conversion.datumShiftAssumed, isFalse);
    });

    test('acepta los nombres de parámetro de OGC además de los de ESRI', () {
      const ogcStyle = 'PROJCS["test",'
          'GEOGCS["g",DATUM["d",SPHEROID["s",6378137.0,298.257223563]],'
          'PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],'
          'PROJECTION["Transverse Mercator"],'
          'PARAMETER["false easting",500000.0],'
          'PARAMETER["central meridian",-75.0],'
          'UNIT["Meter",1.0]]';

      final definition = wktToProj4(ogcStyle)!.definition;
      expect(definition, contains('+proj=tmerc'));
      expect(definition, contains('+x_0=500000'));
      expect(definition, contains('+lon_0=-75'));
    });

    test('devuelve null ante texto que no es WKT', () {
      expect(wktToProj4('esto no es un WKT'), isNull);
      expect(wktToProj4(''), isNull);
      expect(wktToProj4(null), isNull);
    });
  });

  group('CRS', () {
    test('deriva el sistema geográfico de uno proyectado', () {
      final definition = wktToProj4(kMagnaSirgasWkt)!.definition;
      final geographic = geographicVariantOf(definition);

      expect(geographic, isNotNull);
      expect(geographic, contains('+proj=longlat'));
      // Conserva la forma de la Tierra...
      expect(geographic, contains('+a=6378137'));
      expect(geographic, contains('+rf=298.257222101'));
      // ...y descarta los parámetros de la proyección.
      expect(geographic, isNot(contains('+lat_0')));
      expect(geographic, isNot(contains('+x_0')));
      expect(geographic, isNot(contains('+units=m')));
    });

    test('un CRS ya geográfico se devuelve sin cambios', () {
      const geographic = '+proj=longlat +datum=WGS84 +no_defs';
      expect(geographicVariantOf(geographic), geographic);
    });

    test('resuelve códigos EPSG de UTM', () {
      expect(proj4ForEpsg(32718), contains('+proj=utm'));
      expect(proj4ForEpsg(32718), contains('+zone=18'));
      expect(proj4ForEpsg(32718), contains('+south'));
      expect(proj4ForEpsg(32618), contains('+zone=18'));
      expect(proj4ForEpsg(32618), isNot(contains('+south')));
    });
  });

  group('Geodesia', () {
    test('un grado de latitud en el ecuador mide ~110.574 m', () {
      final distance = vincentyDistance(
        const LatLon(0, 0),
        const LatLon(1, 0),
      );
      expect(distance, closeTo(110574.389, 1.0));
    });

    test('un grado de longitud en el ecuador mide ~111.319 m', () {
      final distance = vincentyDistance(
        const LatLon(0, 0),
        const LatLon(0, 1),
      );
      expect(distance, closeTo(111319.491, 1.0));
    });

    test('la distancia a uno mismo es cero', () {
      const point = LatLon(6.2402, -75.5354);
      expect(vincentyDistance(point, point), 0);
    });

    test('vincenty y haversine concuerdan dentro del 0,5 %', () {
      const a = LatLon(6.25815, -75.54704);
      const b = LatLon(6.22238, -75.52389);
      final exact = vincentyDistance(a, b);
      final approximate = haversineDistance(a, b);
      expect((exact - approximate).abs() / exact, lessThan(0.005));
    });

    test('el área de una celda pequeña coincide con el cálculo planar', () {
      // En una celda de ~100 m la Tierra es plana a todos los efectos, así que
      // el área geodésica debe coincidir con ancho x alto medidos por Vincenty.
      const south = 6.240;
      const north = 6.241;
      const west = -75.535;
      const east = -75.534;

      final area = ringArea(const [
        LatLon(south, west),
        LatLon(south, east),
        LatLon(north, east),
        LatLon(north, west),
      ]);

      final width = vincentyDistance(
        const LatLon(south, west),
        const LatLon(south, east),
      );
      final height = vincentyDistance(
        const LatLon(south, west),
        const LatLon(north, west),
      );

      expect(area, closeTo(width * height, width * height * 0.005));
    });

    test('el área no depende del sentido de giro del anillo', () {
      const ring = [
        LatLon(6.240, -75.535),
        LatLon(6.240, -75.534),
        LatLon(6.241, -75.534),
        LatLon(6.241, -75.535),
      ];
      expect(
        ringArea(ring),
        closeTo(ringArea(ring.reversed.toList()), 1e-6),
      );
    });

    test('acepta anillos ya cerrados sin contar dos veces el vértice', () {
      const open = [
        LatLon(6.240, -75.535),
        LatLon(6.240, -75.534),
        LatLon(6.241, -75.534),
      ];
      final closed = [...open, open.first];
      expect(ringArea(closed), closeTo(ringArea(open), 1e-6));
    });

    test('el rumbo al norte es 0 y al este 90', () {
      expect(
        initialBearing(const LatLon(0, 0), const LatLon(1, 0)),
        closeTo(0, 1e-6),
      );
      expect(
        initialBearing(const LatLon(0, 0), const LatLon(0, 1)),
        closeTo(90, 1e-6),
      );
    });
  });

  group('Mapeo página ⇄ imagen', () {
    const mediaBox = [0.0, 0.0, 595.274, 841.888];

    test('ida y vuelta exacta en las cuatro rotaciones', () {
      for (final rotate in [0, 90, 180, 270]) {
        final quarterTurned = rotate == 90 || rotate == 270;
        final mapping = PageRasterMapping(
          mediaBox: mediaBox,
          rotate: rotate,
          imageWidth: quarterTurned ? 1200 : 800,
          imageHeight: quarterTurned ? 800 : 1200,
        );

        const page = Point2(123.4, 567.8);
        final back = mapping.pixelToPage(mapping.pageToPixel(page));
        expect(back.x, closeTo(page.x, 1e-6), reason: 'rotate=$rotate');
        expect(back.y, closeTo(page.y, 1e-6), reason: 'rotate=$rotate');
      }
    });

    test('sin rotación, el origen PDF cae abajo-izquierda de la imagen', () {
      const mapping = PageRasterMapping(
        mediaBox: mediaBox,
        rotate: 0,
        imageWidth: 800,
        imageHeight: 1200,
      );

      // El PDF tiene el origen abajo-izquierda; la imagen, arriba-izquierda.
      final pixel = mapping.pageToPixel(const Point2(0, 0));
      expect(pixel.x, closeTo(0, 1e-6));
      expect(pixel.y, closeTo(1200, 1e-6));
    });

    test('con 90° la esquina inferior izquierda pasa a arriba-izquierda', () {
      const mapping = PageRasterMapping(
        mediaBox: mediaBox,
        rotate: 90,
        imageWidth: 1200,
        imageHeight: 800,
      );

      final pixel = mapping.pageToPixel(const Point2(0, 0));
      expect(pixel.x, closeTo(0, 1e-6));
      expect(pixel.y, closeTo(0, 1e-6));
    });
  });
}

/// Tests del generador de KML y del empaquetado KMZ.
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

import 'package:avenza_para_pobres/geo/export/kml_model.dart';
import 'package:avenza_para_pobres/geo/export/kml_writer.dart';
import 'package:avenza_para_pobres/geo/export/kmz_writer.dart';
import 'package:avenza_para_pobres/geo/geometry/geometry.dart';
import 'package:avenza_para_pobres/geo/geometry/primitives.dart';

const _punto = LatLon(6.2402649, -75.5354646);

KmlDocument documentWith(KmlPlacemark placemark, {int color = 0xFFE53935}) =>
    KmlDocument(
      name: 'Proyecto',
      folders: [
        KmlFolder(name: 'Capa', color: color, placemarks: [placemark]),
      ],
    );

void main() {
  group('Color', () {
    test('invierte el orden de canales a aabbggrr', () {
      // KML no usa ARGB: si se copian los canales tal cual, el rojo sale azul.
      // ARGB ff e5 39 35  ->  KML aa bb gg rr = ff 35 39 e5
      expect(kmlColor(0xFFE53935), 'ff3539e5');
      expect(kmlColor(0xFF1E88E5), 'ffe5881e');
    });

    test('aplica la opacidad sobre el canal alfa', () {
      expect(kmlColor(0xFFE53935, opacity: 0.35), '593539e5');
      expect(kmlColor(0xFFE53935, opacity: 0), '003539e5');
    });

    test('los canales de un solo dígito se rellenan a dos', () {
      expect(kmlColor(0xFF000000), 'ff000000');
      expect(kmlColor(0x01020304).length, 8);
    });
  });

  group('Geometrías', () {
    test('un punto emite lon,lat en ese orden', () {
      final kml = buildKml(
        documentWith(
          const KmlPlacemark(name: 'P1', geometry: PointGeometry(_punto)),
        ),
      );

      expect(kml, contains('<Point>'));
      // KML va al revés que los GPTS del PDF: primero longitud.
      expect(kml, contains('-75.53546460,6.24026490,0'));
    });

    test('una línea encadena los vértices', () {
      final kml = buildKml(
        documentWith(
          const KmlPlacemark(
            name: 'L1',
            geometry: LineGeometry([
              LatLon(6.240, -75.535),
              LatLon(6.241, -75.534),
            ]),
          ),
        ),
      );

      expect(kml, contains('<LineString>'));
      expect(kml, contains('-75.53500000,6.24000000,0 -75.53400000,6.24100000,0'));
    });

    test('el polígono se cierra repitiendo el primer vértice', () {
      // Sin cerrar el anillo, Google Earth descarta el polígono sin avisar.
      final kml = buildKml(
        documentWith(
          const KmlPlacemark(
            name: 'A1',
            geometry: PolygonGeometry([
              LatLon(6.240, -75.535),
              LatLon(6.240, -75.534),
              LatLon(6.241, -75.534),
            ]),
          ),
        ),
      );

      expect(kml, contains('<LinearRing>'));

      final coords = RegExp(r'<coordinates>([^<]+)</coordinates>')
          .firstMatch(kml)!
          .group(1)!
          .trim()
          .split(' ');

      expect(coords, hasLength(4));
      expect(coords.first, coords.last);
    });
  });

  group('Contenido del placemark', () {
    test('los atributos salen como ExtendedData', () {
      final kml = buildKml(
        documentWith(
          const KmlPlacemark(
            name: 'P1',
            geometry: PointGeometry(_punto),
            attributes: {'Estado': 'Bueno', 'Altura': 12.5},
          ),
        ),
      );

      // ExtendedData es lo que leen QGIS y ArcGIS al reimportar.
      expect(kml, contains('<ExtendedData>'));
      expect(kml, contains('name="Estado"'));
      expect(kml, contains('<value>Bueno</value>'));
      expect(kml, contains('<value>12.5</value>'));
    });

    test('los atributos nulos no se emiten', () {
      final kml = buildKml(
        documentWith(
          const KmlPlacemark(
            name: 'P1',
            geometry: PointGeometry(_punto),
            attributes: {'Vacio': null, 'Lleno': 'si'},
          ),
        ),
      );

      expect(kml, isNot(contains('name="Vacio"')));
      expect(kml, contains('name="Lleno"'));
    });

    test('las fotos se incrustan apuntando a files/', () {
      final kml = buildKml(
        documentWith(
          const KmlPlacemark(
            name: 'P1',
            geometry: PointGeometry(_punto),
            media: [KmlMedia(fileName: 'foto.jpg', isImage: true)],
          ),
        ),
      );

      expect(kml, contains('<img src="files/foto.jpg"'));
    });

    test('el video se enlaza en vez de incrustarse', () {
      // Google Earth no reproduce video embebido de forma fiable.
      final kml = buildKml(
        documentWith(
          const KmlPlacemark(
            name: 'P1',
            geometry: PointGeometry(_punto),
            media: [KmlMedia(fileName: 'clip.mp4', isImage: false)],
          ),
        ),
      );

      expect(kml, isNot(contains('<img src="files/clip.mp4"')));
      expect(kml, contains('<a href="files/clip.mp4">'));
    });

    test('el HTML del usuario se escapa', () {
      final kml = buildKml(
        documentWith(
          const KmlPlacemark(
            name: 'P1',
            geometry: PointGeometry(_punto),
            description: 'Poste <roto> & caído',
          ),
        ),
      );

      // Si no se escapara, rompería el CDATA del globo.
      expect(kml, contains('&lt;roto&gt;'));
      expect(kml, contains('&amp;'));
    });

    test('sin descripción ni atributos no se emite globo vacío', () {
      final kml = buildKml(
        documentWith(
          const KmlPlacemark(name: 'P1', geometry: PointGeometry(_punto)),
        ),
      );
      expect(kml, isNot(contains('<description>')));
    });
  });

  group('Estructura', () {
    test('cada carpeta lleva su propio estilo', () {
      final kml = buildKml(
        const KmlDocument(
          name: 'Proyecto',
          folders: [
            KmlFolder(
              name: 'Postes',
              color: 0xFFE53935,
              placemarks: [
                KmlPlacemark(name: 'P', geometry: PointGeometry(_punto)),
              ],
            ),
            KmlFolder(
              name: 'Senderos',
              color: 0xFF1E88E5,
              placemarks: [
                KmlPlacemark(name: 'S', geometry: PointGeometry(_punto)),
              ],
            ),
          ],
        ),
      );

      expect(kml, contains('id="estilo-0"'));
      expect(kml, contains('id="estilo-1"'));
      expect(kml, contains('<styleUrl>#estilo-0</styleUrl>'));
      expect(kml, contains('<styleUrl>#estilo-1</styleUrl>'));
      expect(kml, contains('<name>Postes</name>'));
      expect(kml, contains('<name>Senderos</name>'));
    });
  });

  group('KMZ', () {
    test('empaqueta doc.kml en la raíz', () {
      final result = buildKmz(
        document: documentWith(
          const KmlPlacemark(name: 'P1', geometry: PointGeometry(_punto)),
        ),
      );

      final archive = ZipDecoder().decodeBytes(result.bytes);
      // Los visores buscan exactamente ese nombre al abrir un KMZ.
      expect(archive.findFile('doc.kml'), isNotNull);
      expect(result.placemarkCount, 1);
    });

    test('la multimedia va bajo files/', () {
      final result = buildKmz(
        document: documentWith(
          const KmlPlacemark(
            name: 'P1',
            geometry: PointGeometry(_punto),
            media: [KmlMedia(fileName: 'foto.jpg', isImage: true)],
          ),
        ),
        media: {'foto.jpg': utf8.encode('bytes-de-la-foto')},
      );

      final archive = ZipDecoder().decodeBytes(result.bytes);
      final photo = archive.findFile('files/foto.jpg');

      expect(photo, isNotNull);
      expect(utf8.decode(photo!.content as List<int>), 'bytes-de-la-foto');
      expect(result.mediaCount, 1);
    });

    test('el KML empaquetado sigue siendo válido', () {
      final result = buildKmz(
        document: documentWith(
          const KmlPlacemark(name: 'Ñandú', geometry: PointGeometry(_punto)),
        ),
      );

      final archive = ZipDecoder().decodeBytes(result.bytes);
      final content = utf8.decode(
        archive.findFile('doc.kml')!.content as List<int>,
      );

      expect(content, contains('<?xml version="1.0" encoding="UTF-8"?>'));
      // Los acentos deben sobrevivir al viaje por UTF-8.
      expect(content, contains('Ñandú'));
    });
  });

  group('Nombres de archivo', () {
    test('se quitan los caracteres que rompen rutas', () {
      expect(sanitizeFileName('Predio 1/2: "norte"'), 'Predio 1_2_ _norte_');
      expect(sanitizeFileName('a\\b*c?'), 'a_b_c_');
    });

    test('un nombre vacío no deja el archivo sin nombre', () {
      expect(sanitizeFileName('   '), 'sin_nombre');
      expect(sanitizeFileName(''), 'sin_nombre');
    });
  });
}

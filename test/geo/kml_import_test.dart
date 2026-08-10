/// Tests del lector de KML/KMZ.
///
/// Los casos imitan lo que escriben generadores reales, que difieren bastante
/// entre sí: Google Earth, QGIS/ogr2ogr y receptores GPS.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

import 'package:avenza_para_pobres/geo/geometry/geometry.dart';
import 'package:avenza_para_pobres/geo/import/kml_reader.dart';
import 'package:avenza_para_pobres/geo/import/kmz_reader.dart';

const _reader = KmlReader();

String kml(String body) => '''
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>Levantamiento</name>
    $body
  </Document>
</kml>
''';

void main() {
  group('Colores', () {
    test('invierte los canales de aabbggrr a ARGB', () {
      // Rojo en KML es ff0000ff (a=ff, b=00, g=00, r=ff).
      expect(parseKmlColor('ff0000ff'), 0xFFFF0000);
      // Azul en KML es ffff0000.
      expect(parseKmlColor('ffff0000'), 0xFF0000FF);
    });

    test('descarta valores inválidos y transparentes', () {
      expect(parseKmlColor(null), isNull);
      expect(parseKmlColor('abc'), isNull);
      expect(parseKmlColor('zzzzzzzz'), isNull);
      // Alfa cero sería invisible en el mapa.
      expect(parseKmlColor('00ff0000'), isNull);
    });
  });

  group('Coordenadas', () {
    test('lee lon,lat en ese orden', () {
      final points = parseCoordinates('-75.5354646,6.2402649,0');
      expect(points, hasLength(1));
      // KML pone la longitud primero; invertirlo manda el punto a otro
      // continente.
      expect(points.first.latitude, closeTo(6.2402649, 1e-9));
      expect(points.first.longitude, closeTo(-75.5354646, 1e-9));
    });

    test('tolera saltos de línea y espacios', () {
      final points = parseCoordinates('''
        -75.535,6.240,0
        -75.534,6.241,0
           -75.533,6.242
      ''');
      expect(points, hasLength(3));
    });

    test('descarta tuplas corruptas sin abortar el resto', () {
      final points = parseCoordinates('-75.5,6.2,0 basura -75.4,6.3,0');
      expect(points, hasLength(2));
    });

    test('descarta coordenadas fuera de rango', () {
      expect(parseCoordinates('-500,999,0'), isEmpty);
    });
  });

  group('Geometrías', () {
    test('lee un punto', () {
      final result = _reader.read(kml('''
        <Placemark>
          <name>Poste 1</name>
          <Point><coordinates>-75.5354646,6.2402649,0</coordinates></Point>
        </Placemark>
      '''));

      expect(result.layers, hasLength(1));
      final layer = result.layers.single;
      expect(layer.geometryType, GeometryType.point);
      expect(layer.features.single.name, 'Poste 1');
    });

    test('lee una línea', () {
      final result = _reader.read(kml('''
        <Placemark>
          <name>Sendero</name>
          <LineString>
            <coordinates>-75.535,6.240,0 -75.534,6.241,0</coordinates>
          </LineString>
        </Placemark>
      '''));

      final geometry = result.layers.single.features.single.geometry;
      expect(geometry, isA<LineGeometry>());
      expect((geometry as LineGeometry).points, hasLength(2));
    });

    test('el polígono se abre quitando el vértice repetido', () {
      final result = _reader.read(kml('''
        <Placemark>
          <name>Predio</name>
          <Polygon><outerBoundaryIs><LinearRing>
            <coordinates>
              -75.535,6.240,0 -75.534,6.240,0 -75.534,6.241,0 -75.535,6.240,0
            </coordinates>
          </LinearRing></outerBoundaryIs></Polygon>
        </Placemark>
      '''));

      final geometry = result.layers.single.features.single.geometry;
      expect(geometry, isA<PolygonGeometry>());
      // KML cierra el anillo; el modelo interno lo guarda abierto.
      expect((geometry as PolygonGeometry).ring, hasLength(3));
    });

    test('MultiGeometry genera un elemento por geometría', () {
      final result = _reader.read(kml('''
        <Placemark>
          <name>Conjunto</name>
          <MultiGeometry>
            <Point><coordinates>-75.535,6.240,0</coordinates></Point>
            <Point><coordinates>-75.534,6.241,0</coordinates></Point>
          </MultiGeometry>
        </Placemark>
      '''));

      expect(result.featureCount, 2);
      expect(result.layers.single.features.first.name, 'Conjunto (1)');
    });

    test('gx:Track se importa como línea', () {
      // Google Earth separa con espacios, no con comas como el resto de KML.
      final result = _reader.read('''
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2"
     xmlns:gx="http://www.google.com/kml/ext/2.2">
  <Document>
    <Placemark>
      <name>Recorrido</name>
      <gx:Track>
        <gx:coord>-75.535 6.240 1500</gx:coord>
        <gx:coord>-75.534 6.241 1502</gx:coord>
        <gx:coord>-75.533 6.242 1505</gx:coord>
      </gx:Track>
    </Placemark>
  </Document>
</kml>
''');

      final geometry = result.layers.single.features.single.geometry;
      expect(geometry, isA<LineGeometry>());
      expect((geometry as LineGeometry).points, hasLength(3));
      expect(geometry.points.first.latitude, closeTo(6.240, 1e-9));
    });

    test('los agujeros de un polígono se avisan', () {
      final result = _reader.read(kml('''
        <Placemark>
          <Polygon>
            <outerBoundaryIs><LinearRing><coordinates>
              -75.535,6.240 -75.534,6.240 -75.534,6.241
            </coordinates></LinearRing></outerBoundaryIs>
            <innerBoundaryIs><LinearRing><coordinates>
              -75.5345,6.2405 -75.5342,6.2405 -75.5342,6.2408
            </coordinates></LinearRing></innerBoundaryIs>
          </Polygon>
        </Placemark>
      '''));

      expect(result.featureCount, 1);
      expect(result.warnings.join(), contains('agujeros'));
    });
  });

  group('Espacios de nombres', () {
    test('funciona con prefijo kml:', () {
      // ArcGIS y algunas herramientas prefijan todos los elementos.
      final result = _reader.read('''
<?xml version="1.0" encoding="UTF-8"?>
<kml:kml xmlns:kml="http://www.opengis.net/kml/2.2">
  <kml:Document>
    <kml:name>Con prefijo</kml:name>
    <kml:Placemark>
      <kml:name>Punto</kml:name>
      <kml:Point>
        <kml:coordinates>-75.535,6.240,0</kml:coordinates>
      </kml:Point>
    </kml:Placemark>
  </kml:Document>
</kml:kml>
''');

      expect(result.featureCount, 1);
      expect(result.documentName, 'Con prefijo');
    });
  });

  group('Carpetas', () {
    test('cada carpeta se convierte en una capa', () {
      final result = _reader.read(kml('''
        <Folder>
          <name>Postes</name>
          <Placemark><name>P1</name>
            <Point><coordinates>-75.535,6.240</coordinates></Point>
          </Placemark>
        </Folder>
        <Folder>
          <name>Senderos</name>
          <Placemark><name>S1</name>
            <LineString><coordinates>-75.535,6.240 -75.534,6.241</coordinates>
            </LineString>
          </Placemark>
        </Folder>
      '''));

      expect(result.layers, hasLength(2));
      expect(
        result.layers.map((l) => l.name),
        containsAll(['Postes', 'Senderos']),
      );
    });

    test('una carpeta con tipos mezclados se parte y se sufija', () {
      final result = _reader.read(kml('''
        <Folder>
          <name>Mixta</name>
          <Placemark><Point><coordinates>-75.535,6.240</coordinates></Point>
          </Placemark>
          <Placemark>
            <LineString><coordinates>-75.535,6.240 -75.534,6.241</coordinates>
            </LineString>
          </Placemark>
        </Folder>
      '''));

      // Una capa tiene un solo tipo de geometría, como un shapefile.
      expect(result.layers, hasLength(2));
      expect(
        result.layers.map((l) => l.name),
        containsAll(['Mixta (puntos)', 'Mixta (líneas)']),
      );
    });

    test('los nombres con espacios y barras no rompen el agrupado', () {
      final result = _reader.read(kml('''
        <Folder>
          <name>Zona norte / sector A</name>
          <Placemark><name>X</name>
            <Point><coordinates>-75.535,6.240</coordinates></Point>
          </Placemark>
        </Folder>
      '''));

      expect(result.layers.single.name, 'Zona norte / sector A');
    });
  });

  group('Atributos', () {
    test('lee ExtendedData con Data', () {
      final result = _reader.read(kml('''
        <Placemark>
          <name>Muestra</name>
          <ExtendedData>
            <Data name="Estado"><value>Bueno</value></Data>
            <Data name="Altura"><value>12.5</value></Data>
          </ExtendedData>
          <Point><coordinates>-75.535,6.240</coordinates></Point>
        </Placemark>
      '''));

      final attributes = result.layers.single.features.single.attributes;
      expect(attributes['Estado'], 'Bueno');
      expect(attributes['Altura'], '12.5');
    });

    test('lee SchemaData, que es lo que exporta QGIS', () {
      final result = _reader.read(kml('''
        <Placemark>
          <ExtendedData>
            <SchemaData schemaUrl="#capa">
              <SimpleData name="codigo">A-17</SimpleData>
              <SimpleData name="area_m2">1450</SimpleData>
            </SchemaData>
          </ExtendedData>
          <Point><coordinates>-75.535,6.240</coordinates></Point>
        </Placemark>
      '''));

      final attributes = result.layers.single.features.single.attributes;
      expect(attributes['codigo'], 'A-17');
      expect(attributes['area_m2'], '1450');
    });

    test('el HTML del globo se convierte en texto legible', () {
      final result = _reader.read(kml('''
        <Placemark>
          <name>Con globo</name>
          <description><![CDATA[
            <p>Poste en <b>mal</b> estado</p><br/><p>Requiere cambio</p>
          ]]></description>
          <Point><coordinates>-75.535,6.240</coordinates></Point>
        </Placemark>
      '''));

      final description = result.layers.single.features.single.description!;
      expect(description, contains('Poste en'));
      expect(description, contains('Requiere cambio'));
      // Sin etiquetas HTML sueltas.
      expect(description, isNot(contains('<b>')));
      expect(description, isNot(contains('<p>')));
    });

    test('detecta las imágenes referenciadas en el globo', () {
      final result = _reader.read(kml('''
        <Placemark>
          <description><![CDATA[
            <img src="files/foto1.jpg"/>
            <img src='files/foto2.jpg'/>
            <img src="https://ejemplo.com/remota.jpg"/>
          ]]></description>
          <Point><coordinates>-75.535,6.240</coordinates></Point>
        </Placemark>
      '''));

      final images = result.layers.single.features.single.imageNames;
      // Las remotas no se descargan.
      expect(images, ['files/foto1.jpg', 'files/foto2.jpg']);
    });
  });

  group('Estilos', () {
    test('el color se toma del estilo referenciado', () {
      final result = _reader.read(kml('''
        <Style id="rojo">
          <LineStyle><color>ff0000ff</color></LineStyle>
        </Style>
        <Placemark>
          <styleUrl>#rojo</styleUrl>
          <LineString><coordinates>-75.535,6.240 -75.534,6.241</coordinates>
          </LineString>
        </Placemark>
      '''));

      expect(result.layers.single.color, 0xFFFF0000);
    });

    test('StyleMap se resuelve a su variante normal', () {
      final result = _reader.read(kml('''
        <Style id="normalAzul">
          <IconStyle><color>ffff0000</color></IconStyle>
        </Style>
        <StyleMap id="mapa">
          <Pair><key>normal</key><styleUrl>#normalAzul</styleUrl></Pair>
          <Pair><key>highlight</key><styleUrl>#otro</styleUrl></Pair>
        </StyleMap>
        <Placemark>
          <styleUrl>#mapa</styleUrl>
          <Point><coordinates>-75.535,6.240</coordinates></Point>
        </Placemark>
      '''));

      expect(result.layers.single.color, 0xFF0000FF);
    });
  });

  group('Avisos', () {
    test('se informa de lo que no se puede importar', () {
      final result = _reader.read(kml('''
        <NetworkLink><name>Remoto</name></NetworkLink>
        <GroundOverlay><name>Imagen</name></GroundOverlay>
        <Placemark><Point><coordinates>-75.535,6.240</coordinates></Point>
        </Placemark>
      '''));

      expect(result.warnings, hasLength(2));
      expect(result.warnings.join(), contains('enlaces de red'));
      expect(result.warnings.join(), contains('imágenes superpuestas'));
      // Lo demás sí se importa.
      expect(result.featureCount, 1);
    });
  });

  group('Errores', () {
    test('un XML corrupto da un mensaje claro', () {
      expect(
        () => _reader.read('<kml><Document>'),
        throwsA(isA<FormatException>()),
      );
    });

    test('un XML que no es KML se rechaza', () {
      expect(
        () => _reader.read('<?xml version="1.0"?><root><a>1</a></root>'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('KMZ', () {
    Uint8List buildKmz(String kmlContent, Map<String, List<int>> files) {
      final archive = Archive();
      final bytes = utf8.encode(kmlContent);
      archive.addFile(ArchiveFile('doc.kml', bytes.length, bytes));
      for (final entry in files.entries) {
        archive.addFile(
          ArchiveFile(entry.key, entry.value.length, entry.value),
        );
      }
      return Uint8List.fromList(ZipEncoder().encode(archive)!);
    }

    test('abre el KMZ y encuentra su KML', () {
      final bytes = buildKmz(
        kml('''
          <Placemark><name>P</name>
            <Point><coordinates>-75.535,6.240</coordinates></Point>
          </Placemark>
        '''),
        {'files/foto.jpg': utf8.encode('contenido')},
      );

      final result = const KmzReader().read(bytes);
      expect(result.data.featureCount, 1);
      expect(result.media.containsKey('files/foto.jpg'), isTrue);
    });

    test('acepta también un KML suelto sin comprimir', () {
      final bytes = Uint8List.fromList(
        utf8.encode(kml('''
          <Placemark><Point><coordinates>-75.535,6.240</coordinates></Point>
          </Placemark>
        ''')),
      );

      final result = const KmzReader().read(bytes);
      expect(result.data.featureCount, 1);
    });

    test('un ZIP sin KML dentro da un mensaje claro', () {
      final archive = Archive()
        ..addFile(ArchiveFile('leeme.txt', 4, utf8.encode('hola')));
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);

      expect(
        () => const KmzReader().read(bytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('resolveMedia tolera variantes de la ruta', () {
      final media = {'files/Foto.JPG': Uint8List.fromList([1, 2, 3])};

      expect(resolveMedia(media, 'files/Foto.JPG'), isNotNull);
      // Distinta caja.
      expect(resolveMedia(media, 'files/foto.jpg'), isNotNull);
      // Prefijo relativo.
      expect(resolveMedia(media, './files/Foto.JPG'), isNotNull);
      // Solo el nombre del archivo.
      expect(resolveMedia(media, 'Foto.JPG'), isNotNull);
      expect(resolveMedia(media, 'otra.jpg'), isNull);
    });
  });
}

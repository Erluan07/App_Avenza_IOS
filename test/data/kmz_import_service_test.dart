/// Tests de la importación de KMZ contra una base en memoria.
///
/// Cubre la cadena completa: archivo en disco → parseo → capas y elementos
/// guardados, que es donde se juntan las piezas que los tests unitarios miran
/// por separado.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:test/test.dart';

import 'package:avenza_para_pobres/data/db/connection.dart';
import 'package:avenza_para_pobres/data/db/database.dart';
import 'package:avenza_para_pobres/data/repositories/kmz_import_service.dart';
import 'package:avenza_para_pobres/data/repositories/project_repository.dart';
import 'package:avenza_para_pobres/data/storage/project_storage.dart';
import 'package:avenza_para_pobres/geo/geometry/geometry.dart';

const _kml = '''
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>Levantamiento de prueba</name>
    <Style id="verde">
      <IconStyle><color>ff00ff00</color></IconStyle>
    </Style>
    <Folder>
      <name>Postes</name>
      <Placemark>
        <name>Poste 1</name>
        <styleUrl>#verde</styleUrl>
        <description><![CDATA[<p>En mal estado</p><img src="files/p1.jpg"/>]]></description>
        <ExtendedData>
          <Data name="estado"><value>Malo</value></Data>
        </ExtendedData>
        <Point><coordinates>-75.5354646,6.2402649,0</coordinates></Point>
      </Placemark>
      <Placemark>
        <name>Poste 2</name>
        <ExtendedData>
          <Data name="altura"><value>9</value></Data>
        </ExtendedData>
        <Point><coordinates>-75.5350000,6.2405000,0</coordinates></Point>
      </Placemark>
    </Folder>
    <Folder>
      <name>Predios</name>
      <Placemark>
        <name>Predio A</name>
        <Polygon><outerBoundaryIs><LinearRing><coordinates>
          -75.535,6.240 -75.534,6.240 -75.534,6.241 -75.535,6.241 -75.535,6.240
        </coordinates></LinearRing></outerBoundaryIs></Polygon>
      </Placemark>
    </Folder>
  </Document>
</kml>
''';

File writeKmz(Directory dir, {bool withPhoto = true}) {
  final archive = Archive();
  final kml = utf8.encode(_kml);
  archive.addFile(ArchiveFile('doc.kml', kml.length, kml));

  if (withPhoto) {
    final photo = utf8.encode('bytes-de-la-foto');
    archive.addFile(ArchiveFile('files/p1.jpg', photo.length, photo));
  }

  final file = File('${dir.path}/prueba.kmz')
    ..writeAsBytesSync(ZipEncoder().encode(archive)!);
  return file;
}

void main() {
  late AppDatabase database;
  late ProjectRepository repository;
  late KmzImportService service;
  late Directory tempRoot;
  late Project project;

  setUp(() async {
    database = openInMemoryDatabase();
    tempRoot = await Directory.systemTemp.createTemp('avenza_kmz_');
    final storage = ProjectStorage(tempRoot);
    repository = ProjectRepository(database: database, storage: storage);
    service = KmzImportService(
      database: database,
      storage: storage,
      repository: repository,
    );
    project = await repository.createProject(name: 'Destino');
  });

  tearDown(() async {
    await database.close();
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  test('analiza el archivo sin tocar la base', () async {
    final file = writeKmz(tempRoot);
    final analysis = await service.analyze(file);

    expect(analysis.isReadable, isTrue);
    expect(analysis.documentName, 'Levantamiento de prueba');
    expect(analysis.layers, hasLength(2));
    expect(analysis.featureCount, 3);
    expect(analysis.mediaCount, 1);

    // Nada se guardó todavía.
    expect(await repository.watchLayers(project.id).first, isEmpty);
  });

  test('crea una capa por carpeta con su tipo y color', () async {
    final file = writeKmz(tempRoot);
    final analysis = await service.analyze(file);

    await service.import(
      projectId: project.id,
      source: file,
      layers: analysis.layers,
      importImages: false,
    );

    final layers = await repository.watchLayers(project.id).first;
    expect(layers, hasLength(2));

    final postes = layers.firstWhere((l) => l.name == 'Postes');
    expect(postes.geometryType, GeometryType.point);
    // El verde del KML (ff00ff00) traducido a ARGB.
    expect(postes.color, 0xFF00FF00);

    final predios = layers.firstWhere((l) => l.name == 'Predios');
    expect(predios.geometryType, GeometryType.polygon);
  });

  test('los elementos conservan geometría, nombre y atributos', () async {
    final file = writeKmz(tempRoot);
    final analysis = await service.analyze(file);

    final count = await service.import(
      projectId: project.id,
      source: file,
      layers: analysis.layers,
      importImages: false,
    );
    expect(count, 3);

    final layers = await repository.watchLayers(project.id).first;
    final postes = layers.firstWhere((l) => l.name == 'Postes');
    final features = await repository.watchFeatures(postes.id).first;

    final poste1 = features.firstWhere((f) => f.name == 'Poste 1');
    final geometry = poste1.geometry;
    expect(geometry, isA<PointGeometry>());

    final position = (geometry! as PointGeometry).position;
    // El KML trae lon,lat; invertirlo mandaría el punto a otro continente.
    expect(position.latitude, closeTo(6.2402649, 1e-7));
    expect(position.longitude, closeTo(-75.5354646, 1e-7));

    expect(poste1.attributes['estado'], 'Malo');
    // El globo HTML se guarda como texto legible.
    expect(poste1.description, contains('En mal estado'));
    expect(poste1.description, isNot(contains('<p>')));
  });

  test('declara los campos de la capa a partir de los atributos', () async {
    final file = writeKmz(tempRoot);
    final analysis = await service.analyze(file);

    await service.import(
      projectId: project.id,
      source: file,
      layers: analysis.layers,
      importImages: false,
    );

    final layers = await repository.watchLayers(project.id).first;
    final postes = layers.firstWhere((l) => l.name == 'Postes');
    final fields = await repository.fieldsOf(postes.id);

    // La unión de las claves de todos los elementos de la capa, para que el
    // formulario de captura las ofrezca luego.
    expect(fields.map((f) => f.key), containsAll(['estado', 'altura']));
  });

  test('adjunta las fotos que el globo referencia', () async {
    final file = writeKmz(tempRoot);
    final analysis = await service.analyze(file);

    await service.import(
      projectId: project.id,
      source: file,
      layers: analysis.layers,
    );

    final layers = await repository.watchLayers(project.id).first;
    final postes = layers.firstWhere((l) => l.name == 'Postes');
    final features = await repository.watchFeatures(postes.id).first;
    final poste1 = features.firstWhere((f) => f.name == 'Poste 1');

    final attachments = await repository.attachmentsOf(poste1.id);
    expect(attachments, hasLength(1));

    final stored = ProjectStorage(tempRoot)
        .resolve(project.id, attachments.single.filePath);
    expect(stored.existsSync(), isTrue);
    expect(stored.readAsStringSync(), 'bytes-de-la-foto');

    // El poste 2 no referenciaba ninguna foto.
    final poste2 = features.firstWhere((f) => f.name == 'Poste 2');
    expect(await repository.attachmentsOf(poste2.id), isEmpty);
  });

  test('se pueden importar solo algunas capas', () async {
    final file = writeKmz(tempRoot);
    final analysis = await service.analyze(file);

    final soloPredios =
        analysis.layers.where((l) => l.name == 'Predios').toList();

    final count = await service.import(
      projectId: project.id,
      source: file,
      layers: soloPredios,
      importImages: false,
    );

    expect(count, 1);
    final layers = await repository.watchLayers(project.id).first;
    expect(layers, hasLength(1));
    expect(layers.single.name, 'Predios');
  });

  test('importar dos veces no duplica el nombre de la capa', () async {
    final file = writeKmz(tempRoot);
    final analysis = await service.analyze(file);

    for (var i = 0; i < 2; i++) {
      await service.import(
        projectId: project.id,
        source: file,
        layers: analysis.layers,
        importImages: false,
      );
    }

    final layers = await (database.select(database.featureLayers)
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();

    final names = layers.map((l) => l.name).toList();
    expect(names, hasLength(4));
    // La segunda tanda queda numerada en lugar de repetir el nombre.
    expect(names.toSet(), hasLength(4));
    expect(names, contains('Postes'));
    expect(names, contains('Postes (2)'));
  });

  test('un archivo que no es KMZ da un error legible', () async {
    final basura = File('${tempRoot.path}/roto.kmz')
      ..writeAsBytesSync([1, 2, 3, 4, 5]);

    final analysis = await service.analyze(basura);
    expect(analysis.isReadable, isFalse);
    expect(analysis.error, isNotNull);
  });
}

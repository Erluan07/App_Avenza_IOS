/// Tests de la capa de datos contra una base SQLite en memoria.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'package:avenza_para_pobres/data/db/connection.dart';
import 'package:avenza_para_pobres/data/db/database.dart';
import 'package:avenza_para_pobres/data/models/enums.dart';
import 'package:avenza_para_pobres/data/repositories/project_repository.dart';
import 'package:avenza_para_pobres/data/storage/project_storage.dart';
import 'package:avenza_para_pobres/geo/geometry/geometry.dart';
import 'package:avenza_para_pobres/geo/geometry/primitives.dart';

void main() {
  late AppDatabase database;
  late ProjectRepository repository;
  late Directory tempRoot;

  setUp(() async {
    database = openInMemoryDatabase();
    tempRoot = await Directory.systemTemp.createTemp('avenza_test_');
    repository = ProjectRepository(
      database: database,
      storage: ProjectStorage(tempRoot),
    );
  });

  tearDown(() async {
    await database.close();
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  group('Proyectos', () {
    test('se crean y se listan', () async {
      final project = await repository.createProject(
        name: 'Quebrada La Iguaná',
        description: 'Levantamiento de campo',
      );

      expect(project.name, 'Quebrada La Iguaná');
      final projects = await repository.watchProjects().first;
      expect(projects, hasLength(1));
    });

    test('crear un proyecto prepara sus carpetas', () async {
      final project = await repository.createProject(name: 'P');
      expect(
        Directory('${tempRoot.path}/${project.id}/maps').existsSync(),
        isTrue,
      );
      expect(
        Directory('${tempRoot.path}/${project.id}/media').existsSync(),
        isTrue,
      );
    });
  });

  group('Capas y elementos', () {
    late Project project;

    setUp(() async {
      project = await repository.createProject(name: 'Proyecto');
    });

    test('un punto conserva su geometría al ir y volver de la base', () async {
      final layer = await repository.createLayer(
        projectId: project.id,
        name: 'Postes',
        geometryType: GeometryType.point,
      );

      const position = LatLon(6.2402649, -75.5354646);
      final created = await repository.createFeature(
        layerId: layer.id,
        geometry: const PointGeometry(position),
        name: 'Poste 1',
        gpsAccuracy: 4.2,
      );

      final geometry = created.geometry;
      expect(geometry, isA<PointGeometry>());
      expect(
        (geometry! as PointGeometry).position.latitude,
        closeTo(position.latitude, 1e-9),
      );
      expect(created.centroidLat, closeTo(position.latitude, 1e-9));
      expect(created.gpsAccuracy, 4.2);
    });

    test('un polígono calcula perímetro y área', () async {
      final layer = await repository.createLayer(
        projectId: project.id,
        name: 'Predios',
        geometryType: GeometryType.polygon,
      );

      const ring = [
        LatLon(6.240, -75.535),
        LatLon(6.240, -75.534),
        LatLon(6.241, -75.534),
        LatLon(6.241, -75.535),
      ];
      final created = await repository.createFeature(
        layerId: layer.id,
        geometry: const PolygonGeometry(ring),
      );

      final geometry = created.geometry!;
      // ~110 m de lado: el área ronda 1,2 ha.
      expect(geometry.areaMeters2, greaterThan(10000));
      expect(geometry.areaMeters2, lessThan(15000));
      expect(geometry.lengthMeters, greaterThan(400));
    });

    test('los atributos personalizados sobreviven al viaje', () async {
      final layer = await repository.createLayer(
        projectId: project.id,
        name: 'Muestras',
        geometryType: GeometryType.point,
      );
      await repository.addField(
        layerId: layer.id,
        key: 'estado',
        label: 'Estado',
        type: FieldType.lista,
        options: ['Bueno', 'Regular', 'Malo'],
      );

      final created = await repository.createFeature(
        layerId: layer.id,
        geometry: const PointGeometry(LatLon(6.24, -75.53)),
        attributes: {'estado': 'Regular', 'profundidad': 3.5},
      );

      expect(created.attributes['estado'], 'Regular');
      expect(created.attributes['profundidad'], 3.5);

      final fields = await repository.fieldsOf(layer.id);
      expect(fields.single.options, ['Bueno', 'Regular', 'Malo']);
    });

    test('borrar la capa arrastra sus elementos', () async {
      final layer = await repository.createLayer(
        projectId: project.id,
        name: 'Temporal',
        geometryType: GeometryType.point,
      );
      await repository.createFeature(
        layerId: layer.id,
        geometry: const PointGeometry(LatLon(6.24, -75.53)),
      );

      expect(await repository.watchFeatures(layer.id).first, hasLength(1));
      await repository.deleteLayer(layer.id);
      // La cascada solo funciona con PRAGMA foreign_keys activado.
      expect(await repository.watchFeatures(layer.id).first, isEmpty);
    });
  });

  group('Adjuntos', () {
    test('se copian dentro del proyecto y se guardan como ruta relativa',
        () async {
      final project = await repository.createProject(name: 'Con fotos');
      final layer = await repository.createLayer(
        projectId: project.id,
        name: 'Puntos',
        geometryType: GeometryType.point,
      );
      final feature = await repository.createFeature(
        layerId: layer.id,
        geometry: const PointGeometry(LatLon(6.24, -75.53)),
      );

      final source = File('${tempRoot.path}/origen.jpg')
        ..writeAsBytesSync(List<int>.filled(1024, 7));

      final attachment = await repository.addAttachment(
        projectId: project.id,
        featureId: feature.id,
        source: source,
        kind: AttachmentKind.foto,
        caption: 'Vista general',
      );

      // La ruta guardada debe ser relativa, para que el proyecto se pueda mover.
      expect(attachment.filePath, isNot(contains(tempRoot.path)));
      expect(attachment.filePath, startsWith('media/'));
      expect(attachment.sizeBytes, 1024);

      final resolved = ProjectStorage(tempRoot)
          .resolve(project.id, attachment.filePath);
      expect(resolved.existsSync(), isTrue);
    });

    test('un nombre repetido no pisa el archivo anterior', () async {
      final project = await repository.createProject(name: 'Duplicados');
      final layer = await repository.createLayer(
        projectId: project.id,
        name: 'Puntos',
        geometryType: GeometryType.point,
      );
      final feature = await repository.createFeature(
        layerId: layer.id,
        geometry: const PointGeometry(LatLon(6.24, -75.53)),
      );

      final source = File('${tempRoot.path}/foto.jpg')
        ..writeAsBytesSync([1, 2, 3]);

      final first = await repository.addAttachment(
        projectId: project.id,
        featureId: feature.id,
        source: source,
        kind: AttachmentKind.foto,
      );
      final second = await repository.addAttachment(
        projectId: project.id,
        featureId: feature.id,
        source: source,
        kind: AttachmentKind.foto,
      );

      expect(first.filePath, isNot(second.filePath));
      final storage = ProjectStorage(tempRoot);
      expect(storage.resolve(project.id, first.filePath).existsSync(), isTrue);
      expect(storage.resolve(project.id, second.filePath).existsSync(), isTrue);
    });
  });
}

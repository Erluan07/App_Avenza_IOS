/// Acceso a proyectos, capas, elementos y adjuntos.
///
/// Los métodos `watch*` devuelven streams: la UI se actualiza sola cuando algo
/// cambia en la base, sin tener que refrescar a mano tras cada captura.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../geo/geometry/geometry.dart';
import '../../geo/geometry/primitives.dart';
import '../db/database.dart';
import '../models/enums.dart';
import '../storage/project_storage.dart';

class ProjectRepository {
  ProjectRepository({
    required this.database,
    required this.storage,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  final AppDatabase database;
  final ProjectStorage storage;
  final Uuid _uuid;

  // ---------------------------------------------------------------------------
  // Proyectos
  // ---------------------------------------------------------------------------

  Stream<List<Project>> watchProjects() => (database.select(database.projects)
        ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
      .watch();

  Future<Project?> findProject(String id) =>
      (database.select(database.projects)..where((t) => t.id.equals(id)))
          .getSingleOrNull();

  Future<Project> createProject({
    required String name,
    String? description,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now();

    await database.into(database.projects).insert(
          ProjectsCompanion.insert(
            id: id,
            name: name,
            description: Value(description),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await storage.ensureProjectDirs(id);

    return (await findProject(id))!;
  }

  Future<void> updateProject(
    String id, {
    String? name,
    String? description,
  }) async {
    await (database.update(database.projects)..where((t) => t.id.equals(id)))
        .write(
      ProjectsCompanion(
        name: name == null ? const Value.absent() : Value(name),
        description:
            description == null ? const Value.absent() : Value(description),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Borra el proyecto y **todos sus archivos**. Las filas dependientes se van
  /// solas por las claves foráneas en cascada.
  Future<void> deleteProject(String id) async {
    await (database.delete(database.projects)..where((t) => t.id.equals(id)))
        .go();
    await storage.deleteProject(id);
  }

  // ---------------------------------------------------------------------------
  // Mapas base
  // ---------------------------------------------------------------------------

  Stream<List<BaseMap>> watchBaseMaps(String projectId) =>
      (database.select(database.baseMaps)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .watch();

  Future<void> setBaseMapVisible(String id, {required bool visible}) =>
      (database.update(database.baseMaps)..where((t) => t.id.equals(id)))
          .write(BaseMapsCompanion(visible: Value(visible)));

  /// Gira el mapa base un cuarto de vuelta más, para enderezarlo a mano.
  Future<void> rotateBaseMap(String id, int currentAdjust) =>
      (database.update(database.baseMaps)..where((t) => t.id.equals(id)))
          .write(
        BaseMapsCompanion(rotationAdjust: Value((currentAdjust + 90) % 360)),
      );

  Future<void> setBaseMapOpacity(String id, double opacity) =>
      (database.update(database.baseMaps)..where((t) => t.id.equals(id)))
          .write(BaseMapsCompanion(opacity: Value(opacity.clamp(0, 1))));

  // ---------------------------------------------------------------------------
  // Capas
  // ---------------------------------------------------------------------------

  Stream<List<FeatureLayer>> watchLayers(String projectId) =>
      (database.select(database.featureLayers)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .watch();

  Future<FeatureLayer> createLayer({
    required String projectId,
    required String name,
    required GeometryType geometryType,
    int color = 0xFFE53935,
  }) async {
    final id = _uuid.v4();
    final existing = await (database.select(database.featureLayers)
          ..where((t) => t.projectId.equals(projectId)))
        .get();

    await database.into(database.featureLayers).insert(
          FeatureLayersCompanion.insert(
            id: id,
            projectId: projectId,
            name: name,
            geometryType: geometryType,
            color: Value(color),
            sortOrder: Value(existing.length),
            createdAt: DateTime.now(),
          ),
        );

    return (await (database.select(database.featureLayers)
              ..where((t) => t.id.equals(id)))
            .getSingle());
  }

  Future<void> deleteLayer(String id) =>
      (database.delete(database.featureLayers)..where((t) => t.id.equals(id)))
          .go();

  Future<void> setLayerVisible(String id, {required bool visible}) =>
      (database.update(database.featureLayers)..where((t) => t.id.equals(id)))
          .write(FeatureLayersCompanion(visible: Value(visible)));

  // ---------------------------------------------------------------------------
  // Campos de atributos
  // ---------------------------------------------------------------------------

  Stream<List<FieldDef>> watchFields(String layerId) =>
      (database.select(database.fieldDefs)
            ..where((t) => t.layerId.equals(layerId))
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .watch();

  Future<List<FieldDef>> fieldsOf(String layerId) =>
      (database.select(database.fieldDefs)
            ..where((t) => t.layerId.equals(layerId))
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .get();

  Future<FieldDef> addField({
    required String layerId,
    required String key,
    required String label,
    required FieldType type,
    bool required = false,
    List<String>? options,
  }) async {
    final id = _uuid.v4();
    final existing = await fieldsOf(layerId);

    await database.into(database.fieldDefs).insert(
          FieldDefsCompanion.insert(
            id: id,
            layerId: layerId,
            key: key,
            label: label,
            type: type,
            required: Value(required),
            optionsJson:
                Value(options == null ? null : jsonEncode(options)),
            sortOrder: Value(existing.length),
          ),
        );

    return (await (database.select(database.fieldDefs)
              ..where((t) => t.id.equals(id)))
            .getSingle());
  }

  Future<void> deleteField(String id) =>
      (database.delete(database.fieldDefs)..where((t) => t.id.equals(id))).go();

  // ---------------------------------------------------------------------------
  // Elementos
  // ---------------------------------------------------------------------------

  Stream<List<MapFeature>> watchFeatures(String layerId) =>
      (database.select(database.mapFeatures)
            ..where((t) => t.layerId.equals(layerId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  Future<MapFeature> createFeature({
    required String layerId,
    required Geometry geometry,
    String? name,
    String? description,
    Map<String, Object?> attributes = const {},
    double? gpsAccuracy,
    double? elevation,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now();
    final centroid = geometry.centroid;

    await database.into(database.mapFeatures).insert(
          MapFeaturesCompanion.insert(
            id: id,
            layerId: layerId,
            name: Value(name),
            description: Value(description),
            geometryJson: jsonEncode(geometry.toJson()),
            attributesJson: Value(jsonEncode(attributes)),
            centroidLat: centroid.latitude,
            centroidLon: centroid.longitude,
            gpsAccuracy: Value(gpsAccuracy),
            elevation: Value(elevation),
            createdAt: now,
            updatedAt: now,
          ),
        );

    return (await (database.select(database.mapFeatures)
              ..where((t) => t.id.equals(id)))
            .getSingle());
  }

  Future<void> updateFeature(
    String id, {
    Geometry? geometry,
    String? name,
    String? description,
    Map<String, Object?>? attributes,
  }) async {
    final centroid = geometry?.centroid;

    await (database.update(database.mapFeatures)..where((t) => t.id.equals(id)))
        .write(
      MapFeaturesCompanion(
        geometryJson: geometry == null
            ? const Value.absent()
            : Value(jsonEncode(geometry.toJson())),
        centroidLat:
            centroid == null ? const Value.absent() : Value(centroid.latitude),
        centroidLon:
            centroid == null ? const Value.absent() : Value(centroid.longitude),
        name: name == null ? const Value.absent() : Value(name),
        description:
            description == null ? const Value.absent() : Value(description),
        attributesJson: attributes == null
            ? const Value.absent()
            : Value(jsonEncode(attributes)),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> deleteFeature(String id) =>
      (database.delete(database.mapFeatures)..where((t) => t.id.equals(id)))
          .go();

  // ---------------------------------------------------------------------------
  // Adjuntos
  // ---------------------------------------------------------------------------

  Stream<List<Attachment>> watchAttachments(String featureId) =>
      (database.select(database.attachments)
            ..where((t) => t.featureId.equals(featureId))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .watch();

  Future<List<Attachment>> attachmentsOf(String featureId) =>
      (database.select(database.attachments)
            ..where((t) => t.featureId.equals(featureId)))
          .get();

  /// Copia el archivo dentro del proyecto y lo asocia al elemento.
  ///
  /// Si se pasan [bytes], se guardan esos en lugar de copiar [source]: es lo
  /// que permite escribir la foto ya estampada sin tocar el original de la
  /// galería del usuario.
  Future<Attachment> addAttachment({
    required String projectId,
    required String featureId,
    required File source,
    required AttachmentKind kind,
    String? caption,
    Uint8List? bytes,
    DateTime? capturedAt,
    LatLon? position,
    double? accuracy,
    double? elevation,
    double? heading,
  }) async {
    final relativePath = await storage.importFile(
      projectId: projectId,
      source: source,
      destination: storage.mediaDir(projectId),
      bytes: bytes,
    );

    final stored = storage.resolve(projectId, relativePath);

    final id = _uuid.v4();
    await database.into(database.attachments).insert(
          AttachmentsCompanion.insert(
            id: id,
            featureId: featureId,
            kind: kind,
            filePath: relativePath,
            caption: Value(caption),
            sizeBytes: Value(await stored.length()),
            createdAt: DateTime.now(),
            capturedAt: Value(capturedAt),
            latitude: Value(position?.latitude),
            longitude: Value(position?.longitude),
            accuracy: Value(accuracy),
            elevation: Value(elevation),
            heading: Value(heading),
          ),
        );

    return (await (database.select(database.attachments)
              ..where((t) => t.id.equals(id)))
            .getSingle());
  }

  Future<void> deleteAttachment(String projectId, Attachment attachment) async {
    final file = storage.resolve(projectId, attachment.filePath);
    if (file.existsSync()) await file.delete();
    await (database.delete(database.attachments)
          ..where((t) => t.id.equals(attachment.id)))
        .go();
  }
}

/// Ayudas para leer los campos que se guardan serializados.
extension MapFeatureX on MapFeature {
  Geometry? get geometry {
    try {
      return Geometry.fromJson(
        jsonDecode(geometryJson) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> get attributes {
    try {
      return (jsonDecode(attributesJson) as Map).cast<String, Object?>();
    } catch (_) {
      return const {};
    }
  }
}

extension FieldDefX on FieldDef {
  List<String> get options {
    final raw = optionsJson;
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return const [];
    }
  }
}

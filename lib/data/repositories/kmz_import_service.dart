/// Importación de KMZ/KML a un proyecto.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../geo/import/kml_import_models.dart';
import '../../geo/import/kmz_reader.dart';
import '../db/database.dart';
import '../models/enums.dart';
import '../storage/project_storage.dart';
import 'project_repository.dart';

/// Análisis previo: qué trae el archivo, antes de tocar la base.
class KmzAnalysis {
  const KmzAnalysis({
    required this.layers,
    this.documentName,
    this.warnings = const [],
    this.mediaCount = 0,
    this.error,
  });

  final List<ImportedLayer> layers;
  final String? documentName;
  final List<String> warnings;
  final int mediaCount;
  final String? error;

  bool get isReadable => error == null;

  int get featureCount =>
      layers.fold(0, (total, layer) => total + layer.features.length);
}

class KmzImportService {
  KmzImportService({
    required this.database,
    required this.storage,
    required this.repository,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  final AppDatabase database;
  final ProjectStorage storage;
  final ProjectRepository repository;
  final Uuid _uuid;

  /// Lee el archivo y reporta su contenido sin modificar nada.
  Future<KmzAnalysis> analyze(File file) async {
    try {
      final bytes = await file.readAsBytes();
      // Parsear un KMZ grande puede tardar; va en otro isolate para no
      // bloquear la interfaz.
      return await Isolate.run(() => _analyzeBytes(bytes));
    } on FormatException catch (e) {
      return KmzAnalysis(layers: const [], error: e.message);
    } catch (e) {
      return KmzAnalysis(layers: const [], error: 'No se pudo leer: $e');
    }
  }

  /// Crea las capas y los elementos elegidos dentro del proyecto.
  ///
  /// Devuelve cuántos elementos se importaron.
  Future<int> import({
    required String projectId,
    required File source,
    required List<ImportedLayer> layers,
    bool importImages = true,
  }) async {
    if (layers.isEmpty) return 0;

    // La multimedia se relee aquí: llevarla en el análisis obligaría a
    // arrastrar megabytes por la interfaz sin saber aún si se van a usar.
    final media = importImages
        ? (await Isolate.run(() => _readMedia(source.path)))
        : const <String, List<int>>{};

    await storage.ensureProjectDirs(projectId);

    final existing = await (database.select(database.featureLayers)
          ..where((t) => t.projectId.equals(projectId)))
        .get();
    var sortOrder = existing.length;

    var imported = 0;

    for (final layer in layers) {
      if (layer.features.isEmpty) continue;

      final layerId = _uuid.v4();
      await database.into(database.featureLayers).insert(
            FeatureLayersCompanion.insert(
              id: layerId,
              projectId: projectId,
              name: _uniqueLayerName(layer.name, existing),
              geometryType: layer.geometryType,
              color: Value(layer.color ?? 0xFF1E88E5),
              sortOrder: Value(sortOrder++),
              createdAt: DateTime.now(),
            ),
          );

      // Los campos se declaran una vez por capa, con la unión de las claves de
      // todos sus elementos: así el formulario de captura los ofrece luego.
      final fieldKeys = <String>{
        for (final feature in layer.features) ...feature.attributes.keys,
      };
      var fieldOrder = 0;
      for (final key in fieldKeys) {
        await database.into(database.fieldDefs).insert(
              FieldDefsCompanion.insert(
                id: _uuid.v4(),
                layerId: layerId,
                key: key,
                label: key,
                type: FieldType.texto,
                sortOrder: Value(fieldOrder++),
              ),
            );
      }

      for (final feature in layer.features) {
        final created = await repository.createFeature(
          layerId: layerId,
          geometry: feature.geometry,
          name: feature.name,
          description: feature.description,
          attributes: feature.attributes,
        );
        imported++;

        if (!importImages) continue;

        for (final reference in feature.imageNames) {
          final bytes = resolveMedia(
            {
              for (final e in media.entries)
                e.key: Uint8List.fromList(e.value),
            },
            reference,
          );
          if (bytes == null) continue;

          await repository.addAttachment(
            projectId: projectId,
            featureId: created.id,
            // El archivo original no existe en disco: solo aporta el nombre,
            // el contenido va en `bytes`.
            source: File(p.basename(reference)),
            kind: AttachmentKind.foto,
            bytes: bytes,
            capturedAt: feature.timestamp,
          );
        }
      }
    }

    return imported;
  }

  /// Evita que dos capas del proyecto acaben con el mismo nombre.
  String _uniqueLayerName(String name, List<FeatureLayer> existing) {
    final taken = existing.map((l) => l.name).toSet();
    if (!taken.contains(name)) return name;

    var counter = 2;
    while (taken.contains('$name ($counter)')) {
      counter++;
    }
    return '$name ($counter)';
  }
}

/// Se ejecuta en otro isolate: solo lee y parsea.
KmzAnalysis _analyzeBytes(Uint8List bytes) {
  try {
    final result = const KmzReader().read(bytes);
    return KmzAnalysis(
      layers: result.data.layers,
      documentName: result.data.documentName,
      warnings: result.data.warnings,
      mediaCount: result.media.length,
    );
  } on FormatException catch (e) {
    return KmzAnalysis(layers: const [], error: e.message);
  } catch (e) {
    return KmzAnalysis(layers: const [], error: 'Archivo ilegible: $e');
  }
}

/// Relee solo la multimedia del KMZ, ya en el momento de importar.
Map<String, List<int>> _readMedia(String path) {
  try {
    final bytes = File(path).readAsBytesSync();
    final result = const KmzReader().read(bytes);
    return result.media;
  } catch (_) {
    return const {};
  }
}

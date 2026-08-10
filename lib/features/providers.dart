/// Providers de Riverpod: el cableado entre la capa de datos y la interfaz.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../data/db/database.dart';
import '../data/repositories/export_service.dart';
import '../data/repositories/geopdf_import_service.dart';
import '../data/repositories/kmz_import_service.dart';
import '../data/repositories/project_repository.dart';
import '../data/storage/project_storage.dart';
import '../geo/transform/georeference.dart';
import 'map/geopdf_raster_service.dart';
import 'tracks/track_recorder.dart';

/// Se sobrescriben en `main()` con las instancias ya inicializadas: así el
/// resto de la app las consume de forma síncrona, sin estados de carga.
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider sin inicializar'),
);

final storageProvider = Provider<ProjectStorage>(
  (ref) => throw UnimplementedError('storageProvider sin inicializar'),
);

final repositoryProvider = Provider<ProjectRepository>(
  (ref) => ProjectRepository(
    database: ref.watch(databaseProvider),
    storage: ref.watch(storageProvider),
  ),
);

final importServiceProvider = Provider<GeoPdfImportService>(
  (ref) => GeoPdfImportService(
    database: ref.watch(databaseProvider),
    storage: ref.watch(storageProvider),
  ),
);

final kmzImportServiceProvider = Provider<KmzImportService>(
  (ref) => KmzImportService(
    database: ref.watch(databaseProvider),
    storage: ref.watch(storageProvider),
    repository: ref.watch(repositoryProvider),
  ),
);

final exportServiceProvider = Provider<ExportService>(
  (ref) => ExportService(
    database: ref.watch(databaseProvider),
    storage: ref.watch(storageProvider),
    trackRepository: ref.watch(trackRepositoryProvider),
  ),
);

final rasterServiceProvider = Provider<GeoPdfRasterService>(
  (ref) => const GeoPdfRasterService(),
);

// ---------------------------------------------------------------------------
// Consultas reactivas
// ---------------------------------------------------------------------------

final projectsProvider = StreamProvider<List<Project>>(
  (ref) => ref.watch(repositoryProvider).watchProjects(),
);

final baseMapsProvider = StreamProvider.family<List<BaseMap>, String>(
  (ref, projectId) => ref.watch(repositoryProvider).watchBaseMaps(projectId),
);

final layersProvider = StreamProvider.family<List<FeatureLayer>, String>(
  (ref, projectId) => ref.watch(repositoryProvider).watchLayers(projectId),
);

final featuresProvider = StreamProvider.family<List<MapFeature>, String>(
  (ref, layerId) => ref.watch(repositoryProvider).watchFeatures(layerId),
);

final fieldsProvider = StreamProvider.family<List<FieldDef>, String>(
  (ref, layerId) => ref.watch(repositoryProvider).watchFields(layerId),
);

final attachmentsProvider = StreamProvider.family<List<Attachment>, String>(
  (ref, featureId) => ref.watch(repositoryProvider).watchAttachments(featureId),
);

// ---------------------------------------------------------------------------
// Rasterizado de mapas base
// ---------------------------------------------------------------------------

/// Imagen rasterizada y georreferenciada de un mapa base.
///
/// `keepAlive` porque rasterizar es caro: no queremos rehacerlo cada vez que
/// la pantalla se reconstruye.
final baseMapRasterProvider =
    FutureProvider.family<GeoPdfRaster?, BaseMap>((ref, baseMap) async {
  ref.keepAlive();

  final storage = ref.watch(storageProvider);
  final georeference = GeoReference.fromJsonString(baseMap.georeferenceJson);
  if (georeference == null) return null;

  final pdf = storage.resolve(baseMap.projectId, baseMap.filePath);
  if (!pdf.existsSync()) return null;

  final mediaBox = _decodeMediaBox(baseMap.mediaBoxJson);
  if (mediaBox == null) return null;

  // La imagen se cachea junto al PDF, con el id del mapa base en el nombre
  // para que dos páginas del mismo archivo no colisionen.
  // El ajuste de rotación va en el nombre: cambia el recorte de la zona
  // georreferenciada, así que la imagen cacheada deja de servir.
  final cache = File(
    p.join(
      storage.mapsDir(baseMap.projectId).path,
      '.cache',
      '${baseMap.id}_r${baseMap.rotationAdjust}.png',
    ),
  );

  return ref.watch(rasterServiceProvider).rasterize(
    pdf: pdf,
    pageIndex: baseMap.pageIndex,
    pageRotate: baseMap.pageRotate,
    mediaBox: mediaBox,
    georeference: georeference,
    cacheFile: cache,
    rotationAdjust: baseMap.rotationAdjust,
  );
});

List<double>? _decodeMediaBox(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List || decoded.length < 4) return null;
    return [for (final v in decoded) (v as num).toDouble()];
  } catch (_) {
    return null;
  }
}

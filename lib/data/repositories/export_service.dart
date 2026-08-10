/// Exportación de un proyecto a KMZ.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../geo/export/kml_model.dart';
import '../../geo/export/kmz_writer.dart';
import '../../geo/geometry/geometry.dart';
import '../../geo/measure/format.dart';
import '../db/database.dart';
import '../models/enums.dart';
import '../storage/project_storage.dart';
import 'project_repository.dart';
import 'track_repository.dart';

class ExportResult {
  const ExportResult({
    required this.file,
    required this.placemarkCount,
    required this.mediaCount,
    required this.sizeBytes,
    this.skippedMedia = const [],
  });

  final File file;
  final int placemarkCount;
  final int mediaCount;
  final int sizeBytes;

  /// Adjuntos que se referenciaban en la base pero cuyo archivo ya no está.
  /// Se informan en lugar de fallar: perder el KMZ entero por una foto
  /// borrada sería peor.
  final List<String> skippedMedia;

  String get sizeLabel => sizeBytes < 1024 * 1024
      ? '${(sizeBytes / 1024).toStringAsFixed(0)} KB'
      : '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

class ExportService {
  const ExportService({
    required this.database,
    required this.storage,
    required this.trackRepository,
  });

  final AppDatabase database;
  final ProjectStorage storage;
  final TrackRepository trackRepository;

  Future<ExportResult> exportProjectToKmz({
    required Project project,
    required File output,
    bool includeMedia = true,
    bool includeTracks = true,
  }) async {
    final folders = <KmlFolder>[];
    final media = <String, List<int>>{};
    final skipped = <String>[];

    final layers = await (database.select(database.featureLayers)
          ..where((t) => t.projectId.equals(project.id))
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();

    for (final layer in layers) {
      final features = await (database.select(database.mapFeatures)
            ..where((t) => t.layerId.equals(layer.id))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get();

      final placemarks = <KmlPlacemark>[];

      for (final feature in features) {
        final geometry = feature.geometry;
        if (geometry == null) continue;

        final attachments = await (database.select(database.attachments)
              ..where((t) => t.featureId.equals(feature.id))
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();

        final kmlMedia = <KmlMedia>[];
        for (final attachment in attachments) {
          final source = storage.resolve(project.id, attachment.filePath);
          if (!source.existsSync()) {
            skipped.add(attachment.filePath);
            continue;
          }

          // El id va en el nombre porque dos elementos distintos pueden traer
          // fotos llamadas igual y una pisaría a la otra dentro del ZIP.
          final name = '${attachment.id}_'
              '${sanitizeFileName(p.basename(attachment.filePath))}';

          if (includeMedia) {
            media[name] = await source.readAsBytes();
          }

          kmlMedia.add(
            KmlMedia(
              fileName: name,
              isImage: attachment.kind == AttachmentKind.foto,
              caption: attachment.caption,
            ),
          );
        }

        placemarks.add(
          KmlPlacemark(
            name: feature.name?.trim().isNotEmpty ?? false
                ? feature.name!
                : 'Sin nombre',
            geometry: geometry,
            description: feature.description,
            attributes: {
              ...feature.attributes,
              ..._geometryStats(geometry),
              if (feature.gpsAccuracy != null)
                'Precisión GPS': formatAccuracy(feature.gpsAccuracy!),
              if (feature.elevation != null)
                'Altitud': '${feature.elevation!.round()} m',
            },
            media: includeMedia ? kmlMedia : const [],
            timestamp: feature.createdAt,
          ),
        );
      }

      if (placemarks.isNotEmpty) {
        folders.add(
          KmlFolder(
            name: layer.name,
            color: layer.color,
            placemarks: placemarks,
          ),
        );
      }
    }

    if (includeTracks) {
      final trackFolder = await _buildTrackFolder(project.id);
      if (trackFolder != null) folders.add(trackFolder);
    }

    final result = buildKmz(
      document: KmlDocument(
        name: project.name,
        description: project.description,
        folders: folders,
      ),
      media: media,
    );

    await output.parent.create(recursive: true);
    await output.writeAsBytes(result.bytes, flush: true);

    return ExportResult(
      file: output,
      placemarkCount: result.placemarkCount,
      mediaCount: result.mediaCount,
      sizeBytes: result.sizeBytes,
      skippedMedia: skipped,
    );
  }

  Future<KmlFolder?> _buildTrackFolder(String projectId) async {
    final tracks = await (database.select(database.tracks)
          ..where((t) => t.projectId.equals(projectId))
          ..orderBy([(t) => OrderingTerm.asc(t.startedAt)]))
        .get();

    if (tracks.isEmpty) return null;

    final formatter = DateFormat('d MMM y HH:mm', 'es');
    final placemarks = <KmlPlacemark>[];

    for (final track in tracks) {
      final points = await trackRepository.pointsOf(track.id);
      // Un recorrido de un solo punto no dibuja línea alguna.
      if (points.length < 2) continue;

      placemarks.add(
        KmlPlacemark(
          name: track.name,
          geometry: LineGeometry([for (final point in points) point.latLon]),
          description: track.notes,
          attributes: {
            'Distancia': formatDistance(track.distanceMeters),
            'Duración': _formatDuration(track.duration),
            'Puntos': track.pointCount,
            'Inicio': formatter.format(track.startedAt),
            if (track.endedAt != null) 'Fin': formatter.format(track.endedAt!),
          },
          timestamp: track.startedAt,
        ),
      );
    }

    if (placemarks.isEmpty) return null;

    return KmlFolder(
      name: 'Recorridos',
      color: tracks.first.color,
      placemarks: placemarks,
    );
  }

  /// Empaqueta todas las fotos y videos del proyecto en un ZIP.
  ///
  /// Los archivos se organizan en una carpeta por capa y llevan el nombre del
  /// elemento, para que el ZIP se pueda recorrer sin abrir la app. Incluye un
  /// `fotos.csv` con las coordenadas, la fecha y el rumbo de cada toma: es lo
  /// que permite volcarlas a una hoja de cálculo o a un SIG.
  Future<ExportResult> exportPhotosToZip({
    required Project project,
    required File output,
    bool includeVideos = true,
  }) async {
    final archive = Archive();
    final skipped = <String>[];
    final rows = <List<String>>[
      [
        'archivo',
        'capa',
        'elemento',
        'latitud',
        'longitud',
        'precision_m',
        'altitud_m',
        'rumbo_grados',
        'tomada',
        'descripcion',
      ],
    ];

    final layers = await (database.select(database.featureLayers)
          ..where((t) => t.projectId.equals(project.id))
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();

    final timestampFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
    var mediaCount = 0;

    // Los nombres repetidos dentro del ZIP se pisarían entre sí, así que se
    // lleva la cuenta y se numeran.
    final usedNames = <String>{};

    for (final layer in layers) {
      final features = await (database.select(database.mapFeatures)
            ..where((t) => t.layerId.equals(layer.id))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get();

      for (final feature in features) {
        final attachments = await (database.select(database.attachments)
              ..where((t) => t.featureId.equals(feature.id))
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();

        for (final attachment in attachments) {
          if (!includeVideos && attachment.kind != AttachmentKind.foto) {
            continue;
          }

          final source = storage.resolve(project.id, attachment.filePath);
          if (!source.existsSync()) {
            skipped.add(attachment.filePath);
            continue;
          }

          final featureName = sanitizeFileName(
            feature.name?.trim().isNotEmpty ?? false
                ? feature.name!
                : 'sin_nombre',
          );
          final extension = p.extension(attachment.filePath);

          var name = '${sanitizeFileName(layer.name)}/'
              '$featureName$extension';
          var counter = 2;
          while (!usedNames.add(name)) {
            name = '${sanitizeFileName(layer.name)}/'
                '${featureName}_$counter$extension';
            counter++;
          }

          final bytes = await source.readAsBytes();
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
          mediaCount++;

          rows.add([
            name,
            layer.name,
            feature.name ?? '',
            attachment.latitude?.toStringAsFixed(7) ?? '',
            attachment.longitude?.toStringAsFixed(7) ?? '',
            attachment.accuracy?.toStringAsFixed(1) ?? '',
            attachment.elevation?.toStringAsFixed(1) ?? '',
            attachment.heading?.toStringAsFixed(1) ?? '',
            attachment.capturedAt == null
                ? ''
                : timestampFormat.format(attachment.capturedAt!),
            attachment.caption ?? feature.description ?? '',
          ]);
        }
      }
    }

    // BOM al inicio: sin él, Excel abre el CSV en ANSI y destroza los acentos.
    final csv = '﻿${rows.map(_csvRow).join('\r\n')}';
    final csvBytes = utf8.encode(csv);
    archive.addFile(ArchiveFile('fotos.csv', csvBytes.length, csvBytes));

    final encoded = ZipEncoder().encode(archive);
    if (encoded == null) throw StateError('No se pudo comprimir el ZIP');

    await output.parent.create(recursive: true);
    await output.writeAsBytes(encoded, flush: true);

    return ExportResult(
      file: output,
      placemarkCount: mediaCount,
      mediaCount: mediaCount,
      sizeBytes: encoded.length,
      skippedMedia: skipped,
    );
  }

  /// Una fila de CSV con las comillas escapadas según RFC 4180.
  static String _csvRow(List<String> values) => values.map((value) {
        final needsQuotes = value.contains(RegExp('[",\r\n]'));
        final escaped = value.replaceAll('"', '""');
        return needsQuotes ? '"$escaped"' : escaped;
      }).join(',');

  Map<String, Object?> _geometryStats(Geometry geometry) => switch (geometry) {
        PointGeometry() => const {},
        LineGeometry() => {'Longitud': formatDistance(geometry.lengthMeters)},
        PolygonGeometry() => {
            'Área': formatArea(geometry.areaMeters2),
            'Perímetro': formatDistance(geometry.lengthMeters),
          },
      };

  static String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    return hours > 0 ? '${hours}h ${minutes}min' : '${minutes}min';
  }
}

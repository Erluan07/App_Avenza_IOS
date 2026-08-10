/// Acceso a los recorridos grabados y a sus puntos.
library;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../geo/geometry/primitives.dart';
import '../db/database.dart';

class TrackRepository {
  TrackRepository({required this.database, Uuid? uuid})
      : _uuid = uuid ?? const Uuid();

  final AppDatabase database;
  final Uuid _uuid;

  Stream<List<Track>> watchTracks(String projectId) =>
      (database.select(database.tracks)
            ..where((t) => t.projectId.equals(projectId))
            ..orderBy([(t) => OrderingTerm.desc(t.startedAt)]))
          .watch();

  Future<Track?> findTrack(String id) =>
      (database.select(database.tracks)..where((t) => t.id.equals(id)))
          .getSingleOrNull();

  /// Recorridos sin hora de fin: quedaron abiertos porque la app se cerró de
  /// golpe. Se ofrecen al usuario para retomarlos o cerrarlos.
  Future<List<Track>> openTracks(String projectId) =>
      (database.select(database.tracks)
            ..where((t) => t.projectId.equals(projectId) & t.endedAt.isNull())
            ..orderBy([(t) => OrderingTerm.desc(t.startedAt)]))
          .get();

  Future<Track> startTrack({
    required String projectId,
    required String name,
    int color = 0xFF1E88E5,
  }) async {
    final id = _uuid.v4();

    await database.into(database.tracks).insert(
          TracksCompanion.insert(
            id: id,
            projectId: projectId,
            name: name,
            color: Value(color),
            startedAt: DateTime.now(),
          ),
        );

    return (await findTrack(id))!;
  }

  /// Añade un punto y actualiza los acumulados del recorrido.
  ///
  /// Va en una transacción: si el proceso muere entre la inserción y la
  /// actualización, la distancia dejaría de cuadrar con los puntos guardados.
  Future<void> appendPoint({
    required String trackId,
    required int sequence,
    required LatLon position,
    required DateTime recordedAt,
    required double totalDistanceMeters,
    double? accuracy,
    double? elevation,
    double? speed,
  }) =>
      database.transaction(() async {
        await database.into(database.trackPoints).insert(
              TrackPointsCompanion.insert(
                trackId: trackId,
                sequence: sequence,
                latitude: position.latitude,
                longitude: position.longitude,
                accuracy: Value(accuracy),
                elevation: Value(elevation),
                speed: Value(speed),
                recordedAt: recordedAt,
              ),
            );

        await (database.update(database.tracks)
              ..where((t) => t.id.equals(trackId)))
            .write(
          TracksCompanion(
            distanceMeters: Value(totalDistanceMeters),
            pointCount: Value(sequence + 1),
          ),
        );
      });

  Future<void> finishTrack(String trackId) =>
      (database.update(database.tracks)..where((t) => t.id.equals(trackId)))
          .write(TracksCompanion(endedAt: Value(DateTime.now())));

  Future<void> renameTrack(String trackId, String name) =>
      (database.update(database.tracks)..where((t) => t.id.equals(trackId)))
          .write(TracksCompanion(name: Value(name)));

  Future<void> setTrackVisible(String trackId, {required bool visible}) =>
      (database.update(database.tracks)..where((t) => t.id.equals(trackId)))
          .write(TracksCompanion(visible: Value(visible)));

  Future<void> deleteTrack(String trackId) =>
      (database.delete(database.tracks)..where((t) => t.id.equals(trackId)))
          .go();

  Future<List<TrackPoint>> pointsOf(String trackId) =>
      (database.select(database.trackPoints)
            ..where((t) => t.trackId.equals(trackId))
            ..orderBy([(t) => OrderingTerm.asc(t.sequence)]))
          .get();

  Stream<List<TrackPoint>> watchPoints(String trackId) =>
      (database.select(database.trackPoints)
            ..where((t) => t.trackId.equals(trackId))
            ..orderBy([(t) => OrderingTerm.asc(t.sequence)]))
          .watch();

  /// Todos los puntos de todos los recorridos visibles de un proyecto.
  /// Es una sola consulta: pedirlos recorrido a recorrido dispararía una
  /// consulta por cada uno al dibujar el mapa.
  Stream<Map<String, List<LatLon>>> watchVisibleTrackLines(String projectId) {
    final query = database.select(database.trackPoints).join([
      innerJoin(
        database.tracks,
        database.tracks.id.equalsExp(database.trackPoints.trackId),
      ),
    ])
      ..where(
        database.tracks.projectId.equals(projectId) &
            database.tracks.visible.equals(true),
      )
      ..orderBy([OrderingTerm.asc(database.trackPoints.sequence)]);

    return query.watch().map((rows) {
      final result = <String, List<LatLon>>{};
      for (final row in rows) {
        final point = row.readTable(database.trackPoints);
        result
            .putIfAbsent(point.trackId, () => <LatLon>[])
            .add(LatLon(point.latitude, point.longitude));
      }
      return result;
    });
  }
}

extension TrackX on Track {
  bool get isRecording => endedAt == null;

  Duration get duration =>
      (endedAt ?? DateTime.now()).difference(startedAt);
}

extension TrackPointX on TrackPoint {
  LatLon get latLon => LatLon(latitude, longitude);
}

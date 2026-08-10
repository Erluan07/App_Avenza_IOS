/// Grabación de recorridos por GPS.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/repositories/track_repository.dart';
import '../../geo/geometry/primitives.dart';
import '../../geo/measure/geodesy.dart';
import '../location/location_providers.dart';
import '../location/location_service.dart';
import '../providers.dart';

class TrackRecorderState {
  const TrackRecorderState({
    this.track,
    this.points = const [],
    this.distanceMeters = 0,
    this.isPaused = false,
    this.discardedCount = 0,
    this.lastAccuracy,
  });

  final Track? track;

  /// Puntos en memoria, para dibujar sin releer la base en cada lectura.
  final List<LatLon> points;

  final double distanceMeters;
  final bool isPaused;

  /// Lecturas descartadas por precisión insuficiente. Se muestra para que el
  /// usuario entienda por qué el recorrido no avanza bajo cobertura densa.
  final int discardedCount;

  final double? lastAccuracy;

  bool get isRecording => track != null;

  Duration get elapsed =>
      track == null ? Duration.zero : DateTime.now().difference(track!.startedAt);

  TrackRecorderState copyWith({
    Track? track,
    List<LatLon>? points,
    double? distanceMeters,
    bool? isPaused,
    int? discardedCount,
    double? lastAccuracy,
    bool clearTrack = false,
  }) =>
      TrackRecorderState(
        track: clearTrack ? null : (track ?? this.track),
        points: points ?? this.points,
        distanceMeters: distanceMeters ?? this.distanceMeters,
        isPaused: isPaused ?? this.isPaused,
        discardedCount: discardedCount ?? this.discardedCount,
        lastAccuracy: lastAccuracy ?? this.lastAccuracy,
      );
}

class TrackRecorder extends Notifier<TrackRecorderState> {
  /// Lecturas peores que esto se descartan: incorporarlas mete zigzags que
  /// falsean la distancia recorrida.
  static const double maxAccuracyMeters = 30;

  /// El GPS oscila unos metros aunque estés quieto. Sin este mínimo, un
  /// descanso de veinte minutos acabaría sumando kilómetros que nunca se
  /// caminaron.
  static const double minDistanceMeters = 5;

  @override
  TrackRecorderState build() {
    ref.listen<AsyncValue<UserPosition>>(userPositionProvider, (_, next) {
      final position = next.valueOrNull;
      if (position != null) _onPosition(position);
    });

    return const TrackRecorderState();
  }

  Future<void> start({
    required String projectId,
    required String name,
    int color = 0xFF1E88E5,
  }) async {
    if (state.isRecording) return;

    final track = await ref.read(trackRepositoryProvider).startTrack(
          projectId: projectId,
          name: name,
          color: color,
        );

    state = TrackRecorderState(track: track);
  }

  /// Retoma un recorrido que quedó abierto porque la app se cerró de golpe.
  Future<void> resume(Track track) async {
    if (state.isRecording) return;

    final stored = await ref.read(trackRepositoryProvider).pointsOf(track.id);
    state = TrackRecorderState(
      track: track,
      points: [for (final p in stored) p.latLon],
      distanceMeters: track.distanceMeters,
    );
  }

  void pause() => state = state.copyWith(isPaused: true);

  void unpause() => state = state.copyWith(isPaused: false);

  Future<Track?> stop() async {
    final track = state.track;
    if (track == null) return null;

    await ref.read(trackRepositoryProvider).finishTrack(track.id);
    final finished = await ref.read(trackRepositoryProvider).findTrack(track.id);

    state = const TrackRecorderState();
    return finished;
  }

  Future<void> _onPosition(UserPosition position) async {
    final track = state.track;
    if (track == null || state.isPaused) return;

    if (position.accuracyMeters > maxAccuracyMeters) {
      state = state.copyWith(
        discardedCount: state.discardedCount + 1,
        lastAccuracy: position.accuracyMeters,
      );
      return;
    }

    final last = state.points.isEmpty ? null : state.points.last;
    var distance = state.distanceMeters;

    if (last != null) {
      final step = vincentyDistance(last, position.latLon);
      if (step < minDistanceMeters) {
        // No es un descarte: la lectura es buena, simplemente no nos movimos.
        state = state.copyWith(lastAccuracy: position.accuracyMeters);
        return;
      }
      distance += step;
    }

    final sequence = state.points.length;
    state = state.copyWith(
      points: [...state.points, position.latLon],
      distanceMeters: distance,
      lastAccuracy: position.accuracyMeters,
    );

    await ref.read(trackRepositoryProvider).appendPoint(
          trackId: track.id,
          sequence: sequence,
          position: position.latLon,
          recordedAt: position.timestamp,
          totalDistanceMeters: distance,
          accuracy: position.accuracyMeters,
          elevation: position.altitudeMeters,
          speed: position.speedMetersPerSecond,
        );
  }
}

final trackRecorderProvider =
    NotifierProvider<TrackRecorder, TrackRecorderState>(TrackRecorder.new);

final trackRepositoryProvider = Provider<TrackRepository>(
  (ref) => TrackRepository(database: ref.watch(databaseProvider)),
);

final tracksProvider = StreamProvider.family<List<Track>, String>(
  (ref, projectId) => ref.watch(trackRepositoryProvider).watchTracks(projectId),
);

/// Líneas de todos los recorridos visibles, en una sola consulta.
final trackLinesProvider =
    StreamProvider.family<Map<String, List<LatLon>>, String>(
  (ref, projectId) =>
      ref.watch(trackRepositoryProvider).watchVisibleTrackLines(projectId),
);

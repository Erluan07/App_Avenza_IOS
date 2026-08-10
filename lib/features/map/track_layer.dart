/// Dibuja los recorridos guardados y el que se está grabando.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../geo/geometry/primitives.dart';
import '../tracks/track_recorder.dart';
import 'map_conversions.dart';

class TrackLayer extends ConsumerWidget {
  const TrackLayer({required this.projectId, super.key});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(trackLinesProvider(projectId)).valueOrNull ??
        const <String, List<LatLon>>{};
    final tracks = ref.watch(tracksProvider(projectId)).valueOrNull ?? const [];
    final recording = ref.watch(trackRecorderProvider);

    final colorOf = {for (final track in tracks) track.id: Color(track.color)};
    final recordingId = recording.track?.id;

    final polylines = <Polyline>[];

    for (final entry in lines.entries) {
      // El recorrido en curso se dibuja aparte, desde memoria: va más al día
      // que lo que ya se escribió en la base.
      if (entry.key == recordingId) continue;
      if (entry.value.length < 2) continue;

      polylines.add(
        Polyline(
          points: entry.value.toLatLngList,
          color: colorOf[entry.key] ?? Colors.blue,
          strokeWidth: 4,
        ),
      );
    }

    if (recording.isRecording && recording.points.length >= 2) {
      polylines.add(
        Polyline(
          points: recording.points.toLatLngList,
          color: Color(recording.track?.color ?? 0xFF1E88E5),
          strokeWidth: 5,
          // Punteado mientras se graba: distingue de un vistazo lo que todavía
          // está abierto de lo ya cerrado.
          pattern: const StrokePattern.dotted(),
        ),
      );
    }

    if (polylines.isEmpty) return const SizedBox.shrink();
    return PolylineLayer(polylines: polylines);
  }
}

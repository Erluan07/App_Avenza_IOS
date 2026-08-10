/// Panel con las estadísticas del recorrido que se está grabando.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../geo/measure/format.dart';
import 'track_recorder.dart';

class RecordingPanel extends ConsumerStatefulWidget {
  const RecordingPanel({required this.onStop, super.key});

  final Future<void> Function() onStop;

  @override
  ConsumerState<RecordingPanel> createState() => _RecordingPanelState();
}

class _RecordingPanelState extends ConsumerState<RecordingPanel> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // El cronómetro avanza aunque no lleguen posiciones nuevas: si dependiera
    // del GPS, parecería congelado estando quieto.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(trackRecorderProvider);
    if (!state.isRecording) return const SizedBox.shrink();

    final recorder = ref.read(trackRecorderProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Align(
      alignment: Alignment.topCenter,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(14),
            color: scheme.surface,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _RecordingDot(paused: state.isPaused),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          state.track!.name,
                          style: Theme.of(context).textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: state.isPaused ? 'Reanudar' : 'Pausar',
                        icon: Icon(
                          state.isPaused ? Icons.play_arrow : Icons.pause,
                        ),
                        onPressed: state.isPaused
                            ? recorder.unpause
                            : recorder.pause,
                      ),
                      IconButton(
                        tooltip: 'Terminar recorrido',
                        icon: const Icon(Icons.stop_circle_outlined),
                        color: scheme.error,
                        onPressed: widget.onStop,
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      _Stat(
                        label: 'Distancia',
                        value: formatDistance(state.distanceMeters),
                      ),
                      _Stat(
                        label: 'Tiempo',
                        value: _formatElapsed(state.elapsed),
                      ),
                      _Stat(label: 'Puntos', value: '${state.points.length}'),
                    ],
                  ),
                  if (state.lastAccuracy != null || state.discardedCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        [
                          if (state.lastAccuracy != null)
                            'GPS ${formatAccuracy(state.lastAccuracy!)}',
                          // Explicar los descartes evita que parezca que la
                          // grabación se colgó bajo cobertura densa.
                          if (state.discardedCount > 0)
                            '${state.discardedCount} lecturas descartadas por baja precisión',
                        ].join(' · '),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _formatElapsed(Duration duration) {
    String two(int value) => value.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return hours > 0
        ? '$hours:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }
}

class _RecordingDot extends StatelessWidget {
  const _RecordingDot({required this.paused});

  final bool paused;

  @override
  Widget build(BuildContext context) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: paused ? Colors.orange : Colors.redAccent,
          shape: BoxShape.circle,
        ),
      );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            Text(
              value,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      );
}

/// Panel inferior de la herramienta de medición.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../geo/measure/format.dart';
import '../../ui/app_theme.dart';
// UserPosition (y su getter latLon) llegan a través de location_providers.
import '../location/location_providers.dart';
import 'measure_controller.dart';

class MeasurePanel extends ConsumerWidget {
  const MeasurePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(measureControllerProvider);
    if (state == null) return const SizedBox.shrink();

    final controller = ref.read(measureControllerProvider.notifier);
    final position = ref.watch(userPositionProvider).valueOrNull;
    final measure = context.appColors.measure;
    final theme = Theme.of(context);

    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
            color: theme.colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.straighten, color: measure),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Medición',
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Cerrar',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close),
                        onPressed: controller.close,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<MeasureMode>(
                    segments: const [
                      ButtonSegment(
                        value: MeasureMode.distancia,
                        icon: Icon(Icons.timeline, size: 18),
                        label: Text('Distancia'),
                      ),
                      ButtonSegment(
                        value: MeasureMode.area,
                        icon: Icon(Icons.pentagon_outlined, size: 18),
                        label: Text('Área'),
                      ),
                    ],
                    selected: {state.mode},
                    onSelectionChanged: (values) =>
                        controller.setMode(values.first),
                  ),
                  const SizedBox(height: 12),
                  _Readout(state: state, color: measure),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: position == null
                              ? null
                              : () => controller.addVertex(position.latLon),
                          icon: const Icon(Icons.my_location, size: 18),
                          label: Text(position == null ? 'Sin GPS' : 'Aquí'),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton.filledTonal(
                        tooltip: 'Deshacer',
                        onPressed: state.vertices.isEmpty
                            ? null
                            : controller.undo,
                        icon: const Icon(Icons.undo),
                      ),
                      const SizedBox(width: 6),
                      IconButton.filledTonal(
                        tooltip: 'Limpiar',
                        onPressed: state.vertices.isEmpty
                            ? null
                            : controller.clear,
                        icon: const Icon(Icons.delete_sweep_outlined),
                      ),
                    ],
                  ),
                  if (state.vertices.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Tocá el mapa para ir marcando el recorrido a medir.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
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
}

class _Readout extends StatelessWidget {
  const _Readout({required this.state, required this.color});

  final MeasureState state;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final primary = state.mode == MeasureMode.area
        ? ('Área', formatArea(state.areaMeters2))
        : ('Distancia total', formatDistance(state.lengthMeters));

    final secondary = state.mode == MeasureMode.area
        ? ('Perímetro', formatDistance(state.perimeterMeters))
        : ('Último tramo', formatDistance(state.lastSegmentMeters));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  primary.$1,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  primary.$2,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                secondary.$1,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                secondary.$2,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Barra inferior que aparece mientras se está capturando una geometría.
///
/// Muestra las medidas en vivo: al recorrer un perímetro, ver el área crecer
/// es la forma de saber que vas bien sin tener que cerrar el polígono.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../geo/geometry/geometry.dart';
import '../../geo/measure/format.dart';
import '../location/location_providers.dart';
import 'capture_state.dart';

class CaptureToolbar extends ConsumerWidget {
  const CaptureToolbar({required this.onFinish, super.key});

  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(captureControllerProvider);
    if (session == null) return const SizedBox.shrink();

    final controller = ref.read(captureControllerProvider.notifier);
    final position = ref.watch(userPositionProvider).valueOrNull;
    final scheme = Theme.of(context).colorScheme;

    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(16),
            color: scheme.surface,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        switch (session.geometryType) {
                          GeometryType.point => Icons.place,
                          GeometryType.line => Icons.polyline,
                          GeometryType.polygon => Icons.pentagon_outlined,
                        },
                        color: Color(session.color),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          session.layerName,
                          style: Theme.of(context).textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${session.vertices.length} '
                        '${session.vertices.length == 1 ? 'vértice' : 'vértices'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _Measurements(session: session),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: position == null
                              ? null
                              : () => controller.addVertex(
                                    position.latLon,
                                    accuracy: position.accuracyMeters,
                                  ),
                          icon: const Icon(Icons.my_location, size: 18),
                          label: Text(
                            position == null ? 'Sin GPS' : 'Aquí',
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton.filledTonal(
                        tooltip: 'Deshacer último vértice',
                        onPressed: session.vertices.isEmpty
                            ? null
                            : controller.undo,
                        icon: const Icon(Icons.undo),
                      ),
                      const SizedBox(width: 6),
                      IconButton.filledTonal(
                        tooltip: 'Cancelar captura',
                        onPressed: controller.cancel,
                        icon: const Icon(Icons.close),
                      ),
                      const SizedBox(width: 6),
                      FilledButton.icon(
                        onPressed: session.canFinish ? onFinish : null,
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('Guardar'),
                      ),
                    ],
                  ),
                  if (!session.canFinish)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _hint(session),
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

  String _hint(CaptureSession session) {
    final faltan = session.minimumVertices - session.vertices.length;
    return switch (session.geometryType) {
      GeometryType.point => 'Tocá el mapa o usá "Aquí" para ubicar el punto.',
      GeometryType.line =>
        'Faltan $faltan ${faltan == 1 ? 'vértice' : 'vértices'} para formar una línea.',
      GeometryType.polygon =>
        'Faltan $faltan ${faltan == 1 ? 'vértice' : 'vértices'} para cerrar el polígono.',
    };
  }
}

class _Measurements extends StatelessWidget {
  const _Measurements({required this.session});

  final CaptureSession session;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;

    final items = switch (session.geometryType) {
      GeometryType.point => [
          if (session.vertices.isNotEmpty)
            ('Lat', formatLatLon(session.vertices.first.latitude)),
          if (session.vertices.isNotEmpty)
            ('Lon', formatLatLon(session.vertices.first.longitude)),
        ],
      GeometryType.line => [
          ('Longitud', formatDistance(session.lengthMeters)),
        ],
      GeometryType.polygon => [
          ('Área', formatArea(session.areaMeters2)),
          ('Perímetro', formatDistance(session.perimeterMeters)),
        ],
    };

    if (items.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 16,
      runSpacing: 2,
      children: [
        for (final (label, value) in items)
          RichText(
            text: TextSpan(
              style: style,
              children: [
                TextSpan(
                  text: '$label: ',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                TextSpan(
                  text: value,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

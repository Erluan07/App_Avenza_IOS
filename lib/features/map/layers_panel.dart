/// Panel de capas: encender y apagar mapas base y capas de captura, y ajustar
/// la opacidad de los GeoPDF.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/db/database.dart';
import '../../data/repositories/track_repository.dart';
import '../../geo/geometry/geometry.dart';
import '../../geo/geometry/primitives.dart';
import '../../geo/measure/format.dart';
import '../layers/layer_editor_sheet.dart';
import '../layers/layer_features_screen.dart';
import '../providers.dart';
import '../tracks/track_recorder.dart';

class LayersPanel extends ConsumerWidget {
  const LayersPanel({required this.projectId, this.onLocate, super.key});

  final String projectId;

  /// Permite centrar el mapa en un elemento elegido desde la lista.
  final void Function(LatLon target)? onLocate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baseMaps = ref.watch(baseMapsProvider(projectId));
    final layers = ref.watch(layersProvider(projectId));
    final repository = ref.watch(repositoryProvider);

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          const _SectionTitle('Mapas base'),
          ...baseMaps.maybeWhen(
            data: (maps) => maps.isEmpty
                ? [const _EmptyHint('Todavía no importaste ningún GeoPDF.')]
                : [
                    for (final map in maps)
                      _BaseMapTile(
                        baseMap: map,
                        onVisibilityChanged: (value) => repository
                            .setBaseMapVisible(map.id, visible: value),
                        onOpacityChanged: (value) =>
                            repository.setBaseMapOpacity(map.id, value),
                      ),
                  ],
            orElse: () => const [_LoadingTile()],
          ),
          const Divider(height: 24),
          const _SectionTitle('Capas de captura'),
          ...layers.maybeWhen(
            data: (items) => items.isEmpty
                ? [const _EmptyHint('Todavía no creaste ninguna capa.')]
                : [
                    for (final layer in items)
                      _LayerTile(
                        projectId: projectId,
                        layer: layer,
                        onLocate: onLocate,
                        onVisibilityChanged: (value) =>
                            repository.setLayerVisible(layer.id, visible: value),
                      ),
                  ],
            orElse: () => const [_LoadingTile()],
          ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Nueva capa'),
            onTap: () => showLayerEditor(context, projectId),
          ),
          ..._tracksSection(context, ref),
        ],
      ),
    );
  }

  List<Widget> _tracksSection(BuildContext context, WidgetRef ref) {
    final tracks = ref.watch(tracksProvider(projectId)).valueOrNull;
    if (tracks == null || tracks.isEmpty) return const [];

    final repository = ref.read(trackRepositoryProvider);
    final formatter = DateFormat('d MMM y HH:mm', 'es');

    return [
      const Divider(height: 24),
      const _SectionTitle('Recorridos'),
      for (final track in tracks)
        SwitchListTile(
          value: track.visible,
          onChanged: (value) =>
              repository.setTrackVisible(track.id, visible: value),
          secondary: Icon(
            track.isRecording ? Icons.fiber_manual_record : Icons.route,
            color: track.isRecording ? Colors.redAccent : Color(track.color),
          ),
          title: Text(track.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              formatDistance(track.distanceMeters),
              '${track.pointCount} puntos',
              formatter.format(track.startedAt),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
  }
}

/// Fila de capa. El interruptor controla la visibilidad y el resto de la fila
/// abre la lista de elementos: son dos acciones distintas y conviene que no
/// compitan por el mismo toque.
class _LayerTile extends ConsumerWidget {
  const _LayerTile({
    required this.projectId,
    required this.layer,
    required this.onVisibilityChanged,
    this.onLocate,
  });

  final String projectId;
  final FeatureLayer layer;
  final ValueChanged<bool> onVisibilityChanged;
  final void Function(LatLon target)? onLocate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final features = ref.watch(featuresProvider(layer.id)).valueOrNull;
    final count = features?.length;

    return ListTile(
      leading: Icon(
        switch (layer.geometryType) {
          GeometryType.point => Icons.place,
          GeometryType.line => Icons.polyline,
          GeometryType.polygon => Icons.pentagon_outlined,
        },
        color: Color(layer.color),
      ),
      title: Text(layer.name),
      subtitle: Text(
        count == null
            ? '…'
            : count == 1
                ? '1 elemento'
                : '$count elementos',
      ),
      trailing: Switch(value: layer.visible, onChanged: onVisibilityChanged),
      onTap: () {
        Navigator.of(context).pop();
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => LayerFeaturesScreen(
              projectId: projectId,
              layer: layer,
              onLocate: onLocate,
            ),
          ),
        );
      },
    );
  }
}

class _BaseMapTile extends ConsumerWidget {
  const _BaseMapTile({
    required this.baseMap,
    required this.onVisibilityChanged,
    required this.onOpacityChanged,
  });

  final BaseMap baseMap;
  final ValueChanged<bool> onVisibilityChanged;
  final ValueChanged<double> onOpacityChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final raster = ref.watch(baseMapRasterProvider(baseMap));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          value: baseMap.visible,
          onChanged: onVisibilityChanged,
          secondary: switch (raster) {
            AsyncLoading() => const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            AsyncError() => Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
              ),
            _ => const Icon(Icons.map),
          },
          title: Text(baseMap.name),
          subtitle: Text(
            baseMap.crsName ?? 'Sin CRS declarado',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (baseMap.visible)
          Padding(
            padding: const EdgeInsets.only(left: 72, right: 12),
            child: Row(
              children: [
                const Icon(Icons.opacity, size: 18),
                Expanded(
                  child: Slider(
                    value: baseMap.opacity,
                    onChanged: onOpacityChanged,
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text('${(baseMap.opacity * 100).round()}%'),
                ),
                IconButton(
                  tooltip: baseMap.rotationAdjust == 0
                      ? 'Girar 90° si el mapa se ve mal orientado'
                      : 'Girado ${baseMap.rotationAdjust}° · tocá para girar más',
                  icon: Icon(
                    Icons.rotate_90_degrees_cw,
                    color: baseMap.rotationAdjust == 0
                        ? null
                        : Theme.of(context).colorScheme.primary,
                  ),
                  onPressed: () => ref
                      .read(repositoryProvider)
                      .rotateBaseMap(baseMap.id, baseMap.rotationAdjust),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(
          text,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      );
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(text, style: Theme.of(context).textTheme.bodySmall),
      );
}

class _LoadingTile extends StatelessWidget {
  const _LoadingTile();

  @override
  Widget build(BuildContext context) => const ListTile(
        leading: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text('Cargando…'),
      );
}

/// Lista de los elementos de una capa.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/db/database.dart';
import '../../data/repositories/project_repository.dart';
import '../../geo/geometry/geometry.dart';
import '../../geo/geometry/primitives.dart';
import '../../geo/measure/format.dart';
import '../capture/feature_detail_sheet.dart';
import '../providers.dart';

class LayerFeaturesScreen extends ConsumerWidget {
  const LayerFeaturesScreen({
    required this.projectId,
    required this.layer,
    this.onLocate,
    super.key,
  });

  final String projectId;
  final FeatureLayer layer;
  final void Function(LatLon target)? onLocate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final features = ref.watch(featuresProvider(layer.id));
    final color = Color(layer.color);

    return Scaffold(
      appBar: AppBar(
        title: Text(layer.name),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: Container(height: 3, color: color),
        ),
      ),
      body: features.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (items) => items.isEmpty
            ? const _Empty()
            : ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) => _FeatureTile(
                  projectId: projectId,
                  layer: layer,
                  feature: items[index],
                  onLocate: onLocate,
                ),
              ),
      ),
    );
  }
}

class _FeatureTile extends ConsumerWidget {
  const _FeatureTile({
    required this.projectId,
    required this.layer,
    required this.feature,
    this.onLocate,
  });

  final String projectId;
  final FeatureLayer layer;
  final MapFeature feature;
  final void Function(LatLon target)? onLocate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final geometry = feature.geometry;
    final attachments =
        ref.watch(attachmentsProvider(feature.id)).valueOrNull ?? const [];

    final subtitle = <String>[
      if (geometry case PolygonGeometry()) formatArea(geometry.areaMeters2),
      if (geometry case LineGeometry())
        formatDistance(geometry.lengthMeters),
      DateFormat('d MMM, HH:mm', 'es').format(feature.createdAt),
    ];

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Color(layer.color).withValues(alpha: 0.18),
        child: Icon(
          switch (layer.geometryType) {
            GeometryType.point => Icons.place,
            GeometryType.line => Icons.polyline,
            GeometryType.polygon => Icons.pentagon_outlined,
          },
          color: Color(layer.color),
          size: 20,
        ),
      ),
      title: Text(
        feature.name?.trim().isNotEmpty ?? false ? feature.name! : 'Sin nombre',
      ),
      subtitle: Text(subtitle.join(' · ')),
      trailing: attachments.isEmpty
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.photo_library_outlined, size: 16),
                const SizedBox(width: 4),
                Text('${attachments.length}'),
              ],
            ),
      onTap: () => showFeatureDetail(
        context,
        projectId: projectId,
        feature: feature,
        layer: layer,
        onLocate: onLocate == null
            ? null
            : (target) {
                // Se cierra la lista para que el mapa quede a la vista tras
                // centrarlo; si no, el usuario tendría que volver a mano.
                Navigator.of(context).pop();
                onLocate!(target);
              },
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.layers_clear_outlined, size: 56),
              const SizedBox(height: 12),
              Text(
                'Esta capa todavía no tiene elementos',
                style: Theme.of(context).textTheme.titleSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'Usá el botón Capturar en el mapa para agregar el primero.',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
}

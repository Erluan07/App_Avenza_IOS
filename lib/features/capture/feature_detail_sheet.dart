/// Ficha de un elemento capturado: atributos, medidas y multimedia.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/db/database.dart';
import '../../data/models/enums.dart';
import '../../data/repositories/project_repository.dart';
import '../../geo/geometry/geometry.dart';
import '../../geo/geometry/primitives.dart';
import '../../geo/measure/format.dart';
import '../../geo/photo/photo_metadata.dart';
import '../providers.dart';

Future<void> showFeatureDetail(
  BuildContext context, {
  required String projectId,
  required MapFeature feature,
  required FeatureLayer layer,
  void Function(LatLon target)? onLocate,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        minChildSize: 0.3,
        maxChildSize: 0.92,
        builder: (_, controller) => FeatureDetailSheet(
          projectId: projectId,
          feature: feature,
          layer: layer,
          scrollController: controller,
          onLocate: onLocate,
        ),
      ),
    );

class FeatureDetailSheet extends ConsumerWidget {
  const FeatureDetailSheet({
    required this.projectId,
    required this.feature,
    required this.layer,
    required this.scrollController,
    this.onLocate,
    super.key,
  });

  final String projectId;
  final MapFeature feature;
  final FeatureLayer layer;
  final ScrollController scrollController;
  final void Function(LatLon target)? onLocate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final geometry = feature.geometry;
    final attachments =
        ref.watch(attachmentsProvider(feature.id)).valueOrNull ?? const [];
    final fields = ref.watch(fieldsProvider(layer.id)).valueOrNull ?? const [];
    final theme = Theme.of(context);
    final color = Color(layer.color);

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.18),
              child: Icon(
                switch (layer.geometryType) {
                  GeometryType.point => Icons.place,
                  GeometryType.line => Icons.polyline,
                  GeometryType.polygon => Icons.pentagon_outlined,
                },
                color: color,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    feature.name?.trim().isNotEmpty ?? false
                        ? feature.name!
                        : 'Sin nombre',
                    style: theme.textTheme.titleLarge,
                  ),
                  Text(
                    layer.name,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (feature.description?.trim().isNotEmpty ?? false) ...[
          const SizedBox(height: 16),
          Text(feature.description!, style: theme.textTheme.bodyMedium),
        ],
        const SizedBox(height: 20),
        if (geometry != null) _MeasurementChips(geometry: geometry),
        const SizedBox(height: 16),
        _DetailSection(
          title: 'Ubicación',
          children: [
            if (geometry != null)
              _DetailRow(
                label: 'Coordenadas',
                value: '${formatLatLon(geometry.centroid.latitude)}, '
                    '${formatLatLon(geometry.centroid.longitude)}',
              ),
            if (geometry != null)
              _DetailRow(
                label: 'Grados/min/seg',
                value:
                    '${formatDms(geometry.centroid.latitude, isLatitude: true)}  '
                    '${formatDms(geometry.centroid.longitude, isLatitude: false)}',
              ),
            if (feature.gpsAccuracy != null)
              _DetailRow(
                label: 'Precisión GPS',
                value: formatAccuracy(feature.gpsAccuracy!),
              ),
            if (feature.elevation != null)
              _DetailRow(
                label: 'Altitud',
                value: '${feature.elevation!.round()} m',
              ),
            _DetailRow(
              label: 'Capturado',
              value: DateFormat('d MMM y, HH:mm', 'es')
                  .format(feature.createdAt),
            ),
          ],
        ),
        if (feature.attributes.isNotEmpty) ...[
          const SizedBox(height: 16),
          _DetailSection(
            title: 'Atributos',
            children: [
              for (final entry in feature.attributes.entries)
                _DetailRow(
                  // Se prefiere la etiqueta declarada en la capa; si el campo
                  // se borró, se muestra la clave cruda antes que ocultar el
                  // dato.
                  label: fields
                          .where((f) => f.key == entry.key)
                          .map((f) => f.label)
                          .firstOrNull ??
                      entry.key,
                  value: '${entry.value}',
                ),
            ],
          ),
        ],
        if (attachments.isNotEmpty) ...[
          const SizedBox(height: 16),
          _DetailSection(
            title: 'Multimedia (${attachments.length})',
            children: [
              SizedBox(
                height: 120,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: attachments.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) => _AttachmentThumb(
                    projectId: projectId,
                    attachment: attachments[index],
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            if (onLocate != null && geometry != null)
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    onLocate!(geometry.centroid);
                  },
                  icon: const Icon(Icons.center_focus_strong),
                  label: const Text('Centrar'),
                ),
              ),
            if (onLocate != null && geometry != null) const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _confirmDelete(context, ref),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Borrar'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('¿Borrar el elemento?'),
        content: const Text(
          'Se eliminan también sus fotos y videos. No se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );

    if (!(confirmed ?? false)) return;

    await ref.read(repositoryProvider).deleteFeature(feature.id);
    if (context.mounted) Navigator.of(context).pop();
  }
}

class _MeasurementChips extends StatelessWidget {
  const _MeasurementChips({required this.geometry});

  final Geometry geometry;

  @override
  Widget build(BuildContext context) {
    final items = switch (geometry) {
      PointGeometry() => <(IconData, String, String)>[],
      LineGeometry(:final points) => [
          (Icons.straighten, 'Longitud', formatDistance(geometry.lengthMeters)),
          (Icons.timeline, 'Vértices', '${points.length}'),
        ],
      PolygonGeometry(:final ring) => [
          (Icons.crop_square, 'Área', formatArea(geometry.areaMeters2)),
          (
            Icons.straighten,
            'Perímetro',
            formatDistance(geometry.lengthMeters)
          ),
          (Icons.timeline, 'Vértices', '${ring.length}'),
        ],
    };

    if (items.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (icon, label, value) in items)
          Chip(
            avatar: Icon(icon, size: 18),
            label: Text('$label: $value'),
          ),
      ],
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// Datos de la toma bajo la foto a pantalla completa.
///
/// Repite lo que ya va sellado en la imagen, pero aquí es seleccionable: sirve
/// para copiar las coordenadas a otra herramienta.
class _PhotoMetadataBar extends StatelessWidget {
  const _PhotoMetadataBar({required this.attachment});

  final Attachment attachment;

  @override
  Widget build(BuildContext context) {
    final rows = <(IconData, String)>[
      if (attachment.capturedAt != null)
        (
          Icons.schedule,
          DateFormat('d MMM y, HH:mm', 'es').format(attachment.capturedAt!),
        ),
      if (attachment.latitude != null && attachment.longitude != null)
        (
          Icons.place,
          '${formatLatLon(attachment.latitude!)}, '
              '${formatLatLon(attachment.longitude!)}',
        ),
      if (attachment.heading != null)
        (
          Icons.explore,
          '${cardinalPoint(attachment.heading!)} '
              '${attachment.heading!.round()}°',
        ),
      if (attachment.accuracy != null)
        (Icons.gps_fixed, formatAccuracy(attachment.accuracy!)),
    ];

    return Container(
      width: double.infinity,
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (icon, text) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Icon(icon, size: 15, color: Colors.white54),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SelectableText(
                      text,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AttachmentThumb extends StatelessWidget {
  const _AttachmentThumb({required this.projectId, required this.attachment});

  final String projectId;
  final Attachment attachment;

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final file = ref
            .read(storageProvider)
            .resolve(projectId, attachment.filePath);
        final exists = file.existsSync();
        final isPhoto = attachment.kind == AttachmentKind.foto;

        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: exists && isPhoto
              ? () => _openViewer(context, file)
              : null,
          // El tamaño se fija aquí, fuera del Stack: dentro de una lista
          // horizontal el ancho disponible es infinito, y un Stack sin
          // restricciones acotadas no puede medirse.
          child: SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              children: [
                Positioned.fill(
                  child: _thumb(context, file, exists: exists, isPhoto: isPhoto),
                ),
                // La chincheta avisa de un vistazo qué fotos llevan
                // coordenadas.
                if (attachment.latitude != null)
                  const Positioned(
                    right: 4,
                    bottom: 4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: Padding(
                        padding: EdgeInsets.all(3),
                        child: Icon(
                          Icons.place,
                          size: 13,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _thumb(
    BuildContext context,
    File file, {
    required bool exists,
    required bool isPhoto,
  }) =>
      ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: !exists
            ? const ColoredBox(
                color: Colors.black12,
                child: Center(child: Icon(Icons.broken_image_outlined)),
              )
            : isPhoto
                ? Image.file(file, fit: BoxFit.cover)
                : ColoredBox(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Center(
                      child: Icon(Icons.play_circle_outline, size: 36),
                    ),
                  ),
      );

  void _openViewer(BuildContext context, File file) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(attachment.caption ?? 'Foto'),
          ),
          body: Column(
            children: [
              Expanded(
                child: Center(
                  // Zoom con dos dedos: en campo se revisan detalles de la foto.
                  child: InteractiveViewer(
                    maxScale: 5,
                    child: Image.file(file),
                  ),
                ),
              ),
              if (attachment.latitude != null || attachment.capturedAt != null)
                _PhotoMetadataBar(attachment: attachment),
            ],
          ),
        ),
      ),
    );
  }
}

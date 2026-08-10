/// Exportación del proyecto a KMZ.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/db/database.dart';
import '../../data/repositories/export_service.dart';
import '../../geo/export/kmz_writer.dart';
import '../providers.dart';

Future<void> showExportSheet(BuildContext context, Project project) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ExportSheet(project: project),
    );

class _ExportSheet extends ConsumerStatefulWidget {
  const _ExportSheet({required this.project});

  final Project project;

  @override
  ConsumerState<_ExportSheet> createState() => _ExportSheetState();
}

/// Qué se produce al exportar.
enum _ExportKind {
  kmz,
  fotos;

  String get label => switch (this) {
        _ExportKind.kmz => 'Mapa (KMZ)',
        _ExportKind.fotos => 'Fotos (ZIP)',
      };
}

class _ExportSheetState extends ConsumerState<_ExportSheet> {
  _ExportKind _kind = _ExportKind.kmz;
  bool _includeMedia = true;
  bool _includeTracks = true;
  bool _includeVideos = true;
  bool _exporting = false;
  ExportResult? _result;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Exportar', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          SegmentedButton<_ExportKind>(
            segments: const [
              ButtonSegment(
                value: _ExportKind.kmz,
                icon: Icon(Icons.public, size: 18),
                label: Text('Mapa'),
              ),
              ButtonSegment(
                value: _ExportKind.fotos,
                icon: Icon(Icons.photo_library_outlined, size: 18),
                label: Text('Fotos'),
              ),
            ],
            selected: {_kind},
            // Cambiar de formato invalida el resultado anterior: si no, el
            // botón de compartir mandaría el archivo equivocado.
            onSelectionChanged: _exporting
                ? null
                : (values) => setState(() {
                      _kind = values.first;
                      _result = null;
                      _error = null;
                    }),
          ),
          const SizedBox(height: 6),
          Text(
            _kind == _ExportKind.kmz
                ? 'Se abre en Google Earth, QGIS y ArcGIS.'
                : 'Todas las fotos en un ZIP, por capa, con un CSV de '
                    'coordenadas.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          if (_kind == _ExportKind.kmz) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _includeMedia,
              onChanged: _exporting
                  ? null
                  : (value) => setState(() => _includeMedia = value),
              title: const Text('Incluir fotos y videos'),
              subtitle: const Text(
                'Las fotos se ven dentro del globo. El archivo pesa bastante '
                'más.',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _includeTracks,
              onChanged: _exporting
                  ? null
                  : (value) => setState(() => _includeTracks = value),
              title: const Text('Incluir recorridos'),
              subtitle: const Text('Los tracks grabados por GPS.'),
            ),
          ] else
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _includeVideos,
              onChanged: _exporting
                  ? null
                  : (value) => setState(() => _includeVideos = value),
              title: const Text('Incluir videos'),
              subtitle: const Text('Aumentan mucho el tamaño del ZIP.'),
            ),
          const SizedBox(height: 8),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_result case final result?) ...[
            _ResultCard(result: result),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _share(result),
              icon: const Icon(Icons.share),
              label: const Text('Compartir'),
            ),
          ] else
            FilledButton.icon(
              onPressed: _exporting ? null : _export,
              icon: _exporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_alt),
              label: Text(_exporting ? 'Exportando…' : 'Exportar'),
            ),
        ],
      ),
    );
  }

  Future<void> _export() async {
    setState(() {
      _exporting = true;
      _error = null;
    });

    try {
      final documents = await getApplicationDocumentsDirectory();
      // La fecha en el nombre evita pisar exportaciones anteriores, que es lo
      // que uno quiere al ir sacando versiones del mismo levantamiento.
      final stamp = DateFormat('yyyy-MM-dd_HHmm').format(DateTime.now());
      final isKmz = _kind == _ExportKind.kmz;
      final output = File(
        p.join(
          documents.path,
          'exports',
          '${sanitizeFileName(widget.project.name)}_$stamp'
              '${isKmz ? '.kmz' : '_fotos.zip'}',
        ),
      );

      final service = ref.read(exportServiceProvider);
      final result = isKmz
          ? await service.exportProjectToKmz(
              project: widget.project,
              output: output,
              includeMedia: _includeMedia,
              includeTracks: _includeTracks,
            )
          : await service.exportPhotosToZip(
              project: widget.project,
              output: output,
              includeVideos: _includeVideos,
            );

      if (mounted) setState(() => _result = result);
    } catch (error) {
      if (mounted) setState(() => _error = 'No se pudo exportar: $error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _share(ExportResult result) async {
    await Share.shareXFiles(
      [
        XFile(
          result.file.path,
          mimeType: _kind == _ExportKind.kmz
              ? 'application/vnd.google-earth.kmz'
              : 'application/zip',
        ),
      ],
      subject: widget.project.name,
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final ExportResult result;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle, color: scheme.onSecondaryContainer),
                const SizedBox(width: 8),
                Text(
                  'Exportado',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${result.placemarkCount} elementos · '
              '${result.mediaCount} archivos · ${result.sizeLabel}',
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
            const SizedBox(height: 4),
            Text(
              p.basename(result.file.path),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
            ),
            if (result.skippedMedia.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                // Se avisa en lugar de fallar: perder el KMZ entero por una
                // foto borrada a mano sería peor.
                '${result.skippedMedia.length} archivos no se encontraron y '
                'quedaron fuera.',
                style: TextStyle(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

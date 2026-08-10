/// Flujo de importación de un KMZ o KML.
///
/// Antes de tocar nada muestra qué trae el archivo y deja elegir qué capas
/// importar: un KMZ ajeno puede traer decenas de carpetas y rara vez se
/// quieren todas.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/kmz_import_service.dart';
import '../../geo/geometry/geometry.dart';
import '../../geo/import/kml_import_models.dart';
import '../providers.dart';

/// Devuelve cuántos elementos se importaron.
Future<int> importKmzFlow(
  BuildContext context,
  WidgetRef ref,
  String projectId,
) async {
  final picked = await FilePicker.platform.pickFiles(
    type: FileType.any,
    dialogTitle: 'Elegí un KMZ o KML',
  );

  final path = picked?.files.singleOrNull?.path;
  if (path == null) return 0;

  final extension = path.toLowerCase();
  if (!extension.endsWith('.kmz') && !extension.endsWith('.kml')) {
    if (!context.mounted) return 0;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Elegí un archivo .kmz o .kml')),
    );
    return 0;
  }

  final file = File(path);

  if (!context.mounted) return 0;
  final analysis = await showDialog<KmzAnalysis>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AnalyzingDialog(file: file),
  );
  if (analysis == null || !context.mounted) return 0;

  if (!analysis.isReadable) {
    await _showMessage(context, 'No se pudo leer el archivo', analysis.error!);
    return 0;
  }

  if (analysis.featureCount == 0) {
    await _showMessage(
      context,
      'Sin elementos que importar',
      'El archivo no contiene puntos, líneas ni polígonos.'
          '${analysis.warnings.isEmpty ? '' : '\n\n${analysis.warnings.join('\n')}'}',
    );
    return 0;
  }

  final imported = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (_, controller) => _LayerChooser(
        projectId: projectId,
        file: file,
        analysis: analysis,
        scrollController: controller,
      ),
    ),
  );

  return imported ?? 0;
}

class _AnalyzingDialog extends ConsumerStatefulWidget {
  const _AnalyzingDialog({required this.file});

  final File file;

  @override
  ConsumerState<_AnalyzingDialog> createState() => _AnalyzingDialogState();
}

class _AnalyzingDialogState extends ConsumerState<_AnalyzingDialog> {
  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final analysis =
        await ref.read(kmzImportServiceProvider).analyze(widget.file);
    if (mounted) Navigator.of(context).pop(analysis);
  }

  @override
  Widget build(BuildContext context) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('Leyendo el archivo…')),
          ],
        ),
      );
}

class _LayerChooser extends ConsumerStatefulWidget {
  const _LayerChooser({
    required this.projectId,
    required this.file,
    required this.analysis,
    required this.scrollController,
  });

  final String projectId;
  final File file;
  final KmzAnalysis analysis;
  final ScrollController scrollController;

  @override
  ConsumerState<_LayerChooser> createState() => _LayerChooserState();
}

class _LayerChooserState extends ConsumerState<_LayerChooser> {
  late final Set<ImportedLayer> _selected =
      widget.analysis.layers.toSet();
  bool _importImages = true;
  bool _importing = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _selected.fold<int>(
      0,
      (sum, layer) => sum + layer.features.length,
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.analysis.documentName ?? 'Importar',
                style: theme.textTheme.titleLarge,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                '${widget.analysis.layers.length} capas · '
                '${widget.analysis.featureCount} elementos'
                '${widget.analysis.mediaCount > 0 ? ' · ${widget.analysis.mediaCount} archivos' : ''}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            controller: widget.scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final warning in widget.analysis.warnings)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          warning,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              for (final layer in widget.analysis.layers)
                CheckboxListTile(
                  value: _selected.contains(layer),
                  onChanged: _importing
                      ? null
                      : (checked) => setState(() {
                            if (checked ?? false) {
                              _selected.add(layer);
                            } else {
                              _selected.remove(layer);
                            }
                          }),
                  secondary: Icon(
                    switch (layer.geometryType) {
                      GeometryType.point => Icons.place,
                      GeometryType.line => Icons.polyline,
                      GeometryType.polygon => Icons.pentagon_outlined,
                    },
                    color: Color(layer.color ?? 0xFF1E88E5),
                  ),
                  title: Text(layer.name),
                  subtitle: Text(
                    '${layer.features.length} '
                    '${layer.features.length == 1 ? 'elemento' : 'elementos'}',
                  ),
                ),
              if (widget.analysis.mediaCount > 0)
                SwitchListTile(
                  value: _importImages,
                  onChanged: _importing
                      ? null
                      : (value) => setState(() => _importImages = value),
                  title: const Text('Importar las fotos del archivo'),
                  subtitle: const Text(
                    'Las que los globos referencian se adjuntan a su elemento.',
                  ),
                ),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: FilledButton.icon(
              onPressed: _selected.isEmpty || _importing ? null : _import,
              icon: _importing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              label: Text(
                _importing
                    ? 'Importando…'
                    : 'Importar $total ${total == 1 ? 'elemento' : 'elementos'}',
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _import() async {
    setState(() => _importing = true);

    try {
      final count = await ref.read(kmzImportServiceProvider).import(
            projectId: widget.projectId,
            source: widget.file,
            // Se respeta el orden original del archivo, no el de selección.
            layers: widget.analysis.layers
                .where(_selected.contains)
                .toList(),
            importImages: _importImages,
          );

      if (mounted) Navigator.of(context).pop(count);
    } catch (error) {
      if (!mounted) return;
      setState(() => _importing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo importar: $error')),
      );
    }
  }
}

Future<void> _showMessage(
  BuildContext context,
  String title,
  String body,
) =>
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );

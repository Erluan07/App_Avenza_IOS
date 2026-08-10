/// Flujo de importación de un GeoPDF a un proyecto.
///
/// Antes de copiar nada muestra qué encontró en el archivo: qué páginas están
/// georreferenciadas, en qué CRS y a qué escala. Si algo no cuadra, es mejor
/// que el usuario lo vea aquí que descubrirlo en campo.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/geopdf_import_service.dart';
import '../providers.dart';

/// Devuelve `true` si se importó algo.
Future<bool> importGeoPdfFlow(
  BuildContext context,
  WidgetRef ref,
  String projectId,
) async {
  final picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['pdf'],
    dialogTitle: 'Elegí un GeoPDF',
  );

  final path = picked?.files.singleOrNull?.path;
  if (path == null) return false;
  final file = File(path);

  if (!context.mounted) return false;
  final analysis = await showDialog<GeoPdfAnalysis>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AnalyzingDialog(file: file),
  );
  if (analysis == null || !context.mounted) return false;

  if (!analysis.isReadable) {
    await _showMessage(context, 'No se pudo leer el PDF', analysis.error!);
    return false;
  }

  if (!analysis.hasAnyGeoreference) {
    await _showMessage(
      context,
      'El PDF no está georreferenciado',
      analysis.pages
          .map((p) => 'Página ${p.index + 1}: ${p.issueLabel}')
          .join('\n'),
    );
    return false;
  }

  final georeferenced =
      analysis.pages.where((page) => page.isGeoreferenced).toList();

  final chosen = georeferenced.length == 1
      ? georeferenced.single
      : await showModalBottomSheet<GeoPdfPageOption>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          builder: (_) => _PageChooser(pages: georeferenced),
        );

  if (chosen == null || !context.mounted) return false;

  await ref.read(importServiceProvider).import(
        projectId: projectId,
        source: file,
        page: chosen,
      );
  return true;
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
    final analysis = await ref.read(importServiceProvider).analyze(widget.file);
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
            Expanded(child: Text('Analizando el PDF…')),
          ],
        ),
      );
}

class _PageChooser extends StatelessWidget {
  const _PageChooser({required this.pages});

  final List<GeoPdfPageOption> pages;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Elegí la página a importar',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final page in pages)
              ListTile(
                leading: const Icon(Icons.map),
                title: Text(
                  'Página ${page.index + 1}'
                  '${page.viewportName != null ? ' — ${page.viewportName}' : ''}',
                ),
                subtitle: Text(
                  [
                    page.crsName ?? 'CRS desconocido',
                    if (page.scaleDenominator != null)
                      '1:${page.scaleDenominator!.round()}',
                  ].join(' · '),
                  maxLines: 2,
                ),
                trailing: page.hasWarnings
                    ? const Icon(Icons.warning_amber, color: Colors.orange)
                    : null,
                onTap: () => Navigator.of(context).pop(page),
              ),
          ],
        ),
      );
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

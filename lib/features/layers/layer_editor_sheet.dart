/// Creación de capas de captura.
///
/// Una capa fija un tipo de geometría, igual que un shapefile: así los
/// atributos y la simbología son coherentes dentro de ella.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../geo/geometry/geometry.dart';
import '../providers.dart';

/// Paleta de colores con buen contraste sobre cartografía impresa, que suele
/// tener fondos claros y muchas líneas finas.
const List<int> kLayerColors = [
  0xFFE53935, // rojo
  0xFFFB8C00, // naranja
  0xFFFDD835, // amarillo
  0xFF43A047, // verde
  0xFF00ACC1, // cian
  0xFF1E88E5, // azul
  0xFF8E24AA, // violeta
  0xFF6D4C41, // marrón
  0xFF212121, // negro
];

/// Muestra el formulario y devuelve la capa creada, o `null` si se canceló.
Future<FeatureLayer?> showLayerEditor(
  BuildContext context,
  String projectId,
) =>
    showModalBottomSheet<FeatureLayer>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: _LayerEditor(projectId: projectId),
      ),
    );

class _LayerEditor extends ConsumerStatefulWidget {
  const _LayerEditor({required this.projectId});

  final String projectId;

  @override
  ConsumerState<_LayerEditor> createState() => _LayerEditorState();
}

class _LayerEditorState extends ConsumerState<_LayerEditor> {
  final _nameController = TextEditingController();

  GeometryType _geometryType = GeometryType.point;
  int _color = kLayerColors.first;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Nueva capa', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _nameController,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Nombre',
              hintText: 'Ej.: Postes, Senderos, Predios',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          Text('Tipo de geometría',
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<GeometryType>(
            segments: const [
              ButtonSegment(
                value: GeometryType.point,
                icon: Icon(Icons.place),
                label: Text('Puntos'),
              ),
              ButtonSegment(
                value: GeometryType.line,
                icon: Icon(Icons.polyline),
                label: Text('Líneas'),
              ),
              ButtonSegment(
                value: GeometryType.polygon,
                icon: Icon(Icons.pentagon_outlined),
                label: Text('Polígonos'),
              ),
            ],
            selected: {_geometryType},
            onSelectionChanged: (values) =>
                setState(() => _geometryType = values.first),
          ),
          const SizedBox(height: 20),
          Text('Color', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final color in kLayerColors)
                _ColorChip(
                  color: color,
                  selected: color == _color,
                  onTap: () => setState(() => _color = color),
                ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _nameController.text.trim().isEmpty || _saving
                ? null
                : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: const Text('Crear capa'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);

    final layer = await ref.read(repositoryProvider).createLayer(
          projectId: widget.projectId,
          name: _nameController.text.trim(),
          geometryType: _geometryType,
          color: _color,
        );

    if (mounted) Navigator.of(context).pop(layer);
  }
}

class _ColorChip extends StatelessWidget {
  const _ColorChip({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final int color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Color(color),
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.onSurface
                  : Colors.transparent,
              width: 3,
            ),
          ),
          child: selected
              ? const Icon(Icons.check, color: Colors.white, size: 20)
              : null,
        ),
      );
}

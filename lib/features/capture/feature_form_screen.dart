/// Formulario de atributos de un elemento capturado, con su multimedia.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
// Uint8List llega vía services.dart, que reexporta dart:typed_data.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../data/db/database.dart';
import '../../data/models/enums.dart';
import '../../data/repositories/project_repository.dart';
import '../../geo/geometry/geometry.dart';
import '../../geo/measure/format.dart';
import '../../geo/photo/photo_metadata.dart';
import '../location/location_providers.dart';
import '../providers.dart';
import 'photo_stamper.dart';

/// Archivo elegido que todavía no está en la base: se copia al proyecto recién
/// cuando el elemento se guarda, para no dejar basura si el usuario cancela.
class _PendingMedia {
  const _PendingMedia(this.file, this.kind, {this.metadata, this.bytes});

  final File file;
  final AttachmentKind kind;

  /// Dónde y cuándo se tomó. Solo lo tienen las fotos hechas con la cámara
  /// dentro de la app: una imagen de galería se sacó en otro momento y no
  /// tenemos forma de saber su ubicación.
  final PhotoMetadata? metadata;

  /// Bytes ya estampados, listos para escribir.
  final Uint8List? bytes;
}

class FeatureFormScreen extends ConsumerStatefulWidget {
  const FeatureFormScreen({
    required this.projectId,
    required this.layer,
    required this.geometry,
    this.gpsAccuracy,
    super.key,
  });

  final String projectId;
  final FeatureLayer layer;
  final Geometry geometry;
  final double? gpsAccuracy;

  @override
  ConsumerState<FeatureFormScreen> createState() => _FeatureFormScreenState();
}

class _FeatureFormScreenState extends ConsumerState<FeatureFormScreen> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _attributes = <String, Object?>{};
  final _pendingMedia = <_PendingMedia>[];

  bool _saving = false;

  /// La foto se está estampando. Bloquea el guardado para no perder el
  /// procesado a medio hacer.
  bool _processing = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fields = ref.watch(fieldsProvider(widget.layer.id)).valueOrNull ??
        const <FieldDef>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nuevo elemento'),
        actions: [
          TextButton.icon(
            onPressed: _saving || _processing ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: const Text('Guardar'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _GeometrySummary(
            layer: widget.layer,
            geometry: widget.geometry,
            gpsAccuracy: widget.gpsAccuracy,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _nameController,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Nombre',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descriptionController,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Descripción',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          if (fields.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              'Atributos de la capa',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            for (final field in fields) ...[
              _FieldInput(
                field: field,
                value: _attributes[field.key],
                onChanged: (value) =>
                    setState(() => _attributes[field.key] = value),
              ),
              const SizedBox(height: 12),
            ],
          ],
          const SizedBox(height: 24),
          Text('Multimedia', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          _MediaPicker(
            items: _pendingMedia,
            processing: _processing,
            onAdd: _addMedia,
            onRemove: (index) => setState(() => _pendingMedia.removeAt(index)),
          ),
        ],
      ),
    );
  }

  Future<void> _addMedia(AttachmentKind kind, ImageSource source) async {
    final picker = ImagePicker();

    // La posición y el rumbo se leen **antes** de abrir la cámara: mientras el
    // usuario encuadra puede haberse movido, y lo que interesa es dónde estaba
    // al decidir la toma.
    final position = ref.read(userPositionProvider).valueOrNull;
    final heading = ref.read(headingProvider).valueOrNull;

    // El redimensionado se delega a image_picker, que lo hace con código
    // nativo en milisegundos. Hacerlo después en Dart obligaría a decodificar
    // los 12 MP completos —unos 48 MB en memoria— y en una build de debug eso
    // tarda decenas de segundos.
    final XFile? picked = kind == AttachmentKind.video
        ? await picker.pickVideo(source: source)
        : await picker.pickImage(
            source: source,
            maxWidth: kMaxPhotoWidth.toDouble(),
            maxHeight: kMaxPhotoWidth.toDouble(),
            imageQuality: 92,
          );

    if (picked == null) return;
    final file = File(picked.path);

    // Los videos no se estampan: habría que reencodarlos entero, que en un
    // teléfono es lento y destruye calidad. Sus metadatos sí se guardan.
    if (kind != AttachmentKind.foto) {
      setState(() => _pendingMedia.add(_PendingMedia(file, kind)));
      return;
    }

    // Una foto de galería no se sacó aquí ni ahora: sellarla con la posición
    // actual sería inventar un dato.
    final fromCamera = source == ImageSource.camera;
    final metadata = fromCamera
        ? PhotoMetadata(
            capturedAt: DateTime.now(),
            position: position?.latLon,
            accuracyMeters: position?.accuracyMeters,
            elevationMeters: position?.altitudeMeters,
            headingDegrees: heading,
          )
        : null;

    if (metadata == null) {
      setState(() => _pendingMedia.add(_PendingMedia(file, kind)));
      return;
    }

    setState(() => _processing = true);

    StampedPhoto? result;
    Object? failure;

    try {
      final bytes = await file.readAsBytes();
      try {
        // El procesado va en otro isolate: decodificar y reencodar bloquearía
        // la interfaz. Se llama a una función de nivel superior para que el
        // closure no arrastre `this`, que no es transferible entre isolates.
        result = await Isolate.run(() => stampPhoto(bytes, metadata))
            // Red de seguridad: sin tope, un fallo dentro del isolate dejaría
            // el formulario colgado para siempre.
            .timeout(const Duration(seconds: 45));
      } catch (isolateError) {
        // Segundo intento en el hilo principal. Congela la interfaz un
        // instante, pero es preferible a quedarse sin sello: si el fallo era
        // del transporte al isolate y no del procesado, aquí funciona.
        debugPrint('Estampado en isolate falló: $isolateError');
        result = stampPhoto(bytes, metadata);
      }
    } catch (error, stack) {
      failure = error;
      debugPrint('Estampado falló por completo: $error\n$stack');
    }

    if (!mounted) return;
    setState(() {
      _processing = false;
      _pendingMedia.add(
        _PendingMedia(file, kind, metadata: metadata, bytes: result?.bytes),
      );
    });

    if (failure != null) {
      // Se muestra el motivo real: sin poder depurar en el dispositivo, es la
      // única forma de saber qué falló.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            'La foto se guarda sin sello (sus datos de ubicación sí quedan). '
            'Motivo: $failure',
          ),
        ),
      );
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final repository = ref.read(repositoryProvider);

    try {
      final feature = await repository.createFeature(
        layerId: widget.layer.id,
        geometry: widget.geometry,
        name: _nameController.text.trim().isEmpty
            ? null
            : _nameController.text.trim(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        attributes: Map.of(_attributes)..removeWhere((_, v) => v == null),
        gpsAccuracy: widget.gpsAccuracy,
      );

      // Los adjuntos se copian ahora, ya con el id del elemento.
      for (final media in _pendingMedia) {
        await repository.addAttachment(
          projectId: widget.projectId,
          featureId: feature.id,
          source: media.file,
          kind: media.kind,
          bytes: media.bytes,
          capturedAt: media.metadata?.capturedAt,
          position: media.metadata?.position,
          accuracy: media.metadata?.accuracyMeters,
          elevation: media.metadata?.elevationMeters,
          heading: media.metadata?.headingDegrees,
        );
      }

      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo guardar: $error')),
      );
    }
  }
}

class _GeometrySummary extends StatelessWidget {
  const _GeometrySummary({
    required this.layer,
    required this.geometry,
    this.gpsAccuracy,
  });

  final FeatureLayer layer;
  final Geometry geometry;
  final double? gpsAccuracy;

  @override
  Widget build(BuildContext context) {
    final centroid = geometry.centroid;

    final details = <String>[
      switch (geometry) {
        PointGeometry() => 'Punto',
        LineGeometry(:final points) =>
          'Línea · ${points.length} vértices · ${formatDistance(geometry.lengthMeters)}',
        PolygonGeometry(:final ring) =>
          'Polígono · ${ring.length} vértices · ${formatArea(geometry.areaMeters2)}',
      },
      '${formatLatLon(centroid.latitude)}, ${formatLatLon(centroid.longitude)}',
      if (gpsAccuracy != null) 'Precisión ${formatAccuracy(gpsAccuracy!)}',
    ];

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(
          switch (layer.geometryType) {
            GeometryType.point => Icons.place,
            GeometryType.line => Icons.polyline,
            GeometryType.polygon => Icons.pentagon_outlined,
          },
          color: Color(layer.color),
        ),
        title: Text(layer.name),
        subtitle: Text(details.join('\n')),
        isThreeLine: details.length > 2,
      ),
    );
  }
}

class _FieldInput extends StatelessWidget {
  const _FieldInput({
    required this.field,
    required this.value,
    required this.onChanged,
  });

  final FieldDef field;
  final Object? value;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = field.required ? '${field.label} *' : field.label;

    return switch (field.type) {
      FieldType.booleano => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          value: value as bool? ?? false,
          onChanged: onChanged,
        ),
      FieldType.lista => DropdownButtonFormField<String>(
          initialValue: value as String?,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          items: [
            for (final option in field.options)
              DropdownMenuItem(value: option, child: Text(option)),
          ],
          onChanged: onChanged,
        ),
      FieldType.fecha => _DateField(
          label: label,
          value: value as String?,
          onChanged: onChanged,
        ),
      FieldType.entero || FieldType.numero => TextFormField(
          initialValue: value?.toString(),
          keyboardType: TextInputType.numberWithOptions(
            decimal: field.type == FieldType.numero,
            signed: true,
          ),
          inputFormatters: [
            FilteringTextInputFormatter.allow(
              field.type == FieldType.numero
                  ? RegExp(r'^-?\d*[.,]?\d*')
                  : RegExp(r'^-?\d*'),
            ),
          ],
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          onChanged: (text) {
            final normalized = text.replaceAll(',', '.');
            onChanged(
              field.type == FieldType.entero
                  ? int.tryParse(normalized)
                  : double.tryParse(normalized),
            );
          },
        ),
      FieldType.texto => TextFormField(
          initialValue: value as String?,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          onChanged: onChanged,
        ),
    };
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context) {
    final parsed = value == null ? null : DateTime.tryParse(value!);

    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: parsed ?? DateTime.now(),
          firstDate: DateTime(1900),
          lastDate: DateTime(2200),
        );
        // Se guarda en ISO 8601 para que ordene bien y no dependa del idioma.
        if (picked != null) onChanged(picked.toIso8601String());
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: const Icon(Icons.calendar_today, size: 18),
        ),
        child: Text(
          parsed == null
              ? 'Sin fecha'
              : DateFormat('d MMM y', 'es').format(parsed),
        ),
      ),
    );
  }
}

class _MediaPicker extends StatelessWidget {
  const _MediaPicker({
    required this.items,
    required this.processing,
    required this.onAdd,
    required this.onRemove,
  });

  final List<_PendingMedia> items;
  final bool processing;
  final void Function(AttachmentKind, ImageSource) onAdd;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.photo_camera, size: 18),
                label: const Text('Foto'),
                onPressed: processing
                    ? null
                    : () => onAdd(AttachmentKind.foto, ImageSource.camera),
              ),
              ActionChip(
                avatar: const Icon(Icons.photo_library, size: 18),
                label: const Text('Galería'),
                onPressed: processing
                    ? null
                    : () => onAdd(AttachmentKind.foto, ImageSource.gallery),
              ),
              ActionChip(
                avatar: const Icon(Icons.videocam, size: 18),
                label: const Text('Video'),
                onPressed: processing
                    ? null
                    : () => onAdd(AttachmentKind.video, ImageSource.camera),
              ),
            ],
          ),
          if (processing)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text('Sellando fecha y ubicación…'),
                ],
              ),
            ),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) => _MediaThumb(
                media: items[index],
                onRemove: () => onRemove(index),
              ),
            ),
          ],
        ],
      );
}

class _MediaThumb extends StatelessWidget {
  const _MediaThumb({required this.media, required this.onRemove});

  final _PendingMedia media;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: media.kind == AttachmentKind.foto
                // Se muestran los bytes procesados cuando existen, para que la
                // miniatura enseñe el sello tal como quedará guardado.
                ? (media.bytes != null
                    ? Image.memory(media.bytes!, fit: BoxFit.cover)
                    : Image.file(media.file, fit: BoxFit.cover))
                : ColoredBox(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Center(
                      child: Icon(Icons.play_circle_outline, size: 32),
                    ),
                  ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: Material(
              color: Colors.black54,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 16, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      );
}

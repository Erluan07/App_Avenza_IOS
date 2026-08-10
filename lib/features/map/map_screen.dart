/// Visor del mapa: dibuja los GeoPDF georreferenciados, las capas capturadas
/// y la posición del usuario en vivo.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../data/db/database.dart';
import '../../data/repositories/project_repository.dart';
import '../../geo/geometry/geometry.dart';
import '../../geo/geometry/primitives.dart';
import '../../geo/measure/format.dart';
import 'dart:math' as math;

import 'package:intl/intl.dart';

import '../../geo/geometry/hit_test.dart';
import '../../ui/app_theme.dart';
import '../capture/capture_state.dart';
import '../capture/capture_toolbar.dart';
import '../capture/feature_detail_sheet.dart';
import '../capture/feature_form_screen.dart';
import '../export/export_sheet.dart';
import '../import/import_kmz_sheet.dart';
import '../layers/layer_editor_sheet.dart';
import '../measure/measure_controller.dart';
import '../measure/measure_layer.dart';
import '../measure/measure_panel.dart';
import '../tracks/recording_panel.dart';
import '../tracks/track_recorder.dart';
import '../location/location_providers.dart';
import '../location/location_service.dart';
import '../providers.dart';
import 'capture_layer.dart';
import 'import_geopdf_sheet.dart';
import 'layers_panel.dart';
import 'location_layer.dart';
import 'map_conversions.dart';
import 'north_arrow.dart';
import 'track_layer.dart';

/// Cómo sigue el mapa a la posición del usuario.
enum FollowMode {
  /// El mapa no se mueve solo.
  libre,

  /// Se centra en la posición, manteniendo el norte arriba.
  centrado,

  /// Se centra y además gira para que el rumbo del teléfono quede hacia
  /// arriba. Es el modo útil caminando: lo que ves delante queda arriba.
  brujula;

  IconData get icon => switch (this) {
        FollowMode.libre => Icons.my_location,
        FollowMode.centrado => Icons.gps_fixed,
        FollowMode.brujula => Icons.explore,
      };

  String get label => switch (this) {
        FollowMode.libre => 'Centrar en mi posición',
        FollowMode.centrado => 'Siguiendo mi posición · tocá para orientar',
        FollowMode.brujula => 'Orientado a mi rumbo · tocá para liberar',
      };

  FollowMode get next => switch (this) {
        FollowMode.libre => FollowMode.centrado,
        FollowMode.centrado => FollowMode.brujula,
        FollowMode.brujula => FollowMode.libre,
      };
}

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({required this.project, super.key});

  final Project project;

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final MapController _controller = MapController();

  /// El encuadre inicial se hace una sola vez: si se repitiera en cada
  /// reconstrucción, el mapa saltaría cada vez que el usuario lo mueve.
  bool _didFitInitially = false;

  bool _showOnlineBasemap = true;
  FollowMode _followMode = FollowMode.libre;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseMaps = ref.watch(baseMapsProvider(widget.project.id));
    final layers = ref.watch(layersProvider(widget.project.id));

    // Mover la cámara al llegar cada posición nueva, sin reconstruir el mapa.
    ref.listen(userPositionProvider, (_, next) {
      final position = next.valueOrNull;
      if (position != null) _applyFollow(position);
    });
    ref.listen(headingProvider, (_, next) {
      if (_followMode == FollowMode.brujula && next.valueOrNull != null) {
        _controller.rotate(-next.valueOrNull!);
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.project.name),
        actions: [
          IconButton(
            tooltip: _showOnlineBasemap
                ? 'Ocultar mapa base en línea'
                : 'Mostrar mapa base en línea',
            icon: Icon(_showOnlineBasemap ? Icons.public : Icons.public_off),
            onPressed: () =>
                setState(() => _showOnlineBasemap = !_showOnlineBasemap),
          ),
          IconButton(
            tooltip: 'Encuadrar en el contenido',
            icon: const Icon(Icons.fit_screen),
            onPressed: () => _fitToContent(baseMaps.valueOrNull ?? const []),
          ),
          IconButton(
            tooltip: 'Capas',
            icon: const Icon(Icons.layers),
            onPressed: () => _openLayersPanel(context),
          ),
          PopupMenuButton<String>(
            onSelected: (value) => switch (value) {
              'importar' => _importGeoPdf(),
              'importarKmz' => _importKmz(),
              'grabar' => _startTrack(),
              'detener' => _stopTrack(),
              'exportar' => showExportSheet(context, widget.project),
              _ => null,
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'importar',
                child: ListTile(
                  leading: Icon(Icons.note_add_outlined),
                  title: Text('Importar GeoPDF'),
                ),
              ),
              const PopupMenuItem(
                value: 'importarKmz',
                child: ListTile(
                  leading: Icon(Icons.folder_zip_outlined),
                  title: Text('Importar KMZ / KML'),
                ),
              ),
              if (ref.read(trackRecorderProvider).isRecording)
                const PopupMenuItem(
                  value: 'detener',
                  child: ListTile(
                    leading: Icon(Icons.stop_circle_outlined),
                    title: Text('Terminar recorrido'),
                  ),
                )
              else
                const PopupMenuItem(
                  value: 'grabar',
                  child: ListTile(
                    leading: Icon(Icons.fiber_manual_record),
                    title: Text('Grabar recorrido'),
                  ),
                ),
              const PopupMenuItem(
                value: 'exportar',
                child: ListTile(
                  leading: Icon(Icons.ios_share),
                  title: Text('Exportar a KMZ'),
                ),
              ),
            ],
          ),
        ],
      ),
      // Mientras se mide o se captura mandan los paneles de la barra inferior:
      // dejar los flotantes encima solo estorbaría.
      floatingActionButton:
          ref.watch(isCapturingProvider) || ref.watch(isMeasuringProvider)
              ? null
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _FollowButton(
                      mode: _followMode,
                      onPressed: _cycleFollowMode,
                    ),
                    const SizedBox(height: 12),
                    FloatingActionButton.small(
                      heroTag: 'medir',
                      tooltip: 'Medir distancia o área',
                      backgroundColor: context.appColors.measure,
                      foregroundColor: Colors.white,
                      onPressed: _startMeasuring,
                      child: const Icon(Icons.straighten),
                    ),
                    const SizedBox(height: 12),
                    FloatingActionButton.extended(
                      heroTag: 'capturar',
                      onPressed: _startCapture,
                      icon: const Icon(Icons.add_location_alt),
                      label: const Text('Capturar'),
                    ),
                  ],
                ),
      body: baseMaps.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorBox(message: '$error'),
        data: (maps) {
          _scheduleInitialFit(maps);
          return Stack(
            children: [
              FlutterMap(
                mapController: _controller,
                options: MapOptions(
                  initialCenter: _fallbackCenter,
                  initialZoom: 3,
                  minZoom: 2,
                  // Tope necesario: más allá, la imagen del GeoPDF se
                  // transforma a un tamaño que el motor gráfico ya no puede
                  // rasterizar y el mapa desaparece de golpe. A 4096 px la
                  // resolución nativa se agota cerca del zoom 17,5, así que de
                  // 20 para arriba solo se ampliaría desenfoque.
                  maxZoom: 20,
                  // La rotación va habilitada: en campo es útil orientar el
                  // mapa hacia donde uno camina.
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all,
                  ),
                  onPositionChanged: _onPositionChanged,
                  onTap: _onMapTap,
                ),
                children: [
                  if (_showOnlineBasemap)
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName:
                          'com.avenzapobres.avenza_para_pobres',
                      maxNativeZoom: 19,
                    ),
                  ..._buildBaseMapOverlays(maps),
                  ...layers.maybeWhen(
                    data: _buildFeatureLayers,
                    orElse: () => const <Widget>[],
                  ),
                  TrackLayer(projectId: widget.project.id),
                  const CaptureLayer(),
                  const MeasureLayer(),
                  const LocationLayer(),
                  NorthArrow(onTap: _resetRotation),
                  const _Attribution(),
                ],
              ),
              const Align(
                alignment: Alignment.bottomLeft,
                child: _LocationStatusBanner(),
              ),
              CaptureToolbar(onFinish: _finishCapture),
              const MeasurePanel(),
              RecordingPanel(onStop: _stopTrack),
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Seguimiento de la posición
  // ---------------------------------------------------------------------------

  void _cycleFollowMode() {
    final next = _followMode.next;
    setState(() => _followMode = next);

    if (next == FollowMode.libre) return;

    final position = ref.read(userPositionProvider).valueOrNull;
    if (position == null) return;
    _applyFollow(position, zoomIn: true);
  }

  void _applyFollow(UserPosition position, {bool zoomIn = false}) {
    if (_followMode == FollowMode.libre) return;

    final target = LatLng(position.latitude, position.longitude);
    // Al activar el seguimiento conviene acercar; después se respeta el zoom
    // que el usuario haya elegido.
    final zoom = zoomIn
        ? (_controller.camera.zoom < 16 ? 17.0 : _controller.camera.zoom)
        : _controller.camera.zoom;

    if (_followMode == FollowMode.brujula) {
      final heading = ref.read(headingProvider).valueOrNull;
      if (heading != null) {
        // Rotar el mapa en sentido contrario al rumbo deja lo que el usuario
        // tiene delante en la parte de arriba de la pantalla.
        _controller.moveAndRotate(target, zoom, -heading);
        return;
      }
    }

    _controller.move(target, zoom);
  }

  /// Un gesto del usuario cancela el seguimiento: si el mapa siguiera
  /// recentrándose solo, sería imposible mirar los alrededores.
  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    if (hasGesture && _followMode != FollowMode.libre) {
      setState(() => _followMode = FollowMode.libre);
    }
  }

  void _resetRotation() {
    _controller.rotate(0);
    if (_followMode == FollowMode.brujula) {
      setState(() => _followMode = FollowMode.centrado);
    }
  }

  // ---------------------------------------------------------------------------
  // Recorridos
  // ---------------------------------------------------------------------------

  Future<void> _startTrack() async {
    final suggested =
        'Recorrido ${DateFormat('d MMM HH:mm', 'es').format(DateTime.now())}';

    final name = await showDialog<String>(
      context: context,
      builder: (_) => _TrackNameDialog(initialValue: suggested),
    );
    if (name == null || !mounted) return;

    await ref.read(trackRecorderProvider.notifier).start(
          projectId: widget.project.id,
          name: name.trim().isEmpty ? suggested : name.trim(),
        );

    // Seguir la posición mientras se graba es lo que uno espera: si no, el
    // recorrido crece fuera de la pantalla.
    if (mounted && _followMode == FollowMode.libre) {
      setState(() => _followMode = FollowMode.centrado);
    }
  }

  Future<void> _stopTrack() async {
    final recorder = ref.read(trackRecorderProvider.notifier);
    final state = ref.read(trackRecorderProvider);
    if (!state.isRecording) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('¿Terminar el recorrido?'),
        content: Text(
          'Llevás ${formatDistance(state.distanceMeters)} en '
          '${state.points.length} puntos.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Seguir grabando'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Terminar'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) await recorder.stop();
  }

  // ---------------------------------------------------------------------------
  // Captura
  // ---------------------------------------------------------------------------

  void _onMapTap(TapPosition _, LatLng point) {
    if (ref.read(isMeasuringProvider)) {
      ref.read(measureControllerProvider.notifier).addVertex(point.toLatLon);
      return;
    }
    if (ref.read(isCapturingProvider)) {
      // Un toque en el mapa no trae precisión asociada: el vértice queda donde
      // el usuario apuntó, no donde está el GPS.
      ref.read(captureControllerProvider.notifier).addVertex(point.toLatLon);
      return;
    }
    _openFeatureAt(point.toLatLon);
  }

  void _startMeasuring() {
    // Medir y capturar comparten los toques del mapa: no pueden convivir.
    ref.read(captureControllerProvider.notifier).cancel();
    ref.read(measureControllerProvider.notifier).open();
  }

  /// Abre la ficha del elemento más cercano al toque, si hay alguno a tiro.
  Future<void> _openFeatureAt(LatLon tap) async {
    final layers = ref.read(layersProvider(widget.project.id)).valueOrNull ??
        const <FeatureLayer>[];
    if (layers.isEmpty) return;

    // La tolerancia se fija en píxeles y se traduce a metros con el zoom
    // actual: un dedo tapa lo mismo en pantalla, pero muchos más metros de
    // terreno cuando el mapa está alejado.
    final metersPerPixel = 156543.03392 *
        math.cos(tap.latitude * math.pi / 180) /
        math.pow(2, _controller.camera.zoom);
    final tolerance = metersPerPixel * 24;

    MapFeature? best;
    FeatureLayer? bestLayer;
    var bestDistance = double.infinity;

    for (final layer in layers.where((l) => l.visible)) {
      final features = ref.read(featuresProvider(layer.id)).valueOrNull;
      if (features == null) continue;

      for (final feature in features) {
        final geometry = feature.geometry;
        if (geometry == null) continue;

        final distance =
            hitDistance(geometry, tap, toleranceMeters: tolerance);
        if (distance != null && distance < bestDistance) {
          best = feature;
          bestLayer = layer;
          bestDistance = distance;
        }
      }
    }

    if (best == null || bestLayer == null || !mounted) return;

    await showFeatureDetail(
      context,
      projectId: widget.project.id,
      feature: best,
      layer: bestLayer,
      onLocate: (target) =>
          _controller.move(target.toLatLng, _controller.camera.zoom),
    );
  }

  Future<void> _startCapture() async {
    // Capturar y medir comparten los toques del mapa: cerrar la medición al
    // empezar a capturar evita que un toque haga las dos cosas.
    ref.read(measureControllerProvider.notifier).close();

    final layers = ref.read(layersProvider(widget.project.id)).valueOrNull ??
        const <FeatureLayer>[];

    final layer = layers.isEmpty
        ? await showLayerEditor(context, widget.project.id)
        : await _pickLayer(layers);

    if (layer == null || !mounted) return;

    ref.read(captureControllerProvider.notifier).start(
          layerId: layer.id,
          layerName: layer.name,
          geometryType: layer.geometryType,
          color: layer.color,
        );

    // Si la capa estaba oculta, capturar sin verla sería desconcertante.
    if (!layer.visible) {
      await ref.read(repositoryProvider).setLayerVisible(layer.id, visible: true);
    }
  }

  Future<FeatureLayer?> _pickLayer(List<FeatureLayer> layers) =>
      showModalBottomSheet<FeatureLayer>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '¿En qué capa?',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              for (final layer in layers)
                ListTile(
                  leading: Icon(
                    switch (layer.geometryType) {
                      GeometryType.point => Icons.place,
                      GeometryType.line => Icons.polyline,
                      GeometryType.polygon => Icons.pentagon_outlined,
                    },
                    color: Color(layer.color),
                  ),
                  title: Text(layer.name),
                  onTap: () => Navigator.of(sheetContext).pop(layer),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Nueva capa'),
                onTap: () async {
                  final created =
                      await showLayerEditor(sheetContext, widget.project.id);
                  if (sheetContext.mounted) {
                    Navigator.of(sheetContext).pop(created);
                  }
                },
              ),
            ],
          ),
        ),
      );

  Future<void> _finishCapture() async {
    final session = ref.read(captureControllerProvider);
    final geometry = session?.geometry;
    if (session == null || geometry == null) return;

    final layers = ref.read(layersProvider(widget.project.id)).valueOrNull;
    final layer = layers?.where((l) => l.id == session.layerId).firstOrNull;
    if (layer == null) return;

    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FeatureFormScreen(
          projectId: widget.project.id,
          layer: layer,
          geometry: geometry,
          gpsAccuracy: session.bestAccuracy,
        ),
      ),
    );

    // Solo se cierra la sesión si de verdad se guardó: si el usuario vuelve
    // atrás, la geometría que acaba de trazar sigue ahí.
    if ((saved ?? false) && mounted) {
      ref.read(captureControllerProvider.notifier).cancel();
    }
  }

  // ---------------------------------------------------------------------------
  // Mapas base (GeoPDF)
  // ---------------------------------------------------------------------------

  List<Widget> _buildBaseMapOverlays(List<BaseMap> maps) {
    final images = <BaseOverlayImage>[];

    for (final map in maps.where((m) => m.visible)) {
      final raster = ref.watch(baseMapRasterProvider(map)).valueOrNull;
      if (raster == null) continue;

      // Tres esquinas bastan: la georreferencia es afín, así que la cuarta
      // queda determinada.
      images.add(
        RotatedOverlayImage(
          imageProvider: FileImage(raster.file),
          topLeftCorner: raster.topLeft.toLatLng,
          bottomLeftCorner: raster.bottomLeft.toLatLng,
          bottomRightCorner: raster.bottomRight.toLatLng,
          opacity: map.opacity,
          filterQuality: FilterQuality.medium,
        ),
      );
    }

    if (images.isEmpty) return const [];
    return [OverlayImageLayer(overlayImages: images)];
  }

  // ---------------------------------------------------------------------------
  // Capas capturadas
  // ---------------------------------------------------------------------------

  List<Widget> _buildFeatureLayers(List<FeatureLayer> layers) {
    final polygons = <Polygon>[];
    final polylines = <Polyline>[];
    final markers = <Marker>[];

    for (final layer in layers.where((l) => l.visible)) {
      final features = ref.watch(featuresProvider(layer.id)).valueOrNull;
      if (features == null) continue;

      final color = Color(layer.color);

      for (final feature in features) {
        final geometry = feature.geometry;
        switch (geometry) {
          case PolygonGeometry(:final ring):
            polygons.add(
              Polygon(
                points: ring.toLatLngList,
                color: color.withValues(alpha: 0.25),
                borderColor: color,
                borderStrokeWidth: 2,
              ),
            );
          case LineGeometry(:final points):
            polylines.add(
              Polyline(
                points: points.toLatLngList,
                color: color,
                strokeWidth: 3,
              ),
            );
          case PointGeometry(:final position):
            markers.add(
              Marker(
                point: position.toLatLng,
                width: 32,
                height: 32,
                alignment: Alignment.topCenter,
                // Los chinches se mantienen verticales aunque el mapa gire.
                rotate: true,
                child: Icon(Icons.place, color: color, size: 32),
              ),
            );
          case null:
            break;
        }
      }
    }

    return [
      if (polygons.isNotEmpty) PolygonLayer(polygons: polygons),
      if (polylines.isNotEmpty) PolylineLayer(polylines: polylines),
      if (markers.isNotEmpty) MarkerLayer(markers: markers),
    ];
  }

  // ---------------------------------------------------------------------------
  // Encuadre
  // ---------------------------------------------------------------------------

  void _scheduleInitialFit(List<BaseMap> maps) {
    if (_didFitInitially || maps.isEmpty) return;
    _didFitInitially = true;

    // Tras el primer frame: el mapa todavía no conoce su tamaño mientras
    // estamos dentro de build().
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitToContent(maps);
    });
  }

  void _fitToContent(List<BaseMap> maps) {
    final visible = maps.where((m) => m.visible).toList();
    if (visible.isEmpty) return;

    var south = double.infinity;
    var west = double.infinity;
    var north = double.negativeInfinity;
    var east = double.negativeInfinity;

    for (final map in visible) {
      south = map.coverageSouth < south ? map.coverageSouth : south;
      west = map.coverageWest < west ? map.coverageWest : west;
      north = map.coverageNorth > north ? map.coverageNorth : north;
      east = map.coverageEast > east ? map.coverageEast : east;
    }

    if (!south.isFinite || !west.isFinite) return;

    _controller.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds(
          LatLon(south, west).toLatLng,
          LatLon(north, east).toLatLng,
        ),
        padding: const EdgeInsets.all(24),
      ),
    );
  }

  Future<void> _importKmz() async {
    final imported = await importKmzFlow(context, ref, widget.project.id);
    if (imported == 0 || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Se importaron $imported '
          '${imported == 1 ? 'elemento' : 'elementos'}.',
        ),
      ),
    );
    // Las capas nuevas pueden caer lejos de donde está el mapa ahora.
    await _fitToImported();
  }

  /// Encuadra en todo lo capturado del proyecto, tras importar.
  Future<void> _fitToImported() async {
    final layers = ref.read(layersProvider(widget.project.id)).valueOrNull;
    if (layers == null) return;

    var south = double.infinity;
    var west = double.infinity;
    var north = double.negativeInfinity;
    var east = double.negativeInfinity;

    for (final layer in layers.where((l) => l.visible)) {
      final features = ref.read(featuresProvider(layer.id)).valueOrNull;
      if (features == null) continue;

      for (final feature in features) {
        final bounds = feature.geometry?.bounds;
        if (bounds == null || !bounds.isValid) continue;
        if (bounds.south < south) south = bounds.south;
        if (bounds.west < west) west = bounds.west;
        if (bounds.north > north) north = bounds.north;
        if (bounds.east > east) east = bounds.east;
      }
    }

    if (!south.isFinite || !west.isFinite) return;

    _controller.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds(
          LatLon(south, west).toLatLng,
          LatLon(north, east).toLatLng,
        ),
        padding: const EdgeInsets.all(32),
      ),
    );
  }

  Future<void> _importGeoPdf() async {
    final imported = await importGeoPdfFlow(context, ref, widget.project.id);
    // Tras importar el primero conviene encuadrar: si no, el mapa se queda
    // mirando el centro por defecto y parece que no pasó nada.
    if (imported) _didFitInitially = false;
  }

  Future<void> _openLayersPanel(BuildContext context) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => LayersPanel(
          projectId: widget.project.id,
          onLocate: (target) =>
              _controller.move(target.toLatLng, _controller.camera.zoom),
        ),
      );
}

/// Centro por defecto mientras no hay ningún mapa cargado.
const LatLng _fallbackCenter = LatLng(4.6, -74.1);

class _TrackNameDialog extends StatefulWidget {
  const _TrackNameDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_TrackNameDialog> createState() => _TrackNameDialogState();
}

class _TrackNameDialogState extends State<_TrackNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Grabar recorrido'),
        content: TextField(
          controller: _controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Nombre',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(_controller.text),
            icon: const Icon(Icons.fiber_manual_record, size: 16),
            label: const Text('Empezar'),
          ),
        ],
      );
}

class _FollowButton extends StatelessWidget {
  const _FollowButton({required this.mode, required this.onPressed});

  final FollowMode mode;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = mode != FollowMode.libre;

    return FloatingActionButton(
      onPressed: onPressed,
      tooltip: mode.label,
      backgroundColor: active ? scheme.primary : scheme.surfaceContainerHighest,
      foregroundColor: active ? scheme.onPrimary : scheme.onSurfaceVariant,
      child: Icon(mode.icon),
    );
  }
}

/// Avisa cuando no hay ubicación disponible y ofrece la acción para arreglarlo.
class _LocationStatusBanner extends ConsumerWidget {
  const _LocationStatusBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final availability = ref.watch(locationAvailabilityProvider).valueOrNull;
    if (availability == null ||
        availability == LocationAvailability.disponible) {
      return const SizedBox.shrink();
    }

    final service = ref.read(locationServiceProvider);
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Material(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () async {
              if (availability == LocationAvailability.servicioApagado) {
                await service.openLocationSettings();
              } else {
                await service.openSystemSettings();
              }
              ref.invalidate(locationAvailabilityProvider);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.location_off, color: scheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      availability.mensaje,
                      style: TextStyle(color: scheme.onErrorContainer),
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

class _Attribution extends StatelessWidget {
  const _Attribution();

  @override
  Widget build(BuildContext context) => const RichAttributionWidget(
        attributions: [
          TextSourceAttribution('OpenStreetMap contributors'),
        ],
      );
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      );
}

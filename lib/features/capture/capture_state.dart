/// Estado de una captura en curso.
///
/// Vive fuera del widget del mapa a propósito: la barra de captura, la capa de
/// dibujo y el formulario de atributos necesitan el mismo estado, y pasarlo por
/// constructores acabaría en un enredo.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../geo/geometry/geometry.dart';
import '../../geo/geometry/primitives.dart';
import '../../geo/measure/geodesy.dart';

class CaptureSession {
  const CaptureSession({
    required this.layerId,
    required this.layerName,
    required this.geometryType,
    required this.color,
    this.vertices = const [],
    this.accuracies = const [],
  });

  final String layerId;
  final String layerName;
  final GeometryType geometryType;
  final int color;

  final List<LatLon> vertices;

  /// Precisión del GPS de cada vértice tomado con el botón de ubicación.
  /// `null` en los puestos tocando el mapa.
  final List<double?> accuracies;

  CaptureSession copyWith({
    List<LatLon>? vertices,
    List<double?>? accuracies,
  }) =>
      CaptureSession(
        layerId: layerId,
        layerName: layerName,
        geometryType: geometryType,
        color: color,
        vertices: vertices ?? this.vertices,
        accuracies: accuracies ?? this.accuracies,
      );

  /// Vértices mínimos para que la geometría tenga sentido.
  int get minimumVertices => switch (geometryType) {
        GeometryType.point => 1,
        GeometryType.line => 2,
        GeometryType.polygon => 3,
      };

  bool get canFinish => vertices.length >= minimumVertices;

  Geometry? get geometry => switch (geometryType) {
        GeometryType.point =>
          vertices.isEmpty ? null : PointGeometry(vertices.first),
        GeometryType.line =>
          vertices.length < 2 ? null : LineGeometry(List.of(vertices)),
        GeometryType.polygon =>
          vertices.length < 3 ? null : PolygonGeometry(List.of(vertices)),
      };

  /// Longitud del trazado tal como va, sin cerrar el anillo. Es lo que
  /// interesa ver mientras se camina el perímetro.
  double get lengthMeters => vertices.length < 2 ? 0 : pathLength(vertices);

  /// Área del polígono en curso. Los anillos de menos de tres vértices no
  /// encierran nada.
  double get areaMeters2 =>
      geometryType == GeometryType.polygon && vertices.length >= 3
          ? ringArea(vertices)
          : 0;

  double get perimeterMeters =>
      geometryType == GeometryType.polygon && vertices.length >= 3
          ? ringPerimeter(vertices)
          : lengthMeters;

  /// Mejor precisión registrada, para guardarla junto al elemento.
  double? get bestAccuracy {
    final valid = accuracies.whereType<double>();
    if (valid.isEmpty) return null;
    return valid.reduce((a, b) => a < b ? a : b);
  }
}

class CaptureController extends Notifier<CaptureSession?> {
  @override
  CaptureSession? build() => null;

  void start({
    required String layerId,
    required String layerName,
    required GeometryType geometryType,
    required int color,
  }) {
    state = CaptureSession(
      layerId: layerId,
      layerName: layerName,
      geometryType: geometryType,
      color: color,
    );
  }

  void addVertex(LatLon position, {double? accuracy}) {
    final current = state;
    if (current == null) return;

    // Un punto solo tiene un vértice: volver a tocar lo reubica en lugar de
    // acumular vértices que nunca se usarían.
    if (current.geometryType == GeometryType.point) {
      state = current.copyWith(vertices: [position], accuracies: [accuracy]);
      return;
    }

    state = current.copyWith(
      vertices: [...current.vertices, position],
      accuracies: [...current.accuracies, accuracy],
    );
  }

  void undo() {
    final current = state;
    if (current == null || current.vertices.isEmpty) return;

    state = current.copyWith(
      vertices: current.vertices.sublist(0, current.vertices.length - 1),
      accuracies: current.accuracies.isEmpty
          ? const []
          : current.accuracies.sublist(0, current.accuracies.length - 1),
    );
  }

  void clearVertices() {
    final current = state;
    if (current == null) return;
    state = current.copyWith(vertices: const [], accuracies: const []);
  }

  void cancel() => state = null;
}

final captureControllerProvider =
    NotifierProvider<CaptureController, CaptureSession?>(CaptureController.new);

/// `true` mientras haya una captura abierta. Lo consulta el mapa para saber si
/// debe interpretar los toques como vértices.
final isCapturingProvider = Provider<bool>(
  (ref) => ref.watch(captureControllerProvider) != null,
);

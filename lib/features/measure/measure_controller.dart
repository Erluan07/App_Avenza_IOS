/// Herramienta de medición rápida.
///
/// A diferencia de la captura, no crea ninguna capa ni guarda nada: es para
/// medir sobre la marcha y salir. El estado vive solo mientras la herramienta
/// está abierta.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../geo/geometry/primitives.dart';
import '../../geo/measure/geodesy.dart';

enum MeasureMode {
  distancia,
  area;

  String get label => switch (this) {
        MeasureMode.distancia => 'Distancia',
        MeasureMode.area => 'Área',
      };
}

class MeasureState {
  const MeasureState({
    this.mode = MeasureMode.distancia,
    this.vertices = const [],
  });

  final MeasureMode mode;
  final List<LatLon> vertices;

  MeasureState copyWith({MeasureMode? mode, List<LatLon>? vertices}) =>
      MeasureState(
        mode: mode ?? this.mode,
        vertices: vertices ?? this.vertices,
      );

  /// Longitud del trazado abierto, en metros.
  double get lengthMeters => vertices.length < 2 ? 0 : pathLength(vertices);

  /// Longitud del último tramo, para ir viendo cuánto suma cada punto.
  double get lastSegmentMeters => vertices.length < 2
      ? 0
      : vincentyDistance(
          vertices[vertices.length - 2],
          vertices.last,
        );

  /// Área encerrada, solo en modo área y con al menos tres vértices.
  double get areaMeters2 =>
      mode == MeasureMode.area && vertices.length >= 3
          ? ringArea(vertices)
          : 0;

  /// Perímetro cerrado en modo área; en modo distancia, la longitud abierta.
  double get perimeterMeters => mode == MeasureMode.area && vertices.length >= 3
      ? ringPerimeter(vertices)
      : lengthMeters;

  /// Puntos medios de cada tramo, para colocar la etiqueta de su distancia.
  List<({LatLon at, double meters})> get segments {
    final result = <({LatLon at, double meters})>[];
    for (var i = 1; i < vertices.length; i++) {
      final a = vertices[i - 1];
      final b = vertices[i];
      result.add((
        at: LatLon(
          (a.latitude + b.latitude) / 2,
          (a.longitude + b.longitude) / 2,
        ),
        meters: vincentyDistance(a, b),
      ));
    }
    return result;
  }
}

class MeasureController extends Notifier<MeasureState?> {
  @override
  MeasureState? build() => null;

  void open([MeasureMode mode = MeasureMode.distancia]) {
    state = MeasureState(mode: mode);
  }

  void setMode(MeasureMode mode) {
    final current = state;
    if (current == null) return;
    state = current.copyWith(mode: mode);
  }

  void addVertex(LatLon position) {
    final current = state;
    if (current == null) return;
    state = current.copyWith(vertices: [...current.vertices, position]);
  }

  void undo() {
    final current = state;
    if (current == null || current.vertices.isEmpty) return;
    state = current.copyWith(
      vertices: current.vertices.sublist(0, current.vertices.length - 1),
    );
  }

  void clear() {
    final current = state;
    if (current == null) return;
    state = current.copyWith(vertices: const []);
  }

  void close() => state = null;
}

final measureControllerProvider =
    NotifierProvider<MeasureController, MeasureState?>(MeasureController.new);

/// `true` mientras la herramienta de medición está abierta. Lo consulta el
/// mapa para saber si un toque agrega un punto de medición.
final isMeasuringProvider = Provider<bool>(
  (ref) => ref.watch(measureControllerProvider) != null,
);

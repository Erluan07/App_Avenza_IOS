/// Tests de la herramienta de medición.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:avenza_para_pobres/features/measure/measure_controller.dart';
import 'package:avenza_para_pobres/geo/geometry/primitives.dart';

void main() {
  group('Estado de medición', () {
    test('sin dos puntos la distancia es cero', () {
      const vacio = MeasureState();
      expect(vacio.lengthMeters, 0);
      expect(
        const MeasureState(vertices: [LatLon(6.24, -75.53)]).lengthMeters,
        0,
      );
    });

    test('suma la distancia de todos los tramos', () {
      const state = MeasureState(vertices: [
        LatLon(6.240, -75.535),
        LatLon(6.241, -75.535),
        LatLon(6.242, -75.535),
      ]);

      // Dos tramos de ~111 m cada uno.
      expect(state.lengthMeters, closeTo(222, 5));
    });

    test('el último tramo mide solo el segmento final', () {
      const state = MeasureState(vertices: [
        LatLon(6.240, -75.535),
        LatLon(6.241, -75.535),
        LatLon(6.242, -75.535),
      ]);
      expect(state.lastSegmentMeters, closeTo(111, 3));
    });

    test('el área solo existe en modo área con tres o más vértices', () {
      const ring = [
        LatLon(6.240, -75.535),
        LatLon(6.240, -75.534),
        LatLon(6.241, -75.534),
        LatLon(6.241, -75.535),
      ];

      // En modo distancia no hay área aunque sobren vértices.
      expect(
        const MeasureState(mode: MeasureMode.distancia, vertices: ring)
            .areaMeters2,
        0,
      );
      expect(
        const MeasureState(mode: MeasureMode.area, vertices: ring).areaMeters2,
        greaterThan(10000),
      );
    });

    test('genera un punto medio y una distancia por tramo', () {
      const state = MeasureState(vertices: [
        LatLon(6.240, -75.535),
        LatLon(6.242, -75.535),
      ]);

      final segments = state.segments;
      expect(segments, hasLength(1));
      // El punto medio cae a mitad de camino en latitud.
      expect(segments.first.at.latitude, closeTo(6.241, 1e-9));
      expect(segments.first.meters, closeTo(222, 6));
    });
  });

  group('Controlador', () {
    late ProviderContainer container;
    late MeasureController controller;

    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
      controller = container.read(measureControllerProvider.notifier);
    });

    MeasureState? read() => container.read(measureControllerProvider);

    test('arranca cerrado', () {
      expect(read(), isNull);
      expect(container.read(isMeasuringProvider), isFalse);
    });

    test('abrir y cerrar alternan el estado', () {
      controller.open();
      expect(container.read(isMeasuringProvider), isTrue);
      controller.close();
      expect(read(), isNull);
    });

    test('acumula vértices y los deshace', () {
      controller.open();
      controller.addVertex(const LatLon(6.24, -75.53));
      controller.addVertex(const LatLon(6.25, -75.54));
      expect(read()!.vertices, hasLength(2));

      controller.undo();
      expect(read()!.vertices, hasLength(1));

      controller.clear();
      expect(read()!.vertices, isEmpty);
    });

    test('cambiar de modo no pierde los vértices', () {
      controller.open();
      controller.addVertex(const LatLon(6.24, -75.53));
      controller.setMode(MeasureMode.area);

      expect(read()!.mode, MeasureMode.area);
      expect(read()!.vertices, hasLength(1));
    });

    test('deshacer sin vértices no rompe', () {
      controller.open();
      controller.undo();
      expect(read()!.vertices, isEmpty);
    });
  });
}

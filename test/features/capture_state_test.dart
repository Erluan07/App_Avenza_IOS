/// Tests del estado de captura.
///
/// Usa `flutter_test` porque `capture_state.dart` depende de Riverpod, que
/// arrastra Flutter.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:avenza_para_pobres/features/capture/capture_state.dart';
import 'package:avenza_para_pobres/geo/geometry/geometry.dart';
import 'package:avenza_para_pobres/geo/geometry/primitives.dart';

CaptureSession sessionOf(GeometryType type) => CaptureSession(
      layerId: 'capa-1',
      layerName: 'Prueba',
      geometryType: type,
      color: 0xFFE53935,
    );

void main() {
  group('Requisitos mínimos', () {
    test('cada tipo exige su número de vértices', () {
      expect(sessionOf(GeometryType.point).minimumVertices, 1);
      expect(sessionOf(GeometryType.line).minimumVertices, 2);
      expect(sessionOf(GeometryType.polygon).minimumVertices, 3);
    });

    test('una geometría incompleta no se puede construir', () {
      final line = sessionOf(GeometryType.line)
          .copyWith(vertices: const [LatLon(6.24, -75.53)]);

      expect(line.canFinish, isFalse);
      expect(line.geometry, isNull);
    });

    test('un polígono necesita tres vértices para encerrar algo', () {
      final polygon = sessionOf(GeometryType.polygon).copyWith(
        vertices: const [LatLon(6.240, -75.535), LatLon(6.240, -75.534)],
      );

      expect(polygon.canFinish, isFalse);
      expect(polygon.areaMeters2, 0);
    });
  });

  group('Medidas en curso', () {
    test('la línea acumula longitud a medida que crece', () {
      final dos = sessionOf(GeometryType.line).copyWith(
        vertices: const [LatLon(6.240, -75.535), LatLon(6.241, -75.535)],
      );
      final tres = dos.copyWith(
        vertices: [...dos.vertices, const LatLon(6.242, -75.535)],
      );

      expect(dos.lengthMeters, greaterThan(100));
      expect(tres.lengthMeters, greaterThan(dos.lengthMeters));
    });

    test('el polígono reporta área y perímetro', () {
      final polygon = sessionOf(GeometryType.polygon).copyWith(
        vertices: const [
          LatLon(6.240, -75.535),
          LatLon(6.240, -75.534),
          LatLon(6.241, -75.534),
          LatLon(6.241, -75.535),
        ],
      );

      // ~110 m de lado.
      expect(polygon.areaMeters2, greaterThan(10000));
      expect(polygon.areaMeters2, lessThan(15000));
      // El perímetro cierra el anillo, así que supera a la longitud abierta.
      expect(polygon.perimeterMeters, greaterThan(polygon.lengthMeters));
    });

    test('una línea no tiene área', () {
      final line = sessionOf(GeometryType.line).copyWith(
        vertices: const [
          LatLon(6.240, -75.535),
          LatLon(6.241, -75.534),
          LatLon(6.242, -75.533),
        ],
      );
      expect(line.areaMeters2, 0);
    });
  });

  group('Controlador', () {
    late ProviderContainer container;
    late CaptureController controller;

    setUp(() {
      // Un Notifier de Riverpod necesita estar montado en un contenedor: no
      // se le puede asignar `state` suelto.
      container = ProviderContainer();
      addTearDown(container.dispose);
      controller = container.read(captureControllerProvider.notifier);
    });

    void startWith(GeometryType type) => controller.start(
          layerId: 'capa-1',
          layerName: 'Prueba',
          geometryType: type,
          color: 0xFFE53935,
        );

    CaptureSession session() => container.read(captureControllerProvider)!;

    test('arranca sin sesión abierta', () {
      expect(container.read(captureControllerProvider), isNull);
      expect(container.read(isCapturingProvider), isFalse);
    });

    test('iniciar abre la sesión', () {
      startWith(GeometryType.point);
      expect(container.read(isCapturingProvider), isTrue);
      expect(session().layerName, 'Prueba');
    });

    test('un punto se reubica en lugar de acumular vértices', () {
      startWith(GeometryType.point);

      controller.addVertex(const LatLon(6.24, -75.53));
      controller.addVertex(const LatLon(6.25, -75.54));

      expect(session().vertices, hasLength(1));
      expect(session().vertices.single.latitude, 6.25);
    });

    test('una línea sí acumula', () {
      startWith(GeometryType.line);

      controller.addVertex(const LatLon(6.24, -75.53));
      controller.addVertex(const LatLon(6.25, -75.54));

      expect(session().vertices, hasLength(2));
    });

    test('deshacer quita el último vértice y su precisión', () {
      startWith(GeometryType.line);
      controller.addVertex(const LatLon(6.24, -75.53), accuracy: 5);
      controller.addVertex(const LatLon(6.25, -75.54), accuracy: 8);

      controller.undo();

      expect(session().vertices, hasLength(1));
      expect(session().accuracies, hasLength(1));
      expect(session().accuracies.single, 5);
    });

    test('deshacer sin vértices no rompe nada', () {
      startWith(GeometryType.line);
      controller.undo();
      expect(session().vertices, isEmpty);
    });

    test('se guarda la mejor precisión registrada', () {
      startWith(GeometryType.line);
      controller.addVertex(const LatLon(6.24, -75.53), accuracy: 12);
      controller.addVertex(const LatLon(6.25, -75.54), accuracy: 4);
      controller.addVertex(const LatLon(6.26, -75.55));

      expect(session().bestAccuracy, 4);
    });

    test('sin ninguna lectura de GPS no se inventa precisión', () {
      startWith(GeometryType.line);
      controller.addVertex(const LatLon(6.24, -75.53));

      expect(session().bestAccuracy, isNull);
    });

    test('cancelar cierra la sesión', () {
      startWith(GeometryType.point);
      controller.cancel();
      expect(container.read(captureControllerProvider), isNull);
      expect(container.read(isCapturingProvider), isFalse);
    });
  });
}

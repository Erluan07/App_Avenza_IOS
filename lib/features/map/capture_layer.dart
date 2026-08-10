/// Dibuja la geometría que se está capturando, antes de guardarla.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../geo/geometry/geometry.dart';
import '../capture/capture_state.dart';
import 'map_conversions.dart';

class CaptureLayer extends ConsumerWidget {
  const CaptureLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(captureControllerProvider);
    if (session == null || session.vertices.isEmpty) {
      return const SizedBox.shrink();
    }

    final color = Color(session.color);
    final points = session.vertices.toLatLngList;
    final isPolygon = session.geometryType == GeometryType.polygon;

    return Stack(
      children: [
        // El polígono se previsualiza cerrado aunque falte confirmar, para que
        // se vea la superficie que realmente se está encerrando.
        if (isPolygon && points.length >= 3)
          PolygonLayer(
            polygons: [
              Polygon(
                points: points,
                color: color.withValues(alpha: 0.2),
                borderColor: color,
                borderStrokeWidth: 2,
              ),
            ],
          ),
        if (points.length >= 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points: isPolygon ? [...points, points.first] : points,
                color: color,
                strokeWidth: 3,
              ),
            ],
          ),
        MarkerLayer(
          markers: [
            for (var i = 0; i < points.length; i++)
              Marker(
                point: points[i],
                width: 18,
                height: 18,
                rotate: true,
                child: _Vertex(
                  color: color,
                  // El último vértice va marcado: es el que deshace "Deshacer".
                  isLast: i == points.length - 1,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Vertex extends StatelessWidget {
  const _Vertex({required this.color, required this.isLast});

  final Color color;
  final bool isLast;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: isLast ? Colors.white : color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isLast ? color : Colors.white,
            width: isLast ? 4 : 2,
          ),
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 3),
          ],
        ),
      );
}

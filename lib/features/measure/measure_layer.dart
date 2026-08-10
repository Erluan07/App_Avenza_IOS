/// Dibujo de la medición en curso: trazado, vértices y etiquetas de tramo.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../geo/measure/format.dart';
import '../../ui/app_theme.dart';
import '../map/map_conversions.dart';
import 'measure_controller.dart';

class MeasureLayer extends ConsumerWidget {
  const MeasureLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(measureControllerProvider);
    if (state == null || state.vertices.isEmpty) {
      return const SizedBox.shrink();
    }

    final color = context.appColors.measure;
    final points = state.vertices.toLatLngList;
    final isArea = state.mode == MeasureMode.area;

    return Stack(
      children: [
        if (isArea && points.length >= 3)
          PolygonLayer(
            polygons: [
              Polygon(
                points: points,
                color: color.withValues(alpha: 0.18),
                borderColor: color,
                borderStrokeWidth: 2,
              ),
            ],
          ),
        if (points.length >= 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points: isArea ? [...points, points.first] : points,
                color: color,
                strokeWidth: 3,
              ),
            ],
          ),
        MarkerLayer(
          markers: [
            // Etiqueta de distancia en el medio de cada tramo.
            for (final segment in state.segments)
              Marker(
                point: segment.at.toLatLng,
                width: 88,
                height: 26,
                rotate: true,
                child: _SegmentLabel(
                  text: formatDistance(segment.meters),
                  color: color,
                ),
              ),
            for (final point in points)
              Marker(
                point: point,
                width: 16,
                height: 16,
                rotate: true,
                child: _Vertex(color: color),
              ),
          ],
        ),
      ],
    );
  }
}

class _Vertex extends StatelessWidget {
  const _Vertex({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 3),
        ),
      );
}

class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
}

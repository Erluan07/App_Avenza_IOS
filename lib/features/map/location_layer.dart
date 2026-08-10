/// Capa que dibuja al usuario sobre el mapa: punto, círculo de precisión y
/// cono de orientación.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Solo LatLng: latlong2 exporta además un `Path<LatLng>` que taparía el Path
// de dart:ui que usa el CustomPainter de más abajo.
import 'package:latlong2/latlong.dart' show LatLng;

import '../location/location_providers.dart';

class LocationLayer extends ConsumerWidget {
  const LocationLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(userPositionProvider).valueOrNull;
    if (position == null) return const SizedBox.shrink();

    final heading = ref.watch(headingProvider).valueOrNull;
    final point = LatLng(position.latitude, position.longitude);
    final scheme = Theme.of(context).colorScheme;

    // El color del punto comunica la calidad de la señal: en campo saber que
    // el GPS está en 40 m evita capturar un punto donde no es.
    final color = position.esPrecisa
        ? scheme.primary
        : position.esAceptable
            ? Colors.orange
            : Colors.redAccent;

    return Stack(
      children: [
        CircleLayer(
          circles: [
            CircleMarker(
              point: point,
              radius: position.accuracyMeters,
              useRadiusInMeter: true,
              color: color.withValues(alpha: 0.12),
              borderColor: color.withValues(alpha: 0.45),
              borderStrokeWidth: 1,
            ),
          ],
        ),
        MarkerLayer(
          markers: [
            if (heading != null)
              Marker(
                point: point,
                width: 88,
                height: 88,
                // El rumbo es una dirección geográfica, así que el cono debe
                // girar junto con el mapa, no mantenerse fijo a la pantalla.
                rotate: false,
                child: Transform.rotate(
                  angle: heading * math.pi / 180,
                  child: CustomPaint(painter: _HeadingConePainter(color)),
                ),
              ),
            Marker(
              point: point,
              width: 24,
              height: 24,
              child: _PositionDot(color: color),
            ),
          ],
        ),
      ],
    );
  }
}

class _PositionDot extends StatelessWidget {
  const _PositionDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [
            BoxShadow(color: Colors.black38, blurRadius: 4, spreadRadius: 1),
          ],
        ),
      );
}

/// Cono difuminado que indica hacia dónde apunta el teléfono.
class _HeadingConePainter extends CustomPainter {
  const _HeadingConePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Apertura de ±25°, centrada hacia arriba (el 0 de la rotación aplicada).
    const halfSweep = 25 * math.pi / 180;
    const start = -math.pi / 2 - halfSweep;

    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color.withValues(alpha: 0.55), color.withValues(alpha: 0)],
      ).createShader(rect);

    canvas.drawPath(
      Path()
        ..moveTo(center.dx, center.dy)
        ..arcTo(rect, start, halfSweep * 2, false)
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(_HeadingConePainter oldDelegate) =>
      oldDelegate.color != color;
}

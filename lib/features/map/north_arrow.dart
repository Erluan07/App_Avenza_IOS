/// Rosa de los vientos que indica dónde queda el norte cuando el mapa está
/// girado. Al tocarla, el mapa vuelve a norte arriba.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

class NorthArrow extends StatelessWidget {
  const NorthArrow({required this.onTap, super.key});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // El mapa aplica esta misma rotación a su contenido, así que girando la
    // rosa lo mismo, su aguja acaba apuntando al norte real en pantalla.
    final rotation = MapCamera.of(context).rotationRad;
    final isNorthUp = rotation.abs() < 0.005;
    final scheme = Theme.of(context).colorScheme;

    return Align(
      alignment: Alignment.topRight,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            color: scheme.surface.withValues(alpha: 0.88),
            shape: const CircleBorder(),
            elevation: 3,
            child: Tooltip(
              message: isNorthUp
                  ? 'El mapa está orientado al norte'
                  : 'Volver a norte arriba',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: SizedBox(
                  width: 46,
                  height: 46,
                  child: Transform.rotate(
                    angle: rotation,
                    child: CustomPaint(
                      painter: _CompassRosePainter(
                        northColor: Colors.redAccent,
                        southColor: scheme.onSurfaceVariant,
                        labelColor: scheme.onSurface,
                        // Atenuada mientras el mapa ya está al norte: así solo
                        // llama la atención cuando de verdad está girado.
                        opacity: isNorthUp ? 0.45 : 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CompassRosePainter extends CustomPainter {
  const _CompassRosePainter({
    required this.northColor,
    required this.southColor,
    required this.labelColor,
    required this.opacity,
  });

  final Color northColor;
  final Color southColor;
  final Color labelColor;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 7;
    const halfWidth = 0.16; // media anchura de la aguja, en radianes

    void needle(double pointAngle, Color color) {
      final tip = center + Offset.fromDirection(pointAngle, radius);
      final left = center + Offset.fromDirection(pointAngle + math.pi / 2, radius * halfWidth);
      final right = center + Offset.fromDirection(pointAngle - math.pi / 2, radius * halfWidth);

      canvas.drawPath(
        Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(left.dx, left.dy)
          ..lineTo(right.dx, right.dy)
          ..close(),
        Paint()..color = color.withValues(alpha: opacity),
      );
    }

    // -pi/2 es hacia arriba en el sistema de coordenadas del canvas.
    needle(-math.pi / 2, northColor);
    needle(math.pi / 2, southColor);

    final label = TextPainter(
      text: TextSpan(
        text: 'N',
        style: TextStyle(
          color: labelColor.withValues(alpha: opacity),
          fontSize: 10,
          fontWeight: FontWeight.bold,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    label.paint(canvas, Offset(center.dx - label.width / 2, 0));
  }

  @override
  bool shouldRepaint(_CompassRosePainter oldDelegate) =>
      oldDelegate.opacity != opacity ||
      oldDelegate.northColor != northColor ||
      oldDelegate.labelColor != labelColor;
}

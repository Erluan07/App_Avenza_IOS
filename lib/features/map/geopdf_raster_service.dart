/// Rasterizado de la página de un GeoPDF para dibujarla sobre el mapa.
///
/// El PDF se rasteriza **una sola vez** y se cachea en disco junto al archivo
/// original: renderizar una A4 a 300 ppp tarda cerca de un segundo, y hacerlo
/// en cada apertura del mapa sería inaceptable en campo.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../geo/geometry/primitives.dart';
import '../../geo/transform/georeference.dart';
import '../../geo/transform/page_raster.dart';

/// Imagen ya recortada a la zona georreferenciada, con las esquinas que
/// necesita el mapa para colocarla.
class GeoPdfRaster {
  const GeoPdfRaster({
    required this.file,
    required this.topLeft,
    required this.bottomLeft,
    required this.bottomRight,
    required this.widthPx,
    required this.heightPx,
  });

  final File file;

  /// Esquinas de la imagen en coordenadas geográficas. Son tres porque una
  /// transformación afín queda determinada por tres puntos: la cuarta esquina
  /// se deduce.
  final LatLon topLeft;
  final LatLon bottomLeft;
  final LatLon bottomRight;

  final int widthPx;
  final int heightPx;
}

class GeoPdfRasterService {
  const GeoPdfRasterService();

  /// Lado mayor de la imagen rasterizada, en píxeles.
  ///
  /// 4096 px sobre una A4 son unos 495 ppp. El techo lo pone la memoria, no
  /// las ganas: a esta resolución el bitmap ocupa ~95 MB en RGBA, y durante la
  /// importación conviven el que genera PDFium y el que decodifica Flutter.
  /// Por eso el manifiesto pide `largeHeap`.
  ///
  /// Subir más obliga a renderizar por regiones bajo demanda en lugar de una
  /// imagen única (ver ARCHITECTURE.md §6).
  static const int defaultMaxDimension = 4096;

  /// Renderiza la página, la recorta a la zona georreferenciada y devuelve la
  /// imagen lista para el mapa. Si ya está cacheada, la reutiliza.
  Future<GeoPdfRaster> rasterize({
    required File pdf,
    required int pageIndex,
    required int pageRotate,
    required List<double> mediaBox,
    required GeoReference georeference,
    required File cacheFile,
    int maxDimension = defaultMaxDimension,
    int rotationAdjust = 0,
  }) async {
    final pageWidthPt = mediaBox[2] - mediaBox[0];
    final pageHeightPt = mediaBox[3] - mediaBox[1];

    // Se le preguntan al renderer sus propias dimensiones en vez de deducirlas
    // del MediaBox. Es la única forma fiable: unas plataformas aplican el
    // `/Rotate` de la página al rasterizar y otras no, y suponerlo hacía que
    // los mapas con rotación salieran girados.
    final measured = await _measurePage(pdf, pageIndex + 1);

    final rendererWidth = measured?.width ?? pageWidthPt;
    final rendererHeight = measured?.height ?? pageHeightPt;

    final scale = maxDimension /
        (rendererWidth > rendererHeight ? rendererWidth : rendererHeight);
    final fullWidth = (rendererWidth * scale).round();
    final fullHeight = (rendererHeight * scale).round();

    final effectiveRotation = _effectiveRotation(
      declared: pageRotate,
      rendererWidth: rendererWidth,
      rendererHeight: rendererHeight,
      pageWidthPt: pageWidthPt,
      pageHeightPt: pageHeightPt,
    );

    final raster = PageRasterMapping(
      mediaBox: mediaBox,
      // El ajuste manual permite corregir a mano lo que la detección no
      // acierte: hay PDF donde ni las proporciones lo delatan.
      rotate: (effectiveRotation + rotationAdjust) % 360,
      imageWidth: fullWidth.toDouble(),
      imageHeight: fullHeight.toDouble(),
    );

    // Zona georreferenciada, en píxeles de la imagen completa.
    final bbox = georeference.bbox;
    final corners = [
      raster.pageToPixel(Point2(bbox[0], bbox[1])),
      raster.pageToPixel(Point2(bbox[0], bbox[3])),
      raster.pageToPixel(Point2(bbox[2], bbox[3])),
      raster.pageToPixel(Point2(bbox[2], bbox[1])),
    ];

    var left = corners.first.x;
    var right = corners.first.x;
    var top = corners.first.y;
    var bottom = corners.first.y;
    for (final c in corners) {
      if (c.x < left) left = c.x;
      if (c.x > right) right = c.x;
      if (c.y < top) top = c.y;
      if (c.y > bottom) bottom = c.y;
    }

    left = left.clamp(0, fullWidth.toDouble());
    right = right.clamp(0, fullWidth.toDouble());
    top = top.clamp(0, fullHeight.toDouble());
    bottom = bottom.clamp(0, fullHeight.toDouble());

    final cropRect = Rect.fromLTRB(left, top, right, bottom);

    if (!cacheFile.existsSync()) {
      final bytes = await _renderPage(
        pdf: pdf,
        pageNumber: pageIndex + 1,
        width: fullWidth,
        height: fullHeight,
      );
      final cropped = await _crop(bytes, cropRect);
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(cropped, flush: true);
    }

    // Las esquinas se derivan del recorte en espacio de imagen, no del BBox
    // directamente: así el cálculo vale igual para páginas rotadas.
    LatLon cornerAt(double x, double y) =>
        georeference.pageToLatLon(raster.pixelToPage(Point2(x, y)));

    return GeoPdfRaster(
      file: cacheFile,
      topLeft: cornerAt(cropRect.left, cropRect.top),
      bottomLeft: cornerAt(cropRect.left, cropRect.bottom),
      bottomRight: cornerAt(cropRect.right, cropRect.bottom),
      widthPx: cropRect.width.round(),
      heightPx: cropRect.height.round(),
    );
  }

  /// Dimensiones que el renderer atribuye a la página, en sus propias
  /// unidades. `null` si no se pudo abrir.
  Future<({double width, double height})?> _measurePage(
    File pdf,
    int pageNumber,
  ) async {
    try {
      final document = await pdfx.PdfDocument.openFile(pdf.path);
      try {
        final page = await document.getPage(pageNumber);
        try {
          return (width: page.width, height: page.height);
        } finally {
          await page.close();
        }
      } finally {
        await document.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// Rotación que la imagen rasterizada trae **realmente** aplicada.
  ///
  /// Se deduce comparando la proporción que reporta el renderer con la del
  /// MediaBox: si vienen los lados intercambiados, el renderer aplicó el
  /// cuarto de vuelta; si coinciden, entregó la página sin rotar y el mapeo no
  /// debe compensar nada.
  ///
  /// Con 180 grados no hay nada que comparar —los lados no se intercambian—,
  /// así que se confía en lo declarado. Lo mismo con páginas cuadradas, donde
  /// las dos proporciones son idénticas.
  static int _effectiveRotation({
    required int declared,
    required double rendererWidth,
    required double rendererHeight,
    required double pageWidthPt,
    required double pageHeightPt,
  }) {
    if (declared != 90 && declared != 270) return declared;

    if (rendererWidth <= 0 ||
        rendererHeight <= 0 ||
        pageWidthPt <= 0 ||
        pageHeightPt <= 0) {
      return declared;
    }

    final rendered = rendererWidth / rendererHeight;
    final direct = pageWidthPt / pageHeightPt;
    final swapped = pageHeightPt / pageWidthPt;

    // Página cuadrada: ambas hipótesis encajan igual y no hay forma de
    // distinguirlas por tamaño.
    if ((direct - swapped).abs() < 0.001) return declared;

    final rendererSwapped =
        (rendered - swapped).abs() < (rendered - direct).abs();

    return rendererSwapped ? declared : 0;
  }

  Future<Uint8List> _renderPage({
    required File pdf,
    required int pageNumber,
    required int width,
    required int height,
  }) async {
    final document = await pdfx.PdfDocument.openFile(pdf.path);
    try {
      final page = await document.getPage(pageNumber);
      try {
        final image = await page.render(
          width: width.toDouble(),
          height: height.toDouble(),
          format: pdfx.PdfPageImageFormat.png,
          // Los mapas suelen tener fondo transparente; sin blanco de base
          // quedarían zonas negras al componer.
          backgroundColor: '#FFFFFF',
        );
        if (image == null) {
          throw StateError('No se pudo rasterizar la página $pageNumber');
        }
        return image.bytes;
      } finally {
        await page.close();
      }
    } finally {
      await document.close();
    }
  }

  /// Recorta usando el canvas de Flutter, para no sumar una dependencia de
  /// procesamiento de imagen solo por esto.
  Future<Uint8List> _crop(Uint8List pngBytes, Rect rect) async {
    final codec = await ui.instantiateImageCodec(pngBytes);
    final frame = await codec.getNextFrame();
    final source = frame.image;

    final width = rect.width.round();
    final height = rect.height.round();
    if (width <= 0 || height <= 0) return pngBytes;

    // Sin recorte que hacer: evitamos una recodificación innecesaria.
    if (width == source.width && height == source.height) {
      source.dispose();
      return pngBytes;
    }

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      source,
      rect,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );

    final picture = recorder.endRecording();
    final cropped = await picture.toImage(width, height);
    final data = await cropped.toByteData(format: ui.ImageByteFormat.png);

    picture.dispose();
    source.dispose();
    cropped.dispose();

    if (data == null) return pngBytes;
    return data.buffer.asUint8List();
  }
}

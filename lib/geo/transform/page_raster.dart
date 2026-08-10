/// Puente entre la imagen rasterizada de la página y el espacio de coordenadas
/// del PDF.
///
/// Son dos sistemas distintos y es fácil confundirlos:
/// - **Página PDF**: unidades de punto (1/72"), origen abajo-izquierda, Y hacia
///   arriba, desplazado según el `/MediaBox`.
/// - **Imagen**: píxeles, origen arriba-izquierda, Y hacia abajo.
///
/// [rotate] es la rotación que la imagen trae **realmente** aplicada, que no
/// tiene por qué ser el `/Rotate` declarado en el PDF: no todas las
/// plataformas lo aplican al rasterizar. Quien construye este objeto debe
/// determinarlo, no darlo por hecho — ver `GeoPdfRasterService`.
library;

import '../geometry/primitives.dart';
import 'georeference.dart';

class PageRasterMapping {
  const PageRasterMapping({
    required this.mediaBox,
    required this.rotate,
    required this.imageWidth,
    required this.imageHeight,
  });

  /// `[minX, minY, maxX, maxY]` en puntos PDF.
  final List<double> mediaBox;

  /// Rotación declarada de la página: 0, 90, 180 o 270 grados.
  final int rotate;

  final double imageWidth;
  final double imageHeight;

  double get pageWidthPt => mediaBox[2] - mediaBox[0];
  double get pageHeightPt => mediaBox[3] - mediaBox[1];

  /// Con 90 o 270 grados, la imagen sale con el ancho y el alto intercambiados
  /// respecto de la página.
  bool get isQuarterTurned => rotate == 90 || rotate == 270;

  Point2 pageToPixel(Point2 page) {
    final u = (page.x - mediaBox[0]) / pageWidthPt;
    final v = (page.y - mediaBox[1]) / pageHeightPt;

    final (a, b) = switch (rotate) {
      90 => (v, u),
      180 => (1 - u, v),
      270 => (1 - v, 1 - u),
      _ => (u, 1 - v),
    };

    return Point2(a * imageWidth, b * imageHeight);
  }

  Point2 pixelToPage(Point2 pixel) {
    final a = pixel.x / imageWidth;
    final b = pixel.y / imageHeight;

    final (u, v) = switch (rotate) {
      90 => (b, a),
      180 => (1 - a, b),
      270 => (1 - b, 1 - a),
      _ => (a, 1 - b),
    };

    return Point2(
      mediaBox[0] + u * pageWidthPt,
      mediaBox[1] + v * pageHeightPt,
    );
  }
}

/// Composición de [PageRasterMapping] y [GeoReference]: es lo que consume la
/// capa de mapa para dibujar el PDF y ubicar el GPS encima.
class GeoRasterMapping {
  const GeoRasterMapping({
    required this.raster,
    required this.georeference,
  });

  final PageRasterMapping raster;
  final GeoReference georeference;

  LatLon pixelToLatLon(Point2 pixel) =>
      georeference.pageToLatLon(raster.pixelToPage(pixel));

  Point2? latLonToPixel(LatLon position) {
    final page = georeference.latLonToPage(position);
    return page == null ? null : raster.pageToPixel(page);
  }

  /// Las cuatro esquinas de la zona georreferenciada, en píxeles de la imagen.
  /// Recortar por aquí evita dibujar los márgenes del layout (leyenda, título)
  /// sobre el mapa.
  List<Point2> get georeferencedCornersPixel {
    final bbox = georeference.bbox;
    return [
      raster.pageToPixel(Point2(bbox[0], bbox[1])),
      raster.pageToPixel(Point2(bbox[0], bbox[3])),
      raster.pageToPixel(Point2(bbox[2], bbox[3])),
      raster.pageToPixel(Point2(bbox[2], bbox[1])),
    ];
  }
}

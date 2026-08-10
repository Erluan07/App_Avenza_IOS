/// Generación del KML.
///
/// Dart puro y testeable: recibe un [KmlDocument] y devuelve el XML.
library;

import 'package:xml/xml.dart';

import '../geometry/geometry.dart';
import '../geometry/primitives.dart';
import 'kml_model.dart';

/// Convierte un color ARGB a la notación de KML.
///
/// KML usa **aabbggrr**: el orden de los canales de color está invertido
/// respecto de ARGB. Confundirlos hace que el rojo salga azul, que es un fallo
/// silencioso y desconcertante.
String kmlColor(int argb, {double opacity = 1}) {
  final a = ((argb >> 24 & 0xFF) * opacity.clamp(0, 1)).round();
  final r = argb >> 16 & 0xFF;
  final g = argb >> 8 & 0xFF;
  final b = argb & 0xFF;

  String hex(int value) => value.toRadixString(16).padLeft(2, '0');
  return '${hex(a)}${hex(b)}${hex(g)}${hex(r)}';
}

/// Formatea una coordenada como la espera KML: `lon,lat,alt`.
String _coordinate(LatLon point) =>
    '${point.longitude.toStringAsFixed(8)},'
    '${point.latitude.toStringAsFixed(8)},0';

String buildKml(KmlDocument document) {
  final builder = XmlBuilder();
  builder.processing('xml', 'version="1.0" encoding="UTF-8"');

  builder.element(
    'kml',
    attributes: {'xmlns': 'http://www.opengis.net/kml/2.2'},
    nest: () {
      builder.element('Document', nest: () {
        builder.element('name', nest: document.name);
        if (document.description != null) {
          builder.element('description', nest: document.description);
        }

        // Un estilo por carpeta: repetirlo en cada placemark infla el archivo
        // sin necesidad.
        for (var i = 0; i < document.folders.length; i++) {
          _writeStyle(builder, 'estilo-$i', document.folders[i].color);
        }

        for (var i = 0; i < document.folders.length; i++) {
          _writeFolder(builder, document.folders[i], 'estilo-$i');
        }
      });
    },
  );

  // Sin pretty-print a propósito. Al indentar, el escritor mete saltos de
  // línea alrededor del CDATA de <description>, y Google Earth Pro deja de
  // tratar ese contenido como HTML: el globo sale con las etiquetas en crudo
  // o directamente sin las imágenes.
  return builder.buildDocument().toXmlString();
}

void _writeStyle(XmlBuilder builder, String id, int color) {
  builder.element('Style', attributes: {'id': id}, nest: () {
    // Sin BalloonStyle explícito, Google Earth Pro arma su globo por defecto:
    // al haber ExtendedData, muestra esa tabla y se come la descripción con
    // las fotos. Declarándolo, manda nuestro HTML.
    builder.element('BalloonStyle', nest: () {
      builder.element('text', nest: () {
        builder.cdata('<h3>\$[name]</h3>\$[description]');
      });
    });
    builder.element('IconStyle', nest: () {
      builder.element('color', nest: kmlColor(color));
      builder.element('scale', nest: '1.1');
      builder.element('Icon', nest: () {
        builder.element(
          'href',
          nest: 'http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png',
        );
      });
    });
    builder.element('LineStyle', nest: () {
      builder.element('color', nest: kmlColor(color));
      builder.element('width', nest: '3');
    });
    builder.element('PolyStyle', nest: () {
      // Relleno translúcido: opaco taparía el mapa que hay debajo.
      builder.element('color', nest: kmlColor(color, opacity: 0.35));
      builder.element('fill', nest: '1');
      builder.element('outline', nest: '1');
    });
  });
}

void _writeFolder(XmlBuilder builder, KmlFolder folder, String styleId) {
  builder.element('Folder', nest: () {
    builder.element('name', nest: folder.name);
    if (folder.description != null) {
      builder.element('description', nest: folder.description);
    }

    for (final placemark in folder.placemarks) {
      _writePlacemark(builder, placemark, styleId);
    }
  });
}

void _writePlacemark(
  XmlBuilder builder,
  KmlPlacemark placemark,
  String styleId,
) {
  builder.element('Placemark', nest: () {
    builder.element('name', nest: placemark.name);
    builder.element('styleUrl', nest: '#$styleId');

    final html = _balloonHtml(placemark);
    if (html != null) {
      builder.element('description', nest: () => builder.cdata(html));
    }

    if (placemark.timestamp != null) {
      builder.element('TimeStamp', nest: () {
        builder.element(
          'when',
          nest: placemark.timestamp!.toUtc().toIso8601String(),
        );
      });
    }

    _writeExtendedData(builder, placemark);
    _writeGeometry(builder, placemark.geometry);
  });
}

/// Los atributos van también como `ExtendedData` porque es lo que leen QGIS y
/// ArcGIS al reimportar; el globo HTML es solo para mirarlo en Google Earth.
void _writeExtendedData(XmlBuilder builder, KmlPlacemark placemark) {
  if (placemark.attributes.isEmpty) return;

  builder.element('ExtendedData', nest: () {
    for (final entry in placemark.attributes.entries) {
      if (entry.value == null) continue;
      builder.element('Data', attributes: {'name': entry.key}, nest: () {
        builder.element('value', nest: '${entry.value}');
      });
    }
  });
}

void _writeGeometry(XmlBuilder builder, Geometry geometry) {
  switch (geometry) {
    case PointGeometry(:final position):
      builder.element('Point', nest: () {
        builder.element('coordinates', nest: _coordinate(position));
      });

    case LineGeometry(:final points):
      builder.element('LineString', nest: () {
        builder.element('tessellate', nest: '1');
        builder.element(
          'coordinates',
          nest: points.map(_coordinate).join(' '),
        );
      });

    case PolygonGeometry(:final ring):
      builder.element('Polygon', nest: () {
        builder.element('tessellate', nest: '1');
        builder.element('outerBoundaryIs', nest: () {
          builder.element('LinearRing', nest: () {
            // KML exige el anillo cerrado: el primer punto debe repetirse al
            // final o Google Earth descarta el polígono sin avisar.
            final closed = [...ring, if (ring.isNotEmpty) ring.first];
            builder.element(
              'coordinates',
              nest: closed.map(_coordinate).join(' '),
            );
          });
        });
      });
  }
}

String? _balloonHtml(KmlPlacemark placemark) {
  final parts = <String>[];

  if (placemark.description != null && placemark.description!.isNotEmpty) {
    parts.add('<p>${_escapeHtml(placemark.description!)}</p>');
  }

  final attributes = placemark.attributes.entries
      .where((e) => e.value != null && '${e.value}'.isNotEmpty)
      .toList();

  if (attributes.isNotEmpty) {
    final rows = attributes
        .map(
          (e) => '<tr>'
              '<td style="padding:2px 8px 2px 0;color:#666">'
              '${_escapeHtml(e.key)}</td>'
              '<td style="padding:2px 0"><b>${_escapeHtml('${e.value}')}</b></td>'
              '</tr>',
        )
        .join();
    parts.add('<table>$rows</table>');
  }

  final images = placemark.media.where((m) => m.isImage).toList();
  for (final image in images) {
    // Marcado deliberadamente simple: el renderizador de globos de Google
    // Earth Pro es muy limitado y con CSS moderno deja de mostrar la imagen.
    parts.add(
      '<p><img src="${image.path}" width="480" /></p>'
      '${image.caption != null ? '<p>${_escapeHtml(image.caption!)}</p>' : ''}',
    );
  }

  // El video se empaqueta igual dentro del KMZ, pero solo se enlaza: Google
  // Earth no lo reproduce en el globo. Al descomprimir el archivo sí se abre.
  final others = placemark.media.where((m) => !m.isImage).toList();
  if (others.isNotEmpty) {
    final links = others
        .map((m) => '<li><a href="${m.path}">${_escapeHtml(m.fileName)}</a></li>')
        .join();
    parts.add('<p>Archivos adjuntos:</p><ul>$links</ul>');
  }

  return parts.isEmpty ? null : parts.join();
}

String _escapeHtml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

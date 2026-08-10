/// Lector de KML.
///
/// Pensado para tragar archivos de cualquier origen —Google Earth, QGIS,
/// ArcGIS, receptores GPS—, que difieren bastante entre sí. Por eso:
///
/// - Los elementos se buscan por **nombre local**, ignorando el espacio de
///   nombres: unos escriben `<Placemark>` y otros `<kml:Placemark>`.
/// - Lo que no se entiende se salta y se anota como aviso, en vez de abortar
///   la importación entera.
library;

import 'package:xml/xml.dart';

import '../geometry/geometry.dart';
import '../geometry/primitives.dart';
import 'kml_import_models.dart';

/// Convierte un color KML (`aabbggrr`) a ARGB.
///
/// KML invierte el orden de los canales respecto de ARGB; leerlo tal cual
/// intercambia el rojo con el azul.
int? parseKmlColor(String? value) {
  if (value == null) return null;
  final hex = value.trim().replaceAll('#', '');
  if (hex.length != 8) return null;

  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null) return null;

  final a = (parsed >> 24) & 0xFF;
  final b = (parsed >> 16) & 0xFF;
  final g = (parsed >> 8) & 0xFF;
  final r = parsed & 0xFF;

  // Un color totalmente transparente sería invisible en el mapa; se ignora y
  // la capa se queda con el color por defecto.
  if (a == 0) return null;

  return (a << 24) | (r << 16) | (g << 8) | b;
}

/// Parsea una lista de coordenadas KML.
///
/// El formato es `lon,lat[,alt]` separado por espacios o saltos de línea —al
/// revés que la mayoría de APIs, que esperan lat,lon primero.
List<LatLon> parseCoordinates(String raw) {
  final result = <LatLon>[];

  for (final chunk in raw.split(RegExp(r'\s+'))) {
    if (chunk.isEmpty) continue;
    final parts = chunk.split(',');
    if (parts.length < 2) continue;

    final lon = double.tryParse(parts[0]);
    final lat = double.tryParse(parts[1]);
    if (lon == null || lat == null) continue;

    final point = LatLon(lat, lon);
    if (point.isValid) result.add(point);
  }

  return result;
}

class KmlReader {
  const KmlReader();

  /// Lee un KML y devuelve sus capas.
  ///
  /// Lanza [FormatException] si el XML no es válido o no parece un KML.
  KmlImportResult read(String xml) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(xml);
    } on XmlException catch (e) {
      throw FormatException('El archivo no es XML válido: ${e.message}');
    }

    final root = document.rootElement;
    if (_localName(root) != 'kml' && _find(root, 'Document') == null) {
      // Algunos generadores omiten el <kml> raíz; solo se rechaza si tampoco
      // hay nada reconocible dentro.
      if (_findAll(root, 'Placemark').isEmpty) {
        throw const FormatException('El archivo no contiene datos KML.');
      }
    }

    final warnings = <String>[];
    final styles = _collectStyles(root);

    for (final unsupported in const [
      ('NetworkLink', 'enlaces de red (no se descargan)'),
      ('GroundOverlay', 'imágenes superpuestas'),
      ('ScreenOverlay', 'superposiciones de pantalla'),
      ('PhotoOverlay', 'fotos panorámicas'),
    ]) {
      final count = _findAll(root, unsupported.$1).length;
      if (count > 0) {
        warnings.add('$count ${unsupported.$2} no se importaron.');
      }
    }

    // Cada grupo lógico queda identificado por su ruta de carpetas; dentro se
    // separa por tipo de geometría.
    // La clave es un registro (ruta, tipo): concatenar en una cadena obligaría
    // a inventar un separador que no aparezca en los nombres de carpeta, que
    // llevan espacios y barras.
    final groups = <(String, GeometryType), List<ImportedFeature>>{};
    final groupColors = <(String, GeometryType), int?>{};

    // Nombre visible de cada ruta. Se guarda al recorrer en lugar de
    // reconstruirlo partiendo la ruta: un nombre de carpeta puede contener el
    // mismo separador que se use para unirlas.
    final pathLabels = <String, String>{};

    void visit(XmlElement element, String path) {
      for (final child in element.childElements) {
        final tag = _localName(child);

        if (tag == 'Folder' || tag == 'Document') {
          final name = _text(child, 'name')?.trim();
          final childPath = name == null || name.isEmpty
              ? path
              : (path.isEmpty ? name : '$path / $name');
          if (name != null && name.isNotEmpty) {
            pathLabels[childPath] = name;
          }
          visit(child, childPath);
          continue;
        }

        if (tag != 'Placemark') continue;

        final feature = _readPlacemark(child, warnings);
        for (final entry in feature) {
          final key = (path, entry.geometry.type);
          groups.putIfAbsent(key, () => []).add(entry);
          groupColors.putIfAbsent(
            key,
            () => _colorOf(child, styles, entry.geometry.type),
          );
        }
      }
    }

    visit(root, '');

    final layers = <ImportedLayer>[];
    // Un grupo puede haberse partido en varios tipos; se sufija el nombre solo
    // cuando de verdad hay más de uno, para no ensuciar el caso normal.
    final pathTypeCount = <String, int>{};
    for (final (path, _) in groups.keys) {
      pathTypeCount[path] = (pathTypeCount[path] ?? 0) + 1;
    }

    for (final entry in groups.entries) {
      final (path, type) = entry.key;

      final base = pathLabels[path] ??
          (path.isEmpty ? (_documentName(root) ?? 'Importado') : path);

      final name = (pathTypeCount[path] ?? 1) > 1
          ? '$base (${_typeLabel(type)})'
          : base;

      layers.add(
        ImportedLayer(
          name: name,
          geometryType: type,
          features: entry.value,
          color: groupColors[entry.key],
        ),
      );
    }

    return KmlImportResult(
      layers: layers,
      documentName: _documentName(root),
      warnings: warnings,
    );
  }

  // ---------------------------------------------------------------------------
  // Placemarks
  // ---------------------------------------------------------------------------

  /// Devuelve una entrada por geometría: un `MultiGeometry` produce varias.
  List<ImportedFeature> _readPlacemark(
    XmlElement placemark,
    List<String> warnings,
  ) {
    final geometries = <Geometry>[];
    _collectGeometries(placemark, geometries, warnings);
    if (geometries.isEmpty) return const [];

    final name = _text(placemark, 'name')?.trim();
    final description = _text(placemark, 'description')?.trim();
    final attributes = _readExtendedData(placemark);
    final images = _imageNames(description);
    final timestamp = _readTimestamp(placemark);

    final result = <ImportedFeature>[];
    for (var i = 0; i < geometries.length; i++) {
      result.add(
        ImportedFeature(
          name: geometries.length == 1
              ? (name?.isNotEmpty ?? false ? name! : 'Sin nombre')
              : '${name?.isNotEmpty ?? false ? name! : 'Sin nombre'} '
                  '(${i + 1})',
          geometry: geometries[i],
          description: _stripHtml(description),
          attributes: attributes,
          imageNames: images,
          timestamp: timestamp,
        ),
      );
    }
    return result;
  }

  void _collectGeometries(
    XmlElement element,
    List<Geometry> out,
    List<String> warnings,
  ) {
    for (final child in element.childElements) {
      switch (_localName(child)) {
        case 'Point':
          final points = _coordinatesOf(child);
          if (points.isNotEmpty) out.add(PointGeometry(points.first));

        case 'LineString':
          final points = _coordinatesOf(child);
          if (points.length >= 2) out.add(LineGeometry(points));

        case 'LinearRing':
          // Un anillo suelto fuera de un Polygon: se trata como polígono.
          final points = _openRing(_coordinatesOf(child));
          if (points.length >= 3) out.add(PolygonGeometry(points));

        case 'Polygon':
          final outer = _find(child, 'outerBoundaryIs');
          final ring = outer == null ? null : _find(outer, 'LinearRing');
          final points =
              ring == null ? <LatLon>[] : _openRing(_coordinatesOf(ring));
          if (points.length >= 3) out.add(PolygonGeometry(points));

          if (_findAll(child, 'innerBoundaryIs').isNotEmpty) {
            // El modelo de la app no tiene agujeros; el contorno se conserva.
            warnings.add(
              'Se ignoraron los agujeros de al menos un polígono.',
            );
          }

        case 'MultiGeometry':
          _collectGeometries(child, out, warnings);

        case 'Track':
          // gx:Track de Google Earth: cada <gx:coord> es "lon lat alt" con
          // espacios, no con comas como el resto de KML.
          final points = <LatLon>[];
          for (final coord in child.childElements) {
            if (_localName(coord) != 'coord') continue;
            final parts = coord.innerText.trim().split(RegExp(r'\s+'));
            if (parts.length < 2) continue;
            final lon = double.tryParse(parts[0]);
            final lat = double.tryParse(parts[1]);
            if (lon == null || lat == null) continue;
            final point = LatLon(lat, lon);
            if (point.isValid) points.add(point);
          }
          if (points.length >= 2) out.add(LineGeometry(points));

        case 'MultiTrack':
          _collectGeometries(child, out, warnings);
      }
    }
  }

  List<LatLon> _coordinatesOf(XmlElement element) {
    final node = _find(element, 'coordinates');
    if (node == null) return const [];
    return parseCoordinates(node.innerText);
  }

  /// KML cierra los anillos repitiendo el primer punto; el modelo interno los
  /// guarda abiertos.
  List<LatLon> _openRing(List<LatLon> ring) {
    if (ring.length >= 2 && ring.first == ring.last) {
      return ring.sublist(0, ring.length - 1);
    }
    return ring;
  }

  Map<String, String> _readExtendedData(XmlElement placemark) {
    final extended = _find(placemark, 'ExtendedData');
    if (extended == null) return const {};

    final result = <String, String>{};

    for (final data in _findAll(extended, 'Data')) {
      final key = data.getAttribute('name');
      final value = _text(data, 'value');
      if (key != null && value != null && value.trim().isNotEmpty) {
        result[key] = value.trim();
      }
    }

    // SchemaData es la forma que usan QGIS y ogr2ogr al exportar tablas.
    for (final schema in _findAll(extended, 'SchemaData')) {
      for (final field in _findAll(schema, 'SimpleData')) {
        final key = field.getAttribute('name');
        final value = field.innerText.trim();
        if (key != null && value.isNotEmpty) result[key] = value;
      }
    }

    return result;
  }

  DateTime? _readTimestamp(XmlElement placemark) {
    final stamp = _find(placemark, 'TimeStamp');
    final when = stamp == null ? null : _text(stamp, 'when');
    if (when != null) return DateTime.tryParse(when.trim());

    final span = _find(placemark, 'TimeSpan');
    final begin = span == null ? null : _text(span, 'begin');
    return begin == null ? null : DateTime.tryParse(begin.trim());
  }

  // ---------------------------------------------------------------------------
  // Estilos
  // ---------------------------------------------------------------------------

  /// Recoge los estilos del documento por id, resolviendo los `StyleMap` a su
  /// variante normal.
  Map<String, XmlElement> _collectStyles(XmlElement root) {
    final styles = <String, XmlElement>{};

    for (final style in _findAll(root, 'Style')) {
      final id = style.getAttribute('id');
      if (id != null) styles[id] = style;
    }

    for (final map in _findAll(root, 'StyleMap')) {
      final id = map.getAttribute('id');
      if (id == null) continue;

      for (final pair in _findAll(map, 'Pair')) {
        if (_text(pair, 'key')?.trim() != 'normal') continue;
        final target = _text(pair, 'styleUrl')?.trim().replaceAll('#', '');
        final resolved = target == null ? null : styles[target];
        if (resolved != null) styles[id] = resolved;
      }
    }

    return styles;
  }

  int? _colorOf(
    XmlElement placemark,
    Map<String, XmlElement> styles,
    GeometryType type,
  ) {
    // Estilo en línea primero; si no, el referenciado por styleUrl.
    final inline = _find(placemark, 'Style');
    final url = _text(placemark, 'styleUrl')?.trim().replaceAll('#', '');
    final style = inline ?? (url == null ? null : styles[url]);
    if (style == null) return null;

    // Se mira el sub-estilo que corresponde al tipo de geometría; si falta, se
    // acepta cualquiera antes que quedarse sin color.
    final preferred = switch (type) {
      GeometryType.point => 'IconStyle',
      GeometryType.line => 'LineStyle',
      GeometryType.polygon => 'PolyStyle',
    };

    for (final name in [preferred, 'LineStyle', 'IconStyle', 'PolyStyle']) {
      final sub = _find(style, name);
      final color = parseKmlColor(sub == null ? null : _text(sub, 'color'));
      if (color != null) return color;
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // Texto y utilidades
  // ---------------------------------------------------------------------------

  /// Nombres de archivo de las imágenes referenciadas en el globo.
  List<String> _imageNames(String? description) {
    if (description == null || description.isEmpty) return const [];

    final result = <String>[];
    final pattern = RegExp(
      '''<img[^>]+src\\s*=\\s*["']([^"']+)["']''',
      caseSensitive: false,
    );

    for (final match in pattern.allMatches(description)) {
      final source = match.group(1);
      if (source == null) continue;
      // Solo interesan las rutas internas del KMZ; las remotas no se descargan.
      if (source.startsWith('http://') || source.startsWith('https://')) {
        continue;
      }
      result.add(source);
    }

    return result;
  }

  /// Deja el texto del globo legible: los KML suelen traer tablas HTML enteras.
  String? _stripHtml(String? html) {
    if (html == null || html.isEmpty) return null;

    final text = html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(p|tr|div|h\d)>', caseSensitive: false), '\n')
        .replaceAll(RegExp('<[^>]*>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n\s*\n+'), '\n')
        .trim();

    return text.isEmpty ? null : text;
  }

  String? _documentName(XmlElement root) {
    final document = _find(root, 'Document') ?? root;
    final name = _text(document, 'name')?.trim();
    return name?.isEmpty ?? true ? null : name;
  }

  String _typeLabel(GeometryType type) => switch (type) {
        GeometryType.point => 'puntos',
        GeometryType.line => 'líneas',
        GeometryType.polygon => 'polígonos',
      };

  static String _localName(XmlElement element) => element.name.local;

  /// Primer descendiente directo con ese nombre local.
  static XmlElement? _find(XmlElement parent, String name) {
    for (final child in parent.childElements) {
      if (_localName(child) == name) return child;
    }
    return null;
  }

  /// Todos los descendientes con ese nombre local, a cualquier profundidad.
  static List<XmlElement> _findAll(XmlElement parent, String name) => [
        for (final element in parent.descendantElements)
          if (_localName(element) == name) element,
      ];

  static String? _text(XmlElement parent, String name) =>
      _find(parent, name)?.innerText;
}

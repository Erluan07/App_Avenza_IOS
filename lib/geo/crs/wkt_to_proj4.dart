/// Traduce un WKT1 de ArcGIS a una cadena de definición proj4.
///
/// `proj4dart` no entiende WKT, solo cadenas `+proj=...`. Como ArcGIS Pro
/// escribe el CRS en WKT dentro del `/Measure`, esta traducción es lo que
/// permite reproyectar sin depender de GDAL.
library;

import 'wkt_parser.dart';

class Proj4Conversion {
  const Proj4Conversion({
    required this.definition,
    required this.isGeographic,
    this.crsName,
    this.datumName,
    this.datumShiftAssumed = false,
    this.datumShiftMissing = false,
  });

  /// Cadena lista para `proj4dart`.
  final String definition;

  final bool isGeographic;
  final String? crsName;
  final String? datumName;

  /// El WKT no traía `TOWGS84` y aplicamos parámetros de nuestra tabla.
  /// Son buenos en general, pero conviene que el usuario lo sepa.
  final bool datumShiftAssumed;

  /// El datum no es WGS84 y no pudimos determinar la transformación: las
  /// coordenadas pueden salir desplazadas cientos de metros.
  final bool datumShiftMissing;

  @override
  String toString() => 'Proj4Conversion($definition)';
}

/// Proyecciones ESRI/OGC → `+proj=`.
const Map<String, String> _projections = {
  'transverse_mercator': 'tmerc',
  'gauss_kruger': 'tmerc',
  'transverse_mercator_complex': 'tmerc',
  'lambert_conformal_conic': 'lcc',
  'lambert_conformal_conic_1sp': 'lcc',
  'lambert_conformal_conic_2sp': 'lcc',
  'mercator': 'merc',
  'mercator_1sp': 'merc',
  'mercator_2sp': 'merc',
  'albers': 'aea',
  'albers_conic_equal_area': 'aea',
  'albers_equal_area_conic': 'aea',
  'stereographic': 'stere',
  'polar_stereographic': 'stere',
  'stereographic_north_pole': 'stere',
  'stereographic_south_pole': 'stere',
  'double_stereographic': 'sterea',
  'oblique_stereographic': 'sterea',
  'lambert_azimuthal_equal_area': 'laea',
  'azimuthal_equidistant': 'aeqd',
  'orthographic': 'ortho',
  'gnomonic': 'gnom',
  'cassini': 'cass',
  'cassini_soldner': 'cass',
  'krovak': 'krovak',
  'hotine_oblique_mercator': 'omerc',
  'hotine_oblique_mercator_azimuth_center': 'omerc',
  'hotine_oblique_mercator_azimuth_natural_origin': 'omerc',
  'equidistant_conic': 'eqdc',
  'sinusoidal': 'sinu',
  'robinson': 'robin',
  'mollweide': 'moll',
  'miller_cylindrical': 'mill',
  'equirectangular': 'eqc',
  'plate_carree': 'eqc',
  'van_der_grinten_i': 'vandg',
  'new_zealand_map_grid': 'nzmg',
  'polyconic': 'poly',
  'bonne': 'bonne',
  'cylindrical_equal_area': 'cea',
};

/// Parámetros ESRI/OGC → claves proj4.
const Map<String, String> _parameters = {
  'falseeasting': 'x_0',
  'falsenorthing': 'y_0',
  'centralmeridian': 'lon_0',
  'longitudeoforigin': 'lon_0',
  'longitudeofnaturalorigin': 'lon_0',
  'longitudeofcenter': 'lon_0',
  'latitudeoforigin': 'lat_0',
  'latitudeofnaturalorigin': 'lat_0',
  'latitudeofcenter': 'lat_0',
  'scalefactor': 'k_0',
  'scalefactoratnaturalorigin': 'k_0',
  'standardparallel1': 'lat_1',
  'standardparallel2': 'lat_2',
  'pseudostandardparallel1': 'lat_1',
  'azimuth': 'alpha',
  'azimuthangle': 'alpha',
  'rectifiedgridangle': 'gamma',
  'xyplanerotation': 'gamma',
};

/// Datums que proj4 conoce por nombre.
const Map<String, String> _knownDatums = {
  'd_wgs_1984': 'WGS84',
  'wgs_1984': 'WGS84',
  'wgs1984': 'WGS84',
  'worldgeodeticsystem1984': 'WGS84',
  'd_north_american_1983': 'NAD83',
  'north_american_datum_1983': 'NAD83',
  'd_north_american_1927': 'NAD27',
  'north_american_datum_1927': 'NAD27',
  'd_wgs_1972': 'WGS72',
};

/// Transformaciones a WGS84 para datums frecuentes en Sudamérica que ArcGIS
/// suele exportar **sin** el nodo `TOWGS84`.
///
/// Sin esto, un mapa en PSAD56 se dibujaría desplazado ~300 m respecto de un
/// mapa base WGS84. Son valores de uso general: si el proyecto exige precisión
/// geodésica, hay que confirmarlos con la transformación oficial del país.
const Map<String, String> _assumedTowgs84 = {
  'd_provisional_s_american_1956': '-279,175,-379',
  'provisional_south_american_datum_1956': '-279,175,-379',
  'd_south_american_1969': '-57,1,-41',
  'south_american_datum_1969': '-57,1,-41',
  'd_sirgas_2000': '0,0,0',
  'sirgas_2000': '0,0,0',
  'd_sirgas': '0,0,0',
  'd_wgs_1972': '0,0,4.5,0,0,0.554,0.2263',
};

/// Datums geocéntricos modernos, equivalentes a WGS84 a efectos prácticos
/// (las diferencias son de centímetros, no de metros).
const Set<String> _wgs84Equivalent = {
  'd_wgs_1984',
  'wgs_1984',
  'd_sirgas_2000',
  'sirgas_2000',
  'd_sirgas',
  'd_itrf_2000',
  'd_itrf_2008',
  'd_itrf_2014',
  // MAGNA-SIRGAS (Colombia): es la realización nacional de SIRGAS, geocéntrica.
  'd_magna',
  'd_magna_sirgas',
  'magna_sirgas',
  'marco_geocentrico_nacional_de_referencia',
  'marco_geocentrico_nacional_de_referencia_2018',
  // Otras realizaciones nacionales de ITRF.
  'd_geocentric_datum_of_australia_2020',
  'd_etrs_1989',
  'etrs_1989',
  'd_posgar_2007',
  'd_sirgas_ros98',
};

/// Convierte un WKT a definición proj4. `null` si no es reconocible.
Proj4Conversion? wktToProj4(String? wkt) {
  final root = parseWkt(wkt);
  if (root == null) return null;
  return nodeToProj4(root);
}

Proj4Conversion? nodeToProj4(WktNode root) {
  final keyword = root.keyword.toUpperCase();

  if (keyword == 'GEOGCS' || keyword == 'GEOGRAPHICCRS' || keyword == 'GEODCRS') {
    return _geographicToProj4(root);
  }
  if (keyword == 'PROJCS' || keyword == 'PROJECTEDCRS' || keyword == 'PROJCRS') {
    return _projectedToProj4(root);
  }

  // A veces el WKT viene envuelto (COMPD_CS, VERT_CS…): buscamos hacia dentro.
  final projcs = root.find('PROJCS');
  if (projcs != null) return _projectedToProj4(projcs);
  final geogcs = root.find('GEOGCS');
  if (geogcs != null) return _geographicToProj4(geogcs);

  return null;
}

// ---------------------------------------------------------------------------

Proj4Conversion? _geographicToProj4(WktNode geogcs) {
  final datum = _datumParts(geogcs);
  if (datum == null) return null;

  final parts = <String>['+proj=longlat', ...datum.tokens];

  final primem = geogcs.child('PRIMEM');
  final pm = primem?.numbers.firstOrNull;
  if (pm != null && pm != 0) parts.add('+pm=${_num(pm)}');

  parts.add('+no_defs');

  return Proj4Conversion(
    definition: parts.join(' '),
    isGeographic: true,
    crsName: geogcs.name,
    datumName: datum.name,
    datumShiftAssumed: datum.assumed,
    datumShiftMissing: datum.missing,
  );
}

Proj4Conversion? _projectedToProj4(WktNode projcs) {
  final geogcs = projcs.child('GEOGCS') ?? projcs.find('GEOGCS');
  if (geogcs == null) return null;

  final projectionName = projcs.child('PROJECTION')?.name ?? '';
  final normalized = _normalize(projectionName);

  // Web Mercator es un caso aparte: usa una esfera aunque el datum sea WGS84.
  if (normalized == 'mercator_auxiliary_sphere' ||
      normalized == 'popular_visualisation_pseudo_mercator') {
    return Proj4Conversion(
      definition: '+proj=merc +a=6378137 +b=6378137 +lat_ts=0 +lon_0=0 '
          '+x_0=0 +y_0=0 +k=1 +units=m +nadgrids=@null +no_defs',
      isGeographic: false,
      crsName: projcs.name,
      datumName: geogcs.child('DATUM')?.name,
    );
  }

  final proj = _projections[normalized];
  if (proj == null) return null;

  final datum = _datumParts(geogcs);
  if (datum == null) return null;

  final parts = <String>['+proj=$proj'];

  // Parámetros de la proyección.
  final params = <String, double>{};
  for (final node in projcs.childrenNamed('PARAMETER')) {
    final key = _parameters[_compact(node.name ?? '')];
    final value = node.numbers.firstOrNull;
    if (key != null && value != null) params[key] = value;
  }

  // Mercator expresa su paralelo de referencia como +lat_ts, no +lat_1.
  if (proj == 'merc' && params.containsKey('lat_1')) {
    params['lat_ts'] = params.remove('lat_1')!;
  }
  // Oblique Mercator toma el meridiano como +lonc.
  if (proj == 'omerc' && params.containsKey('lon_0')) {
    params['lonc'] = params.remove('lon_0')!;
  }

  for (final key in const [
    'lat_0',
    'lon_0',
    'lonc',
    'lat_1',
    'lat_2',
    'lat_ts',
    'k_0',
    'alpha',
    'gamma',
    'x_0',
    'y_0',
  ]) {
    final value = params[key];
    if (value != null) parts.add('+$key=${_num(value)}');
  }

  parts.addAll(datum.tokens);

  final primem = geogcs.child('PRIMEM');
  final pm = primem?.numbers.firstOrNull;
  if (pm != null && pm != 0) parts.add('+pm=${_num(pm)}');

  parts.add(_linearUnits(projcs));
  parts.add('+no_defs');

  return Proj4Conversion(
    definition: parts.where((p) => p.isNotEmpty).join(' '),
    isGeographic: false,
    crsName: projcs.name,
    datumName: datum.name,
    datumShiftAssumed: datum.assumed,
    datumShiftMissing: datum.missing,
  );
}

// ---------------------------------------------------------------------------

class _DatumParts {
  const _DatumParts(this.tokens, this.name, this.assumed, this.missing);

  final List<String> tokens;
  final String? name;
  final bool assumed;
  final bool missing;
}

_DatumParts? _datumParts(WktNode geogcs) {
  final datum = geogcs.child('DATUM');
  final datumName = datum?.name;
  final key = _normalize(datumName ?? '');

  // 1. Datum que proj4 conoce por nombre.
  final known = _knownDatums[key];
  if (known != null) {
    return _DatumParts(['+datum=$known'], datumName, false, false);
  }

  // 2. Elipsoide explícito: siempre exacto, sin depender de tablas de nombres.
  final spheroid = datum?.child('SPHEROID') ?? datum?.find('SPHEROID');
  final numbers = spheroid?.numbers.toList() ?? const <double>[];
  final tokens = <String>[];

  if (numbers.length >= 2) {
    final a = numbers[0];
    final rf = numbers[1];
    tokens.add('+a=${_num(a)}');
    // rf = 0 significa esfera.
    tokens.add(rf == 0 ? '+b=${_num(a)}' : '+rf=${_num(rf)}');
  } else {
    // Sin elipsoide utilizable no podemos hacer nada mejor que asumir WGS84.
    return _DatumParts(
      ['+datum=WGS84'],
      datumName,
      false,
      !_wgs84Equivalent.contains(key),
    );
  }

  // 3. Desplazamiento de datum: preferimos el TOWGS84 del propio archivo.
  final towgs84 = datum?.child('TOWGS84');
  final shift = towgs84?.numbers.toList() ?? const <double>[];
  if (shift.length >= 3) {
    tokens.add('+towgs84=${shift.map(_num).join(',')}');
    return _DatumParts(tokens, datumName, false, false);
  }

  final assumed = _assumedTowgs84[key];
  if (assumed != null) {
    tokens.add('+towgs84=$assumed');
    return _DatumParts(tokens, datumName, true, false);
  }

  if (_wgs84Equivalent.contains(key)) {
    return _DatumParts(tokens, datumName, false, false);
  }

  // Elipsoide correcto pero sin desplazamiento: puede haber error de decenas
  // o cientos de metros. Lo marcamos para avisar en la UI.
  return _DatumParts(tokens, datumName, false, true);
}

String _linearUnits(WktNode projcs) {
  // La UNIT lineal de un PROJCS es la que cuelga directo del PROJCS (las de
  // los GEOGCS anidados son angulares).
  final unit = projcs.childrenNamed('UNIT').lastOrNull;
  if (unit == null) return '+units=m';

  final name = _normalize(unit.name ?? '');
  final factor = unit.numbers.firstOrNull ?? 1.0;

  if (name.contains('metre') || name.contains('meter') || name == 'm') {
    return '+units=m';
  }
  if (name.contains('foot_us') ||
      name.contains('us_survey_foot') ||
      name.contains('foot_us_survey')) {
    return '+units=us-ft';
  }
  if (name.contains('foot') || name.contains('feet')) return '+units=ft';

  if (factor > 0 && factor != 1.0) return '+to_meter=${_num(factor)}';
  return '+units=m';
}

String _normalize(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[\s\-]+'), '_')
    .replaceAll(RegExp(r'_+'), '_')
    .replaceAll(RegExp(r'^_|_$'), '');

/// Normalización agresiva para nombres de parámetro: ESRI escribe
/// `False_Easting`, OGC `false easting` y EPSG `FalseEasting`. Quitando todo
/// lo que no sea alfanumérico, las tres formas colapsan a la misma clave.
String _compact(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

String _num(double value) {
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return value.toInt().toString();
  }
  return value.toString();
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
  T? get lastOrNull => isEmpty ? null : last;
}

/// Convierte la declaración de CRS de un GeoPDF en una proyección utilizable.
///
/// Estrategia en cascada: código EPSG conocido → WKT traducido a proj4 →
/// nada (el llamador cae a una afín sobre lat/lon, con menor precisión).
library;

import 'package:proj4dart/proj4dart.dart' as proj4;

import '../geopdf/geopdf_models.dart';
import 'wkt_to_proj4.dart';

enum CrsSource {
  /// Resuelto por código EPSG.
  epsg,

  /// Resuelto traduciendo el WKT del archivo.
  wkt,
}

class ResolvedCrs {
  const ResolvedCrs({
    required this.projection,
    required this.definition,
    required this.isGeographic,
    required this.source,
    this.name,
    this.datumName,
    this.datumShiftAssumed = false,
    this.datumShiftMissing = false,
  });

  final proj4.Projection projection;

  /// La cadena proj4 con la que se construyó. Se guarda para poder cachear la
  /// georreferencia en la base de datos sin re-parsear el PDF.
  final String definition;

  final bool isGeographic;
  final CrsSource source;
  final String? name;
  final String? datumName;

  /// Se aplicó una transformación de datum de nuestra tabla, no del archivo.
  final bool datumShiftAssumed;

  /// El datum no es WGS84 y no se pudo determinar el desplazamiento.
  final bool datumShiftMissing;

  @override
  String toString() => 'ResolvedCrs(${name ?? definition})';
}

/// Un CRS declarado junto con su CRS geográfico subyacente.
///
/// Hace falta separarlos porque en un GeoPDF los `GPTS` **siempre** son
/// lat/lon en el sistema geográfico de base, aunque el mapa esté proyectado:
/// el geográfico es el origen de esos puntos y el proyectado es el espacio
/// donde la relación con la página es lineal.
class CrsPair {
  const CrsPair({required this.geographic, this.projected});

  /// Sistema geográfico en el que están expresados los `GPTS`.
  final ResolvedCrs geographic;

  /// Sistema proyectado del mapa, o `null` si el mapa es geográfico.
  final ResolvedCrs? projected;
}

class CrsResolver {
  const CrsResolver._();

  static final Map<String, proj4.Projection?> _cache = {};

  /// WGS84 geográfico: el destino común para dibujar sobre cualquier mapa base.
  static proj4.Projection get wgs84 =>
      _projectionFor('+proj=longlat +datum=WGS84 +no_defs')!;

  static ResolvedCrs? resolve(CrsSpec? spec) {
    if (spec == null || spec.isEmpty) return null;

    // El WKT se parsea igual aunque resolvamos por EPSG: de ahí salen los
    // avisos sobre el datum.
    final conversion = wktToProj4(spec.wkt);

    final epsg = spec.epsg;
    if (epsg != null) {
      final definition = proj4ForEpsg(epsg);
      if (definition != null) {
        final projection = _projectionFor(definition);
        if (projection != null) {
          return ResolvedCrs(
            projection: projection,
            definition: definition,
            isGeographic: definition.contains('+proj=longlat'),
            source: CrsSource.epsg,
            name: spec.displayName ?? 'EPSG:$epsg',
            datumName: conversion?.datumName,
            datumShiftAssumed: conversion?.datumShiftAssumed ?? false,
            datumShiftMissing: conversion?.datumShiftMissing ?? false,
          );
        }
      }

      // proj4dart trae su propio registro con algunos códigos.
      final builtin = proj4.Projection.get('EPSG:$epsg');
      if (builtin != null) {
        return ResolvedCrs(
          projection: builtin,
          definition: 'EPSG:$epsg',
          isGeographic: epsg == 4326 || epsg == 4269,
          source: CrsSource.epsg,
          name: spec.displayName ?? 'EPSG:$epsg',
          datumName: conversion?.datumName,
        );
      }
    }

    if (conversion != null) {
      final projection = _projectionFor(conversion.definition);
      if (projection != null) {
        return ResolvedCrs(
          projection: projection,
          definition: conversion.definition,
          isGeographic: conversion.isGeographic,
          source: CrsSource.wkt,
          name: conversion.crsName ?? spec.displayName,
          datumName: conversion.datumName,
          datumShiftAssumed: conversion.datumShiftAssumed,
          datumShiftMissing: conversion.datumShiftMissing,
        );
      }
    }

    return null;
  }

  /// Resuelve un CRS y deriva además su sistema geográfico subyacente.
  ///
  /// Importante para leer GeoPDF de ArcGIS Pro: escriben el CRS **proyectado**
  /// bajo la clave `/GCS` y no emiten `/PCS`. Confiar en el nombre de la clave
  /// lleva a interpretar los `GPTS` como coordenadas proyectadas — que es
  /// exactamente el error que esta función evita. Lo que manda es el contenido
  /// del WKT, no la clave bajo la que vino.
  static CrsPair? resolvePair(CrsSpec? spec) {
    final resolved = resolve(spec);
    if (resolved == null) return null;

    if (resolved.isGeographic) return CrsPair(geographic: resolved);

    final definition = geographicVariantOf(resolved.definition);
    final projection = definition == null ? null : _projectionFor(definition);

    if (projection == null || definition == null) {
      // Sin sistema geográfico derivable asumimos WGS84, que es lo que usan
      // los GPTS salvo datums locales antiguos.
      return CrsPair(
        geographic: ResolvedCrs(
          projection: wgs84,
          definition: '+proj=longlat +datum=WGS84 +no_defs',
          isGeographic: true,
          source: resolved.source,
          name: 'WGS 84',
        ),
        projected: resolved,
      );
    }

    return CrsPair(
      geographic: ResolvedCrs(
        projection: projection,
        definition: definition,
        isGeographic: true,
        source: resolved.source,
        name: resolved.datumName,
        datumName: resolved.datumName,
        datumShiftAssumed: resolved.datumShiftAssumed,
        datumShiftMissing: resolved.datumShiftMissing,
      ),
      projected: resolved,
    );
  }

  /// Reconstruye una proyección desde una definición ya guardada en DB.
  static proj4.Projection? fromDefinition(String definition) {
    if (definition.startsWith('EPSG:')) {
      return proj4.Projection.get(definition) ??
          _projectionFor(
            proj4ForEpsg(int.tryParse(definition.substring(5)) ?? -1) ?? '',
          );
    }
    return _projectionFor(definition);
  }

  static proj4.Projection? _projectionFor(String definition) {
    if (definition.isEmpty) return null;
    return _cache.putIfAbsent(definition, () {
      try {
        // `add` registra la definición bajo un nombre; usamos la propia
        // definición como nombre para que sea estable entre llamadas.
        return proj4.Projection.get(definition) ??
            proj4.Projection.add(definition, definition);
      } catch (_) {
        return null;
      }
    });
  }
}

/// Deriva la definición del CRS **geográfico** subyacente a uno proyectado.
///
/// Conserva los tokens que describen la forma y posición de la Tierra
/// (elipsoide, datum, desplazamiento, meridiano de origen) y descarta los de
/// la proyección (`+proj`, `+lat_0`, `+zone`, `+units`…). Así funciona igual
/// venga la definición de un WKT o de un código EPSG.
String? geographicVariantOf(String definition) {
  var source = definition;
  if (source.startsWith('EPSG:')) {
    final code = int.tryParse(source.substring(5));
    final expanded = code == null ? null : proj4ForEpsg(code);
    if (expanded == null) return null;
    source = expanded;
  }

  if (source.contains('+proj=longlat')) return source;

  const keep = {
    'datum',
    'ellps',
    'a',
    'b',
    'rf',
    'f',
    'towgs84',
    'pm',
    'nadgrids',
  };

  final tokens = <String>['+proj=longlat'];
  for (final token in source.split(RegExp(r'\s+'))) {
    if (!token.startsWith('+')) continue;
    final key = token.substring(1).split('=').first;
    if (keep.contains(key)) tokens.add(token);
  }

  // Sin ningún token de datum/elipsoide no habría nada que derivar.
  if (tokens.length == 1) return null;

  tokens.add('+no_defs');
  return tokens.join(' ');
}

/// Definiciones proj4 para los códigos EPSG que nos interesan.
///
/// No pretende ser una base EPSG completa: cubre lo que aparece en la práctica
/// y deja el resto al WKT, que el propio archivo siempre trae.
String? proj4ForEpsg(int code) {
  switch (code) {
    case 4326:
      return '+proj=longlat +datum=WGS84 +no_defs';
    case 4269:
      return '+proj=longlat +datum=NAD83 +no_defs';
    case 4267:
      return '+proj=longlat +datum=NAD27 +no_defs';
    case 4674: // SIRGAS 2000
      return '+proj=longlat +ellps=GRS80 +towgs84=0,0,0,0,0,0,0 +no_defs';
    case 4248: // PSAD56
      return '+proj=longlat +ellps=intl +towgs84=-279,175,-379 +no_defs';
    case 4618: // SAD69
      return '+proj=longlat +ellps=aust_SA +towgs84=-57,1,-41 +no_defs';
    case 3857:
    case 900913:
      return '+proj=merc +a=6378137 +b=6378137 +lat_ts=0 +lon_0=0 +x_0=0 '
          '+y_0=0 +k=1 +units=m +nadgrids=@null +no_defs';
  }

  // WGS84 / UTM: 326zz norte, 327zz sur.
  if (code >= 32601 && code <= 32660) {
    return '+proj=utm +zone=${code - 32600} +datum=WGS84 +units=m +no_defs';
  }
  if (code >= 32701 && code <= 32760) {
    return '+proj=utm +zone=${code - 32700} +south +datum=WGS84 +units=m '
        '+no_defs';
  }

  // PSAD56 / UTM — habitual en cartografía peruana antigua. El desplazamiento
  // de datum aquí es de ~300 m, así que importa acertarlo.
  if (code >= 24817 && code <= 24821) {
    return '+proj=utm +zone=${code - 24800} +ellps=intl '
        '+towgs84=-279,175,-379 +units=m +no_defs';
  }
  if (code >= 24877 && code <= 24880) {
    return '+proj=utm +zone=${code - 24860} +south +ellps=intl '
        '+towgs84=-279,175,-379 +units=m +no_defs';
  }

  // SAD69 / UTM sur.
  if (code >= 29177 && code <= 29185) {
    return '+proj=utm +zone=${code - 29160} +south +ellps=aust_SA '
        '+towgs84=-57,1,-41 +units=m +no_defs';
  }

  return null;
}

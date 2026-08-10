/// La georreferencia de una página: convierte puntos de la página PDF en
/// coordenadas geográficas y viceversa.
///
/// La cadena completa es:
/// ```
/// punto de página PDF
///   → coordenada proyectada   (afín ajustada por mínimos cuadrados)
///   → lat/lon WGS84           (inversa de la proyección, vía proj4)
/// ```
/// El paso intermedio importa: si el mapa está en UTM, la relación entre la
/// página y lat/lon **no** es lineal, y ajustar la afín directo sobre lat/lon
/// mete deriva en mapas de gran extensión.
library;

import 'dart:convert';

import 'package:proj4dart/proj4dart.dart' as proj4;

import '../crs/crs_resolver.dart';
import '../geometry/primitives.dart';
import '../geopdf/geopdf_models.dart';
import '../measure/geodesy.dart';
import 'affine.dart';

enum GeoReferenceMode {
  /// La afín se ajustó contra un CRS proyectado. Es el caso exacto.
  proyectado,

  /// La afín se ajustó directo sobre lat/lon. Exacto si el mapa es geográfico;
  /// aproximado si era proyectado y no pudimos resolver el CRS.
  geografico,
}

class GeoReference {
  const GeoReference({
    required this.pageToTarget,
    required this.targetToPage,
    required this.mode,
    required this.bbox,
    required this.rmsError,
    required this.maxError,
    required this.controlPointCount,
    this.targetDefinition,
    this.crsName,
    this.datumName,
    this.datumShiftAssumed = false,
    this.datumShiftMissing = false,
    this.projectedCrsUnresolved = false,
  });

  /// Página PDF → espacio destino (coordenadas proyectadas, o lon/lat si
  /// [mode] es [GeoReferenceMode.geografico]).
  final Affine2D pageToTarget;
  final Affine2D targetToPage;

  final GeoReferenceMode mode;

  /// Zona georreferenciada de la página, `[minX, minY, maxX, maxY]` en puntos.
  final List<double> bbox;

  /// Residuos del ajuste, en unidades del espacio destino (metros si el CRS
  /// destino es proyectado en metros). Es la medida real de confiabilidad.
  final double rmsError;
  final double maxError;
  final int controlPointCount;

  /// Definición proj4 del CRS destino. `null` cuando el destino es lat/lon.
  final String? targetDefinition;

  final String? crsName;
  final String? datumName;

  /// Se aplicó un desplazamiento de datum de nuestra tabla, no del archivo.
  final bool datumShiftAssumed;

  /// Datum distinto de WGS84 sin transformación conocida: puede haber error
  /// de decenas o cientos de metros.
  final bool datumShiftMissing;

  /// El PDF declaraba un CRS proyectado que no pudimos resolver, así que
  /// caímos a una afín sobre lat/lon.
  final bool projectedCrsUnresolved;

  proj4.Projection? get _targetProjection {
    final definition = targetDefinition;
    if (definition == null) return null;
    return CrsResolver.fromDefinition(definition);
  }

  /// `true` si la georreferencia es de fiar sin advertencias.
  bool get isReliable =>
      !datumShiftMissing && !projectedCrsUnresolved && maxError.isFinite;

  // -------------------------------------------------------------------------
  // Construcción
  // -------------------------------------------------------------------------

  /// Construye la georreferencia a partir de un viewport de un GeoPDF.
  /// `null` si los puntos de control son insuficientes o degenerados.
  static GeoReference? fromViewport(GeoPdfViewport viewport) {
    final measure = viewport.measure;
    if (!measure.isUsable) return null;

    final bbox = viewport.bbox;
    // Recorrido **con signo** de cada eje. Un `/BBox` puede venir con las
    // esquinas invertidas —hay productores que escriben `y0 > y1`— y eso
    // indica que el cuadrado unitario de los LPTS crece hacia abajo.
    // Normalizarlo a mínimos y máximos volteaba el mapa de norte a sur.
    final spanX = viewport.spanX;
    final spanY = viewport.spanY;
    if (spanX == 0 || spanY == 0) return null;

    // LPTS viene en cuadrado unitario: hay que llevarlo a puntos de página.
    final pagePoints = [
      for (final l in measure.lpts)
        Point2(bbox[0] + l.x * spanX, bbox[1] + l.y * spanY),
    ];

    // La clave bajo la que viene el CRS no es de fiar: ArcGIS Pro escribe el
    // sistema **proyectado** bajo `/GCS` y no emite `/PCS`. Se clasifica por
    // el contenido del WKT, no por el nombre de la clave.
    final fromPcs = CrsResolver.resolvePair(measure.pcs);
    final fromGcs = CrsResolver.resolvePair(measure.gcs);
    final crs = (fromPcs?.projected != null ? fromPcs : null) ??
        (fromGcs?.projected != null ? fromGcs : null) ??
        fromPcs ??
        fromGcs;

    final geographic = crs?.geographic;
    final projected = crs?.projected;

    // Los GPTS son lat/lon en el sistema geográfico. Si no se pudo resolver,
    // asumimos WGS84, que es lo habitual salvo datums locales antiguos.
    final source = geographic?.projection ?? CrsResolver.wgs84;
    final target = projected?.projection ?? CrsResolver.wgs84;

    final targets = <Point2>[];
    for (final g in measure.gpts) {
      try {
        final p = source.transform(
          target,
          proj4.Point(x: g.longitude, y: g.latitude),
        );
        targets.add(Point2(p.x, p.y));
      } catch (_) {
        return null;
      }
    }

    final fit = fitAffine(pagePoints, targets);
    if (fit == null) return null;
    final inverse = fit.transform.invert();
    if (inverse == null) return null;

    final declaresProjected =
        _declaresProjectedCrs(measure.pcs) || _declaresProjectedCrs(measure.gcs);

    return GeoReference(
      pageToTarget: fit.transform,
      targetToPage: inverse,
      mode: projected != null
          ? GeoReferenceMode.proyectado
          : GeoReferenceMode.geografico,
      // Aquí sí normalizado: se usa para recortar la imagen, donde interesa el
      // rectángulo y no su orientación.
      bbox: viewport.normalizedBbox,
      rmsError: fit.rmsError,
      maxError: fit.maxError,
      controlPointCount: fit.pointCount,
      targetDefinition: projected?.definition,
      crsName: projected?.name ?? geographic?.name,
      datumName: projected?.datumName ?? geographic?.datumName,
      datumShiftAssumed: (geographic?.datumShiftAssumed ?? false) ||
          (projected?.datumShiftAssumed ?? false),
      datumShiftMissing: (geographic?.datumShiftMissing ?? false) ||
          (projected?.datumShiftMissing ?? false),
      // Declaraba una proyección y no la pudimos resolver: la afín queda
      // ajustada sobre lat/lon, con deriva en mapas de gran extensión.
      projectedCrsUnresolved: declaresProjected && projected == null,
    );
  }

  /// Si el CRS declarado es proyectado, mirando el WKT y no la clave.
  static bool _declaresProjectedCrs(CrsSpec? spec) {
    if (spec == null) return false;
    if (spec.type?.toUpperCase() == 'PROJCS') return true;
    final wkt = spec.wkt?.trimLeft().toUpperCase();
    return wkt != null && wkt.startsWith('PROJCS');
  }

  // -------------------------------------------------------------------------
  // Conversión de coordenadas
  // -------------------------------------------------------------------------

  /// Punto de página PDF (origen abajo-izquierda) → lat/lon WGS84.
  LatLon pageToLatLon(Point2 page) {
    final t = pageToTarget.apply(page);
    final projection = _targetProjection;
    if (projection == null) return LatLon(t.y, t.x);

    try {
      final p = projection.transform(
        CrsResolver.wgs84,
        proj4.Point(x: t.x, y: t.y),
      );
      return LatLon(p.y, p.x);
    } catch (_) {
      return LatLon(t.y, t.x);
    }
  }

  /// Lat/lon WGS84 → punto de página PDF. `null` si la conversión falla.
  Point2? latLonToPage(LatLon position) {
    final projection = _targetProjection;

    Point2 target;
    if (projection == null) {
      target = Point2(position.longitude, position.latitude);
    } else {
      try {
        final p = CrsResolver.wgs84.transform(
          projection,
          proj4.Point(x: position.longitude, y: position.latitude),
        );
        target = Point2(p.x, p.y);
      } catch (_) {
        return null;
      }
    }

    return targetToPage.apply(target);
  }

  /// Las cuatro esquinas de la zona georreferenciada, en lat/lon.
  /// Se calculan las cuatro (no dos) porque el mapa puede venir rotado.
  List<LatLon> get cornersLatLon => [
        pageToLatLon(Point2(bbox[0], bbox[1])),
        pageToLatLon(Point2(bbox[0], bbox[3])),
        pageToLatLon(Point2(bbox[2], bbox[3])),
        pageToLatLon(Point2(bbox[2], bbox[1])),
      ];

  GeoBounds get coverage => GeoBounds.fromPoints(cornersLatLon);

  /// Metros de terreno por punto PDF, medido sobre el elipsoide en el centro
  /// del mapa. Sirve para estimar la escala y la resolución de rasterizado.
  double get metersPerPagePoint {
    final cx = (bbox[0] + bbox[2]) / 2;
    final cy = (bbox[1] + bbox[3]) / 2;
    final a = pageToLatLon(Point2(cx, cy));
    final b = pageToLatLon(Point2(cx + 1, cy));
    final distance = vincentyDistance(a, b);
    return distance.isFinite && distance > 0 ? distance : 0;
  }

  /// Denominador de la escala del mapa (el 25000 de "1:25.000").
  /// Un punto PDF es 1/72 de pulgada = 0,0003528 m.
  double get scaleDenominator {
    final metersPerPoint = metersPerPagePoint;
    if (metersPerPoint <= 0) return 0;
    return metersPerPoint / 0.0003527777777777778;
  }

  // -------------------------------------------------------------------------
  // Serialización (para cachear en la base de datos)
  // -------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'pageToTarget': [
          pageToTarget.a,
          pageToTarget.b,
          pageToTarget.c,
          pageToTarget.d,
          pageToTarget.e,
          pageToTarget.f,
        ],
        'mode': mode.name,
        'bbox': bbox,
        'rmsError': rmsError,
        'maxError': maxError,
        'controlPointCount': controlPointCount,
        'targetDefinition': targetDefinition,
        'crsName': crsName,
        'datumName': datumName,
        'datumShiftAssumed': datumShiftAssumed,
        'datumShiftMissing': datumShiftMissing,
        'projectedCrsUnresolved': projectedCrsUnresolved,
      };

  String toJsonString() => jsonEncode(toJson());

  static GeoReference? fromJson(Map<String, dynamic> json) {
    final coefficients = (json['pageToTarget'] as List?)?.cast<num>();
    final bbox = (json['bbox'] as List?)?.cast<num>();
    if (coefficients == null || coefficients.length < 6) return null;
    if (bbox == null || bbox.length < 4) return null;

    final forward = Affine2D(
      coefficients[0].toDouble(),
      coefficients[1].toDouble(),
      coefficients[2].toDouble(),
      coefficients[3].toDouble(),
      coefficients[4].toDouble(),
      coefficients[5].toDouble(),
    );
    final inverse = forward.invert();
    if (inverse == null) return null;

    return GeoReference(
      pageToTarget: forward,
      targetToPage: inverse,
      mode: GeoReferenceMode.values.firstWhere(
        (m) => m.name == json['mode'],
        orElse: () => GeoReferenceMode.geografico,
      ),
      bbox: [for (final v in bbox) v.toDouble()],
      rmsError: (json['rmsError'] as num?)?.toDouble() ?? 0,
      maxError: (json['maxError'] as num?)?.toDouble() ?? 0,
      controlPointCount: (json['controlPointCount'] as num?)?.toInt() ?? 0,
      targetDefinition: json['targetDefinition'] as String?,
      crsName: json['crsName'] as String?,
      datumName: json['datumName'] as String?,
      datumShiftAssumed: json['datumShiftAssumed'] as bool? ?? false,
      datumShiftMissing: json['datumShiftMissing'] as bool? ?? false,
      projectedCrsUnresolved: json['projectedCrsUnresolved'] as bool? ?? false,
    );
  }

  static GeoReference? fromJsonString(String source) {
    try {
      return fromJson(jsonDecode(source) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'GeoReference(${crsName ?? 'sin CRS'}, ${mode.name}, '
      'rms: ${rmsError.toStringAsFixed(3)})';
}

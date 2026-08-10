// Es una herramienta de consola: escribir por stdout es exactamente su función.
// ignore_for_file: avoid_print

/// Diagnóstico de un GeoPDF desde la línea de comandos.
///
/// ```
/// dart run tool/inspect_geopdf.dart Layout.pdf
/// ```
///
/// Sirve para verificar qué está leyendo realmente el parser antes de meterlo
/// en la app, y para diagnosticar archivos que no se georreferencian bien.
library;

import 'dart:io';

import 'package:avenza_para_pobres/geo/crs/crs_resolver.dart';
import 'package:avenza_para_pobres/geo/geometry/primitives.dart';
import 'package:avenza_para_pobres/geo/geopdf/geopdf_models.dart';
import 'package:avenza_para_pobres/geo/geopdf/geopdf_reader.dart';
import 'package:avenza_para_pobres/geo/measure/geodesy.dart';
import 'package:avenza_para_pobres/geo/pdf/pdf_document.dart';
import 'package:avenza_para_pobres/geo/transform/georeference.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Uso: dart run tool/inspect_geopdf.dart <archivo.pdf>');
    exitCode = 64;
    return;
  }

  final file = File(args.first);
  if (!file.existsSync()) {
    stderr.writeln('No existe el archivo: ${file.path}');
    exitCode = 66;
    return;
  }

  final bytes = file.readAsBytesSync();
  _line('ARCHIVO');
  print('Ruta        : ${file.path}');
  print('Tamaño      : ${(bytes.length / 1024 / 1024).toStringAsFixed(2)} MB');

  final document = PdfDocument.parse(bytes);
  final pages = document.pages;
  print('Páginas     : ${pages.length}');

  final info = GeoPdfReader.readDocument(document);

  for (final page in info.pages) {
    _line('PÁGINA ${page.index + 1}');
    print('MediaBox    : ${_fmtList(page.mediaBox)}');
    print('Tamaño      : ${page.widthPt.toStringAsFixed(2)} x '
        '${page.heightPt.toStringAsFixed(2)} pt');
    print('Rotación    : ${page.rotate}°');

    if (!page.isGeoreferenced) {
      print('Georreferencia: NO — ${_describeIssue(page.issue)}');
      continue;
    }

    print('Viewports   : ${page.viewports.length}');

    for (var i = 0; i < page.viewports.length; i++) {
      final viewport = page.viewports[i];
      _dumpViewport(i, viewport);
    }
  }
}

void _dumpViewport(int index, GeoPdfViewport viewport) {
  final measure = viewport.measure;

  _line('  VIEWPORT $index${viewport.name != null ? ' "${viewport.name}"' : ''}');
  print('  BBox        : ${_fmtList(viewport.bbox)}');
  print('  Puntos ctrl : ${measure.lpts.length}');

  for (var i = 0; i < measure.lpts.length; i++) {
    final l = measure.lpts[i];
    final g = measure.gpts[i];
    print('    LPTS(${l.x.toStringAsFixed(3)}, ${l.y.toStringAsFixed(3)})'
        '  ->  GPTS(${g.latitude.toStringAsFixed(6)}, '
        '${g.longitude.toStringAsFixed(6)})');
  }

  print('  GCS declarado: ${measure.gcs?.type ?? '-'} '
      '/ ${measure.gcs?.displayName ?? '-'}');
  print('  PCS declarado: ${measure.pcs?.type ?? '-'} '
      '/ ${measure.pcs?.displayName ?? '-'}');

  // Qué produce el traductor de WKT a proj4.
  for (final entry in {'GCS': measure.gcs, 'PCS': measure.pcs}.entries) {
    final pair = CrsResolver.resolvePair(entry.value);
    if (pair == null) continue;
    print('  ${entry.key} resuelto:');
    print('    geográfico: ${pair.geographic.definition}');
    print('    proyectado: ${pair.projected?.definition ?? '(ninguno)'}');
  }

  final georeference = GeoReference.fromViewport(viewport);
  if (georeference == null) {
    print('  >> No se pudo construir la georreferencia.');
    return;
  }

  _line('  GEORREFERENCIA');
  print('  CRS         : ${georeference.crsName ?? '-'}');
  print('  Datum       : ${georeference.datumName ?? '-'}');
  print('  Modo        : ${georeference.mode.name}');
  print('  Ajuste      : ${georeference.controlPointCount} puntos, '
      'RMS ${georeference.rmsError.toStringAsFixed(4)}, '
      'máx ${georeference.maxError.toStringAsFixed(4)} '
      '(unidades del CRS destino)');
  print('  Escala      : 1:${georeference.scaleDenominator.round()}');
  print('  m por punto : ${georeference.metersPerPagePoint.toStringAsFixed(3)}');

  final coverage = georeference.coverage;
  print('  Cobertura   : S ${coverage.south.toStringAsFixed(6)}  '
      'W ${coverage.west.toStringAsFixed(6)}  '
      'N ${coverage.north.toStringAsFixed(6)}  '
      'E ${coverage.east.toStringAsFixed(6)}');
  print('  Centro      : ${coverage.center}');

  final width = vincentyDistance(
    LatLon(coverage.center.latitude, coverage.west),
    LatLon(coverage.center.latitude, coverage.east),
  );
  final height = vincentyDistance(
    LatLon(coverage.south, coverage.center.longitude),
    LatLon(coverage.north, coverage.center.longitude),
  );
  print('  Extensión   : ${(width / 1000).toStringAsFixed(3)} x '
      '${(height / 1000).toStringAsFixed(3)} km');

  // Verificación de ida y vuelta: el error debería ser numéricamente nulo.
  _line('  IDA Y VUELTA');
  var worst = 0.0;
  for (final corner in georeference.cornersLatLon) {
    final page = georeference.latLonToPage(corner);
    if (page == null) {
      print('  !! No se pudo invertir $corner');
      continue;
    }
    final back = georeference.pageToLatLon(page);
    final error = vincentyDistance(corner, back);
    if (error > worst) worst = error;
  }
  print('  Error máximo: ${worst.toStringAsFixed(6)} m');

  // Contraste contra los propios puntos de control del archivo: mide cuánto
  // se desvía nuestra transformación de lo que declara el PDF.
  _line('  RESIDUOS vs PUNTOS DE CONTROL DEL ARCHIVO');
  final bbox = viewport.bbox;
  var maxResidual = 0.0;
  for (var i = 0; i < measure.lpts.length; i++) {
    final l = measure.lpts[i];
    final page = Point2(
      bbox[0] + l.x * (bbox[2] - bbox[0]),
      bbox[1] + l.y * (bbox[3] - bbox[1]),
    );
    final computed = georeference.pageToLatLon(page);
    final declared = measure.gpts[i];
    final error = vincentyDistance(declared, computed);
    if (error > maxResidual) maxResidual = error;
    print('    punto $i: ${error.toStringAsFixed(4)} m');
  }
  print('  Residuo máx : ${maxResidual.toStringAsFixed(4)} m');

  if (georeference.datumShiftAssumed) {
    print('  AVISO: se asumió una transformación de datum de la tabla interna.');
  }
  if (georeference.datumShiftMissing) {
    print('  AVISO: datum no WGS84 sin transformación conocida.');
  }
  if (georeference.projectedCrsUnresolved) {
    print('  AVISO: CRS proyectado declarado pero no resuelto.');
  }
}

String _describeIssue(GeoPdfIssue? issue) => switch (issue) {
      GeoPdfIssue.sinGeorreferencia => 'la página no trae /VP',
      GeoPdfIssue.formatoLgiDict => 'usa /LGIDict (TerraGo), no soportado',
      GeoPdfIssue.measureInvalido => '/Measure presente pero inválido',
      null => 'motivo desconocido',
    };

String _fmtList(List<double> values) =>
    '[${values.map((v) => v.toStringAsFixed(3)).join(', ')}]';

void _line(String title) {
  print('');
  print('--- $title ${'-' * (60 - title.length).clamp(0, 60)}');
}

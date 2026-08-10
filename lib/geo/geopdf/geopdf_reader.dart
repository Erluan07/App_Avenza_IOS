/// Extracción de la georreferencia de un GeoPDF.
///
/// Busca en cada página el array `/VP` de viewports y, dentro de cada uno, el
/// diccionario `/Measure` de subtipo `/GEO` (ISO 32000-1, §8.8.3) — que es
/// exactamente lo que escribe ArcGIS Pro al exportar un layout.
library;

import 'dart:typed_data';

import '../geometry/primitives.dart';
import '../pdf/pdf_document.dart';
import '../pdf/pdf_object.dart';
import 'geopdf_models.dart';

/// `/Bounds` por defecto cuando el viewport no lo declara: todo el BBox
/// (§8.8.3, tabla 266).
const List<Point2> _defaultBounds = [
  Point2(0, 0),
  Point2(0, 1),
  Point2(1, 1),
  Point2(1, 0),
];

class GeoPdfReader {
  const GeoPdfReader._();

  /// Lee la georreferencia de todas las páginas del PDF.
  ///
  /// Lanza [PdfEncryptedException] si el archivo está protegido.
  static GeoPdfDocumentInfo read(Uint8List bytes) =>
      readDocument(PdfDocument.parse(bytes));

  static GeoPdfDocumentInfo readDocument(PdfDocument doc) {
    final pages = <GeoPdfPageInfo>[];
    for (final page in doc.pages) {
      pages.add(_readPage(doc, page));
    }
    return GeoPdfDocumentInfo(pages: pages);
  }

  static GeoPdfPageInfo _readPage(PdfDocument doc, PdfPage page) {
    final viewports = <GeoPdfViewport>[];
    var sawMeasure = false;

    final vp = page.viewports;
    if (vp != null) {
      for (final item in vp.items) {
        final vpDict = doc.resolveAs<PdfDict>(item);
        if (vpDict == null) continue;

        final measureDict = doc.resolveAs<PdfDict>(vpDict['Measure']);
        if (measureDict == null) continue;

        final subtype = doc.resolveAs<PdfName>(measureDict['Subtype'])?.value;
        if (subtype != 'GEO') continue;
        sawMeasure = true;

        final measure = _readMeasure(doc, measureDict);
        if (measure == null || !measure.isUsable) continue;

        // Sin normalizar: el orden de las esquinas define la orientación del
        // cuadrado unitario de los LPTS (ver GeoPdfViewport.bbox).
        final bbox = _rawRectangle(doc, vpDict['BBox']) ??
            page.cropBox ??
            page.mediaBox;

        viewports.add(
          GeoPdfViewport(
            bbox: bbox,
            measure: measure,
            name: doc.resolveAs<PdfString>(vpDict['Name'])?.asText,
          ),
        );
      }
    }

    GeoPdfIssue? issue;
    if (viewports.isEmpty) {
      if (sawMeasure) {
        issue = GeoPdfIssue.measureInvalido;
      } else if (page.dict.has('LGIDict')) {
        // Georreferencia TerraGo, la que escribía ArcMap. Estructura distinta
        // (/CTM + /Projection); la detectamos para poder dar un mensaje útil.
        issue = GeoPdfIssue.formatoLgiDict;
      } else {
        issue = GeoPdfIssue.sinGeorreferencia;
      }
    }

    return GeoPdfPageInfo(
      index: page.index,
      mediaBox: page.mediaBox,
      rotate: page.rotate,
      viewports: viewports,
      issue: issue,
    );
  }

  static GeoMeasure? _readMeasure(PdfDocument doc, PdfDict dict) {
    final lptsRaw = _numberArray(doc, dict['LPTS']);
    final gptsRaw = _numberArray(doc, dict['GPTS']);
    if (lptsRaw == null || gptsRaw == null) return null;
    if (lptsRaw.length < 6 || lptsRaw.length != gptsRaw.length) return null;

    final lpts = <Point2>[];
    for (var i = 0; i + 1 < lptsRaw.length; i += 2) {
      lpts.add(Point2(lptsRaw[i], lptsRaw[i + 1]));
    }

    // GPTS viene en orden latitud, longitud (§8.8.3, tabla 266).
    final gpts = <LatLon>[];
    for (var i = 0; i + 1 < gptsRaw.length; i += 2) {
      gpts.add(LatLon(gptsRaw[i], gptsRaw[i + 1]));
    }

    final boundsRaw = _numberArray(doc, dict['Bounds']);
    var bounds = _defaultBounds;
    if (boundsRaw != null && boundsRaw.length >= 6) {
      bounds = [
        for (var i = 0; i + 1 < boundsRaw.length; i += 2)
          Point2(boundsRaw[i], boundsRaw[i + 1]),
      ];
    }

    return GeoMeasure(
      lpts: lpts,
      gpts: gpts,
      bounds: bounds,
      gcs: _readCrs(doc, dict['GCS']),
      pcs: _readCrs(doc, dict['PCS']),
      preferredDisplayUnits: _nameArray(doc, dict['PDU']),
    );
  }

  static CrsSpec? _readCrs(PdfDocument doc, PdfObject? obj) {
    final dict = doc.resolveAs<PdfDict>(obj);
    if (dict == null) return null;

    final spec = CrsSpec(
      epsg: doc.resolveAs<PdfNumber>(dict['EPSG'])?.asInt,
      wkt: doc.resolveAs<PdfString>(dict['WKT'])?.asText,
      type: doc.resolveAs<PdfName>(dict['Type'])?.value,
    );
    return spec.isEmpty ? null : spec;
  }

  static List<double>? _numberArray(PdfDocument doc, PdfObject? obj) {
    final arr = doc.resolveAs<PdfArray>(obj);
    if (arr == null) return null;

    final out = <double>[];
    for (final item in arr.items) {
      final value = doc.resolveNumber(item);
      if (value == null) return null;
      out.add(value);
    }
    return out;
  }

  static List<String>? _nameArray(PdfDocument doc, PdfObject? obj) {
    final arr = doc.resolveAs<PdfArray>(obj);
    if (arr == null) return null;
    return [
      for (final item in arr.items)
        if (doc.resolveAs<PdfName>(item)?.value case final v?) v,
    ];
  }

  /// Lee un rectángulo `[x0, y0, x1, y1]` tal cual, sin ordenar las esquinas.
  static List<double>? _rawRectangle(PdfDocument doc, PdfObject? obj) {
    final values = _numberArray(doc, obj);
    if (values == null || values.length < 4) return null;
    return [values[0], values[1], values[2], values[3]];
  }
}

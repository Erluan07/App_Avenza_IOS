/// Análisis e importación de GeoPDF a un proyecto.
///
/// El parseo corre en otro isolate: recorrer la tabla xref y descomprimir
/// object streams de un PDF grande tarda lo suficiente como para que la
/// interfaz se note trabada si se hace en el hilo principal.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

// Uint8List llega vía drift, que reexporta dart:typed_data.
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../geo/geopdf/geopdf_models.dart';
import '../../geo/geopdf/geopdf_reader.dart';
import '../../geo/pdf/pdf_document.dart';
import '../../geo/transform/georeference.dart';
import '../db/database.dart';
import '../storage/project_storage.dart';

/// Una página del PDF y lo que se pudo averiguar de ella.
///
/// Solo contiene tipos primitivos para poder cruzar la frontera del isolate
/// sin sorpresas; la [GeoReference] se reconstruye desde su JSON al pedirla.
class GeoPdfPageOption {
  const GeoPdfPageOption({
    required this.index,
    required this.mediaBox,
    required this.rotate,
    this.viewportName,
    this.georeferenceJson,
    this.crsName,
    this.datumName,
    this.south,
    this.west,
    this.north,
    this.east,
    this.scaleDenominator,
    this.issue,
    this.hasWarnings = false,
  });

  final int index;
  final List<double> mediaBox;
  final int rotate;
  final String? viewportName;

  final String? georeferenceJson;
  final String? crsName;
  final String? datumName;

  final double? south;
  final double? west;
  final double? north;
  final double? east;
  final double? scaleDenominator;

  /// Nombre del [GeoPdfIssue] cuando la página no se pudo georreferenciar.
  final String? issue;

  /// Hay avisos sobre el datum o el CRS que conviene mostrar al usuario.
  final bool hasWarnings;

  bool get isGeoreferenced => georeferenceJson != null;

  GeoReference? get georeference => georeferenceJson == null
      ? null
      : GeoReference.fromJsonString(georeferenceJson!);

  String get issueLabel => switch (issue) {
        'sinGeorreferencia' => 'La página no tiene georreferencia',
        'formatoLgiDict' => 'Usa el formato TerraGo (/LGIDict), aún no soportado',
        'measureInvalido' => 'La georreferencia está incompleta o es inconsistente',
        _ => 'No se pudo georreferenciar',
      };
}

class GeoPdfAnalysis {
  const GeoPdfAnalysis({required this.pages, this.error});

  final List<GeoPdfPageOption> pages;

  /// Mensaje de error cuando el archivo no se pudo leer siquiera.
  final String? error;

  bool get isReadable => error == null;

  bool get hasAnyGeoreference => pages.any((page) => page.isGeoreferenced);

  /// Primera página georreferenciada: la que se propone por defecto.
  GeoPdfPageOption? get suggestedPage {
    for (final page in pages) {
      if (page.isGeoreferenced) return page;
    }
    return null;
  }
}

class GeoPdfImportService {
  GeoPdfImportService({
    required this.database,
    required this.storage,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  final AppDatabase database;
  final ProjectStorage storage;
  final Uuid _uuid;

  /// Lee el PDF y reporta qué páginas se pueden georreferenciar, sin tocar
  /// la base de datos ni copiar nada.
  Future<GeoPdfAnalysis> analyze(File file) async {
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException catch (e) {
      return GeoPdfAnalysis(
        pages: const [],
        error: 'No se pudo leer el archivo: ${e.message}',
      );
    }
    return analyzeBytes(bytes);
  }

  Future<GeoPdfAnalysis> analyzeBytes(Uint8List bytes) =>
      Isolate.run(() => analyzeGeoPdfBytes(bytes));

  /// Copia el PDF dentro del proyecto y registra el mapa base con su
  /// georreferencia ya cacheada.
  Future<BaseMap> import({
    required String projectId,
    required File source,
    required GeoPdfPageOption page,
    String? name,
  }) async {
    if (!page.isGeoreferenced) {
      throw ArgumentError('La página ${page.index} no está georreferenciada');
    }

    await storage.ensureProjectDirs(projectId);
    final relativePath = await storage.importFile(
      projectId: projectId,
      source: source,
      destination: storage.mapsDir(projectId),
    );

    final id = _uuid.v4();
    final now = DateTime.now();

    final companion = BaseMapsCompanion.insert(
      id: id,
      projectId: projectId,
      name: name ?? p.basenameWithoutExtension(source.path),
      filePath: relativePath,
      pageIndex: Value(page.index),
      pageRotate: Value(page.rotate),
      mediaBoxJson: jsonEncode(page.mediaBox),
      georeferenceJson: page.georeferenceJson!,
      coverageSouth: page.south ?? 0,
      coverageWest: page.west ?? 0,
      coverageNorth: page.north ?? 0,
      coverageEast: page.east ?? 0,
      crsName: Value(page.crsName),
      createdAt: now,
    );

    await database.into(database.baseMaps).insert(companion);
    return (await (database.select(database.baseMaps)
              ..where((t) => t.id.equals(id)))
            .getSingle());
  }

  /// Borra el mapa base y su archivo.
  Future<void> remove(BaseMap baseMap) async {
    final file = storage.resolve(baseMap.projectId, baseMap.filePath);
    if (file.existsSync()) await file.delete();
    await (database.delete(database.baseMaps)
          ..where((t) => t.id.equals(baseMap.id)))
        .go();
  }
}

/// Función de nivel superior porque es lo que se ejecuta dentro del isolate.
GeoPdfAnalysis analyzeGeoPdfBytes(Uint8List bytes) {
  final PdfDocument document;
  try {
    document = PdfDocument.parse(bytes);
  } on PdfEncryptedException {
    return const GeoPdfAnalysis(
      pages: [],
      error: 'El PDF está protegido con contraseña.',
    );
  } catch (e) {
    return GeoPdfAnalysis(
      pages: const [],
      error: 'No se pudo interpretar el PDF: $e',
    );
  }

  final info = GeoPdfReader.readDocument(document);
  if (info.pages.isEmpty) {
    return const GeoPdfAnalysis(
      pages: [],
      error: 'El PDF no contiene páginas legibles.',
    );
  }

  final options = <GeoPdfPageOption>[];
  for (final page in info.pages) {
    final viewport = page.primaryViewport;
    final georeference =
        viewport == null ? null : GeoReference.fromViewport(viewport);

    if (georeference == null) {
      options.add(
        GeoPdfPageOption(
          index: page.index,
          mediaBox: page.mediaBox,
          rotate: page.rotate,
          viewportName: viewport?.name,
          issue: (page.issue ?? GeoPdfIssue.measureInvalido).name,
        ),
      );
      continue;
    }

    final coverage = georeference.coverage;
    options.add(
      GeoPdfPageOption(
        index: page.index,
        mediaBox: page.mediaBox,
        rotate: page.rotate,
        viewportName: viewport?.name,
        georeferenceJson: georeference.toJsonString(),
        crsName: georeference.crsName,
        datumName: georeference.datumName,
        south: coverage.south,
        west: coverage.west,
        north: coverage.north,
        east: coverage.east,
        scaleDenominator: georeference.scaleDenominator,
        hasWarnings: !georeference.isReliable ||
            georeference.datumShiftAssumed,
      ),
    );
  }

  return GeoPdfAnalysis(pages: options);
}

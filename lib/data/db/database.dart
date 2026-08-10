/// Esquema de la base de datos local (SQLite vía drift).
///
/// Los archivos pesados —el PDF, las fotos, los videos— viven en el sistema de
/// archivos; aquí solo van sus rutas relativas. Meter blobs en SQLite haría la
/// base lenta y las copias de seguridad inmanejables.
library;

import 'package:drift/drift.dart';

import '../../geo/geometry/geometry.dart';
import '../models/enums.dart';

part 'database.g.dart';

class Projects extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().withLength(min: 1, max: 200)();
  TextColumn get description => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Un GeoPDF importado a un proyecto.
@TableIndex(name: 'idx_base_maps_project', columns: {#projectId})
class BaseMaps extends Table {
  TextColumn get id => text()();
  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();

  /// Ruta del PDF, relativa a la carpeta del proyecto.
  TextColumn get filePath => text()();

  IntColumn get pageIndex => integer().withDefault(const Constant(0))();

  /// `/Rotate` de la página: hace falta para mapear píxeles a puntos de página.
  IntColumn get pageRotate => integer().withDefault(const Constant(0))();

  /// Corrección manual de orientación, en grados (0, 90, 180 o 270).
  ///
  /// La detección automática cubre la mayoría de los casos, pero hay PDF donde
  /// ni las proporciones delatan si el renderer rotó la página. Esto deja al
  /// usuario enderezar el mapa desde el panel de capas.
  IntColumn get rotationAdjust => integer().withDefault(const Constant(0))();

  /// MediaBox `[minX, minY, maxX, maxY]` serializado.
  TextColumn get mediaBoxJson => text()();

  /// [GeoReference] serializada. Se cachea al importar porque parsear el PDF
  /// entero en cada apertura es caro y el resultado nunca cambia.
  TextColumn get georeferenceJson => text()();

  /// Cobertura, desnormalizada para poder encuadrar el mapa sin deserializar
  /// la georreferencia.
  RealColumn get coverageSouth => real()();
  RealColumn get coverageWest => real()();
  RealColumn get coverageNorth => real()();
  RealColumn get coverageEast => real()();

  TextColumn get crsName => text().nullable()();
  BoolColumn get visible => boolean().withDefault(const Constant(true))();
  RealColumn get opacity => real().withDefault(const Constant(1))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Capa de captura. Una capa tiene un único tipo de geometría, igual que un
/// shapefile, para que los atributos y la simbología sean coherentes.
@TableIndex(name: 'idx_layers_project', columns: {#projectId})
class FeatureLayers extends Table {
  TextColumn get id => text()();
  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  TextColumn get geometryType => textEnum<GeometryType>()();

  /// Color ARGB de la simbología.
  IntColumn get color => integer().withDefault(const Constant(0xFFE53935))();

  BoolColumn get visible => boolean().withDefault(const Constant(true))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Definición de un campo de atributo. El esquema es por capa y lo configura
/// el usuario: nombre y descripción son solo los campos que trae una capa
/// nueva, no un esquema fijo.
@TableIndex(name: 'idx_fields_layer', columns: {#layerId})
class FieldDefs extends Table {
  TextColumn get id => text()();
  TextColumn get layerId =>
      text().references(FeatureLayers, #id, onDelete: KeyAction.cascade)();

  /// Clave con la que se guarda el valor en `MapFeatures.attributesJson`.
  TextColumn get key => text()();

  TextColumn get label => text()();
  TextColumn get type => textEnum<FieldType>()();
  BoolColumn get required => boolean().withDefault(const Constant(false))();

  /// Opciones disponibles cuando el tipo es [FieldType.lista].
  TextColumn get optionsJson => text().nullable()();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Un elemento capturado: geometría más atributos.
@TableIndex(name: 'idx_features_layer', columns: {#layerId})
@TableIndex(name: 'idx_features_centroid', columns: {#centroidLat, #centroidLon})
class MapFeatures extends Table {
  TextColumn get id => text()();
  TextColumn get layerId =>
      text().references(FeatureLayers, #id, onDelete: KeyAction.cascade)();

  TextColumn get name => text().nullable()();
  TextColumn get description => text().nullable()();

  /// Geometría en GeoJSON (orden longitud, latitud).
  TextColumn get geometryJson => text()();

  /// Valores de los campos definidos en [FieldDefs], como objeto JSON.
  TextColumn get attributesJson => text().withDefault(const Constant('{}'))();

  /// Centroide desnormalizado: permite ordenar y filtrar por zona sin tener
  /// que deserializar la geometría de cada elemento.
  RealColumn get centroidLat => real()();
  RealColumn get centroidLon => real()();

  /// Precisión del GPS en el momento de capturar, en metros. Se guarda porque
  /// en campo importa saber con qué confianza se tomó cada punto.
  RealColumn get gpsAccuracy => real().nullable()();
  RealColumn get elevation => real().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Foto, video o audio asociado a un elemento.
@TableIndex(name: 'idx_attachments_feature', columns: {#featureId})
class Attachments extends Table {
  TextColumn get id => text()();
  TextColumn get featureId =>
      text().references(MapFeatures, #id, onDelete: KeyAction.cascade)();

  TextColumn get kind => textEnum<AttachmentKind>()();

  /// Ruta relativa a la carpeta de multimedia del proyecto.
  TextColumn get filePath => text()();

  TextColumn get caption => text().nullable()();
  IntColumn get sizeBytes => integer().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  // --- Metadatos del momento de la toma ---
  //
  // Se guardan aparte del archivo a propósito. El EXIF viaja dentro del JPEG,
  // pero se pierde en cuanto la foto pasa por WhatsApp o se reencoda; en la
  // base sobrevive, y además permite consultar sin abrir cada imagen.

  /// Cuándo se tomó. Puede diferir de [createdAt], que es cuándo se adjuntó:
  /// una foto elegida de la galería se sacó mucho antes.
  DateTimeColumn get capturedAt => dateTime().nullable()();

  RealColumn get latitude => real().nullable()();
  RealColumn get longitude => real().nullable()();
  RealColumn get accuracy => real().nullable()();
  RealColumn get elevation => real().nullable()();

  /// Rumbo de la brújula al disparar, en grados desde el norte. Es hacia dónde
  /// apuntaba la cámara, que en campo importa tanto como dónde estaba.
  RealColumn get heading => real().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Un recorrido grabado automáticamente mientras el usuario camina.
///
/// Se guarda aparte de [MapFeatures] porque tiene naturaleza distinta: se
/// registra solo, crece durante horas y cada posición lleva su hora y su
/// precisión. Meterlo como una geometría JSON obligaría a reescribir el
/// registro entero con cada punto nuevo.
@TableIndex(name: 'idx_tracks_project', columns: {#projectId})
class Tracks extends Table {
  TextColumn get id => text()();
  TextColumn get projectId =>
      text().references(Projects, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();

  IntColumn get color => integer().withDefault(const Constant(0xFF1E88E5))();
  BoolColumn get visible => boolean().withDefault(const Constant(true))();

  DateTimeColumn get startedAt => dateTime()();

  /// `null` mientras la grabación sigue abierta. Sirve además para detectar
  /// recorridos que quedaron colgados si la app se cerró de golpe.
  DateTimeColumn get endedAt => dateTime().nullable()();

  /// Distancia y número de puntos acumulados, para poder listar recorridos sin
  /// tener que leer todos sus puntos.
  RealColumn get distanceMeters => real().withDefault(const Constant(0))();
  IntColumn get pointCount => integer().withDefault(const Constant(0))();

  TextColumn get notes => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Cada posición registrada durante un recorrido.
///
/// Se inserta una fila por punto: es una escritura mínima, así que si la app
/// muere a mitad de camino solo se pierde el último punto, no el recorrido.
@TableIndex(name: 'idx_track_points_track', columns: {#trackId, #sequence})
class TrackPoints extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get trackId =>
      text().references(Tracks, #id, onDelete: KeyAction.cascade)();

  /// Orden dentro del recorrido. No basta con la hora: dos lecturas pueden
  /// compartir marca temporal.
  IntColumn get sequence => integer()();

  RealColumn get latitude => real()();
  RealColumn get longitude => real()();
  RealColumn get accuracy => real().nullable()();
  RealColumn get elevation => real().nullable()();
  RealColumn get speed => real().nullable()();

  DateTimeColumn get recordedAt => dateTime()();
}

@DriftDatabase(
  tables: [
    Projects,
    BaseMaps,
    FeatureLayers,
    FieldDefs,
    MapFeatures,
    Attachments,
    Tracks,
    TrackPoints,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // v2: recorridos grabados por GPS.
          if (from < 2) {
            await m.createTable(tracks);
            await m.createTable(trackPoints);
            // Los índices se crean explícitamente: `createTable` no arrastra
            // los declarados con @TableIndex.
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_tracks_project '
              'ON tracks (project_id)',
            );
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_track_points_track '
              'ON track_points (track_id, sequence)',
            );
          }

          // v3: metadatos de captura en los adjuntos. Se añaden como columnas
          // nulables, así las fotos ya guardadas siguen siendo válidas: no
          // tenían estos datos y no hay forma de reconstruirlos.
          if (from < 3) {
            await m.addColumn(attachments, attachments.capturedAt);
            await m.addColumn(attachments, attachments.latitude);
            await m.addColumn(attachments, attachments.longitude);
            await m.addColumn(attachments, attachments.accuracy);
            await m.addColumn(attachments, attachments.elevation);
            await m.addColumn(attachments, attachments.heading);
          }

          // v4: corrección manual de orientación de los mapas base.
          if (from < 4) {
            await m.addColumn(baseMaps, baseMaps.rotationAdjust);
          }
        },
        beforeOpen: (details) async {
          // SQLite ignora las claves foráneas salvo que se activen en cada
          // conexión, y sin esto el borrado en cascada no ocurre.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}

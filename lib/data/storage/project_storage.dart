/// Organización de los archivos en disco.
///
/// En la base de datos solo se guardan rutas **relativas** a la carpeta del
/// proyecto. Así el proyecto entero se puede mover, respaldar o restaurar sin
/// que las referencias queden apuntando a rutas absolutas de otro dispositivo
/// — que es exactamente lo que rompe las copias de seguridad ingenuas.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

class ProjectStorage {
  ProjectStorage(this.root);

  /// Carpeta que contiene un subdirectorio por proyecto.
  ///
  /// Se recibe ya resuelta en lugar de consultarla aquí: así esta clase no
  /// depende de Flutter y se puede testear con un directorio temporal.
  final Directory root;

  Directory projectDir(String projectId) =>
      Directory(p.join(root.path, projectId));

  /// Mapas base (los GeoPDF importados).
  Directory mapsDir(String projectId) =>
      Directory(p.join(root.path, projectId, 'maps'));

  /// Fotos, videos y audio de los elementos capturados.
  Directory mediaDir(String projectId) =>
      Directory(p.join(root.path, projectId, 'media'));

  Future<void> ensureProjectDirs(String projectId) async {
    await mapsDir(projectId).create(recursive: true);
    await mediaDir(projectId).create(recursive: true);
  }

  /// Ruta absoluta a partir de la relativa guardada en la base de datos.
  File resolve(String projectId, String relativePath) =>
      File(p.join(projectDir(projectId).path, relativePath));

  String relativePathOf(String projectId, File file) =>
      p.relative(file.path, from: projectDir(projectId).path).replaceAll(
            r'\',
            '/',
          );

  /// Copia un archivo externo dentro del proyecto y devuelve su ruta relativa.
  ///
  /// Si ya existe un archivo con ese nombre le añade un sufijo, en lugar de
  /// sobrescribir: importar dos mapas distintos llamados `Layout.pdf` es un
  /// caso normal, perder el primero no lo es.
  ///
  /// Con [bytes] se escribe ese contenido en lugar de copiar [source], que
  /// entonces solo aporta el nombre. Sirve para guardar una versión procesada
  /// —por ejemplo una foto ya estampada— sin alterar el archivo original.
  Future<String> importFile({
    required String projectId,
    required File source,
    required Directory destination,
    String? preferredName,
    Uint8List? bytes,
  }) async {
    await destination.create(recursive: true);

    final name = preferredName ?? p.basename(source.path);
    final extension = p.extension(name);
    final stem = p.basenameWithoutExtension(name);

    var candidate = File(p.join(destination.path, name));
    var counter = 1;
    while (candidate.existsSync()) {
      candidate = File(p.join(destination.path, '$stem-$counter$extension'));
      counter++;
    }

    if (bytes != null) {
      await candidate.writeAsBytes(bytes, flush: true);
    } else {
      await source.copy(candidate.path);
    }
    return relativePathOf(projectId, candidate);
  }

  /// Borra la carpeta completa de un proyecto (mapas y multimedia incluidos).
  Future<void> deleteProject(String projectId) async {
    final directory = projectDir(projectId);
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  }

  /// Espacio ocupado por un proyecto, en bytes.
  Future<int> projectSize(String projectId) async {
    final directory = projectDir(projectId);
    if (!directory.existsSync()) return 0;

    var total = 0;
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }
}

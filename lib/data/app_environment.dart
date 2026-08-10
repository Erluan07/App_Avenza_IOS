/// Enlace entre la capa de datos —que es Dart puro— y las rutas reales del
/// dispositivo.
///
/// Es el único archivo de `lib/data/` que importa Flutter. Todo lo demás
/// recibe sus rutas ya resueltas, y por eso se puede testear sin emulador.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db/connection.dart';
import 'db/database.dart';
import 'storage/project_storage.dart';

/// Base de datos de la app, en el directorio de documentos.
Future<AppDatabase> openAppDatabase() async {
  final directory = await getApplicationDocumentsDirectory();
  final file = File(p.join(directory.path, 'avenza.sqlite'));
  await file.parent.create(recursive: true);
  return openDatabaseAt(file);
}

/// Carpeta raíz donde viven los proyectos con sus mapas y multimedia.
Future<ProjectStorage> openProjectStorage() async {
  final documents = await getApplicationDocumentsDirectory();
  final root = Directory(p.join(documents.path, 'projects'));
  await root.create(recursive: true);
  return ProjectStorage(root);
}

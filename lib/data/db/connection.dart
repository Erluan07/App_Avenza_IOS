/// Aperturas de base de datos que **no** dependen de Flutter.
///
/// Las que sí resuelven rutas del dispositivo viven en `app_environment.dart`.
/// Mantener esta separación es lo que permite testear toda la capa de datos
/// con `dart test`, sin emulador ni harness de Flutter.
library;

import 'dart:io';

import 'package:drift/native.dart';

import 'database.dart';

/// Base de datos en memoria, para tests.
AppDatabase openInMemoryDatabase() => AppDatabase(NativeDatabase.memory());

/// Base de datos sobre un archivo concreto.
///
/// `createInBackground` la abre en otro isolate: así una consulta pesada
/// (listar los miles de puntos de un track) no congela la interfaz.
AppDatabase openDatabaseAt(File file) =>
    AppDatabase(NativeDatabase.createInBackground(file));

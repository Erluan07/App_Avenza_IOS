import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'data/app_environment.dart';
import 'features/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Sin esto, formatear una fecha en español lanza excepción.
  await initializeDateFormatting('es');

  // Se inicializan aquí y se inyectan como valores concretos: el resto de la
  // app los consume de forma síncrona, sin manejar estados de carga en cada
  // pantalla.
  final database = await openAppDatabase();
  final storage = await openProjectStorage();

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        storageProvider.overrideWithValue(storage),
      ],
      child: const AvenzaApp(),
    ),
  );
}

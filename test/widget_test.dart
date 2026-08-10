/// Test de humo de la interfaz.
///
/// La app real necesita base de datos y almacenamiento ya inicializados, así
/// que aquí solo se verifica que el árbol de widgets se construya. La lógica
/// de verdad está cubierta por `test/geo` y `test/data`, que corren sin
/// Flutter y son mucho más rápidos.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('el tema de la app se construye sin errores', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1B5E20),
          ),
        ),
        home: const Scaffold(body: Center(child: Text('Avenza para Pobres'))),
      ),
    );

    expect(find.text('Avenza para Pobres'), findsOneWidget);
  });
}

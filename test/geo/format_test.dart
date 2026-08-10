/// Tests del formateo de medidas.
library;

import 'package:test/test.dart';

import 'package:avenza_para_pobres/geo/measure/format.dart';

void main() {
  group('Distancias', () {
    test('por debajo del metro se muestra en centímetros', () {
      expect(formatDistance(0.5), '50 cm');
      expect(formatDistance(0.07), '7 cm');
    });

    test('en la escala de trabajo de campo va en metros', () {
      // Un decimal por debajo de 100 m, donde el GPS todavía lo justifica.
      expect(formatDistance(5.54), '5.5 m');
      expect(formatDistance(99.9), '99.9 m');
      // Por encima el decimal sobra.
      expect(formatDistance(150.4), '150 m');
    });

    test('a partir del kilómetro cambia de unidad', () {
      expect(formatDistance(1500), '1.50 km');
      expect(formatDistance(15000), '15.0 km');
    });

    test('los valores imposibles no revientan', () {
      expect(formatDistance(double.nan), '—');
      expect(formatDistance(double.infinity), '—');
      expect(formatDistance(-5), '—');
    });
  });

  group('Áreas', () {
    test('las superficies chicas van en metros cuadrados', () {
      expect(formatArea(500), '500 m²');
      expect(formatArea(9999), '9999 m²');
    });

    test('a partir de una hectárea usa hectáreas', () {
      // Es la unidad en que se habla de predios, que es el caso de uso real.
      expect(formatArea(10000), '1.00 ha');
      expect(formatArea(15000), '1.50 ha');
      expect(formatArea(2000000), '200.0 ha');
    });

    test('las superficies muy grandes pasan a kilómetros cuadrados', () {
      expect(formatArea(200000000), '200.00 km²');
    });
  });

  group('Coordenadas', () {
    test('los grados decimales se cortan al centímetro', () {
      // Siete decimales son ~1 cm: más allá es ruido.
      expect(formatLatLon(6.2402649123), '6.2402649');
    });

    test('convierte a grados, minutos y segundos con hemisferio', () {
      expect(formatDms(6.2402649, isLatitude: true), '6° 14\' 25.0" N');
      expect(formatDms(-75.5354646, isLatitude: false), '75° 32\' 7.7" W');
    });

    test('el hemisferio depende del signo y del eje', () {
      expect(formatDms(-6.5, isLatitude: true), contains('S'));
      expect(formatDms(6.5, isLatitude: true), contains('N'));
      expect(formatDms(75.5, isLatitude: false), contains('E'));
    });
  });

  group('Precisión', () {
    test('acompaña el número con su interpretación', () {
      // El número solo no le dice nada a quien está en campo.
      expect(formatAccuracy(4.2), '±4.2 m (buena)');
      expect(formatAccuracy(25), '±25 m (aceptable)');
      expect(formatAccuracy(60), '±60 m (baja)');
    });

    test('sin dato no inventa un valor', () {
      expect(formatAccuracy(0), 'Sin dato');
      expect(formatAccuracy(double.nan), 'Sin dato');
    });
  });
}

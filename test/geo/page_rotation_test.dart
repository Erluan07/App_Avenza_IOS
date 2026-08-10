/// Tests de la orientación de la imagen rasterizada.
///
/// Los tests anteriores solo comprobaban que la ida y vuelta fuera
/// consistente, lo que se cumple igual con las fórmulas mal puestas. Estos
/// fijan **dónde acaba cada esquina**, que es lo que se veía torcido.
library;

import 'package:test/test.dart';

import 'package:avenza_para_pobres/geo/geometry/primitives.dart';
import 'package:avenza_para_pobres/geo/transform/page_raster.dart';

/// Página A4 vertical, en puntos.
const _mediaBox = [0.0, 0.0, 600.0, 800.0];

/// Esquinas de la página en su propio espacio (origen abajo-izquierda).
const _abajoIzquierda = Point2(0, 0);
const _abajoDerecha = Point2(600, 0);
const _arribaIzquierda = Point2(0, 800);
const _arribaDerecha = Point2(600, 800);

PageRasterMapping mappingFor(int rotate) {
  // Con un cuarto de vuelta la imagen sale con los lados intercambiados.
  final quarterTurned = rotate == 90 || rotate == 270;
  return PageRasterMapping(
    mediaBox: _mediaBox,
    rotate: rotate,
    imageWidth: quarterTurned ? 800 : 600,
    imageHeight: quarterTurned ? 600 : 800,
  );
}

/// Describe en qué cuadrante de la imagen cae un píxel.
String quadrant(PageRasterMapping mapping, Point2 page) {
  final pixel = mapping.pageToPixel(page);
  final vertical = pixel.y < mapping.imageHeight / 2 ? 'arriba' : 'abajo';
  final horizontal = pixel.x < mapping.imageWidth / 2 ? 'izquierda' : 'derecha';
  return '$vertical-$horizontal';
}

void main() {
  group('Sin rotación', () {
    final mapping = mappingFor(0);

    test('el origen del PDF cae abajo-izquierda de la imagen', () {
      // El PDF tiene el origen abajo-izquierda y la imagen arriba-izquierda:
      // solo se invierte el eje vertical.
      expect(quadrant(mapping, _abajoIzquierda), 'abajo-izquierda');
      expect(quadrant(mapping, _arribaIzquierda), 'arriba-izquierda');
      expect(quadrant(mapping, _arribaDerecha), 'arriba-derecha');
      expect(quadrant(mapping, _abajoDerecha), 'abajo-derecha');
    });
  });

  group('90 grados', () {
    final mapping = mappingFor(90);

    test('la imagen queda apaisada', () {
      expect(mapping.imageWidth, 800);
      expect(mapping.imageHeight, 600);
      expect(mapping.isQuarterTurned, isTrue);
    });

    test('el contenido gira un cuarto de vuelta en sentido horario', () {
      // Lo que estaba arriba en la página aparece a la derecha en la imagen.
      expect(quadrant(mapping, _arribaIzquierda), 'arriba-derecha');
      expect(quadrant(mapping, _abajoIzquierda), 'arriba-izquierda');
      expect(quadrant(mapping, _abajoDerecha), 'abajo-izquierda');
      expect(quadrant(mapping, _arribaDerecha), 'abajo-derecha');
    });
  });

  group('180 grados', () {
    final mapping = mappingFor(180);

    test('la imagen conserva la proporción', () {
      expect(mapping.imageWidth, 600);
      expect(mapping.imageHeight, 800);
      expect(mapping.isQuarterTurned, isFalse);
    });

    test('cada esquina cae en la opuesta', () {
      expect(quadrant(mapping, _arribaIzquierda), 'abajo-derecha');
      expect(quadrant(mapping, _abajoDerecha), 'arriba-izquierda');
      expect(quadrant(mapping, _abajoIzquierda), 'arriba-derecha');
      expect(quadrant(mapping, _arribaDerecha), 'abajo-izquierda');
    });
  });

  group('270 grados', () {
    final mapping = mappingFor(270);

    test('el contenido gira tres cuartos en sentido horario', () {
      // Equivale a un cuarto de vuelta antihorario: lo de arriba va a la
      // izquierda.
      expect(quadrant(mapping, _arribaIzquierda), 'abajo-izquierda');
      expect(quadrant(mapping, _abajoIzquierda), 'abajo-derecha');
      expect(quadrant(mapping, _abajoDerecha), 'arriba-derecha');
      expect(quadrant(mapping, _arribaDerecha), 'arriba-izquierda');
    });
  });

  group('Coherencia entre rotaciones', () {
    test('ninguna rotación espeja la imagen', () {
      // Se recorren las esquinas de la página en sentido antihorario y se mide
      // el área con signo de sus píxeles. El valor absoluto da igual; lo que
      // importa es que **el signo sea el mismo en las cuatro rotaciones**: una
      // que saliera con el signo cambiado estaría volteada respecto del resto.
      //
      // Sale negativo porque el eje vertical se invierte al pasar de la página
      // (Y hacia arriba) a la imagen (Y hacia abajo).
      double signedArea(int rotate) {
        final mapping = mappingFor(rotate);
        final corners = [
          _abajoIzquierda,
          _abajoDerecha,
          _arribaDerecha,
          _arribaIzquierda,
        ].map(mapping.pageToPixel).toList();

        var area = 0.0;
        for (var i = 0; i < corners.length; i++) {
          final a = corners[i];
          final b = corners[(i + 1) % corners.length];
          area += a.x * b.y - b.x * a.y;
        }
        return area;
      }

      final reference = signedArea(0);
      expect(reference, isNot(0));

      for (final rotate in [90, 180, 270]) {
        expect(
          signedArea(rotate).sign,
          reference.sign,
          reason: 'La rotación $rotate sale espejada respecto de la 0.',
        );
      }
    });

    test('la ida y vuelta es exacta en las cuatro rotaciones', () {
      for (final rotate in [0, 90, 180, 270]) {
        final mapping = mappingFor(rotate);
        for (final page in [
          _abajoIzquierda,
          _arribaDerecha,
          const Point2(123, 456),
        ]) {
          final back = mapping.pixelToPage(mapping.pageToPixel(page));
          expect(back.x, closeTo(page.x, 1e-9), reason: 'rotate $rotate');
          expect(back.y, closeTo(page.y, 1e-9), reason: 'rotate $rotate');
        }
      }
    });
  });

  group('MediaBox desplazado', () {
    test('un origen distinto de cero no descoloca la imagen', () {
      // Algunos PDF traen el MediaBox con origen distinto de (0,0).
      const mapping = PageRasterMapping(
        mediaBox: [100, 200, 700, 1000],
        rotate: 0,
        imageWidth: 600,
        imageHeight: 800,
      );

      // La esquina inferior izquierda del MediaBox es el píxel (0, alto).
      final pixel = mapping.pageToPixel(const Point2(100, 200));
      expect(pixel.x, closeTo(0, 1e-9));
      expect(pixel.y, closeTo(800, 1e-9));
    });
  });
}

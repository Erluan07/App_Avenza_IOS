# Avenza para Pobres

App de cartografía de campo offline: abre **GeoPDF exportados desde ArcGIS Pro**, te ubica por
GPS sobre ellos y te deja capturar puntos, líneas y polígonos con atributos, fotos y video.

Alternativa propia a Avenza Maps, sin licencia.

## Estado

| Componente | Estado |
|---|---|
| Lector de PDF (xref streams, object streams, FlateDecode) | ✅ funcionando |
| Extracción de georreferencia `/Measure /GEO` | ✅ funcionando |
| Resolución de CRS (WKT → proj4) y reproyección | ✅ funcionando |
| Transformación página ⇄ lat/lon | ✅ verificada contra archivo real |
| Geodesia (distancias y áreas) | ✅ funcionando |
| Base de datos, repositorios e importación de GeoPDF | ✅ funcionando |
| Visor de mapa con overlay del GeoPDF | ⚠️ compila y pasa tests, **sin verificar visualmente** |
| Captura, GPS, exportación KMZ | ⏳ pendiente |

El APK compila (`build/app/outputs/flutter-apk/app-debug.apk`) y los 45 tests pasan, pero
**la app todavía no se ha ejecutado nunca**. Los tests cubren la matemática de
georreferenciación, no que la imagen se dibuje correctamente sobre el mapa.

Verificado contra `Layout.pdf` (ArcGIS Pro, MAGNA-SIRGAS 2018 / Origen Nacional):
RMS **0,049 m** contra los puntos de control del propio archivo, ida y vuelta exacta.

## Entorno

Todo el toolchain está instalado y `flutter doctor` da verde:

| Componente | Ruta |
|---|---|
| Flutter 3.44.8 / Dart 3.12.2 | `D:\flutter` |
| JDK 21 (Temurin) | `D:\Android\jdk` |
| Android SDK 36 + build-tools 36.0.0 | `D:\Android\Sdk` |

## Comandos

Instalar dependencias:

```bash
flutter pub get
```

Correr todos los tests (45):

```bash
flutter test
```

Solo el núcleo geoespacial y la capa de datos, que son Dart puro y arrancan mucho más rápido
porque no levantan el harness de Flutter:

```bash
dart test test/geo test/data
```

Regenerar el código de drift tras tocar el esquema:

```bash
dart run build_runner build
```

Analizar el código:

```bash
dart analyze lib tool test
```

Diagnosticar un GeoPDF — muestra viewports, puntos de control, CRS resuelto, escala,
cobertura y residuos:

```bash
dart run tool/inspect_geopdf.dart Layout.pdf
```

## Notas de build

**Hay que activar el Modo de desarrollador de Windows.** Flutter necesita crear enlaces
simbólicos para los plugins y avisa en cada `pub get`:

```
Building with plugins requires symlink support.
Please enable Developer Mode in your system settings.
```

Se activa desde Configuración → Sistema → Para desarrolladores (`start ms-settings:developers`).
Es un ajuste del sistema, así que hay que hacerlo a mano.

**`file_picker` debe quedarse en 8.x — no lo actualices a 11.x.** El proyecto usa AGP 9, que
está en plena transición al Kotlin integrado, y el ecosistema de plugins está partido en dos:

| Plugin | Comportamiento |
|---|---|
| `pdfx`, `flutter_compass` | aplican el plugin de Kotlin (KGP) siempre |
| `file_picker` 11.x | con AGP 9 **deja** de aplicarlo y delega en el Kotlin integrado |

No hay valor de `android.builtInKotlin` que contente a ambos bandos:

- `false` → los `.kt` de file_picker 11 no se compilan: *cannot find symbol: class FilePickerPlugin*
- `true` → AGP rechaza a los que aplican KGP: *the 'org.jetbrains.kotlin.android' plugin is no
  longer required since AGP 9.0*

La salida es alinear todos los plugins al mismo lado —el viejo, donde está la mayoría— con
`android.builtInKotlin=false`. El único problema real de la 8.x es que fija `compileSdk 34`,
y eso se corrige forzándolo a 36 desde `android/build.gradle.kts`.

Cuando `pdfx` y `flutter_compass` migren al Kotlin integrado, se podrá invertir todo: subir
`file_picker` a 11.x y poner `builtInKotlin=true`. Debe hacerse **de una sola vez**, no plugin
a plugin.

**`kotlin.incremental=false` en `android/gradle.properties` es necesario.** Sin eso, la
compilación de los plugins (`image_picker_android`, `pdfx`) falla en Windows con cachés
incrementales corruptas:

```
Could not close incremental caches in build\image_picker_android\...
Storage for [...\class-fq-name-to-source.tab] is already registered
```

El error real queda enterrado bajo cientos de líneas de stack de Gradle, así que conviene
**no** redirigir stderr al diagnosticar un build fallido: `flutter build apk` escribe ahí lo
único que importa.

## Arquitectura

Ver [ARCHITECTURE.md](ARCHITECTURE.md). En resumen:

- Todo lo geoespacial vive en `lib/geo/` y **no importa Flutter**, así que se testea con
  `dart test` sin emulador.
- El parser de GeoPDF es propio, en Dart puro: evita tener que compilar GDAL nativo para
  Android e iOS.
- El detalle más importante y menos obvio: **ArcGIS Pro escribe el CRS proyectado bajo la
  clave `/GCS` y no emite `/PCS`**. El resolutor clasifica por el contenido del WKT, no por
  el nombre de la clave. Ver §2.1 de la arquitectura.

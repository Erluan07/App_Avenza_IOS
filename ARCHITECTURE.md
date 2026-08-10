# Arquitectura — Avenza para Pobres

App móvil (Flutter) de cartografía de campo: visualiza **GeoPDF** exportados desde **ArcGIS Pro**,
ubica al usuario por GPS sobre ellos y permite capturar puntos, líneas y polígonos con atributos
y multimedia, para luego exportarlos.

---

## 1. Decisiones de arquitectura

| Tema | Decisión | Motivo |
|---|---|---|
| Plataforma | Flutter (Android + iOS) | Un solo código base, buen acceso a GPS/sensores/cámara |
| Georreferenciación | **Parser propio de GeoPDF en Dart puro** | Evita compilar GDAL nativo para Android/iOS. Los PDF vienen de ArcGIS Pro → formato Adobe ISO 32000 estándar |
| Rasterizado del PDF | `pdfx` (PDFium nativo) | Solo dibuja la página; **no** lee la metadata geoespacial (eso lo hace nuestro parser) |
| Reproyección | `proj4dart` + resolutor propio de WKT | Los mapas de ArcGIS suelen estar en CRS proyectado (UTM/LCC), no en lat/lon |
| Mapa | `flutter_map` | Open source, permite overlays de imagen propios y capas WMS a futuro |
| Persistencia | SQLite (`drift`) + archivos en disco | Proyectos/capas/features en DB; PDF, fotos y videos como archivos |
| Estado | `riverpod` | Inyección de dependencias + estado reactivo sin boilerplate |

---

## 2. El problema central: cómo se georreferencia un GeoPDF

Un GeoPDF **no** es una imagen con un "world file" al lado. La georreferencia va embebida en el
propio PDF, en el diccionario `/Measure` de subtipo `/GEO` colgado del *viewport* de la página:

```
/Type /Page
/MediaBox [0 0 2384 1684]
/VP [ << /Type /Viewport
         /BBox [ 120 90 2264 1594 ]        % zona de la página que está georreferenciada
         /Measure << /Type /Measure
                     /Subtype /GEO
                     /Bounds [0 0 0 1 1 1 1 0]      % polígono válido, en cuadrado unitario
                     /LPTS [0 0  0 1  1 1  1 0]     % puntos en cuadrado unitario del BBox
                     /GPTS [lat1 lon1  lat2 lon2 ...]  % sus coordenadas geográficas
                     /GCS << /Type /PROJCS /WKT (...) >>   % ver 2.1: puede ser proyectado
                     /PCS << /Type /PROJCS /WKT (...) >>   % opcional, ArcGIS Pro no lo emite
                  >>
      >> ]
```

Puntos clave del formato (ISO 32000-1, §8.8.3):

- **`/LPTS`** está en un **cuadrado unitario** `[0..1]`, relativo al `/BBox` del viewport —
  **no** en puntos de la página. Hay que desnormalizar contra el BBox.
- **`/GPTS`** siempre viene en **latitud, longitud** (en ese orden), en grados, y siempre en
  coordenadas **geográficas** — aunque el mapa esté proyectado.
- **`/BBox`** está en el espacio de la página PDF, con origen **abajo-izquierda**.
- **El orden de las esquinas del `/BBox` no se puede normalizar.** A diferencia de un
  `/MediaBox`, aquí `[x0 y0 x1 y1]` define hacia dónde crecen los ejes del cuadrado unitario de
  los `LPTS`. ArcGIS Pro escribe `y0 > y1` en algunos layouts, lo que significa que el origen
  del cuadrado está **arriba**. Ordenarlo a mínimos y máximos voltea el mapa de norte a sur, y
  el resultado se ve en espejo — un fallo que ninguna rotación corrige.

### 2.1 Cómo lo escribe ArcGIS Pro (verificado contra archivo real)

**ArcGIS Pro mete el CRS *proyectado* bajo la clave `/GCS`, y no emite `/PCS` en absoluto.**

Verificado sobre `Layout.pdf`, exportado desde ArcGIS Pro:

```
/GCS << /Type /PROJCS
        /WKT (PROJCS["MAGNA-SIRGAS_2018_Origen-Nacional", GEOGCS[...],
                PROJECTION["Transverse_Mercator"], PARAMETER[...]]) >>
```

Es decir: la clave se llama `GCS` pero el `/Type` y el WKT son `PROJCS`. Confiar en el
**nombre de la clave** lleva a interpretar los `GPTS` (que son lat/lon) como coordenadas
proyectadas e intentar desproyectarlas — el resultado son coordenadas sin ningún sentido.

Por eso el resolutor clasifica el CRS **por el contenido del WKT**, no por la clave, y de un
`PROJCS` deriva su `GEOGCS` subyacente (`geographicVariantOf`, en
[crs_resolver.dart](lib/geo/crs/crs_resolver.dart)) para saber en qué sistema están los `GPTS`.
Hay un test de regresión específico para esto.

### 2.2 Por qué no basta con una afín LPTS → GPTS

Si el mapa está en un CRS proyectado (UTM, Lambert…), la relación entre la página y lat/lon
**no es lineal** — es la inversa de la proyección. En una hoja chica el error es despreciable,
pero en un mapa regional se nota. Por eso la cadena correcta es:

```
pixel de pantalla
   → punto de página PDF            (transform del overlay)
   → cuadrado unitario del /BBox    (normalización lineal)
   → coordenada PROYECTADA          (afín exacta, resuelta por mínimos cuadrados)
   → lat/lon                        (inversa de la proyección, vía proj4dart)
```

La afín se resuelve **contra las coordenadas proyectadas**, no contra lat/lon: para eso
proyectamos los `GPTS` (lat/lon) al `/PCS` y ajustamos `LPTS → PCS`. Esa relación sí es
exactamente lineal, porque el layout de ArcGIS dibuja el mapa en coordenadas proyectadas.

Si no hay `/PCS`, se ajusta directo `LPTS → GPTS` (mapa geográfico, la afín es exacta).

### 2.3 Degradación controlada

El resolutor de CRS intenta, en orden:
1. Código `/EPSG` contra tabla propia + registro de `proj4dart`.
2. `/WKT` traducido a cadena proj4 (Transverse Mercator/UTM, Lambert Conformal Conic 1SP/2SP,
   Mercator, geográficos).
3. Si nada resuelve → afín directa sobre lat/lon, marcando la georreferencia como *degradada*
   (la UI avisa que puede haber deriva en mapas de gran extensión).

### 2.4 Lectura del PDF

ArcGIS Pro exporta PDF 1.7 con **cross-reference streams** y **object streams comprimidos**,
así que un escaneo ingenuo del archivo por la cadena `/Measure` falla. El lector implementa:

- Tokenizer de objetos PDF (dicts, arrays, nombres, números, strings, referencias, streams).
- Tabla xref clásica **y** xref stream (`/Type /XRef`, con `/W`, `/Index`, predictores PNG).
- Object streams (`/Type /ObjStm`) para resolver objetos comprimidos.
- `FlateDecode` (zlib, con fallback a deflate crudo).
- **Fallback**: si el xref está corrupto, barrido secuencial de `N G obj` por todo el archivo.

---

## 3. Modelo de datos

```
Project
 ├── BaseMap        (GeoPDF importado: archivo + georreferencia cacheada + nº de página)
 ├── FeatureLayer   (capa de captura; tipo: point | line | polygon)
 │    ├── FieldDef  (esquema de atributos configurable por capa)
 │    └── Feature   (geometría + valores de atributos)
 │         └── Attachment (foto | video | audio, con ruta local)
 └── Settings       (unidades, datum de trabajo, etc.)
```

- La **georreferencia se cachea** en DB al importar el PDF: parsear el PDF en cada apertura es caro.
- Los **atributos son configurables por capa** (`FieldDef`: texto, número, fecha, lista, booleano),
  no un esquema fijo. Nombre/descripción son solo campos por defecto de una capa nueva.
- Los **adjuntos** se guardan como archivos bajo `<app_docs>/projects/<id>/media/` y en DB solo
  va la ruta relativa + metadatos.

---

## 4. Estructura de carpetas

```
lib/
├── main.dart
├── app.dart
├── core/                  utilidades transversales (Result, extensiones, constantes)
├── geo/                   ── TODO Dart puro, testeable sin Flutter ──
│   ├── pdf/               lector de bajo nivel de PDF (lexer, xref, object streams)
│   ├── geopdf/            extracción de /Measure /GEO → GeoReference
│   ├── crs/               resolución de CRS (EPSG, WKT → proj4)
│   ├── transform/         afín por mínimos cuadrados, página ⇄ geo
│   ├── geometry/          tipos de geometría
│   └── measure/           distancias y áreas geodésicas
├── data/
│   ├── db/                esquema drift + DAOs
│   ├── models/            entidades de dominio
│   └── repositories/
├── features/
│   ├── projects/          CRUD de proyectos y capas
│   ├── map/               visor: overlay del GeoPDF, capas, posición GPS
│   ├── capture/           dibujo de geometrías, formularios de atributos, adjuntos
│   ├── measure/           herramientas de medición
│   └── export/            KMZ / GeoJSON / GPX
└── ui/                    widgets y tema compartidos
```

Todo lo geoespacial vive bajo `lib/geo/` **sin importar Flutter**, para poder testearlo con
`dart test` puro y reutilizarlo (p. ej. en una herramienta de escritorio).

---

## 5. Roadmap

### Fase 1 — MVP
- [x] Lector de GeoPDF (xref streams, object streams, `/Measure /GEO`)
- [x] Resolución de CRS y transformación página ⇄ lat/lon
- [x] Verificado contra `Layout.pdf` real: RMS 0,049 m, ida y vuelta exacta
- [x] Modelo de datos SQLite y repositorios reactivos
- [x] Importar GeoPDF a un proyecto y visualizarlo sobre `flutter_map`
- [x] GPS: posición en vivo, círculo de precisión, brújula, modos de seguimiento
- [x] Rotación del mapa con rosa de los vientos
- [x] Captura de puntos / líneas / polígonos
- [x] Atributos configurables + fotos / videos
- [x] Mediciones en vivo durante la captura (distancia, área geodésica)
- [x] Grabación automática de recorridos por GPS
- [x] Exportar a KMZ con multimedia

### Fase 2
- [ ] Importar KMZ / SHP / GeoTIFF locales
- [ ] Capas base offline (OSM / satelital) con caché de tiles
- [ ] Edición de vértices de geometrías existentes
- [ ] Exportar GPX y GeoJSON

### Fase 3
- [ ] WMS / WFS con caché offline
- [ ] Google Drive (OAuth) para cargar capas remotas
- [ ] GPS externo Bluetooth / NMEA

---

## 6. Dibujo del GeoPDF sobre el mapa

El PDF se rasteriza **una sola vez** con PDFium (`pdfx`) y la imagen se cachea en disco junto
al archivo. Sobre A4, 2400 px de lado mayor equivalen a unos 290 ppp: suficiente para leer la
toponimia sin que la imagen se coma la memoria del teléfono.

La imagen se **recorta al `/BBox` del viewport** antes de dibujarla. Sin ese recorte, un layout
de ArcGIS con leyenda, título y escala pintaría todos esos elementos sobre el terreno.

El recorte se calcula en espacio de imagen y las esquinas geográficas se derivan de él con
`PageRasterMapping.pixelToPage`, no del `/BBox` directamente. Así el mismo código sirve para
páginas con `/Rotate` 90, 180 o 270 sin casos especiales.

Para colocarla se usa `RotatedOverlayImage`, que acepta tres esquinas: como la georreferencia
es afín, la cuarta queda determinada.

### Orientación de la página

El `/Rotate` del PDF es una instrucción de presentación, y **no todas las plataformas lo
aplican al rasterizar**: en Android `pdfx` delega en `android.graphics.pdf.PdfRenderer`, que sí
lo aplica; en iOS el plugin lo maneja por su cuenta con `getDrawingTransform`.

Dar por hecho que la imagen viene rotada hacía que los mapas con `/Rotate ≠ 0` salieran
girados. Ahora no se supone: se le piden al renderer sus propias dimensiones y se comparan con
la proporción del `/MediaBox`. Si vienen los lados intercambiados, aplicó el cuarto de vuelta;
si coinciden, entregó la página sin rotar y el mapeo no compensa nada.

La detección no alcanza en dos casos —`/Rotate 180`, donde los lados no se intercambian, y las
páginas cuadradas—, así que el panel de capas incluye un **botón para girar el mapa a mano**.
El ajuste se guarda por mapa base y entra en el nombre del archivo de caché, porque cambia el
recorte de la zona georreferenciada.

Ojo con los tests: comprobar solo que la ida y vuelta sea consistente **no detecta una imagen
girada**, porque se cumple igual con las fórmulas mal puestas. Los de
[page_rotation_test.dart](test/geo/page_rotation_test.dart) fijan en qué cuadrante cae cada
esquina, y que ninguna rotación espeje la imagen respecto de las demás.

### Limitación 1: resolución fija

La imagen se rasteriza **una sola vez** a 4096 px de lado mayor (~495 ppp sobre A4). Eso agota
su resolución nativa cerca del **zoom 17,5**; por eso el mapa está topado en zoom 20, que deja
algo de margen de ampliación digital sin llegar a que el motor gráfico no pueda rasterizar la
imagen transformada y la haga desaparecer.

Subir el número no es opción: a 4096 px el bitmap ya ocupa ~95 MB en RGBA, y durante la
importación conviven el de PDFium y el que decodifica Flutter (de ahí `largeHeap`).

**El arreglo real es renderizar por regiones bajo demanda**, a la resolución del zoom actual.
Comprobado que es viable con las piezas actuales:

- `PdfPageTexture.updateRect` de `pdfx` **sí hace renderizado parcial real**: arma una matriz
  `(fullWidth/page.width, 0, -srcX, …)` y pinta solo la región pedida, sin reservar la página
  entera.
- El `cropRect` de `render()`, en cambio, **no sirve**: la implementación Android renderiza el
  bitmap completo y recorta después con `Bitmap.createBitmap`.

Implica cambiar `RotatedOverlayImage` por un `Texture` acoplado a la cámara del mapa.

### Limitación 2: colocación por afín

`flutter_map` dibuja en Web Mercator, y la relación entre el CRS del mapa (Transverse Mercator,
en los archivos de ejemplo) y Web Mercator no es lineal. La colocación por afín introduce por
tanto un error que crece con la extensión de la hoja. En un mapa de pocos kilómetros es
despreciable; en uno regional habría que pasar a teselas. El renderizado por regiones
resolvería las dos limitaciones a la vez.

## 7. Sistema de diseño

Todo el tema vive en [app_theme.dart](lib/ui/app_theme.dart). Decisiones de fondo, pensadas
para uso en campo (no para una app de escritorio):

- **Superficies neutras**, no el tinte violáceo que Material 3 pone por defecto: sobre un mapa,
  ese tinte compite con el contenido. Se parte de un `ColorScheme.fromSeed` armónico y se
  sobrescriben los roles de superficie con grises limpios.
- **Verde topográfico** primario + **ámbar cálido** para herramientas y trazados en curso, que
  resalta sobre el verde del terreno. El ámbar y el semáforo de precisión del GPS van en una
  `ThemeExtension` ([AppColors]) para que cambien solos entre claro y oscuro.
- **Objetivos táctiles de 52 px** en los botones principales: dedos con guantes, o tocando al
  caminar.
- **Títulos con más peso** que el estándar: en exteriores un texto fino se pierde.

El tema es la palanca de mayor alcance: al centralizarlo, cada pantalla lo hereda sin tocarla
una por una.

## 8. Ubicación y orientación

Tres modos de seguimiento, que rotan con el botón flotante:

| Modo | Comportamiento |
|---|---|
| Libre | El mapa no se mueve solo |
| Centrado | Se recentra en la posición, norte arriba |
| Brújula | Se recentra y gira para dejar el rumbo hacia arriba |

Cualquier gesto del usuario devuelve al modo libre: un mapa que se recentra solo mientras
intentás mirar los alrededores es inusable.

**El color del punto codifica la precisión** (verde ≤10 m, naranja ≤30 m, rojo por encima).
En campo importa tanto dónde estás como cuánto podés confiar en ello: capturar un punto con
40 m de error y no saberlo es peor que no capturarlo.

**El cono de rumbo gira con el mapa** (`Marker(rotate: false)`), porque representa una
dirección geográfica. Los chinches de los elementos capturados hacen lo contrario
(`rotate: true`): se mantienen verticales para poder leerlos con el mapa girado.

**La brújula viene filtrada** en `LocationService.watchHeading`: el magnetómetro emite
decenas de lecturas por segundo y el ruido las hace bailar. Sin filtrar, cada lectura
repintaría la capa y giraría el mapa. Se descartan los cambios menores a 1,5°, comparando por
la diferencia angular más corta para que pasar de 359° a 1° cuente como 2° y no como 358°.

## 9. Herramienta de medición

Efímera a propósito ([measure_controller.dart](lib/features/measure/measure_controller.dart)):
no crea capa ni guarda nada, es para medir sobre la marcha y salir. Dos modos —distancia y
área— con las mismas rutinas geodésicas que el resto (`pathLength`, `ringArea`). Cada tramo
muestra su distancia en su punto medio, como en las apps de mapas conocidas.

Comparte los toques del mapa con la captura, así que las dos son mutuamente excluyentes:
abrir una cierra la otra.

## 10. Fotos con sello de fecha y ubicación

Cada foto tomada con la cámara de la app queda marcada de **tres formas a la vez**, porque
cada una sobrevive a cosas distintas:

| Dónde | Sobrevive a | Se pierde con |
|---|---|---|
| Sello dibujado sobre la imagen | Reenvíos, capturas, impresiones | Recortar la esquina |
| EXIF dentro del JPEG | Copiar el archivo, Google Photos, QGIS | Reencodar, WhatsApp |
| Columnas en SQLite | Todo lo anterior | Borrar el proyecto |

La posición y el rumbo se leen **antes** de abrir la cámara: mientras el usuario encuadra puede
haberse movido, y lo que interesa es dónde estaba al decidir la toma.

Una foto elegida de la **galería no se sella**: se sacó en otro momento y en otro sitio, y
estamparle la posición actual sería inventar el dato.

### Trampa del EXIF GPS

El setter `IfdDirectory[tag] = valor` deduce el tipo consultando `exifImageTags`, pero **los
tags GPS viven en otro mapa** (`exifGpsTags`). Al no encontrarlos, **descarta el valor en
silencio**: `image.exif.gpsIfd[0x0002] = [[6,1],[14,1],[24950,1000]]` no lanza nada y no
guarda nada.

Hay que construir el `IfdValue` explícitamente (`IfdValueRational.list`, `IfdValueAscii`). Y
como `Rational` no se exporta del paquete, se arma concatenando los `.value` de racionales de
un solo par.

Lo detectó un test que reencoda la foto y **relee** las coordenadas, no uno que solo comprobara
que la llamada no fallaba.

### Procesado

Corre en otro isolate: decodificar y reencodar varios megapíxeles congela la interfaz casi un
segundo. Las fotos se reducen a 2560 px de ancho — de sobra para documentación, y mantiene
manejables el KMZ y el ZIP, que si no llegan a cientos de MB.

## 11. Exportación de fotos en ZIP

Aparte del KMZ, el proyecto se puede sacar como ZIP de fotos organizadas en **una carpeta por
capa**, con el nombre del elemento. Incluye `fotos.csv` con coordenadas, fecha, rumbo y
precisión de cada toma, para volcarlo a una hoja de cálculo o a un SIG.

El CSV lleva **BOM UTF-8**: sin él, Excel lo abre en ANSI y destroza los acentos.

## 12. Importación de KMZ / KML

El lector ([kml_reader.dart](lib/geo/import/kml_reader.dart)) está hecho para tragar archivos
de cualquier origen —Google Earth, QGIS, ArcGIS, receptores GPS—, que difieren bastante:

- **Se busca por nombre local**, ignorando el espacio de nombres: unos escriben `<Placemark>`
  y otros `<kml:Placemark>`.
- Lo que no se entiende **se salta y se avisa**, en vez de abortar la importación entera.
- Acepta también un `.kml` suelto: se detecta por la firma `PK\x03\x04` del ZIP.

Se soportan `Point`, `LineString`, `Polygon`, `LinearRing`, `MultiGeometry` y `gx:Track`
(que Google Earth escribe con espacios en vez de comas). Los atributos se leen tanto de
`Data` como de `SchemaData`, que es lo que emite QGIS.

### Trampas del formato

| Trampa | Qué pasa si se ignora |
|---|---|
| Coordenadas en **lon,lat** | El punto acaba en otro continente |
| Color en **aabbggrr** | El rojo sale azul |
| Anillos **cerrados** | Un vértice duplicado en cada polígono |
| `gx:coord` con **espacios** | No se lee ningún track |

### Agrupación en capas

Una capa de la app tiene un único tipo de geometría, como un shapefile, mientras que una
carpeta KML puede mezclarlos. Por eso se agrupa por **(carpeta, tipo)** y solo se sufija el
nombre —`Mixta (puntos)`— cuando de verdad hay más de un tipo.

La clave de agrupación es un **registro** `(String, GeometryType)`, no una cadena concatenada:
los nombres de carpeta pueden contener cualquier separador que se elija, incluido ` / `. Un
test lo fija.

### Multimedia

Las imágenes que los globos referencian con `<img src="...">` se buscan dentro del KMZ y se
adjuntan a su elemento. La resolución de rutas tolera `./`, distinta caja y subcarpetas,
porque cada generador las escribe distinto. Las URL remotas no se descargan.

## 13. Limitación conocida: video en KMZ

KMZ es un ZIP, y admite empaquetar archivos arbitrarios, pero **Google Earth y la mayoría de
visores no reproducen video embebido de forma confiable**; las fotos sí funcionan bien como
`<img>` dentro del balloon HTML del placemark.

Por eso el export ofrece dos modos:
- **KMZ compatible**: fotos embebidas en el balloon; los videos van dentro del ZIP y se
  referencian como enlace (funciona al descomprimir, no dentro de Google Earth).
- **Paquete completo**: carpeta / ZIP con GeoJSON + toda la multimedia intacta, para respaldo
  o para reimportar a la app sin pérdida.

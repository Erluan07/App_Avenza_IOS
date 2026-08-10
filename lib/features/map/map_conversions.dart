/// Conversión entre las coordenadas del núcleo geoespacial y las de
/// `flutter_map`.
///
/// El núcleo usa su propio [LatLon] a propósito, para no arrastrar
/// dependencias de UI a `lib/geo/`. Esta es la única frontera donde se traduce.
library;

import 'package:latlong2/latlong.dart' as fm;

import '../../geo/geometry/primitives.dart';

extension LatLonToMap on LatLon {
  fm.LatLng get toLatLng => fm.LatLng(latitude, longitude);
}

extension LatLngToGeo on fm.LatLng {
  LatLon get toLatLon => LatLon(latitude, longitude);
}

extension LatLonListToMap on List<LatLon> {
  List<fm.LatLng> get toLatLngList => [for (final p in this) p.toLatLng];
}

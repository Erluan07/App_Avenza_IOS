/// Providers de ubicación y brújula.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'location_service.dart';

final locationServiceProvider = Provider<LocationService>(
  (ref) => const LocationService(),
);

/// Estado del permiso. Se consulta una vez y se reutiliza; `refresh` lo
/// reintenta tras mandar al usuario a los ajustes.
final locationAvailabilityProvider = FutureProvider<LocationAvailability>(
  (ref) => ref.watch(locationServiceProvider).ensurePermission(),
);

/// Posición en vivo. No emite nada si falta el permiso: la UI se queda sin
/// punto en lugar de reventar.
final userPositionProvider = StreamProvider<UserPosition>((ref) async* {
  final service = ref.watch(locationServiceProvider);

  final availability = await service.ensurePermission();
  if (availability != LocationAvailability.disponible) return;

  yield* service.watchPosition();
});

/// Rumbo del teléfono en grados. `null` si no hay magnetómetro fiable.
final headingProvider = StreamProvider<double?>(
  (ref) => ref.watch(locationServiceProvider).watchHeading(),
);

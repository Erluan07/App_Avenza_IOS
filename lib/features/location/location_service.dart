/// Acceso al GPS y a la brújula del dispositivo.
///
/// Envuelve `geolocator` y `flutter_compass` para que el resto de la app no
/// tenga que lidiar con sus estados de permiso ni con sus tipos.
library;

import 'dart:async';

import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

import '../../geo/geometry/primitives.dart';

/// Estado del acceso a la ubicación, ya resuelto a algo accionable.
enum LocationAvailability {
  disponible,

  /// El GPS del dispositivo está apagado.
  servicioApagado,

  /// El usuario negó el permiso, pero se le puede volver a preguntar.
  permisoDenegado,

  /// Negado permanentemente: hay que mandarlo a los ajustes del sistema.
  permisoDenegadoParaSiempre;

  String get mensaje => switch (this) {
        LocationAvailability.disponible => 'Ubicación disponible',
        LocationAvailability.servicioApagado =>
          'El GPS está apagado. Activalo para ver tu posición.',
        LocationAvailability.permisoDenegado =>
          'La app necesita permiso de ubicación para mostrarte en el mapa.',
        LocationAvailability.permisoDenegadoParaSiempre =>
          'El permiso de ubicación está bloqueado. Habilitalo desde los '
              'ajustes del sistema.',
      };
}

/// Posición del usuario, ya despojada de los tipos de geolocator.
class UserPosition {
  const UserPosition({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    this.altitudeMeters,
    this.speedMetersPerSecond,
    this.headingDegrees,
    required this.timestamp,
  });

  final double latitude;
  final double longitude;

  /// Radio de incertidumbre en metros. Es lo que se dibuja como círculo:
  /// en campo importa tanto dónde estás como cuánto se puede confiar en ello.
  final double accuracyMeters;

  final double? altitudeMeters;
  final double? speedMetersPerSecond;

  /// Rumbo del movimiento (no hacia dónde apunta el teléfono).
  final double? headingDegrees;

  final DateTime timestamp;

  LatLon get latLon => LatLon(latitude, longitude);

  /// Clasificación rápida para colorear el indicador de precisión.
  bool get esPrecisa => accuracyMeters <= 10;
  bool get esAceptable => accuracyMeters <= 30;
}

class LocationService {
  const LocationService();

  /// Comprueba el servicio y pide permiso si hace falta.
  Future<LocationAvailability> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationAvailability.servicioApagado;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    return switch (permission) {
      LocationPermission.denied => LocationAvailability.permisoDenegado,
      LocationPermission.deniedForever =>
        LocationAvailability.permisoDenegadoParaSiempre,
      _ => LocationAvailability.disponible,
    };
  }

  /// Flujo continuo de posiciones.
  ///
  /// `distanceFilter: 0` entrega todas las lecturas: para dibujar el punto en
  /// vivo hace falta ver también los cambios de precisión, no solo los
  /// desplazamientos.
  Stream<UserPosition> watchPosition({int distanceFilterMeters = 0}) {
    return Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: distanceFilterMeters,
      ),
    ).map(_toUserPosition);
  }

  Future<UserPosition?> currentPosition() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
        ),
      );
      return _toUserPosition(position);
    } catch (_) {
      return null;
    }
  }

  /// Rumbo al que apunta el teléfono, en grados desde el norte.
  ///
  /// Emite `null` cuando el dispositivo no tiene magnetómetro o la lectura no
  /// es fiable, para que la UI pueda ocultar la flecha en vez de mentir.
  ///
  /// El magnetómetro dispara decenas de lecturas por segundo y el ruido las
  /// hace bailar sin parar. Sin filtrar, cada una repintaría la capa y giraría
  /// el mapa. [minChangeDegrees] recorta ese caudal a los cambios que de
  /// verdad se ven.
  Stream<double?> watchHeading({double minChangeDegrees = 1.5}) {
    final events = FlutterCompass.events;
    if (events == null) return const Stream<double?>.empty();

    double? lastEmitted;

    return events.map((event) => event.heading).where((heading) {
      if (heading == null) {
        final huboCambio = lastEmitted != null;
        lastEmitted = null;
        return huboCambio;
      }

      final previous = lastEmitted;
      if (previous == null) {
        lastEmitted = heading;
        return true;
      }

      // Diferencia angular más corta: así pasar de 359° a 1° cuenta como 2°,
      // no como 358°.
      var delta = (heading - previous).abs() % 360;
      if (delta > 180) delta = 360 - delta;
      if (delta < minChangeDegrees) return false;

      lastEmitted = heading;
      return true;
    });
  }

  Future<void> openSystemSettings() => Geolocator.openAppSettings();

  Future<void> openLocationSettings() => Geolocator.openLocationSettings();

  static UserPosition _toUserPosition(Position position) => UserPosition(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMeters: position.accuracy,
        altitudeMeters: position.altitude,
        speedMetersPerSecond: position.speed,
        headingDegrees: position.heading,
        timestamp: position.timestamp,
      );
}

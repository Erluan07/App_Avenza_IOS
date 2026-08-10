/// Enumeraciones del dominio, en un archivo aparte porque las usan tanto el
/// esquema de la base de datos como la UI.
library;

/// Tipo de un campo de atributo definido por el usuario en una capa.
enum FieldType {
  texto,
  numero,
  entero,
  fecha,
  booleano,

  /// Lista cerrada de opciones, guardadas en `FieldDef.optionsJson`.
  lista;

  String get label => switch (this) {
        FieldType.texto => 'Texto',
        FieldType.numero => 'Número decimal',
        FieldType.entero => 'Número entero',
        FieldType.fecha => 'Fecha',
        FieldType.booleano => 'Sí / No',
        FieldType.lista => 'Lista de opciones',
      };
}

/// Tipo de archivo adjunto a un elemento capturado.
enum AttachmentKind {
  foto,
  video,
  audio;

  String get label => switch (this) {
        AttachmentKind.foto => 'Foto',
        AttachmentKind.video => 'Video',
        AttachmentKind.audio => 'Audio',
      };

  /// Los KMZ solo muestran fotos de forma fiable dentro del globo del
  /// placemark; el resto va empaquetado pero como enlace.
  bool get embeddableInKmz => this == AttachmentKind.foto;
}

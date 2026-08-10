allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Varios plugins (file_picker 8.x, share_plus 10.x) fijan `compileSdk 34` en
// su build.gradle, pero flutter_plugin_android_lifecycle exige que sus
// consumidores compilen contra la 36, y el build muere en
// :<plugin>:checkDebugAarMetadata.
//
// Se aplica a todos los subproyectos en lugar de ir nombrándolos: los que ya
// usan `flutter.compileSdkVersion` quedan con el mismo valor que tenían, y
// cualquier plugin que se agregue después queda cubierto sin tocar esto.
// Subir el compileSdk es seguro: es la API contra la que se compila, no la
// versión mínima de Android soportada.
//
// Se hace por reflexión a propósito: referenciar el tipo de la extensión de
// AGP obligaría a meter el plugin en el classpath de este script, y además el
// nombre del tipo cambia entre el DSL viejo y el nuevo.
val requiredCompileSdk = 36

subprojects {
    // :app queda fuera: el `evaluationDependsOn(":app")` de arriba lo evalúa
    // antes de llegar aquí, y registrarle un afterEvaluate a esas alturas
    // falla con "project is already evaluated". Además ya hereda el
    // compileSdk correcto de Flutter, así que no hay nada que corregirle.
    if (name == "app") return@subprojects

    afterEvaluate {
        val androidExtension = extensions.findByName("android") ?: return@afterEvaluate
        runCatching {
            androidExtension.javaClass
                .getMethod("compileSdkVersion", Int::class.javaPrimitiveType)
                .invoke(androidExtension, requiredCompileSdk)
        }.onFailure {
            logger.warn("No se pudo fijar compileSdk en :$name: ${it.message}")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

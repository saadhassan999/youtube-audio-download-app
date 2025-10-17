import com.android.build.gradle.LibraryExtension

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

val mediaMetadataNamespace = "com.alexmercerind.flutter_media_metadata"

subprojects {
    if (name == "flutter_media_metadata") {
        plugins.withId("com.android.library") {
            (extensions.findByName("android") as? LibraryExtension)?.apply {
                namespace = mediaMetadataNamespace
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

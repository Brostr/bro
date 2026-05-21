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

    // Force all Android library subprojects (e.g. tflite_flutter) to compile
    // Java at 17 so it matches the Kotlin jvmTarget. Without this, plugins that
    // still declare Java 11 break the build with "Inconsistent JVM-target
    // compatibility detected".
    afterEvaluate {
        extensions.findByName("android")?.let { ext ->
            if (ext is com.android.build.gradle.LibraryExtension) {
                ext.compileOptions.sourceCompatibility = JavaVersion.VERSION_17
                ext.compileOptions.targetCompatibility = JavaVersion.VERSION_17
            } else if (ext is com.android.build.gradle.BaseExtension) {
                ext.compileOptions.sourceCompatibility = JavaVersion.VERSION_17
                ext.compileOptions.targetCompatibility = JavaVersion.VERSION_17
            }
        }
        tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = JavaVersion.VERSION_17.toString()
            targetCompatibility = JavaVersion.VERSION_17.toString()
        }
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            kotlinOptions {
                jvmTarget = JavaVersion.VERSION_17.toString()
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

# Keep app-specific release shrinker rules here.

# Flutter and generated plugin entrypoints are loaded reflectively by the engine.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class com.example.flutter_application_1.** { *; }

# Audio playback/effects use services, receivers, reflection, and method channels.
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.just_audio.** { *; }
-keep class androidx.media3.** { *; }

# SharedPreferences and path_provider are plugin-registered at startup.
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class io.flutter.plugins.pathprovider.** { *; }

-keepattributes *Annotation*,InnerClasses,EnclosingMethod,Signature

-dontwarn com.google.android.play.core.**
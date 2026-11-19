# Правила R8 для release-сборки «Мини-канбана».
# Плагины вызываются из Dart по именам каналов и через рефлексию/JNI,
# поэтому их код и код библиотек, которые они грузят по имени, сохраняем.

# --- Flutter и само приложение ---------------------------------------------
-keep class io.flutter.** { *; }
-keep class com.minikanban.** { *; }
-dontwarn io.flutter.embedding.**

# --- Сканер QR: mobile_scanner + CameraX + ML Kit ---------------------------
-keep class dev.steenbakker.mobile_scanner.** { *; }
-keep class androidx.camera.** { *; }
-keep interface androidx.camera.** { *; }
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode_bundled.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }
-keep class com.google.android.gms.vision.** { *; }
-keep class com.google.android.gms.dynamite.** { *; }
-keep class com.google.android.gms.common.** { *; }
-keep class com.google.android.gms.tasks.** { *; }
# ML Kit находит свои компоненты через ComponentRegistrar из манифеста.
-keep class com.google.firebase.components.** { *; }
-keep class * implements com.google.firebase.components.ComponentRegistrar { *; }
-keep class com.google.android.datatransport.** { *; }
-keepclasseswithmembernames class * { native <methods>; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**

# --- Фоновая синхронизация: workmanager -------------------------------------
-keep class dev.fluttercommunity.workmanager.** { *; }
-keep class androidx.work.** { *; }
-keep class androidx.startup.** { *; }
-keep class * extends androidx.work.ListenableWorker { *; }
-keep class * extends androidx.room.RoomDatabase { *; }
-keep class androidx.concurrent.futures.** { *; }

# --- Токен: flutter_secure_storage (Jetpack Security + Tink) ----------------
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class androidx.security.crypto.** { *; }
-keep class com.google.crypto.tink.** { *; }
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite { <fields>; }
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
-dontwarn com.google.api.client.**
-dontwarn org.joda.time.**

# --- Остальные плагины ------------------------------------------------------
-keep class com.haberey.flutter.nsd_android.** { *; }
-keep class com.baseflow.permissionhandler.** { *; }
-keep class com.tekartik.sqflite.** { *; }
-keep class dev.fluttercommunity.plus.device_info.** { *; }
-keep class io.flutter.plugins.pathprovider.** { *; }

# Аннотации и сигнатуры нужны рефлексии Kotlin/ML Kit.
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod

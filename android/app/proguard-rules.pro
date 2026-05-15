# Flutter ProGuard Rules

# =============================================================================
# App's Native Platform Classes (CRITICAL - used by Flutter MethodChannel)
# =============================================================================
# These classes are instantiated via reflection by Flutter and must not be
# stripped or obfuscated, otherwise the app will crash on startup.
-keep class com.example.media_tube.** { *; }
-keepclassmembers class com.example.media_tube.** { *; }

# =============================================================================
# Kotlin Runtime & Metadata
# =============================================================================
# Required for data classes and Kotlin reflection
-keep class kotlin.Metadata { *; }
-keepclassmembers class kotlin.Metadata { *; }
-keep class kotlin.** { *; }
-dontwarn kotlin.**
-dontwarn kotlinx.**

# Keep Kotlin coroutines (used by some plugins)
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}

# Keep Flutter classes
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }

# Keep Flutter engine classes (CRITICAL for release builds)
-keep class io.flutter.embedding.engine.** { *; }
-keep class io.flutter.embedding.android.** { *; }

# FFmpeg Kit
-keep class com.arthenica.ffmpegkit.** { *; }
-keep class com.arthenica.smartexception.** { *; }

# InAppWebView
-keep class com.pichillilorenzo.flutter_inappwebview.** { *; }
-keepclassmembers class * extends android.webkit.WebViewClient {
    public void *(android.webkit.WebView, java.lang.String, android.graphics.Bitmap);
    public boolean *(android.webkit.WebView, java.lang.String);
}
-keep class android.webkit.** { *; }

# Dio / OkHttp
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep class okio.** { *; }

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep Parcelable implementations
-keepclassmembers class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator *;
}

# Keep Serializable classes
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# Keep Flutter Local Notifications plugin
-keep class com.dexterous.** { *; }

# Keep SharedPreferences
-keep class androidx.datastore.preferences.** { *; }

# Keep path_provider
-keep class io.flutter.plugins.pathprovider.** { *; }

# Keep permission_handler
-keep class com.baseflow.permissionhandler.** { *; }

# Keep open_filex
-keep class com.crazecoder.openfile.** { *; }

# Keep package_info_plus
-keep class dev.fluttercommunity.plus.packageinfo.** { *; }

# GSON and JSON parsing
-keepattributes Signature
-keepattributes *Annotation*
-dontwarn sun.misc.**
-keep class com.google.gson.** { *; }

# Suppress warnings
-dontwarn java.lang.invoke.**
-dontwarn javax.annotation.**

# Google Play Core (not used, but referenced by Flutter engine)
-dontwarn com.google.android.play.core.**
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# Keep R8/ProGuard from removing important classes
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# YouTube Explode uses reflection
-keep class * extends java.lang.Enum { *; }
-keepclassmembers class * extends java.lang.Enum {
    <fields>;
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Rhino JavaScript Engine (used by NewPipe extractor)
-keep class org.mozilla.javascript.** { *; }
-dontwarn org.mozilla.javascript.**
-dontwarn jdk.dynalink.**
-keep class jdk.dynalink.** { *; }

# NewPipe Extractor
-keep class org.schabi.newpipe.extractor.** { *; }
-dontwarn org.schabi.newpipe.extractor.**

# JSoup and re2j (used by NewPipe)
-keep class org.jsoup.** { *; }
-dontwarn org.jsoup.**
-dontwarn com.google.re2j.Matcher
-dontwarn com.google.re2j.Pattern



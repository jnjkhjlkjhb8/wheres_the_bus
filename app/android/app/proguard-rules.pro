-keep class io.flutter.** { *; }
-keep class com.google.android.gms.maps.** { *; }
-keep class com.google.maps.** { *; }
-dontwarn io.flutter.embedding.**
-dontwarn com.google.j2objc.annotations.ReflectionSupport
-dontwarn com.google.j2objc.annotations.RetainedWith
-dontwarn com.google.j2objc.annotations.Weak
# Firebase Performance reads its protobuf-lite messages by reflection
# (field "name_" ...); R8 renames those fields and AppStartTrace crashes at launch.
-keep class com.google.firebase.perf.v1.** { *; }
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite {
    <fields>;
}

# Release (R8) rules for FutBeat. The Flutter Gradle plugin adds this file to
# the release build automatically (FlutterPlugin: <app>/proguard-rules.pro).

# Room instantiates every RoomDatabase implementation by reflection through
# its no-arg constructor. WorkManager (pulled in by Google Mobile Ads) creates
# androidx.work.impl.WorkDatabase_Impl at process start; its bundled Room
# 2.2.5 rule keeps the class but not the constructor, which R8 full mode then
# removes, so the app crashed before Flutter started (1.0.0+2 from Play).
-keep class * extends androidx.room.RoomDatabase {
    <init>();
}

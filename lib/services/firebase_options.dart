import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// Firebase project configuration.
///
/// **This file is the only place that knows about the Firebase project.**
/// Replace the placeholder values below with the ones from
/// Firebase Console → Project settings → Your apps → SDK setup and
/// configuration → Config. Nothing else in the app needs to change.
///
/// A web app entry (`appId` starting with `1:`) is what the deployed scheduler
/// uses; the Android entry is only needed for the APK build.
class FirebaseConfig {
  // ---------------------------------------------------------------- web
  // Firebase Console → Project settings → General → Your apps → Web app
  static const webApiKey = 'AIzaSyDUMMY_REPLACE_WITH_YOUR_WEB_API_KEY';
  static const webAppId = '1:000000000000:web:0000000000000000000000';
  static const webAuthDomain = 'june-scheduler.firebaseapp.com';
  static const webStorageBucket = 'june-scheduler.appspot.com';
  static const webMessagingSenderId = '000000000000';

  // ------------------------------------------------------------- project
  static const projectId = 'june-scheduler';

  /// True once the placeholders above have been replaced.
  static bool get isConfigured =>
      !webApiKey.contains('DUMMY') && !webAppId.contains('000000000000');

  static FirebaseOptions get webOptions => FirebaseOptions(
        apiKey: webApiKey,
        appId: webAppId,
        messagingSenderId: webMessagingSenderId,
        projectId: projectId,
        authDomain: webAuthDomain,
        storageBucket: webStorageBucket,
      );
}

/// Initialises Firebase exactly once.
///
/// Returns `false` (instead of throwing) when the project has not been
/// configured yet, so the app still starts, still stores data locally, and
/// simply reports "cloud sync not configured" in Settings.
Future<bool> initFirebase() async {
  if (!FirebaseConfig.isConfigured) {
    debugPrint(
      'CLOUDDBG Firebase is not configured — running in local-only mode. '
      'Fill in lib/services/firebase_options.dart to enable cloud sync.',
    );
    return false;
  }
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: FirebaseConfig.webOptions);
    }
    // The entities map is a single large document; the default cache is fine
    // for a personal scheduler but keep persistence off on web so a shared
    // browser profile never shows another account's cached data.
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: false,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );
    return true;
  } catch (e) {
    debugPrint('CLOUDDBG initFirebase failed: $e');
    return false;
  }
}

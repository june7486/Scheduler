import 'dart:async';

/// Non-web fallback: no browser file picker. Returns null so the caller can
/// fall back to pasting the backup JSON manually.
Future<String?> pickTextFile() async => null;

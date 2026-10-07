import 'dart:typed_data';

/// Non-web fallback: there is no browser download, so the caller should use the
/// share sheet instead. Returns `false` so callers can branch.
bool triggerBrowserDownload(String filename, Uint8List bytes, String mime) {
  return false;
}

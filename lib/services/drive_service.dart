import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'download_stub.dart'
    if (dart.library.js_interop) 'download_web.dart' as downloader;

/// Google Drive upload / backup helper.
///
/// The app cannot hold a Google OAuth token by default, so the flow is:
///   1. On **web**, [backupToDrive] / [downloadToDevice] save the JSON backup
///      straight to the browser's Downloads folder, then [openFolder] opens the
///      configured Drive folder so the user can drop the file in (Drag & drop).
///   2. On **mobile/desktop**, [backupToDrive] shares the JSON file through the
///      system share sheet, where the user picks "Save to Drive" (Drive app).
///   3. [openFolder] opens the configured Drive folder in a browser so the user
///      can drop the file straight into it.
///   4. [uploadFileToDrive] opens the Drive "upload" web endpoint as a manual
///      fallback.
class DriveService {
  /// Builds a `june_scheduler_backup_YYYYMMDD_HHMM.json` filename.
  static String backupFileName([DateTime? now]) {
    final d = now ?? DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'june_scheduler_backup_${d.year}${two(d.month)}${two(d.day)}_'
        '${two(d.hour)}${two(d.minute)}.json';
  }

  /// Pretty-prints [data] as JSON and returns the UTF-8 bytes.
  static Uint8List encode(Map<String, dynamic> data) {
    final json = const JsonEncoder.withIndent('  ').convert(data);
    return Uint8List.fromList(utf8.encode(json));
  }

  /// On web, downloads the backup JSON to the browser's Downloads folder.
  /// On other platforms this is a no-op (returns `false`).
  static bool downloadToDevice(Map<String, dynamic> data, {String? name}) {
    return downloader.triggerBrowserDownload(
      name ?? backupFileName(),
      encode(data),
      'application/json',
    );
  }

  /// Opens a Drive folder (or any URL) in the browser / Drive app.
  static Future<bool> openFolder(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Shares the backup file so the user can save it to Google Drive.
  static Future<bool> backupToDrive(
    Map<String, dynamic> data, {
    String? name,
  }) async {
    try {
      await Share.shareXFiles(
        [
          XFile.fromData(
            encode(data),
            mimeType: 'application/json',
            name: name ?? backupFileName(),
          ),
        ],
        subject: "June's Scheduler backup",
        text: "June's Scheduler backup — save to Google Drive.",
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Web fallback: open the Drive "upload" endpoint in a new tab.
  static Future<bool> uploadFileToDrive(String folderUrl) async {
    final uri = Uri.https('drive.google.com', '/drive/u/0/',
        {'usp': 'docs_upload', 'folder': folderUrl});
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Best-effort: on web download the JSON then open the Drive folder so the
  /// user can drop it in; otherwise share the file so it can be saved to Drive.
  /// Returns a short status message key.
  static Future<String> saveToDrive(
    Map<String, dynamic> data, {
    required String folderUrl,
    String? name,
  }) async {
    if (kIsWeb) {
      final downloaded = downloadToDevice(data, name: name);
      await openFolder(folderUrl);
      return downloaded ? 'drive_downloaded' : 'drive_opened';
    }
    final ok = await backupToDrive(data, name: name);
    return ok ? 'drive_shared' : 'drive_failed';
  }
}

import 'package:shared_preferences/shared_preferences.dart';

/// Manages the 1-hour login session and version/cache handling.
class SessionService {
  static const _kLoginAt = 'login_at';
  static const _kSessionHours = 1;

  /// Returns true if a valid (non-expired) session exists.
  Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_kLoginAt);
    if (ts == null) return false;
    final loginAt = DateTime.fromMillisecondsSinceEpoch(ts);
    return DateTime.now().difference(loginAt).inMinutes < _kSessionHours * 60;
  }

  /// Remaining session time in minutes.
  Future<int> remainingMinutes() async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_kLoginAt);
    if (ts == null) return 0;
    final loginAt = DateTime.fromMillisecondsSinceEpoch(ts);
    final remain =
        _kSessionHours * 60 - DateTime.now().difference(loginAt).inMinutes;
    return remain < 0 ? 0 : remain;
  }

  Future<void> login() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLoginAt, DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLoginAt);
  }

  /// Stores the version string that has been "downloaded".
  Future<void> saveInstalledVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('installed_version', version);
  }

  Future<String?> installedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('installed_version');
  }

  /// Clear cached data (shared preferences cache keys, not user content).
  Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('installed_version');
  }
}

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

Future<bool> isNetworkAvailable() async {
  return true;
}

Future<bool> isPWAInstalled() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('isInstalled') ?? false;
}

Future findWorkingPwaUrl(List urls) async {
  for (final url in urls) {
    try {
      final res = await http.head(Uri.parse(url.toString()))
          .timeout(const Duration(seconds: 10));

      if (res.statusCode >= 200 && res.statusCode < 400) {
        return url;
      }
    } catch (_) {
      // ignore and continue
    }
  }
  return null;
}

void setPWAInstalled({bool installed = true}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('isInstalled', installed);
}

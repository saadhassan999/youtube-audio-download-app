import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettingsNotifier extends ChangeNotifier {
  static const _enableApiSearchKey = 'enable_api_search';
  bool _enableApiSearch = !kReleaseMode;

  bool get enableApiSearch => _enableApiSearch;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enableApiSearch = prefs.getBool(_enableApiSearchKey) ?? !kReleaseMode;
    notifyListeners();
  }

  Future<void> setEnableApiSearch(bool value) async {
    _enableApiSearch = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enableApiSearchKey, _enableApiSearch);
  }
}

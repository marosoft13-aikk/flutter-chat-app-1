// lib/utils/diagnostics_store.dart
import 'package:flutter/foundation.dart';

class DiagnosticsStore {
  static bool firebaseInitialized = false;
  static final List<String> logs = [];
  static final List<String> errors = [];

  static void addLog(String s) {
    logs.insert(0, '${DateTime.now().toIso8601String()}  LOG: $s');
    debugPrint(s);
  }

  static void addError(String s) {
    errors.insert(0, '${DateTime.now().toIso8601String()}  ERROR: $s');
    debugPrint(s);
  }
}

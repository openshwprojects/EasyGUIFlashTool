import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistent command history with frequency tracking.
/// Commands are stored as a JSON map { command: frequency }.
/// Max command length: 1024 chars. Max history entries: 500.
class CommandHistoryService {
  static const String _storageKey = 'command_history';
  static const int maxCommandLength = 1024;
  static const int maxEntries = 500;

  Map<String, int> _history = {};
  bool _initialized = false;

  /// Load history from persistent storage.
  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null) {
      try {
        final decoded = json.decode(raw) as Map<String, dynamic>;
        _history = decoded.map((k, v) => MapEntry(k, v as int));
      } catch (_) {
        _history = {};
      }
    }
    _initialized = true;
  }

  /// Record a sent command. Increments frequency count.
  Future<void> addCommand(String command) async {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return;

    // Enforce max command length
    final stored = trimmed.length > maxCommandLength
        ? trimmed.substring(0, maxCommandLength)
        : trimmed;

    _history[stored] = (_history[stored] ?? 0) + 1;

    // Prune if over limit: remove least-used entries
    if (_history.length > maxEntries) {
      final sorted = _history.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      final toRemove = sorted.take(_history.length - maxEntries);
      for (final entry in toRemove) {
        _history.remove(entry.key);
      }
    }

    await _save();
  }

  /// Get suggestions matching [prefix], sorted by frequency (highest first).
  /// Returns at most [limit] results.
  List<String> getSuggestions(String prefix, {int limit = 10}) {
    if (prefix.trim().isEmpty) return [];
    final lower = prefix.toLowerCase();
    final matches = _history.entries
        .where((e) => e.key.toLowerCase().contains(lower))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return matches.take(limit).map((e) => e.key).toList();
  }

  /// Delete a command from history.
  Future<void> deleteCommand(String command) async {
    _history.remove(command);
    await _save();
  }

  /// Get frequency count for a command.
  int getFrequency(String command) => _history[command] ?? 0;

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, json.encode(_history));
  }
}

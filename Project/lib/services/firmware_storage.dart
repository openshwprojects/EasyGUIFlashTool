import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// General-purpose directory/file manager for firmware files, backups, etc.
/// On native platforms files are persisted to `<appDocDir>/<subdir>/`.
/// On web, files are kept in an in-memory map (lost on refresh).
class FirmwareStorage {
  // Singleton
  static final FirmwareStorage _instance = FirmwareStorage._();
  factory FirmwareStorage() => _instance;
  FirmwareStorage._();

  /// In-memory store for web platform (subdir -> fileName -> bytes).
  final Map<String, Map<String, Uint8List>> _webStore = {};

  // ─── Directory helpers ───

  /// Returns the directory for [subdir], creating it if needed.
  /// Returns `null` on web.
  Future<Directory?> getDir(String subdir) async {
    if (kIsWeb) return null;
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/$subdir');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  // ─── File operations ───

  /// Save [bytes] as [fileName] inside [subdir].
  /// Returns the full file path on native, or `null` on web.
  Future<String?> saveFile(String subdir, String fileName, Uint8List bytes) async {
    if (kIsWeb) {
      _webStore.putIfAbsent(subdir, () => {});
      _webStore[subdir]![fileName] = bytes;
      debugPrint('FirmwareStorage (web): saved $fileName in-memory ($subdir)');
      return null;
    }
    final dir = await getDir(subdir);
    if (dir == null) return null;
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes);
    debugPrint('FirmwareStorage: saved ${file.path}');

    // Remember the last saved file for this subdir
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('firmware_storage_last_${subdir}', fileName);

    return file.path;
  }

  /// List filenames in [subdir], optionally filtered by [prefix].
  Future<List<String>> listFiles(String subdir, {String? prefix}) async {
    if (kIsWeb) {
      final map = _webStore[subdir] ?? {};
      var names = map.keys.toList();
      if (prefix != null) {
        names = names.where((n) => n.startsWith(prefix)).toList();
      }
      names.sort();
      return names;
    }
    final dir = await getDir(subdir);
    if (dir == null || !await dir.exists()) return [];
    final entities = await dir.list().toList();
    var names = entities
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList();
    if (prefix != null) {
      names = names.where((n) => n.startsWith(prefix)).toList();
    }
    names.sort();
    return names;
  }

  /// Full path to [fileName] in [subdir]. Returns `null` on web or if missing.
  Future<String?> getFilePath(String subdir, String fileName) async {
    if (kIsWeb) return null;
    final dir = await getDir(subdir);
    if (dir == null) return null;
    final file = File('${dir.path}/$fileName');
    if (await file.exists()) return file.path;
    return null;
  }

  /// Read file bytes. Works on both native and web.
  Future<Uint8List?> readFile(String subdir, String fileName) async {
    if (kIsWeb) {
      return _webStore[subdir]?[fileName];
    }
    final path = await getFilePath(subdir, fileName);
    if (path == null) return null;
    return File(path).readAsBytes();
  }

  /// Delete a file.
  Future<void> deleteFile(String subdir, String fileName) async {
    if (kIsWeb) {
      _webStore[subdir]?.remove(fileName);
      return;
    }
    final path = await getFilePath(subdir, fileName);
    if (path != null) {
      await File(path).delete();
    }
  }

  /// Get the last saved filename for [subdir] (from shared_preferences).
  Future<String?> getLastSaved(String subdir) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('firmware_storage_last_${subdir}');
  }
}

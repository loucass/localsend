import 'dart:async';

import 'package:dbus/dbus.dart';

/// Client for the org.freedesktop.portal.FileTransfer D-Bus interface.
///
/// This portal is used to retrieve files transferred via drag-and-drop or
/// copy-paste between sandboxed applications. When a file is dragged from
/// a sandboxed app (like Dolphin on Flatpak) to another sandboxed app
/// (like LocalSend on Flatpak), the source app registers the files with
/// the portal and passes a key via the application/vnd.portal.filetransfer
/// mimetype. The target app must call RetrieveFiles with this key to get
/// the actual file paths, which are then accessible within the sandbox.
class FileTransferPortal {
  static const String _busName = 'org.freedesktop.portal.Documents';
  static const String _objectPath = '/org/freedesktop/portal/documents';
  static const String _interface = 'org.freedesktop.portal.FileTransfer';

  final DBusClient _client;
  final DBusObjectPath _object;

  FileTransferPortal(this._client)
      : _object = DBusObjectPath(_objectPath);

  /// Creates a FileTransferPortal client connected to the session bus.
  static Future<FileTransferPortal?> create() async {
    try {
      final client = await DBusClient.session();
      return FileTransferPortal(client);
    } catch (e) {
      // Portal not available (e.g., not on Linux, or xdg-desktop-portal not running)
      return null;
     }
  }

  /// Retrieves files from a transfer session using the provided key.
  ///
  /// Returns a list of file paths that are accessible within the sandbox.
  /// Returns null if the portal is not available or the key is invalid.
  Future<List<String>?> retrieveFiles(String key) async {
    try {
      final result = await _client.callMethod(
        destination: _busName,
        path: _object,
        interface: _interface,
        name: 'RetrieveFiles',
        values: [
          DBusString(key),
          DBusDict.stringVariant(<String, DBusValue>{}),
        ],
      );

      final files = result.values[0] as List<dynamic>;
      return files.cast<String>();
    } catch (e) {
      return null;
    }
  }

  /// Checks if the FileTransfer portal is available.
  Future<bool> isAvailable() async {
    try {
      await _client.callMethod(
        destination: _busName,
        path: _object,
        interface: _interface,
        name: 'StartTransfer',
        values: [
          DBusDict.stringVariant(<String, DBusValue>{}),
        ],
      );
      return true;
    } catch (e) {
      return false;
    }
  }

  void dispose() {
    _client.close();
  }
}

/// Parses drag data to extract the FileTransfer portal key.
///
/// On Wayland with Flatpak, when dragging files between sandboxed apps,
/// the drag data contains the application/vnd.portal.filetransfer mimetype
/// with a key that can be used to retrieve the actual files via the portal.
String? parseFileTransferKey(String dragData) {
  // The drag data from GTK contains URIs, one per line.
  // When the portal is used, one of the lines will be the key.
  // The key format is typically a random string.
  final lines = dragData.split('\n');
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty && !trimmed.startsWith('file://')) {
      // This could be the portal key (not a file URI)
      return trimmed;
    }
  }
  return null;
}

/// Extracts file paths from drag data, using the portal if available.
///
/// [dragData] is the raw text data from the drag operation.
/// [portal] is the FileTransferPortal client, or null if not available.
///
/// Returns a list of file paths that can be accessed within the sandbox.
Future<List<String>> extractFilePaths(
  String dragData, {
  FileTransferPortal? portal,
}) async {
  // First, try to parse file URIs directly
  final uris = <String>[];
  for (final line in dragData.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('file://')) {
      try {
        final uri = Uri.parse(trimmed);
        if (uri.scheme == 'file') {
          uris.add(uri.toFilePath());
        }
      } catch (_) {
        // Ignore invalid URIs
      }
    }
  }

  // If we found file URIs and no portal, return them
  if (uris.isNotEmpty && portal == null) {
    return uris;
  }

  // If portal is available, try to get the key and retrieve files
  if (portal != null) {
    final key = parseFileTransferKey(dragData);
    if (key != null) {
      final portalFiles = await portal.retrieveFiles(key);
      if (portalFiles != null && portalFiles.isNotEmpty) {
        // Portal files take precedence as they're guaranteed to be accessible
        return portalFiles;
      }
    }
  }

  // Fall back to direct URIs
  return uris;
}
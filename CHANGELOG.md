## 0.1.5

- Updated `flutter_secure_storage` to stable 11.x and `device_info_plus` to
  stable 13.x so host applications can keep shared plugin dependencies current.
- Skipped `device_info_plus` 11.x because its `win32` 5.x constraint conflicts
  with the `win32` 6.x requirement in `flutter_secure_storage` 11.x.
- Updated `package_info_plus` to 10.x to use the same `win32` 6.x dependency
  line.
- Raised the Dart SDK floor to 3.8, required by `flutter_secure_storage` 11.x.

## 0.1.4

- Updated analyzer exclusions for generated build output in the package and
  example, keeping lint analysis focused on maintained source files.
- Verified the package has zero Flutter analyzer errors, warnings, or lint
  diagnostics on the current stable toolchain.

## 0.1.3

- Updated `flutter_secure_storage` to 10.x, retaining automatic Android
  migration from the encrypted shared-preferences backend to the new default
  cipher storage.
- Updated `device_info_plus` to the maintained 10.1.x release; version 10.0.0
  is retracted upstream.
- Raised the package floor to Dart 3.3 and Flutter 3.19 to match the upgraded
  plugins.

## 0.1.2

- Moved the package to its independent GitHub repository and removed host-app
  branding from package documentation, metadata, and source comments.
- Added a runnable example covering initialization, incoming-transfer handling,
  and the LAN sync screen.
- Enabled the recommended Flutter lint rules and verified Dart formatting.
- Shortened the package description and corrected the GitHub repository and
  issue-tracker metadata used by pub.dev.
- Expanded public API documentation without changing runtime behavior or
  dependency compatibility.

## 0.1.1

- Added `LanSyncTheme` for host-controlled package colors with fallback
 defaults.
- Added optional `LanSyncItem.dataType` metadata while keeping payload data
 dynamic through `Map<String, dynamic>`.

## 0.1.0

- Initial public release of `flutter_lan_sync`.
- Added scoped UDP device discovery and authenticated peer handshakes.
- Added X25519/HKDF/AES-256-GCM encrypted LAN transport.
- Added explicit item transfer with recipient approval and transfer history.
- Added optional CRDT-based background synchronization.
- Added device management, transfer approval, history, and connected-device UI.

## 0.1.2

- Moved the package to its independent GitHub repository and removed host-app
 branding from package documentation, metadata, and source comments.

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

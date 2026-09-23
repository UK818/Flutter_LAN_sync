# flutter_lan_sync

Offline peer-to-peer data exchange for Flutter apps on the same local network.
The package supports explicit, user-approved item transfers and an optional
CRDT-based background sync flow without requiring internet connectivity.

## Features

- UDP broadcast discovery on local Wi-Fi networks.
- Authenticated device handshakes with application, facility, and instance
  scoping.
- X25519 key exchange, HKDF-SHA256 key derivation, and AES-256-GCM payload
  encryption.
- Explicit item transfer with recipient approval.
- Optional field-level CRDT synchronization with a hybrid logical clock.
- Persistent transfer history and device approval/revocation.
- Ready-made device, approval, history, and incoming-transfer widgets.

## Quick Start

```dart
import 'package:flutter_lan_sync/flutter_lan_sync.dart';

await LanSync.initialize(
  LanSyncConfig(
    appSecret: 'app-specific-secret',
    packageName: 'com.example.app',
    deviceName: 'Clinic Tablet',
    facilityId: 'facility-123',
    instanceType: 'production',
    requireScopedPeers: true,
    theme: const LanSyncTheme(
      primary: Color(0xFF0F766E),
      success: Color(0xFF15803D),
    ),
    onReceive: (items) async {
      // Validate and persist received items in the host application.
    },
  ),
);

LanSyncScreen(
  items: records
      .map((record) => LanSyncItem(
            id: record.id,
            displayName: record.name,
            data: record.toJson(),
          ))
      .toList(),
);
```

`LanSyncItem.data` is a `Map<String, dynamic>`, so the package does not impose
a model type. Transfer patients, appointments, forms, or mixed record shapes;
the host application validates and deserializes the raw maps in `onReceive`.
Use the optional `dataType` field when the host needs a discriminator.

`LanSyncTheme` accepts a partial palette. Unset colors use the package defaults.

For incoming transfers displayed outside `LanSyncScreen`, wrap the app with
`LanTransferListener` and provide a navigator key as shown in the API docs.

## Security Responsibilities

The package encrypts transfer payloads and scopes peers by the configured
application identity and facility/instance values. The host application must:

- Keep `appSecret` out of source control and supply it through a protected
  release mechanism.
- Validate received records before writing them to application storage.
- Use a distinct scope for each facility and deployment instance.
- Provide an explicit user approval flow for incoming data.

LAN traffic is local-network traffic, not a replacement for server-side
authorization, audit, or backup controls.

## Architecture

See [LAN_SYNC.md](LAN_SYNC.md) for the protocol, storage model, transfer flow,
CRDT behavior, and security design.

## Development

```powershell
flutter pub get
flutter analyze
flutter test
```

The package is maintained as an independent Flutter package.

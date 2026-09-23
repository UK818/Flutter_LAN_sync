# flutter_lan_sync — Architecture, Security & Design

## Overview

`flutter_lan_sync` is a self-contained Flutter package that enables two modes of peer-to-peer data exchange between devices on the same local network (Wi-Fi), with no internet connection required:

1. **CRDT background sync** — continuous, automatic conflict-free field-level replication between approved devices.
2. **Item transfer** — explicit, user-approved transfer of structured data objects (e.g. patient records) from one device to another.

Both modes are encrypted end-to-end using a per-device-pair AES-256-GCM key derived from an X25519 ECDH handshake. No data leaves the local network.

---

## Architecture

### Layer diagram

```
┌────────────────────────────────────────────────────────┐
│                  Host Flutter App                     │
│  LanSync.initialize(LanSyncConfig)                     │
│  LanSyncScreen · LanTransferListener · LanStatusIndicator │
└───────────────────────┬────────────────────────────────┘
                        │ public API
┌───────────────────────▼────────────────────────────────┐
│                  LanSyncService (singleton)            │
│  · orchestrates all layers below                       │
│  · exposes: statusStream, incomingTransferStream       │
│             pushItems(), approveTransfer()             │
└───┬──────────────┬──────────────┬──────────────────────┘
    │              │              │
┌───▼───┐   ┌──────▼──────┐  ┌───▼──────────────────────┐
│ mDNS  │   │  LanSync    │  │   LanSyncServer (shelf)  │
│Discov-│   │  Crypto     │  │   POST /handshake        │
│ery +  │   │  X25519     │  │   POST /sync/push        │
│Advert-│   │  HKDF       │  │   GET  /sync/pull        │
│iser   │   │  AES-256-GCM│  │   POST /items/push       │
└───────┘   └─────────────┘  └──────────────────────────┘
                                         │
                              ┌──────────▼───────────────┐
                              │    LanSyncDatabase       │
                              │    (SQLite / sqflite)    │
                              │    devices · sync_logs   │
                              │    transfers · history   │
                              └──────────────────────────┘
```

### Key components

| Component | File | Responsibility |
| --- | --- | --- |
| `LanSync` | `lan_sync.dart` | Public facade — `initialize()`, `pushItems()`, `startSync()` |
| `LanSyncService` | `service/lan_sync_service.dart` | Lifecycle orchestration, status stream, transfer approval |
| `LanSyncServer` | `server/lan_sync_server.dart` | Shelf HTTP server, request authentication middleware |
| `LanSyncCrypto` | `crypto/lan_sync_crypto.dart` | X25519, HKDF-SHA256, AES-256-GCM |
| `AppIdentity` | `identity/app_identity.dart` | HMAC-SHA256 mutual app verification |
| `MdnsDiscovery` / `MdnsAdvertiser` | `discovery/mdns_discovery.dart` | UDP broadcast peer discovery |
| `CrdtMerger` + `Hlc` | `crdt/crdt_merger.dart` | Last-write-wins + append-only CRDT merge, Hybrid Logical Clock |
| `LanSyncDatabase` | `database/lan_sync_database.dart` | sqflite schema: devices, sync_logs, pending_transfers, transfer_logs |
| `LanSyncConfig` | `config.dart` | Host-app configuration contract |
| `LanTransferListener` | `presentation/lan_transfer_listener.dart` | Global stream listener — surfaces approval sheet |
| `IncomingTransferSheet` | `presentation/incoming_transfer_sheet.dart` | Bottom sheet shown to the receiving user |
| `LanSyncScreen` | `presentation/lan_sync_screen.dart` | Full peer-discovery, handshake, and send UI |

---

## Discovery

Peer discovery uses a plain **UDP broadcast beacon** on port **7438** — a design that works on any Wi-Fi network without router mDNS/DNS-SD support.

### How it works

1. When the server starts, `MdnsAdvertiser` binds a UDP socket on the device's Wi-Fi interface and broadcasts a 2-second heartbeat to `255.255.255.255:7438`.
2. The beacon payload is a small JSON object:

   ```json
   { "deviceId": "<uuid>", "port": 7437 }
   ```

3. `MdnsDiscovery.scan()` opens a socket on port 7438, collects all beacons for 5 seconds, and returns the list of discovered `LanPeer` objects (deduped, local device excluded).
4. On shutdown the advertiser sends a final beacon with `"port": 0` so listeners can drop the device immediately.

Scanning is purely passive — no connection is made until the user explicitly initiates a handshake from `LanSyncScreen`.

---

## Handshake

Before any encrypted data can be exchanged, two devices must complete a mutual handshake. This serves three purposes: key exchange, app identity verification, and facility/instance scoping.

### Sequence

```
Initiator                               Responder
─────────                               ─────────
POST /handshake
  deviceId, publicKey (X25519)
  name, packageName
  appToken = HMAC-SHA256(appSecret, deviceId)
  facilityId, instanceType
                        ─────────────────────▶
                                        1. Verify packageName matches config
                                        2. Verify appToken with HMAC
                                        3. Verify facilityId matches (if set)
                                        4. Verify instanceType matches (if set)
                                        5. Persist peer public key in DB
                                        ◀─────────────────────
                              HTTP 200
                              deviceId, publicKey (X25519)
                              appToken = HMAC-SHA256(appSecret, responderDeviceId)

Verify responder's appToken
Persist responder public key in DB
Mark device as approved
```

A `403 Forbidden` response with a structured error body (`app_not_verified`, `facility_mismatch`, `instance_mismatch`) is returned on any check failure. Only devices that have completed a successful handshake are stored in the local database, and only approved devices can call authenticated endpoints.

---

## Transport security

All data payloads sent over the network (CRDT logs and item batches) are encrypted before transmission and decrypted on receipt. No plaintext patient data ever crosses the wire.

### Cryptographic scheme

```
Key exchange:   X25519 ECDH (one persistent key-pair per device)
Key derivation: HKDF-SHA256 → 256-bit key (info = "flutter_lan_sync_v1")
Encryption:     AES-256-GCM
Wire format:    [ nonce (12 B) | ciphertext | GCM tag (16 B) ]
Key storage:    flutter_secure_storage (Android EncryptedSharedPreferences)
```

Each device generates an X25519 key pair once and persists the private key in the platform secure store. For each peer, a unique AES-256-GCM key is derived from the ECDH shared secret via HKDF-SHA256 — so a compromised session key for one peer does not affect other device pairs.

The AES-GCM tag provides both integrity and authenticity guarantees: a modified ciphertext will fail decryption and be rejected with a `FormatException`.

### App-identity token

In addition to channel encryption, the handshake includes a mutual **HMAC-SHA256** token:

```
appToken = HMAC-SHA256(key=appSecret, message=deviceId)
```

`appSecret` is a hardcoded string embedded in genuine builds of the application. Any device that connects with a mismatched secret is rejected during the handshake, before any key material is stored. This prevents rogue apps (even on the same network) from connecting to the sync server.

---

## Request authentication

After a successful handshake, all subsequent HTTP calls to authenticated endpoints (`/sync/push`, `/sync/pull`, `/items/push`) must include the `X-Device-Id` header. The `_withAuth` middleware:

1. Reads the `X-Device-Id` header.
2. Looks up the device in the local SQLite database.
3. Rejects with `401` if the device is unknown, or `403` if it is known but not yet approved.
4. Updates the device's `lastSeen` timestamp on each request.

Device approval is a one-time action taken by the user in the handshake UI of `LanSyncScreen`. Approved status is stored in SQLite. It can be revoked at any time via `LanSyncService.revokeDevice()`.

---

## CRDT sync

The background sync layer replicates **field-level change logs** (not full records) and resolves concurrent edits without user intervention.

### Data model

Each mutation is recorded as a `LanSyncLog` row:

| Field | Type | Description |
| --- | --- | --- |
| `id` | String (UUID) | Unique log entry ID |
| `deviceId` | String | Device that made the change |
| `entityType` | String | e.g. `"patient"` |
| `entityId` | String | Primary key of the changed record |
| `fieldName` | String | Name of the changed field |
| `oldValue` | String? | Value before the change |
| `newValue` | String? | Value after the change |
| `hlcTimestamp` | int | Hybrid Logical Clock timestamp |
| `vectorClock` | int | Monotonic counter for tie-breaking |

### Hybrid Logical Clock (HLC)

Timestamps use a 64-bit packed HLC: **upper 48 bits = wall-clock milliseconds, lower 16 bits = counter**. The counter increments when two events occur within the same millisecond, ensuring strict ordering. On receiving a remote log, `Hlc.receive()` advances the local clock to `max(local, remote)` so causality is preserved across all peers.

### Merge rules

`CrdtMerger.merge()` compares local and remote logs field-by-field:

- **No local entry** for the field → accept remote.
- **Remote HLC > local HLC** → remote wins (last-write-wins).
- **Remote HLC == local HLC, different devices** → higher `deviceId` lexicographic string wins (deterministic tie-break). If neither is strictly greater, a `SyncConflict` is recorded for application-level inspection.
- **Append-only fields** (`notes`, `visitHistory`, `labResults`, `medications`) → always union-merged; no entry is ever dropped.

### Sync cycle

Every N minutes (default 15, configurable) `LanSyncService` runs a sync cycle:

```
1. Scan for peers (UDP, 5 s)
2. For each known, approved peer:
   a. Encrypt unsynced local logs → POST /sync/push
   b. GET /sync/pull?since=<lastHlc>
   c. Decrypt remote logs → CrdtMerger.merge() → write winners to DB
3. Advance local HLC for all received timestamps
```

---

## Item transfer

Item transfer is a separate, explicit flow for sending structured data objects (e.g. full patient records) to a specific peer with recipient approval.

### Flow

```
Sender (LanSyncScreen)               Receiver (background)
──────────────────────               ────────────────────
Select items → pushItems()
  Encrypt batch → POST /items/push
                                      Server decrypts batch
                                      Persists to pending_transfers table
                                      Emits on incomingTransferStream
                                      ▼
                             LanTransferListener (widget)
                             Shows IncomingTransferSheet
                                      ▼
                             User taps "Accept"
                             approveTransfer(id)
                               → config.onReceive(items)
                               → config.onTransferNotification(count, from)
                               → config.onActivity("items_received", ...)
                               → transfer_logs entry written
```

The host app supplies all three callbacks in `LanSyncConfig`. `onReceive` is the only required one — it receives the raw `List<Map<String, dynamic>>` and is responsible for persisting the data.

`LanTransferListener` is placed inside `MaterialApp.router`'s `builder:` callback so it has a valid `Navigator` context for displaying the approval sheet from any screen, including while the user is navigating.

---

## Database schema

Managed by `LanSyncDatabase` (sqflite, no ORM):

```sql
-- Known peer devices
CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  name TEXT,
  publicKey TEXT,
  approved INTEGER DEFAULT 0,
  appVerified INTEGER DEFAULT 0,
  packageName TEXT,
  lastSeen INTEGER,
  lastPort INTEGER,
  syncCount INTEGER DEFAULT 0
);

-- Append-only field-change log for CRDT sync
CREATE TABLE sync_logs (
  id TEXT PRIMARY KEY,
  deviceId TEXT,
  entityType TEXT,
  entityId TEXT,
  fieldName TEXT,
  oldValue TEXT,
  newValue TEXT,
  hlcTimestamp INTEGER,
  vectorClock INTEGER,
  synced INTEGER DEFAULT 0,
  syncedToDevices TEXT DEFAULT '[]'
);

-- Inbound item batches awaiting approval
CREATE TABLE pending_transfers (
  id TEXT PRIMARY KEY,
  fromDeviceId TEXT,
  fromDeviceName TEXT,
  transferredAt INTEGER,
  itemCount INTEGER,
  dataJson TEXT,
  status TEXT DEFAULT 'pending'
);

-- Completed transfer log (both directions)
CREATE TABLE transfer_logs (
  id TEXT PRIMARY KEY,
  deviceId TEXT,
  deviceName TEXT,
  itemCount INTEGER,
  direction TEXT,       -- 'incoming' | 'outgoing'
  completedAt INTEGER,
  itemNamesJson TEXT
);
```

---

## Host-app integration contract

```dart
await LanSync.initialize(LanSyncConfig(
  appSecret:   r'your-hardcoded-secret',   // must match on every device
  packageName: 'com.example.your_app',
  deviceName:  'Dr. Amina Hassan',         // shown to peers
  facilityId:  'FAC-001',                  // optional: scopes to one facility
  instanceType: 'ART',                     // optional: scopes to one instance type

  onReceive: (items) async {
    // Persist accepted items — called only after user approval
  },
  onTransferNotification: (count, fromDevice) {
    // Show local notification
  },
  onActivity: (action, description) {
    // Write to audit log  (action = 'items_sent' | 'items_received')
  },
));
```

Place `LanTransferListener` inside `MaterialApp.router`'s `builder:` so incoming approval sheets render over any screen:

```dart
builder: (context, child) => LanTransferListener(child: child!),
```

Use `LanStatusIndicator` anywhere in the UI for a live server-state dot (green = running, amber = syncing, grey = stopped, invisible = never started).

---

## Ports and network requirements

| Port | Protocol | Purpose |
| --- | --- | --- |
| 7437 | TCP (HTTP) | Sync server (handshake, push, pull, item transfer) |
| 7438 | UDP broadcast | Peer discovery beacon |

Devices must be on the same Wi-Fi subnet. No internet access, DNS, or router mDNS support is required.

---

## Threat model and limitations

| Threat | Mitigation |
| --- | --- |
| Rogue app on the same Wi-Fi | HMAC-SHA256 `appToken` — requires knowledge of `appSecret` |
| Cross-facility data leakage | `facilityId` check during handshake |
| Cross-instance data leakage | `instanceType` check during handshake |
| Eavesdropping on the wire | AES-256-GCM encryption with per-pair keys |
| Payload tampering | GCM authentication tag — modified bytes fail decryption |
| Key theft from device storage | X25519 private key held in `flutter_secure_storage` (OS keystore) |
| Unauthorised device connecting after handshake | `approved` flag in DB — can be revoked; all endpoints require DB lookup |
| Receiving data without consent | Incoming item batches are quarantined in `pending_transfers`; data is only passed to `onReceive` after explicit user approval |
| **Not mitigated:** malicious approved peer | A device the user has approved can push arbitrary data via `/items/push`. Trust is user-granted. |
| **Not mitigated:** UDP spoofing of beacon | Discovery beacons carry no auth. A spoofed beacon leads to a failed handshake — no data exposure. |

<div align="center">

<img src="./web/public/logo.svg" width="88" height="88" alt="Legado Server Logo" />

# Legado Server

**Legado source processing, content caching, and Kindle sync service**

<p align="center">
  <a href="./README.md">简体中文</a> | <b>English</b>
</p>

</div>

---

## Overview

**Legado Server** is a standalone backend built with Kotlin JVM, Ktor, and SQLite. The minimal React WebUI focuses on source management, search, chapter/content viewing, the shelf, and TXT/EPUB export. A KOReader plugin performs Kindle-side reading; other management capabilities remain available through the backend API.

## Key Capabilities

| Capability | Description |
| --- | --- |
| **Source processing** | Retains Legado source import/export, groups, search, debugging, login credentials, book details, chapter and content parsing APIs; Rhino, Jsoup, and JsonPath run in a JVM sandbox. Source checking (the same chain as Android's "check source": domain, search, explore, details, chapter list, content, plus failed-group, `respondTime`, and `// Error:` comment write-back) is served by `POST /api/sources/check`. |
| **Minimal React WebUI** | Keeps source management, search, chapter/content viewing, shelf management, export, and Kindle pairing/push status. Rules, WebDAV, manga, audiobook, and publishing entry points are no longer shown. |
| **Kindle sync and push** | Retains `/api/v1` Kindle Sync Protocol v1: pairing authorization, per-book publication, incremental sync, whole-book EPUB verification, bidirectional progress, and conflict resolution. Auto-publication waits for the complete cache, creates an immutable EPUB, and lets online devices pull it with Range resume, SHA-256 verification, atomic installation, and per-device acknowledgement. |
| **Bookshelf export** | `POST /api/bookshelf/export` creates TXT or EPUB 2.0 jobs for shelf books. Missing chapters use the Android `WebBook.getContent` path with up to three attempts; failed chapters remain in the structure with a `null` placeholder. Books export one at a time in submission order, while `parallel=true` enables up to nine concurrent chapter downloads per book. EPUB supports NCX volume nesting, `epubScope`, and `epubSize` splitting. `/export-epub` remains an EPUB-only alias. |
| **Manga** | Backend APIs retain manga intake, chapter parsing, image proxying, content-addressed caching, prefetch, quota reporting, and cleanup. The minimal WebUI has no manga reader. |
| **Audiobooks** | Backend APIs retain audiobook intake, audio rule parsing, audio proxying, caching, and prefetch. The minimal WebUI has no audio player. |
| **WebDAV and backups** | Retains the `/webdav` file endpoint and Android backup preview with explicit import confirmation. The WebUI backup page has no export, progress-sync settings, or local-book import controls. |

Whole-book EPUB sync records carry stable chapter IDs, ordering, titles, and readiness only. Per-chapter hashes, paths, and sizes remain server-side for bundle publication and EPUB generation, but are omitted from large Kindle reset snapshots. The device verifies each immutable file once during installation and caches that verification, so later resets and reader opens do not repeatedly hash an entire shelf.

Source JSON fields `exploreUrl` and `ruleExplore` and their rule parsing remain supported; the discovery UI and `/api/explore` feature routes have been removed.

## Kindle EPUB Push

`POST /api/bookshelf/export` accepts `pushToKindle=true` and optional `kindleDeviceIds`. After an EPUB export completes, the server copies every output file into a dedicated content-addressed directory and creates a durable delivery for the selected devices. An empty device list targets every non-revoked paired device; exports with failed chapters are not pushed automatically.

Kindle uses its existing Bearer token with:

- `GET /api/v1/inbox?cursor=<decimal>` to claim unacknowledged deliveries.
- `GET /api/v1/inbox/files/{file_id}` to download an EPUB with single-range, `If-Range`, and ETag support.
- `POST /api/v1/inbox/ack` to report `applied` or `failed` for the current cursor range and advance the inbox cursor.

The device writes a `.part` file, verifies its size and SHA-256, then renames it atomically. A lost acknowledgement can safely retry with the old cursor. Failed deliveries remain pending even after the cursor advances. Push files are independent of the normal 24-hour export cache.

Revoking a Kindle blocks its device token immediately and cancels unclaimed deliveries; books already installed on the device remain untouched. KOReader checks the inbox automatically only while the device is online and does not wake Wi-Fi by itself.

## Deployment

### Docker Compose

Compose publishes HTTP on host port `28095/tcp` and UDP `47832` for LAN
discovery. This works with both Linux Docker Engine and Docker Desktop; the
latter runs containers in a VM, where host networking is not reachable from the
physical LAN. The container uses the dedicated external volume
`legado-server-data`. Local HTTP sessions use
`LEGADO_SECURE_COOKIES=false`. Keep the admin environment file outside the
repository, and retain the existing password for an initialized database.

The ports are published on all interfaces by default. If the computer also has
an untrusted or public interface, use the host firewall to allow only private
networks to reach `28095/tcp` and `47832/udp`.

Build and start the service with `compose.server.yml`; keep the administrator
environment file outside the repository.

### Standalone JAR

```bash
LEGADO_PORT=8080 LEGADO_DATA_DIR=./ls_data LEGADO_SECURE_COOKIES=false \
ADMIN_PASSWORD='your_password_at_least_12_chars' \
java -jar legado-server.jar
```

## Environment Variables

| Variable | Default | Description |
| --- | --- | --- |
| `LEGADO_HOST` | `0.0.0.0` | HTTP / WebSocket / WebDAV bind address; can be one LAN address |
| `LEGADO_PORT` | `8080` | HTTP / WebSocket / WebDAV listening port |
| `LEGADO_DATA_DIR` | `/data` | Root directory for SQLite, caches, WebDAV, and local books |
| `ADMIN_PASSWORD` | None | Required on first launch; at least 12 characters |
| `LEGADO_SECURE_COOKIES` | `true` | Keep `true` for production HTTPS; use `false` only for local HTTP |
| `LEGADO_LAN_DISCOVERY` | `true` | Enable UDP discovery for KOReader/Kindle clients on a private LAN |
| `LEGADO_LAN_DISCOVERY_PORT` | `47832` | UDP port used for LAN discovery |
| `LEGADO_LAN_DISCOVERY_GROUP` | `239.255.42.99` | Compatible multicast group for LAN discovery |
| `LEGADO_SERVER_NAME` | Hostname | Server name shown in the Kindle pairing list |

Compose publishes `28095/tcp` and `47832/udp`. Some Docker Desktop, host
firewall, or Wi-Fi isolation setups can still block broadcast/multicast probes.
In that case, use **Pair manually** on the Kindle to enter
`http://<LAN-address>:28095` once.


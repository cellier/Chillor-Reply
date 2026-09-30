# Privacy and local data

- Translation and reply inference use the bundled local Ollama service. No cloud fallback or application telemetry is implemented.
- Runtime and model downloads contact their upstream distribution services. Local inference does not upload captured chats.
- Capture reads text near the pointer and may use a screenshot for on-device Vision OCR. Screenshots are held for the current workflow, not stored in memory history by the normal UI flow. Developer screenshot diagnostics are separate explicit commands.
- Nearby context is heuristic and bounded. Inspect the source/context before adopting a reply.
- Memory is opt-in; private replies bypass memory reads and writes. Users can pause, edit or delete remembered items.
- Memory records use SQLite with AES-GCM payload encryption. The 32-byte key is a local file alongside the database, restricted to the current OS user. This is **not** protection from software running as that same user or from someone who can read both files. Legacy Keychain data can require a one-time migration.
- Default history retention is 90 days when memory is enabled, with user controls. Deletion within the app does not erase external backups.
- Tap detection reads motion sensor values and input-event timing, not key contents.
- Replies are never sent automatically. Filling requires confirmation and validates the original target field; unsupported targets fall back to copy/paste.

## Local paths

| Data | Location |
| --- | --- |
| Model weights | `~/Library/Application Support/ReplyLens/models` |
| Memory database | `~/Library/Application Support/ChillorReply/memory.sqlite` |
| Local memory key | `~/Library/Application Support/ChillorReply/memory.sqlite.key` |
| Preferences | macOS preferences domain `local.cellier.replylens.prototype` |

The model is shared by this app's local runtime and is intentionally excluded from source/build archives. Removing the `.app` alone does not delete these data directories or preferences. Back up data you intend to keep before any manual cleanup; do not post these files in public issues.

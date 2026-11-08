# executor — DevRunner Mobile

A Flutter workspace app for phones: browse and edit a project directory, execute a
declarative batch format against it, render HTML files, and push the result to
GitHub over the REST API.

## What it does

| Area | Behaviour |
|---|---|
| **Runner** | Paste or load a batch script, review it, execute it, watch the terminal log |
| **Explorer** | Lazy file tree, editor with undo/redo, image + binary preview, HTML renderer, multi-select batch export |
| **HTML preview** | Serves the file's directory on a loopback-only HTTP server inside a WebView, so relative CSS/JS/images resolve |
| **GitHub** | Push a workspace to a repo via the Git Data API (blobs → tree → commit → ref), with local SHA-1 dedupe so only changed files upload |

## Batch format

```
[ACTION]: CREATE_FILE          # or DELETE_FILE | CREATE_FOLDER | DELETE_FOLDER | SKIP_BINARY
[PATH]: /lib/src/
[NAME]: main.dart
[CONTENT]:
<verbatim file body>
[ENDFILE]
```

- `[ENDFILE]` is the body terminator; exactly one terminator newline is removed
  on parse, so `export → parse` is a **lossless** round trip.
- `[REST]:` marks the end of machine-readable content. Anything after it is
  ignored, so trailing AI commentary cannot be appended to the last file.
- Binary files are never exported as text. They become `SKIP_BINARY`, which the
  executor reports as skipped and does not touch.

## GitHub push: why a 401 happens, and what to do

The app now verifies **read *and* write** access to the target repo before
uploading a single byte, and prints an actionable remedy instead of a wall of
identical 401 lines. The common causes, in order of frequency:

| Cause | Symptom | Fix |
|---|---|---|
| Token pasted with a prefix or quotes (`Authorization: Bearer ghp_…`, `"ghp_…"`, wrapped across two lines) | 401 on every call | Handled automatically — tokens are sanitised on save and on use |
| Classic token missing the `repo` scope | Repo list works, push 401/403 | Regenerate with `repo` scope |
| Classic token expired / revoked | 401 everywhere | Regenerate and reconnect |
| **Fine-grained** token missing *Contents: Read and write* | `/user` and repo list succeed, blob upload 401 | Add the permission for that repo — this is the most common silent failure |
| Fine-grained token's "Repository access" excludes the repo | 404 or 403 | Add the repo to the token's access list |
| Read-only collaborator role | 403 on write | Get write access, or push to a fork |
| Saved token blanked by a storage failure on some Android builds | Push does nothing / 401 | Now stored in the keystore with a plaintext migration; re-enter once |
| More than ~1000 file operations in an hour | 403 + "rate limit" text | Wait; pushes are split into cached (unchanged) and changed files |

On a rejection the app shows a **Retry push** prompt: paste a new token, it is
verified first, then the push resumes. Nothing is committed unless every blob
uploaded successfully, so a failed push never leaves a half-written branch.

## Storage model

The app is usable with **zero** runtime permissions:

- The default workspace is
  `/storage/emulated/0/Android/data/<pkg>/files/DevRunner` (app-specific
  external storage) — no permission, and still reachable over USB/adb.
- Working anywhere else needs either legacy `WRITE_EXTERNAL_STORAGE`
  (Android ≤ 10) or the explicit **"All files access"** opt-in (Android 11+),
  which is requested only from the directory picker with an explanation.
- The picker verifies a folder is writable before accepting it.

## Security notes

- Every `[PATH]`/`[NAME]` is contained inside the workspace (`PathGuard`):
  traversal, absolute paths, separators and NUL bytes are rejected before any
  write or delete. Symlink escapes are caught before a recursive delete.
- Any batch containing a deletion shows a pre-flight review sheet.
- The GitHub token lives in keystore-backed secure storage. `allowBackup` is
  off and data-extraction is disabled.
- Cleartext HTTP is permitted for loopback only (`network_security_config`), so
  all GitHub traffic is HTTPS.
- The preview server binds to loopback, validates the `Host` header against DNS
  rebinding, returns 403 on traversal and does not send a CORS wildcard.

## Development

```bash
flutter pub get
flutter analyze
flutter test
```

`test/parser_and_execution_test.dart` covers the round-trip guarantees, path
containment, executor accounting and token normalisation.

## Known limitations

- `flutter build web` cannot work: the app is built on `dart:io` filesystem
  access by design.
- Folders are chosen by path, not via the Android Storage Access Framework. SAF
  would remove the `MANAGE_EXTERNAL_STORAGE` requirement entirely and is the
  recommended next step before a Play Store release.

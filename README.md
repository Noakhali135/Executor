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
<<<FILE_WRITE path="src/main.py">>>
print("Hello World")
<<<END>>>

<<<FILE_DELETE path="src/old_file.py">>>

<<<FOLDER_CREATE path="src/utils">>>

<<<FOLDER_DELETE path="src/legacy">>>
```

- One block per action. `FILE_WRITE` is the only block with a body, and its body
  runs from the line after the opener to `<<<END>>>` on its own line.
- A `FILE_WRITE` with **no** `<<<END>>>` is an error. The parser never guesses
  where the body ends, because a guess would write a truncated file.
- The body is stored byte for byte. `export → parse` is a lossless round trip,
  including trailing newlines and CRLF.
- Text outside blocks is ignored, so AI prose around the blocks is harmless.
- Placeholder text (`rest of code`, `code unchanged`, a lone `...`) is flagged
  as a warning: it means the response was truncated, and writing it would
  destroy the real file.
- Binary files are never exported as text; a block would replace their bytes
  with ASCII, so they are left out of the batch.

## Output

Every run reports what it did, one level per line, with the message column
aligned:

```
[10:22:01] INFO  Input received (3 blocks, 184 chars)
[10:22:01] INFO  Parsing blocks...
[10:22:01] OK    Block 1: FILE_WRITE     src/main.py         (42 lines)
[10:22:01] OK    Block 2: FILE_DELETE    src/old_file.py
[10:22:01] INFO  Validating...
[10:22:01] OK    Paths are relative and inside project root
[10:22:01] OK    Every FILE_WRITE has a closing <<<END>>>
[10:22:01] INFO  Creating backup -> .backup/2026-11-08_10-22-01/
[10:22:01] OK    Backed up src/main.py
[10:22:01] INFO  Applying changes...
[10:22:01] OK    Wrote src/main.py (overwritten, +12 / -5 lines)
[10:22:01] OK    Deleted src/old_file.py
[10:22:01] DONE  3 of 3 actions applied, 0 failed, 1 backed up
```

Levels are `INFO`, `OK`, `WARN`, `ERROR`, `FAIL`, `DONE` and `HINT`.

Validation runs **before** anything is written, so a batch with one bad block
changes nothing at all:

```
[10:22:01] ERROR Block 3: FILE_WRITE ../secrets.txt — path escapes the project root
[10:22:01] FAIL  Validation failed (1 error). No files were changed.
[10:22:01] HINT  Copy the errors below back to the AI and ask it to resend the full blocks:
                 - Block 3: use a relative path inside the project
```

Overwritten files are copied to `.backup/<timestamp>/` first. Batch files over
5 MB are skipped rather than copied, and the run says so.

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

The app requests **no storage permissions at all** — the manifest asks for
`INTERNET` and `ACCESS_NETWORK_STATE` only. Workspaces come from two places:

- A folder granted through the **Storage Access Framework**. The grant is
  persisted, so it survives reboots, and it is the only way to reach a project
  outside the app's own directory. Every filesystem call is routed through
  `WorkspaceFs`, so a SAF folder behaves like a normal one for the runner,
  exporter, editor, explorer and GitHub push.
- The app-private directory
  `/storage/emulated/0/Android/data/<pkg>/files/DevRunner`, used as a
  first-launch default. It needs no permission and is reachable over USB/adb.

Older builds required "All files access" or a legacy `WRITE_EXTERNAL_STORAGE`
grant. That path is gone: there is no permission request left to deny.

## Security notes

- Every `path="..."` is validated by `PathGuard.validateRelativePath` before any
  write: absolute paths, drive letters, `~`, `.`/`..` segments, empty segments
  and NUL bytes are rejected, so a block cannot reach outside the workspace.
  Symlink escapes are caught before a recursive delete.
- A batch is validated as a whole and aborted on the first bad block, so a
  rejected path cannot leave the project half-updated.
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

---
name: verify-ui
description: Launch SequelPG against the dev-db database and capture screenshots of specific screens to confirm a UI change actually looks and behaves right. Use after view/layout changes when a build passing is not enough evidence.
---

# Verify a UI change with screenshots

AppleScript UI scripting is not authorized on this machine, so the app is driven by a temporary in-app driver and captured by window id.

## 1. Database

Start the fixture: `make -C dev-db up` (see the `dev-db` skill). Connection: `127.0.0.1:54318`, `demo` / `demo`, database `demo`, schema `app`.

## 2. Temporary demo driver

Add a **temporary** `DemoDriver` in `SequelPGApp/Views/ContentView.swift`, activated only when the environment variable `SEQUELPG_DEMO_SCENE` is set. It connects to the demo profile and navigates to the scene under test (e.g. select `app.orders`, switch to Content, open a sheet). Keep it self-contained so removal is one deletion.

## 3. Build and launch

```bash
xcodebuild -project SequelPG.xcodeproj -scheme SequelPG -configuration Debug \
  -derivedDataPath /tmp/sequelpg-dd build 2>&1 | grep -E '(error:|BUILD )'
SEQUELPG_DEMO_SCENE=orders-content \
  /tmp/sequelpg-dd/Build/Products/Debug/SequelPG.app/Contents/MacOS/SequelPG &
```

## 4. Capture by window id

```bash
WID=$(swift -e 'import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in l where (w["kCGWindowOwnerName"] as? String) == "SequelPG" { print(w["kCGWindowNumber"]!); break }')
screencapture -l "$WID" -o /tmp/sequelpg-shot.png
```

Capture **only** the app window (`-l`). Never take a full-screen capture — it exposes the user's other windows. Read the PNG to inspect it; check both Light and Dark appearance when colors changed.

## 5. Clean up (always)

- Quit the app (`pkill -x SequelPG`).
- Remove the `DemoDriver` code and confirm `git diff` shows no leftovers.
- Remove any demo connection profile the driver saved from `~/Library/Preferences/com.sequelpg.app.plist` (edit with `/usr/libexec/PlistBuddy` or `plutil`; `defaults read com.sequelpg.app` reads a stale sandbox container, not this file).
- Delete the screenshots and `/tmp/sequelpg-dd` unless the user wants them.

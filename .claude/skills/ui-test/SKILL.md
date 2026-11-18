---
name: ui-test
description: Run, write and debug SequelPG's end-to-end UI scenarios — the real app driven through the macOS accessibility API, in the background (no mouse, no focus, no locked screen), against the Docker test cluster, with a screenshot per step. Use after any UI change, when a control "does nothing", when adding a feature that needs an end-to-end check, or to explore the live interface step by step.
---

# SequelPG UI scenarios

`UITest/` is a SwiftPM package that builds `sequelpg-uitest`. It launches the Debug app with `open -g` in UI-test mode and operates it like a person, but through accessibility: it presses controls with `AXPress`, sets text with `AXValue`, selects rows with `AXSelectedRows`, expands outline rows with `AXDisclosing`, posts keys to the app's pid only, and screenshots its window with `screencapture -l`. Your own windows, pointer and keyboard are untouched; the app never comes to the front.

Requirements: `make -C test-db up` (see `test-db` skill), and Accessibility permission for the terminal (System Settings ▸ Privacy & Security ▸ Accessibility). The driver checks `AXIsProcessTrusted()` and stops if it's missing.

## Run

```bash
make -C test-db test-ui                       # build app + driver, run every scenario
make -C test-db test-ui ONLY="smoke edit-rows"
make -C test-db test-ui-smoke
make -C test-db ui-list
```

Report: `build/uitest/report/report.html` (every step's screenshot, failures in red) and `report.json`. Exit status is non-zero if any scenario failed. Each scenario gets a fresh app with isolated defaults, an in-memory Keychain (never the real one — no password prompts) and the profiles it declares.

`SEQUELPG_UITEST_FOREGROUND=1` launches the app in front (only for watching a run). `SEQUELPG_BINARY=…` points at another build.

## Explore step by step

```bash
B=UITest/.build/release/sequelpg-uitest     # or .build/debug after `swift build` in UITest/
$B launch --seed          # app with the standard profiles (PG18 scram, PG16 md5, PG13 trust, PG18 via SSH)
$B dump                   # outline: role, “label”, #identifier, = value
$B dump --all
$B press startPage.connect          # identifier or label
$B set query.editor "SELECT 1"
$B press query.run
$B press workspace.databaseMenu; $B press "Disconnect"
$B key escape
$B shot after-run                   # → build/uitest/interactive/shots/
$B quit
```

## Writing a scenario

Scenarios live in `UITest/Sources/SequelPGUITest/Scenarios*.swift` (connection, query, data, tools) and are listed by `Scenarios.all`.

```swift
Scenario(
    name: "edit-rows",
    summary: "insert and delete rows from the Content tab",
    profiles: Scenarios.standardProfiles,         // default; or custom SeedProfile list
    setupSQL: ["DROP TABLE IF EXISTS qa.ui_rows", "CREATE TABLE qa.ui_rows (...)"]
) { ui in
    try ui.step("connect") { try ui.connect("PG18 scram") }
    try ui.step("open table") {
        try ui.openObject(schema: "qa", name: "ui_rows")
        try ui.mode("Content")
    }
    try ui.step("insert a row") {
        try ui.press(id: A11yID.Content.insertRow)
        try ui.fill(id: A11yID.Content.insertField("label"), "gamma")
        try ui.press(.button("Insert"))
        try ui.expectEqual(try Cluster.sql("SELECT count(*) FROM qa.ui_rows"), "3", "rows in database")
    }
}
```

Building blocks (`Scenario.swift`, `AppActions.swift`):
- Steps: `ui.step(name) { … }` — screenshot after; a failure is screenshotted and stops the scenario.
- Generic: `press(id:)`, `press(Query)`, `choose(menuButton, item:)`, `fill(id:_:)`, `key("escape")`, `dismissSheet()`.
- Checks: `expect(id:)`, `expect(Query)`, `expectGone`, `expectText(id:_:predicate)`, `expectContains(id:_:)`, `expectEqual`.
- App: `selectProfile`, `connect`, `connectExpectingError` (returns alert text), `disconnect`, `mode("Query"|"Content"|…)`, `run(sql)`, `query(sql, rows:)` → grid cells, `scalar(sql)`, `grid(id)`, `openObject(schema:name:category:)`, `exportedFile(extension:)`.
- Database side: `Cluster.sql(…)` runs SQL as admin via `docker exec` — use it to prepare data and to verify what the UI really wrote.
- `SeedProfile("name", server: "pg16", role: "md5")`, `SeedProfile.viaSSH("name", keyPath:)`; set `.sslMode`, `.password`, `.port` etc.
- `openFileContents:` — the file the app's Open panel "chooses" (Import SQL File).

Rules:
1. **Every action is followed by a check of its visible result** — and, for writes, of the database (`Cluster.sql`).
2. Find controls by **identifier** (`A11yID` in `SequelPGApp/Utilities/AccessibilityID.swift`, shared with the driver via a symlink). Add an identifier to the view when a control lacks one; prefer that over matching labels.
3. Scenarios are independent: create the objects you need in `setupSQL` (prefix `qa.ui_…`) rather than relying on another scenario.
4. A control that does nothing, or a message a person can't act on, is a product bug — report it; don't weaken the scenario.

## Gotchas

- **Menu-bar commands are disabled in the background** (they follow the key window). Use the window's own controls: the mode segments, the toolbar **Database** menu (`workspace.databaseMenu`), `results.export`. Pop-up menus and sheets work fine.
- **Lazy lists**: rows scrolled out of view have no cells. `openObject` expands schema ▸ category and types the name into the navigator filter; sheets with long lists (Roles) need their search field set first.
- Escape with focus in a search field clears it first — `dismissSheet()` retries.
- A SwiftUI app launched in the background opens no window by itself; `Session.launch` asks for one via File ▸ New Connection Window.
- Cell texts come from `AXStaticText` values; NULL renders as `‹NULL›`, booleans as `true`/`false`.
- Save/Open panels are replaced in UI-test mode (`FilePanels`): saves land in the run's `files/` folder (`session.saveDirectory`), Open returns `SEQUELPG_UITEST_OPEN_FILE`.

// SQLCompletionWindow has been removed. The custom NSPanel-based completion
// popup it provided was repeatedly stealing key focus from the SQL editor's
// NSTextView in ways AppKit's responder chain made hard to suppress — typing
// became unreliable (typed `l` arrived as `Z`, the popup got stuck on stale
// partial matches like `SET` for input `select`).
//
// Completion is now driven by NSTextView's built-in `complete(_:)` mechanism;
// see `SQLEditorView.swift`. The native popup is plain (no category chips,
// no themed selection) but participates correctly in the responder chain.
//
// This file is intentionally left empty rather than deleted so the
// project.pbxproj references stay valid; remove it in a cleanup pass.

import Foundation

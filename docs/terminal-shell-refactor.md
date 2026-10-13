# Terminal shell refactor

This draft captures the intended refactor for unifying Commander window chrome and
function-key rendering.

## Problem

The normal two-pane view owns a standalone `TerminalKeyBar`, while
`TerminalFileViewer` and `TerminalFileEditor` draw their own function-key rows.
That duplicates layout, margins, hit testing, modifier handling, and visual behavior.

It also makes shared window-level effects such as glass/tint harder to keep
consistent across all modes.

## Target structure

```
Window
├── title bar
└── TerminalShell
    ├── contentHost
    │   └── current main content
    └── TerminalKeyBar
```

The shell owns exactly one function-key bar. Main content is swapped between the
two-pane browser, file viewer, file editor, and future terminal-style modes.

## Architectural invariant

`TerminalKeyBar` is instantiated exactly once for the main window.

Pane, viewer, and editor content must not draw function keys themselves.

## Content / toolbar communication

Main content publishes a toolbar model; the shell renders it and routes toolbar
actions back to the active content/controller.

A possible model:

```swift
struct TerminalKeyItem {
    let number: Int
    let title: String
    let action: () -> Void
}
```

The exact API can be refined during implementation. Prefer typed commands over
stringly-typed dispatch if practical.

The direction of communication should be:

```
content ── publishes toolbar state ──▶ shell
content ◀──── toolbar action ───────── shell
```

Dynamic labels such as Viewer F4 (`Text` / `Hex`) must be able to invalidate
or republish the toolbar state.

## Suggested implementation steps

1. Introduce a shell/container view that owns `contentHost` and the single
   `TerminalKeyBar`.
2. Move the current pane pair into a dedicated main-content container.
3. Define the toolbar model and action-routing contract.
4. Make the pane container publish the current normal-mode key bindings.
5. Remove function-key drawing and hit testing from `TerminalFileViewer`; publish
   viewer bindings instead.
6. Remove function-key drawing and hit testing from `TerminalFileEditor`; publish
   editor bindings instead.
7. Move modifier-state handling (Shift/Option) into the shell/key-bar path.
8. Keep margins, corner radius, terminal-cell spacing, and bottom inset entirely in
   the shared key bar/shell.
9. Add/update tests for toolbar models and mode transitions.

## Non-goals for this PR

- Glass/transparency implementation; that belongs to the separate glass PR.
- Changing keyboard shortcuts or command semantics.
- Redesigning the terminal color palette.
- Adding user-facing preferences.

## Notes

This branch intentionally starts from `main`, not from the glass experiment, so
the structural refactor can be reviewed and evolved independently. Once both
changes are ready, the glass work should only need the shell/content surfaces to
remain transparent rather than special-case viewer/editor toolbar rendering.

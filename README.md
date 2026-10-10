# Commander

Licensed under the [MIT License](LICENSE).

A native macOS two-pane file browser with a custom-drawn, Far-style interface.
Blue panels, cyan borders, and two columns of monospaced filenames are drawn in
a plain AppKit view, without native table or scroll widgets. No terminal or embedded web view. The editor uses TextBuffer behind a private adapter.
Requires macOS 13+ and a Swift 6.2 or newer toolchain.

## Run

```sh
swift run Commander
```

To create a standalone, locally ad-hoc signed app:

```sh
bash scripts/build-app.sh
open dist/Commander.app
```

Both panes initially open your home directory.

### Share a preview

```sh
bash scripts/package-app.sh
```

This builds both Apple silicon and Intel architectures and creates
`dist/Commander-0.1.0-macOS-universal.zip`, containing the app and first-launch
instructions. Recipients need macOS 13+, but do not need Xcode or Swift installed.
The app is ad-hoc signed, not Developer ID signed or notarized. Trusted recipients
may need System Settings > Privacy & Security > Open Anyway on first launch.
For normal public distribution, add Developer ID signing and Apple notarization.
The universal bundle is also available at `dist/universal/Commander.app`.

## Controls

| Key | Action |
| --- | --- |
| Command-T | Open an independent tab at the current pane paths |
| Command-W | Close current tab (confirm quitting for the last tab) |
| Command-Shift-[ / ] | Previous / next tab |
| Up / Down | Move selection |
| Tab / Shift-Tab | Switch active pane |
| Option-F1 / Command-1 | Choose location for the left pane |
| Option-F2 / Command-2 | Choose location for the right pane |
| Command-D | Open the active pane’s current directory in the other pane, keeping focus |
| Space | Toggle marking the current entry |
| Shift + arrows | Extend or shrink a selection range |
| Enter | Enter selected folder or open file in its default app |
| Left / Right | Move between name columns |
| Home / End | First / last item |
| Page Up / Page Down | Move by one visible page |
| Backspace | Go to parent, selecting the folder you left |
| Command-L | Go to a path (absolute, relative, or `~`) |
| Command-R | Refresh active pane, preserving selection if possible |
| Command-period | Toggle hidden files in active pane |
| F3 | Open selected file in the read-only text viewer |
| F4 | Open the selected file in the text editor |
| F5 | Copy selected file to the opposite pane (editable destination) |
| F6 | Move marked entries or the cursor entry |
| Shift-F6 | Rename the entry under the cursor |
| F7 | Create a directory in the active pane |
| F8 | Move selected file or folder to macOS Trash after confirmation |
| F10 / Command-Q | Confirm quitting |

Click to activate a pane; double-click to enter a folder or open a file. Mouse wheel/trackpad
scrolling moves selection; typing a filename prefix selects the first match.
The prefix resets after one second or Escape. The bottom shortcut strip has ten numbered slots: 3 View, 4 Edit, 5 Copy, 6 Move, 7 Mkdir, 8 Delete,
and 10 Quit. Other slots are empty; populated slots are clickable. The Navigate menu
also has a Go Home command. Symbolic links have an arrow suffix; links to folders
can be navigated. Errors appear in the pane footer, with full details on hover.

Marked entries appear yellow, including under the cursor. Space toggles without moving the cursor; Shift+arrows extends a range
from the current entry (reversing direction shrinks it). Previously marked entries
outside that range are preserved; `..` cannot be marked. Marks are independent per pane, survive
a refresh for remaining entries, and reset when changing directories. Copy uses marked files when present and clears marks on success. Delete also uses marked entries, including folders.

F10 in the panes, Command-Q, Quit, and closing the main window ask for exit
confirmation. Cancel is selected initially; Tab selects Quit. Active file
operations must finish or be cancelled before quitting. F10 inside the viewer
continues to close the viewer and return to the panes.

### Tabs

Each tab retains its two pane paths, active pane, selections, marks, hidden-file settings,
and any open viewer or unsaved editor. New tabs start at the current tab’s two paths
with fresh pane state. Tab names follow the active pane’s path (`~` for home).
Use File → Rename Tab or right-click a tab to give it a custom name; an empty name
restores automatic naming. The tab context menu also offers Close Other Tabs,
Close Tabs to the Right, and a Tab Color palette (including No Color). Colors
belong to individual tabs and survive navigation and renaming. Bulk closing
checks unsaved edits in each tab; Cancel stops the remaining closes.
Close with the × button or Command-W. Unsaved edits
are checked when closing a tab and across all tabs when quitting.

The tab strip is hidden when only one tab is open; Command-T reveals it again.
View → Tab Placement switches between tabs in the window title bar and a separate
row beneath it. The placement preference is remembered. Scroll over the strip
with a mouse wheel or trackpad to reach overflowing tabs; selecting a tab reveals it.
Tab switching is temporarily blocked during modal file operations or dialogs.
Tabs themselves are not restored after restarting the app.

### File colors

File-name colors are defined in `Sources/CommanderUI/FileColorScheme.swift`,
including the archive extension list and rule precedence. Hidden items (dot names
or macOS hidden flags) are muted, directories white, archives pink, executables
green, and other files cyan. Executable status uses filesystem permissions and
follows symlinks. Hidden coloring wins over categories; selected names remain
black on the selection background. No configuration file is required.

### Locations

Option-F1 and Option-F2 open the left and right pane location pickers. Command-1
and Command-2 are alternatives when macOS uses the function keys for system controls.
The same commands are available in the Navigate menu. Holding Option/Alt shows
`1 Left` and `2 Right` in the bottom shortcut bar; both labels are clickable.
Use arrows and Enter, or
double-click a location, to open it and focus that pane. Escape cancels without
changing either pane or its focus.

Locations include Home, iCloud Drive when its local folder exists, and visible,
browsable mounted volumes, including external drives, disk images, and mounted
network shares. The list is rediscovered each time it opens. iCloud Drive opens
`~/Library/Mobile Documents/com~apple~CloudDocs`; Finder's virtual view may also
include app-specific folders outside this directory. Browsing does not request
file downloads. A missing or inaccessible location reports an error and retains
the pane's previous listing. Favourites are not included yet.

### File viewer

iCloud files that are not downloaded or are downloading show a cloud with a down
arrow at the right of their filename column. The selected
file's footer repeats the compact icon beside the usual metadata. Locally available
files have no row icon. Panes automatically refresh when filesystem changes are detected
and when Commander becomes active, preserving the selected file and surviving marks.
Filesystem identities keep selection and marks on files renamed within the displayed
directory, with path-based fallback for replaced files and ambiguous hard links.
Status is a metadata snapshot, also refreshed with Command-R,
directory navigation, or closing the viewer; the indicator does not initiate a
download. This uses Apple's iCloud metadata, not third-party cloud-provider status.

F3 (or Fn-F3) and the footer View button open a full-window, read-only UTF-8 text
viewer. F4 toggles text/hex mode, and the clickable F4 footer slot shows the next
mode. Hex mode displays 16 bytes per row, 64-bit hexadecimal offsets, and an ASCII
column (non-printable bytes become dots). Switching preserves the nearby byte
position and resets horizontal panning. Up/Down and the mouse wheel scroll; Page Up/Down or Space move a page;
Home/End jump to the beginning/end; Left/Right pan horizontally. Escape, F3, or F10
returns to the original panes and selection. Command-R refreshes the open file.

`FileViewerDocument` uses positional `pread` reads on a dedicated actor, with one
64 KiB cache and at most 200 visible rows. It stores byte offsets, not a growing
whole-file line index. Reads and decoding stay off the UI thread. The top status bar shows path, encoding, byte position, horizontal column, and
percentage; the numbered footer provides Close, Hex/Text, and Quit. The file is
opened read-only; non-regular files such as devices and FIFOs are rejected.
Relative, absolute, and chained symbolic links are followed. Broken links report
the link and its target. The viewer appears only after opening and reading the
first page successfully; opening errors are displayed over the file panes.
`FileViewerCoordinator` coalesces navigation requests; `TerminalFileViewer` draws
the page and handles input independently of disk access.

Logical lines crossing 4 KiB boundaries continue on another row, preserving UTF-8
characters and CRLF pairs. This bounds both memory and the work needed for backward
scrolling and End, even for files with no newlines. Use horizontal panning to see
wide rows. Byte position is displayed instead of a total line count. Tabs expand
to four-column stops; invalid UTF-8 is replaced with `�`, and other control bytes
are shown as dots. The text and hex viewer does not render PDF/images;
UTF-16 and legacy encoding detection and search are not implemented. Editing is available separately with F4 from the panes.

The viewer tolerates truncation and growth on subsequent navigation/refresh. It
keeps the original file descriptor open; if a file is replaced by a new inode,
close and reopen the viewer to see the replacement. There is no automatic tailing.

### File editor

F4 in the panes opens the file under the cursor in a custom-drawn editor.
Shift-F4 prompts for a filename in the active directory and opens it in the editor.
New files are created on save (including empty files); existing names open for editing.
F4 inside the viewer still toggles hex mode.

- Arrows, Home/End, Command-arrows, and Page Up/Down navigate.
- Shift with movement extends the selection; click/drag also selects.
- Type, Enter, Tab, Backspace, and forward Delete edit the document.
- Command-A/C/X/V selects all, copies, cuts, and pastes.
- Command-Z / Command-Shift-Z undo and redo.
- F2 or Command-S saves. Escape or F10 closes.
- Closing a modified document, including quitting Commander, offers Save, Discard,
  and Cancel. Save failures leave edits available.

The editor supports UTF-8 text without a fixed file-size limit. Files are held in
memory, so practical limits depend on available RAM and performance. It preserves
a UTF-8 BOM and consistent LF, CRLF, or CR line endings. Mixed line endings, binary
files, and other encodings are rejected before displaying the editor. The F3
viewer still supports large files with bounded reads.

Saving stages a sibling temporary file and replaces the resolved target, preserving
symlinks, permissions, and extended attributes. External content changes are checked
before saving and again before replacement; detected conflicts leave the document
open. This is not a cross-process lock. Saving multiply hard-linked files is currently
rejected to avoid breaking their relationship. There is no Save As, search, syntax
highlighting, soft wrapping, or automatic recovery yet.

EditorCore.EditorDocument is the replaceable document interface. Only its private
adapter imports TextBuffer; neither UI nor file I/O exposes dependency types.
The adapter uses RopeBuffer, an incremental line-start index, and delta-based undo.
Line-index updates shift subsequent offsets, so edits near the start are linear in
the number of following lines. No file-sized snapshot is made during drawing.
EditorSelection handles cursor/selection behavior, EditorFile handles loading and
saving, and FileEditorCoordinator owns dialogs and the editor lifetime. TextBuffer
is pinned to an immutable revision; its MIT notice is in
[THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt) and bundled in the app.

### File operations

Shift-F6 opens a rename dialog prefilled with the current entry’s name, ignoring
marked entries. It renames within the current folder and never overwrites an
existing destination. Errors return to the entered name for correction. While
Shift is held, the panels’ footer shows only supported Shift commands (4 New file, 6 Rename);
release Shift to restore the usual commands. Shift-clicking that slot also renames.


F6 (or Move) relocates marked entries, falling back to the cursor entry. It uses
native macOS moves, including folders and symlinks. A single entry can be renamed
by editing the destination path, or moved into an existing directory. Multiple
entries require an existing destination folder. Existing items are never replaced.
The dialog reports item progress; the confirmed operation runs to completion or
the first error and cannot be interrupted mid-item. On failure, completed moves
remain in place and the remaining source entries stay marked. Success clears marks.
On the same volume this is a rename; across volumes macOS transfers the contents
and removes the source after success.


F7 (or the Mkdir footer button) opens a directory-name dialog. Enter creates
a single folder in the active pane; Escape cancels. Existing entries are never
replaced. Errors return to the entered name for correction. The new directory is
selected after creation.


F5 (or Fn-F5, depending on macOS keyboard settings) and the footer Copy button
open a gray terminal-style destination dialog. With multiple marked files, the
destination is an existing folder, and files copy in pane order with combined
byte progress. A failure or cancellation stops the batch, keeps completed copies,
and retains marks; a fully successful copy clears marks. Tab switches between the path and
buttons; Enter copies and Escape cancels. A matching progress dialog shows actual
bytes copied and percentage, with Cancel/Escape to stop the operation. Copy errors
use a red dialog dismissed with OK, Enter, or Escape. Files copy in the background; existing destinations are
never overwritten. Successful copies refresh panes showing the destination folder.
File symlinks are copied as links; relative link targets remain unchanged.

F8 (or Fn-F8) and the footer Delete button open a red confirmation dialog.
Marked entries are trashed together; with no marks, the cursor entry is used.
Selection clears on success. On a failure, processing stops and marks remain on
items still present; the error reports how many items reached Trash.
Cancel is selected initially; Tab or Left/Right selects Trash, then Enter confirms.
Escape cancels. Folders and their contents are moved together; symlinks are trashed
as links. Deletion never falls back to permanent removal if Trash is unavailable.
Errors appear in a red dialog, and successful deletion refreshes affected panes.

This draft does not support folder copying, permanent deletion, shell,
or persistent navigation history.
macOS privacy restrictions can prevent access to some directories; the pane reports
the error and retains the previous listing.

## Structure

### App icon

`Assets/Commander.icns` is included in every app bundle and ZIP. Its iconset
contains 16, 32, 128, 256, and 512-point variants at 1× and 2×, up to 1024 pixels.
Small variants simplify the details. The vector drawing source is
`scripts/generate-icon.swift`; regenerate the PNGs and ICNS with:

```sh
bash scripts/generate-icon.sh
```

### Code

- `FileManagerCore`: immutable file entries, a replaceable `DirectoryReading`
  interface, local directory reads, pure `PaneState` navigation state, and a
  `ColumnViewport` model for paging and keeping selection visible.
- `CommanderUI`: AppKit application/window setup and pane controllers. Each pane
  owns its independent state. `TerminalPaneView` draws and hit-tests a shared
  `PaneGeometry`; `TerminalTheme` centralizes colors and typography. Keyboard
  input is translated into pane actions. `TerminalKeyBar` draws the shortcut strip.
  Directory reads run outside the main actor; request identities and cancellation
  prevent stale results from replacing newer ones. UI updates stay on the main actor.
- `Commander`: executable entry point.

`LocalFileCopier` stages copies in the destination filesystem before publishing
them; a small `CFileCopy` adapter uses macOS `copyfile` to preserve metadata while
reporting progress and checking cancellation. Cancelling removes the staged copy.
`CopyCoordinator` handles the modal lifecycle; `TerminalOperationDialog` draws shared
copy and delete dialog modes, using a borderless native editor for reliable path editing and paste. Extend the operations
service for future file mutations, then refresh affected panes.
Add command execution as a separate process service and output view. Neither needs
to live inside the directory reader or table renderer. A future terminal panel can
be another child view controller, independent of file browsing.

Rendering, viewport logic, and filesystem coordination are separate. A real terminal
emulator is not required for this interface. Native macOS window chrome and the
Go to Folder dialog remain; file panes, shortcut bar, and file-operation dialogs are custom drawn.
Basic accessibility exposes the pane path and selected item; full per-row VoiceOver
navigation and IME-based filename search are not yet implemented.
Directory listings are snapshots rather than live streams; extremely large or
stalled network folders can still take time to load.

## Verification

```sh
swift test
```

Core tests cover sorting, hidden files, symbolic directory links, read errors,
root navigation, restoring selection on returning to a parent, stale selection,
and independent panes. Viewport and AppKit tests cover paging, resize, cell hit
testing, custom keyboard navigation, and equal pane layout at three window sizes.
UI smoke checks should cover Tab, folder entry/return,
Go to Folder, hidden files, resizing, and a denied or missing path.

Copy tests also cover byte progress, cancellation cleanup, empty files, permissions
and modification dates, dialog keyboard focus, and the error-to-pane transition.

`LocalFileTrasher` supplies recoverable deletion; `DeleteCoordinator` owns its
confirmation and error flow. Both operations share `OperationDialogPresenter`
for focus restoration. Delete coordinator tests use an injected service, so they
do not touch personal files or Trash.

Viewer tests cover an 8 GiB sparse file with less than 1 MiB read for opening and
jumping to End, empty files, invalid UTF-8, CRLF and scalar boundaries, growth,
truncation, scrolling, and restoring pane focus.

Hex tests cover byte formatting, partial rows, round-trip mode switching,
empty/truncated files, and byte offsets beyond 4 GiB with bounded reads.

### Editor load profiling

Build the standalone release benchmark and profile the same document preparation
path used by F4:

    swift build -c release --product EditorBenchmark
    COMMANDER_PROFILE_EDITOR=1 .build/release/EditorBenchmark /path/to/file

Stage logging is opt-in and never includes document contents.
See [the 100 MiB baseline](docs/performance/editor-loading.md) for measured results
and the comparison conditions.

### Opening files

Enter or double-click opens the file under the cursor in its macOS default app,
ignoring marks. If there is no default, a custom Open with dialog lists registered
apps and Other…. Arrow keys, Home/End, Page Up/Down, and the mouse wheel navigate
the list; Enter or double-click chooses an item. Escape cancels.
Other… opens a custom folder browser starting in /Applications. Choose an .app,
enter subfolders, use .. to go up, or Enter path… for a folder/application path
(including ~). Cancel returns to the suggested apps. App choices apply only to
this opening and do not change system defaults. Launch errors appear in a dialog.

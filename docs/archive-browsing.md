# Archive browsing

Enter opens recognized local archives as read-only pane sessions. Supported filename
extensions are zip, 7z, tar, tgz, tbz, tbz2, txz, gz, bz2, xz, zst, tzst, rar,
cpio, iso, and cab (case-insensitive). The extension chooses the UI action;
libarchive detects the actual format. Invalid archives report an error and leave
the previous directory, cursor, and marks intact.

Enter navigates directories; `..` or the parent shortcut returns to the previous
directory and selects the directory just left. At the archive root it returns to
the containing local folder and selects the archive. Cmd-D shares the immutable
archive index with the other pane; each pane keeps independent navigation and
selection. A new tab starts in the containing local directories. Home, Locations,
and Go to Folder leave archive browsing; relative Go to Folder paths resolve
against the containing local folder.

View, edit, new file, mkdir, rename, delete, and opening member files are disabled.
Copy and move are disabled whenever either participating pane is inside an archive.
The shortcut bar hides unavailable labels and action handlers enforce the same
rules. Nested archives and link targets cannot be entered. Terminal commands run
in the archive's containing local folder, as shown by the shell prompt; virtual
paths are never sent to a shell or host file operation.

## Implementation

- `FileSystemPath` distinguishes file URLs from virtual addresses.
- `VirtualFileSystem` supplies directory snapshots and operation capabilities.
- `FileSystemSession` holds the current path, provider, local terminal directory,
  and archive exit selection. `PaneState` preserves the existing local identity,
  mark, and selection semantics.
- `ArchiveCore` owns synchronous libarchive handles and returns copied Swift
  metadata. It has no pane or filesystem-index dependencies. Handles and the
  validated regular-file descriptor close on success, error, and cancellation.
- `ArchiveFileSystem` builds an immutable tree, including implicit directories,
  with directories-first natural sorting and hidden-file filtering. Every opened
  index has its own virtual URL namespace.
- Background indexing commits only if its navigation request is still current.
  Cancellation propagates to the worker and is checked between headers and index
  entries. Cancellation cannot interrupt an individual libarchive C call.

The exact dependency is `inikolaev/libarchive-bin` **3.8.10-1**, product/module
`CLibArchive`. It statically bundles libarchive and its compression libraries;
there is no system-libarchive fallback. Only none, gzip, bzip2, xz, lzma, and zstd
filters are enabled, avoiding external helper programs. Its upstream license
notices are included in `THIRD-PARTY-NOTICES.txt`, which app packaging already copies.

## Security and limits

No member data is extracted or written to disk. Links are displayed but never
followed. Absolute paths, `..`, Windows drive prefixes, backslashes, and control
characters are rejected. Repeated slashes and `.` components normalize away.
Conflicting file/directory entries and duplicate files are rejected; repeated
directories are allowed. Names retain case and Unicode spelling.

Limits: 100,000 headers, 200,000 indexed nodes including implicit directories,
128 path components, 4,096 UTF-8 bytes per pathname, and 16 MiB total pathname
metadata. These bound the index, not decompression CPU time. A compressed tar can
require scanning its compressed contents before navigation becomes available.

Encrypted archives and undecodable names fail with an error; no password prompt
is provided. A thread-local UTF-8 locale supports Unicode headers without changing
the process locale. Legacy filename encoding selection is not implemented.
Warnings from libarchive fail the open rather than silently publishing a partial
index. Listing metadata does not verify every member's payload or checksum.

An open index is a snapshot: refresh re-filters it, without reopening the archive.
If another pane or process renames, replaces, or deletes the underlying archive,
the snapshot remains browsable; leave and re-enter to rebuild it. If the containing
folder is gone, exiting reports the local read error and preserves the snapshot;
Home or Locations can still leave it.

Fixtures exercise ZIP, tar, gzip, bzip2, and xz with the released binary. Other
recognized formats depend on bundled libarchive support; RAR is not certified by
this test set. Extraction, archive mutation, nested archives, and member viewing
are deferred.

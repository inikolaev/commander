# Syntax highlighting

# Viewer

The viewer consumes semantic UTF-8 byte spans through `SyntaxHighlighter`.
`ViewerSyntaxProjection` translates them to display positions, and `TerminalTheme`
chooses colors. Language definitions do not depend on the viewer or AppKit.

## Editor

`FileEditorCoordinator` starts `EditorSyntaxController` with the opened `EditorFile.text`.
That text is already BOM-free and LF-normalized; highlighting therefore uses the
same bytes as the editable document, including for CRLF files and new files.
Only supported files of at most 512 KiB of normalized UTF-8 text get an initial
editing session. Larger or unsupported files stay responsive with plain text.
The viewer's separate 8 MiB limit is unchanged.

Session construction and its synchronous first parse run on a detached executor.
The controller observes `EditorDocument` content changes, retaining every ordered
UTF-16 delta from typing, undo, redo, and IME composition. It waits about 100 ms
after the latest edit, then applies the batch through one retained
`SyntaxEditingSession`. Updates are serialized; edits received during an update
form the next batch. The session discards its parser when content grows beyond
512 KiB and can resume highlighting if later edits shrink it. Closing the editor
removes the observer, cancels pending work, and drops the session.

`EditorSyntaxProjection` converts the session's UTF-8 byte spans into immutable
UTF-16 ranges for a source snapshot at the same content version. Projection runs
off the main actor. It snaps colors to complete Swift `Character` boundaries, so
combining sequences and emoji are drawn as whole glyphs. The renderer uses a
binary search per visible glyph; it does no parsing, full-document reads, or
whole-file scans in `draw`. Selected text keeps the selection contrast color,
and marked IME text keeps its underline. Results from older content versions are
discarded before reaching the renderer.

## Responsibilities

- `SyntaxRegistry` detects supported file extensions and exact filenames, enforces the 8 MiB default
  size limit, and falls back to plain text on errors. It accepts either a file URL
  or supplied data, including archive-member contents.
- `TreeSitterSyntaxHighlighter` constructs a parser, evaluates a language's query,
  resolves predicates, and passes semantic captures to the span index. Parser and
  tree objects are local to initialization; the resulting highlighter is immutable.
- `SyntaxSpanNormalizer` resolves overlaps; `SyntaxSpanIndex` stores the result
  and finds spans intersecting a requested byte range.
- Language definitions supply the grammar, query, capture styles, and registry
  metadata. `codeCaptures` provides common semantic roles for code languages.

## Supported languages

| Language | Extensions / filenames |
| --- | --- |
| JSON | `.json` |
| Python | `.py`, `.pyi`, `.pyw` |
| C / C++ | `.c`, `.h` / `.cc`, `.cpp`, `.cxx`, `.c++`, `.hh`, `.hpp`, `.hxx`, `.h++`, `.ipp`, `.tpp` |
| Go | `.go` |
| Bash / shell | `.sh`, `.bash` |
| HTML / JavaScript / JSX | `.html`, `.htm` / `.js`, `.jsx`, `.mjs`, `.cjs` |
| TypeScript / TSX | `.ts`, `.mts`, `.cts`, `.tsx` |
| YAML | `.yaml`, `.yml` |
| TOML | `.toml` |
| Java | `.java` |
| Kotlin | `.kt`, `.kts` |
| Swift | `.swift` |
| Rust | `.rs` |
| Bazel / Starlark | `.bzl`, `.bazel`, `BUILD`, `WORKSPACE` |
| CSS | `.css` |
| Markdown | `.md`, `.markdown`, `.mdown`, `.mkd`, `.mkdn` |

Extensions are case-insensitive. Exact filenames are case-sensitive and work
for both local files and archive members. There is no shebang-based detection.
Keywords use the constant color, functions the accent color, types the property
color, and variables the normal text color in both themes. JSON colors are unchanged.

HTML highlights markup and embedded `<script>`/`<style>` blocks. Script types
select JavaScript (including modules), JSON/JSON-LD, import maps, or speculation
rules. Style blocks select CSS. Unsupported types and external-script bodies
keep HTML-only highlighting. Inline `style` and event-handler attributes remain
attribute strings. `.h` files
use the C grammar; C++ headers can use `.hpp`, `.hh`, or the other C++ extensions
listed above. Shell support uses the Bash grammar. Bazel files use Starlark;
`.bazelrc` is not a Starlark file and remains plain text.

Grammar versions are pinned to releases with usable SwiftPM packages and generated
parsers. Python, JavaScript, and YAML use releases that explicitly include their
external scanners; Swift uses the `with-generated-files` release. When upgrading,
verify linking as well as query compilation and the language fixtures.

## Span contract and precedence

Highlighters return nonempty, sorted, disjoint byte ranges in the original UTF-8
source. A request returns intersecting spans without clipping them. An empty
request returns no spans. Projection clips spans to displayed rows.

Higher configured capture priority wins an overlap. Equal priority favors the
narrower capture, then the earlier capture in query traversal order. An inner
winner splits the enclosing capture, preserving the outer style on either side.
Adjacent spans of the same kind are merged. Normalization takes O(n log n);
indexed lookup takes O(log n + k) for k returned spans.

## Adding a language

1. Add its grammar dependency to `Package.swift` and the `SyntaxCore` target.
2. Create a definition file like `JSONSyntaxDefinition.swift`: supply the grammar,
   query, and a mapping from query capture names to `SyntaxCaptureStyle` values.
   Unmapped captures are ignored and can be used as predicate inputs.
3. Create a `SyntaxLanguageDefinition` with lowercase file extensions, optional exact filenames, and a
   lazy `syntax` factory using the shared engine, then register it in `SyntaxRegistry.viewer`.
   The ID and extensions also resolve fence labels; put additional names in `aliases`.
4. Add fixtures for token kinds, precedence, predicates, and multiline content.
   Use UTF-8 byte offsets in assertions.
5. Add a `SyntaxKind` and theme mapping only when a new visual semantic is needed.

The coordinator, projection, and renderer should not need language-specific edits.


## Supported queries

The engine supports literal `#eq?` and `#not-eq?` comparisons, `#match?`,
`#not-match?`, `#any-of?`, and `#not-any-of?`. Equality and regex predicates take
one capture followed by one literal string. Membership predicates take one
capture followed by zero or more literal strings. Empty membership sets match
nothing; their negation matches everything. Repeated captures must all satisfy
each predicate, and multiple predicates on a match must all pass. Empty and
invalid regex patterns are rejected by Foundation and trigger plain-text fallback.

Literal equality and membership follow Swift's canonical Unicode equivalence:
composed and decomposed forms of `é` compare equal. Source bytes and returned
offsets are preserved. Regex matching follows Foundation's regular-expression
semantics. Text is resolved using
Tree-sitter row/byte-column positions because the dependency's NSRange helpers
and resolving-sequence cache assume UTF-16, while this parser uses UTF-8.

Original query arguments are validated before evaluation because the dependency
discards some extra arguments while constructing its predicate representation.
Wrong argument order, missing or extra equality/regex arguments, and extra
membership captures are rejected instead of silently changing query meaning.

Unknown predicates, capture-to-capture equality, semantic-local predicates, and
directives (including `#set!`) are rejected during query setup, causing the
registry to return plain text. Priorities belong in the capture-style mapping.
This avoids silently accepting semantics the engine cannot honor. Local-symbol analysis is not implemented.

## Embedded languages

`TreeSitterSyntaxDefinition.injections` contains structural queries capturing
`injection.content` and typed language resolvers. `HTMLLanguageInjections` owns
HTML attribute/type selection; the engine has no HTML-specific branches. This
follows the [HTML script type distinctions](https://html.spec.whatwg.org/multipage/scripting.html#the-script-element).

`TreeSitterInjectionHighlighter` parses each captured byte slice with the selected
definition and offsets its spans back into the original document. Each layer is
normalized independently; embedded spans take precedence over host spans. HTML's
parse tree determines block boundaries, including closing tags inside JavaScript
strings. Bodies are parsed as raw text, without decoding HTML entities.

Invalid injection queries, unsupported types, or failed embedded highlighters
leave host highlighting intact and do not prevent other blocks from highlighting.
Repeated regions are processed once, and recursion stops after eight levels.
The registry's size limit applies to the complete document, including archive
members. Structural injection queries do not accept predicates or directives;
selection belongs in the resolver. Existing highlight-query predicate support
is unchanged.

## Markdown

Markdown source highlighting combines the grammar's block and inline parsers.
It colors headings, list/task markers, blockquotes, tables, links/images, emphasis,
strikethrough, and code spans. This colors the source; it does not render Markdown.
Metadata/front-matter blocks use the comment color.

Labelled code fences reuse the installed language definitions, including common
aliases such as `py`, `js`, `ts`, `sh`, `c++`, and `yml`. Unknown and unlabelled
fences retain literal-code coloring. Supported fences use normal text for gaps
between tokens. HTML blocks reuse HTML's JavaScript/CSS injections, and nested
Markdown fences use the same recursion limit as other injections.

For inline content and nested fenced blocks, injection definitions exclude the
block grammar's `block_continuation` children. Tree-sitter included ranges skip
these host prefixes without changing byte offsets. Ancestor ranges are intersected with each child region and its own exclusions
before nested parsing; returned spans are clipped to
those ranges, preserving blockquote/list marker colors even when an embedded
token crosses a line. Language IDs, extensions, and extra aliases live with their definitions in the
shared registry. `MarkdownCodeFences` only extracts the label. The current registry
is passed through nested injections, so registering a new grammar also enables
its fences without changing Markdown or the engine.

Markdown temporarily pins upstream revision `ec1a4f07a20cb5cf8e90653e4a492445e4646154`
(the unreleased fix in tree-sitter-markdown PR #271). It recognizes closing
backtick and tilde fences at EOF, including trailing whitespace, without requiring
a final newline. Move back to a release pin once that fix is released.

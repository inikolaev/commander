# Viewer syntax highlighting

The viewer consumes semantic UTF-8 byte spans through `SyntaxHighlighter`.
`ViewerSyntaxProjection` translates them to display positions, and `TerminalTheme`
chooses colors. Language definitions do not depend on the viewer or AppKit.

## Responsibilities

- `SyntaxRegistry` detects supported file extensions, enforces the 8 MiB default
  size limit, and falls back to plain text on errors. It accepts either a file URL
  or supplied data, including archive-member contents.
- `TreeSitterSyntaxHighlighter` constructs a parser, evaluates a language's query,
  resolves predicates, and passes semantic captures to the span index. Parser and
  tree objects are local to initialization; the resulting highlighter is immutable.
- `SyntaxSpanNormalizer` resolves overlaps; `SyntaxSpanIndex` stores the result
  and finds spans intersecting a requested byte range.
- `JSONSyntaxDefinition` supplies only the grammar, query, capture styles, and
  registry definition for JSON.

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
3. Create a `SyntaxLanguageDefinition` with lowercase file extensions and a
   factory using the shared engine, then register it in `SyntaxRegistry.viewer`.
4. Add fixtures for token kinds, precedence, predicates, and multiline content.
   Use UTF-8 byte offsets in assertions.
5. Add a `SyntaxKind` and theme mapping only when a new visual semantic is needed.

The coordinator, projection, and renderer should not need language-specific edits.
No additional languages are enabled by this refactor.

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
This avoids silently accepting semantics the engine cannot honor. Language
injections and local-symbol analysis are not implemented.

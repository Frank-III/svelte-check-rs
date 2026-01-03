# Zig Parser for svelte-check-rs

A Zig-based JavaScript/TypeScript parser for Svelte. Uses adapted code from Bun's parser for token definitions.

## Structure

```
zig-parser/
├── build.zig              # Build configuration
├── build.zig.zon          # Package manifest
└── src/
    ├── main.zig           # Entry point + FFI exports
    ├── lexer.zig          # JavaScript/TypeScript lexer
    ├── ast.zig            # AST node types
    ├── js_lexer_tables.zig # Token type definitions (from Bun)
    ├── bun.zig            # Bun compatibility layer
    ├── feature_flags.zig  # Feature flags
    └── js_lexer/
        └── identifier.zig # Unicode identifier tables (from Bun)
```

## Building

Requires Zig 0.15.1+

```bash
# Build
cd zig-parser
zig build

# Run tests
zig build test
```

## Status

### Completed
- [x] Token types (all JS/TS operators, keywords, literals)
- [x] Lexer (tokenization with line/column tracking)
- [x] AST node types (expressions, statements, bindings)
- [x] FFI exports for Rust integration

### In Progress
- [ ] Expression parser
- [ ] Statement parser

### Planned
- [ ] Svelte-specific syntax:
  - `{#if}`, `{#each}`, `{#await}`, `{#snippet}`, `{#key}`
  - `{:else}`, `{:then}`, `{:catch}`
  - `{@html}`, `{@debug}`, `{@const}`, `{@render}`, `{@attach}`
  - `{expression}` interpolation
- [ ] TypeScript type annotation parsing
- [ ] JSX support
- [ ] Rust FFI bindings crate

## FFI API

```zig
// Get version string
pub export fn svelte_parser_version() [*:0]const u8;

// Tokenize source code
pub export fn svelte_parser_tokenize(
    source_ptr: [*]const u8,
    source_len: usize,
) ParseResult;
```

## Architecture

The parser is designed to be:

1. **Standalone** - No runtime dependencies beyond Zig's standard library
2. **FFI-ready** - C ABI exports for calling from Rust
3. **Fast** - Direct tokenization without intermediate representations

Token types and keyword maps are adapted from Bun's parser, with a compatibility layer (`bun.zig`) providing the required utilities.

## License

MIT

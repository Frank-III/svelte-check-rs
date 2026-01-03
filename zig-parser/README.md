# svelte-check-zig

A Zig-based Svelte file parser and checker. Fast, standalone, with no runtime dependencies.

## Building

Requires Zig 0.15.1+

```bash
cd zig-parser

# Build CLI executable
zig build

# Run tests
zig build test

# Run the checker
zig build run -- --check path/to/file.svelte
```

## Usage

```
Usage: svelte-check-zig [options] <files...>

Options:
  --help, -h     Show this help
  --version      Show version
  --check        Check files for errors (default)
  --parse        Parse and show AST summary
  --tokens       Show token stream
```

Examples:
```bash
# Check Svelte files
./zig-out/bin/svelte-check-zig --check src/**/*.svelte

# Show tokens
./zig-out/bin/svelte-check-zig --tokens app.js

# Parse and show summary
./zig-out/bin/svelte-check-zig --parse Component.svelte
```

## Structure

```
zig-parser/
├── build.zig              # Build configuration
├── build.zig.zon          # Package manifest
└── src/
    ├── main.zig           # Entry point + CLI + FFI exports
    ├── lexer.zig          # JavaScript/TypeScript lexer
    ├── parser.zig         # JS/TS expression & statement parser
    ├── ast.zig            # AST node types
    ├── svelte.zig         # Svelte template parser
    ├── js_lexer_tables.zig # Token type definitions
    ├── bun.zig            # Bun compatibility layer
    ├── feature_flags.zig  # Feature flags
    └── js_lexer/
        └── identifier.zig # Unicode identifier tables
```

## Features

### Completed
- [x] Full JavaScript/TypeScript lexer
- [x] Expression parser (Pratt parsing with precedence)
- [x] Statement parser (all ES2024 statements)
- [x] Svelte template parser:
  - `{#if}`, `{:else if}`, `{:else}`, `{/if}`
  - `{#each}` with index and key
  - `{#await}`, `{:then}`, `{:catch}`
  - `{#key}`, `{#snippet}`
  - `{@html}`, `{@debug}`, `{@const}`, `{@render}`
  - `{expression}` interpolations
  - Element and component parsing
  - Attribute parsing (directives, spread, shorthand)
- [x] CLI with multiple modes
- [x] FFI C API for embedding

### Planned
- [ ] Type checking / diagnostics
- [ ] CSS parser for `<style>` blocks
- [ ] Source maps
- [ ] Language server protocol (LSP)

## FFI API

For embedding in other applications:

```c
// Get version string
const char* svelte_parser_version();

// Tokenize JavaScript/TypeScript
typedef struct {
    bool success;
    uint32_t error_count;
    uint32_t token_count;
} ParseResult;

ParseResult svelte_parser_tokenize(const char* source, size_t len);

// Parse Svelte file
typedef struct {
    bool success;
    uint32_t error_count;
    bool has_script;
    bool has_module_script;
    bool has_style;
    uint32_t template_node_count;
} SvelteParseResult;

SvelteParseResult svelte_parser_parse_svelte(const char* source, size_t len);
```

## Architecture

The parser is designed to be:

1. **Fast** - Direct tokenization and parsing, no intermediate representations
2. **Standalone** - No runtime dependencies beyond Zig's standard library
3. **Complete** - Full Svelte 5 syntax support
4. **Embeddable** - C ABI exports for calling from other languages

## License

MIT

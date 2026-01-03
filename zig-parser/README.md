# Zig Parser for svelte-check-rs

A Zig-based JavaScript/TypeScript parser, adapted from [Bun's parser](https://github.com/oven-sh/bun).

## Structure

```
zig-parser/
├── build.zig          # Build configuration
├── src/
│   ├── main.zig       # Entry point + FFI exports
│   ├── bun.zig        # Compatibility layer for Bun's APIs
│   ├── js_lexer.zig   # Main lexer (from Bun)
│   ├── js_lexer_tables.zig  # Token definitions
│   ├── logger.zig     # Logging/diagnostics
│   ├── string.zig     # String utilities
│   ├── defines.zig    # Defines/macros
│   ├── options.zig    # Parser options
│   ├── feature_flags.zig
│   ├── import_record.zig
│   ├── js_lexer/
│   │   └── identifier.zig
│   └── ast/
│       ├── P.zig          # Main parser struct (330K lines!)
│       ├── Parser.zig     # Parser interface
│       ├── Expr.zig       # Expression AST
│       ├── Stmt.zig       # Statement AST
│       ├── E.zig          # Expression node types
│       ├── S.zig          # Statement node types
│       ├── B.zig          # Binding types
│       ├── G.zig          # General types
│       ├── Op.zig         # Operators
│       ├── Scope.zig      # Scope handling
│       ├── Symbol.zig     # Symbol table
│       ├── Binding.zig    # Binding AST
│       ├── base.zig       # Base types
│       ├── parse.zig      # Parse entry point
│       ├── parseStmt.zig  # Statement parsing
│       ├── parsePrefix.zig
│       ├── parseSuffix.zig
│       ├── parseFn.zig
│       ├── parseProperty.zig
│       ├── parseImportExport.zig
│       ├── parseJSXElement.zig
│       ├── parseTypescript.zig
│       ├── skipTypescript.zig
│       ├── visit.zig      # AST visitor
│       ├── visitExpr.zig
│       ├── visitStmt.zig
│       ├── visitBinaryExpression.zig
│       ├── maybe.zig
│       └── symbols.zig
```

## Building

Requires Zig 0.14.0+

```bash
# Install Zig (macOS)
brew install zig

# Install Zig (Linux)
# Download from https://ziglang.org/download/

# Build
cd zig-parser
zig build

# Run tests
zig build test
```

## Status

This is a work in progress. The files are copied from Bun's parser and need adaptation:

1. **bun.zig** - Compatibility shim created (minimal)
2. **Lexer** - Copied, needs dependency fixes
3. **Parser** - Copied, needs significant adaptation
4. **AST** - Copied, needs dependency fixes

## Next Steps

1. Fix all import paths and dependencies
2. Remove Bun-specific features (bundler, macros, etc.)
3. Add Svelte-specific syntax:
   - `{#if}`, `{#each}`, `{#await}`, `{#snippet}`, `{#key}`
   - `{:else}`, `{:then}`, `{:catch}`
   - `{@html}`, `{@debug}`, `{@const}`, `{@render}`, `{@attach}`
   - `{expression}` interpolation
4. Create Rust FFI bindings
5. Integrate with svelte-check-rs

## License

MIT (following Bun's license)

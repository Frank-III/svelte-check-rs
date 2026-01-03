// svelte-parser-zig
// A Zig-based JavaScript/TypeScript/Svelte parser

const std = @import("std");

pub const lexer = @import("lexer.zig");
pub const tables = @import("js_lexer_tables.zig");
pub const ast = @import("ast.zig");

pub const Lexer = lexer.Lexer;
pub const Token = lexer.Token;
pub const T = tables.T;
pub const Expr = ast.Expr;
pub const Stmt = ast.Stmt;

// FFI C API for Rust integration
pub export fn svelte_parser_version() [*:0]const u8 {
    return "0.1.0";
}

pub const ParseResult = extern struct {
    success: bool,
    error_count: u32,
    token_count: u32,
};

/// Tokenize source and return basic stats
pub export fn svelte_parser_tokenize(
    source_ptr: [*]const u8,
    source_len: usize,
) ParseResult {
    const source = source_ptr[0..source_len];
    var lex = Lexer.init(source);

    var token_count: u32 = 0;
    var error_count: u32 = 0;

    while (lex.token.tag != .t_end_of_file) {
        if (lex.token.tag == .t_syntax_error) {
            error_count += 1;
        }
        token_count += 1;
        lex.advance();
    }

    return ParseResult{
        .success = error_count == 0,
        .error_count = error_count,
        .token_count = token_count,
    };
}

// Tests
test "lexer integration" {
    const source = "const add = (a, b) => a + b;";
    var lex = Lexer.init(source);

    var count: u32 = 0;
    while (lex.token.tag != .t_end_of_file) {
        count += 1;
        lex.advance();
    }

    // const add = ( a , b ) => a + b ;
    // 1     2   3 4 5 6 7 8  9  10 11 12
    try std.testing.expectEqual(@as(u32, 12), count);
}

test "all modules" {
    _ = @import("js_lexer_tables.zig");
    _ = @import("lexer.zig");
    _ = @import("ast.zig");
}

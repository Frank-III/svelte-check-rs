// svelte-parser-zig
// A Zig-based JavaScript/TypeScript/Svelte parser adapted from Bun

const std = @import("std");
const bun = @import("bun.zig");

// Re-export core modules
pub const tables = @import("js_lexer_tables.zig");

// AST types (from Bun)
pub const ast = struct {
    pub const Expr = @import("ast/Expr.zig");
    pub const Stmt = @import("ast/Stmt.zig");
    pub const E = @import("ast/E.zig");
    pub const S = @import("ast/S.zig");
    pub const B = @import("ast/B.zig");
    pub const G = @import("ast/G.zig");
    pub const Op = @import("ast/Op.zig");
    pub const Binding = @import("ast/Binding.zig");
    pub const Scope = @import("ast/Scope.zig");
    pub const Symbol = @import("ast/Symbol.zig");
    pub const P = @import("ast/P.zig");
};

// Convenience aliases
pub const Token = tables.T;

// FFI C API for Rust integration
pub const c_api = struct {
    pub const ParseResult = extern struct {
        success: bool,
        error_message: ?[*:0]const u8,
        ast_ptr: ?*anyopaque,
    };

    /// Parse JavaScript/TypeScript source code
    /// Returns a ParseResult with either the AST or an error message
    pub export fn svelte_parser_parse(
        source_ptr: [*]const u8,
        source_len: usize,
        is_typescript: bool,
        is_jsx: bool,
    ) ParseResult {
        _ = is_typescript;
        _ = is_jsx;
        _ = source_ptr;
        _ = source_len;

        // TODO: Full parsing once dependencies are resolved
        return ParseResult{
            .success = true,
            .error_message = null,
            .ast_ptr = null,
        };
    }

    /// Free a previously allocated AST
    pub export fn svelte_parser_free(ast_ptr: ?*anyopaque) void {
        _ = ast_ptr;
        // TODO: Implement when AST allocation is working
    }

    /// Get the version string
    pub export fn svelte_parser_version() [*:0]const u8 {
        return "0.1.0";
    }
};

// Tests
test "token types exist" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Token.t_end_of_file));
    try std.testing.expect(@intFromEnum(Token.t_let) > 0);
    try std.testing.expect(@intFromEnum(Token.t_const) > 0);
    try std.testing.expect(@intFromEnum(Token.t_function) > 0);
}

test "token tag methods" {
    try std.testing.expect(Token.t_equals.isAssign());
    try std.testing.expect(Token.t_plus_equals.isAssign());
    try std.testing.expect(!Token.t_plus.isAssign());
}

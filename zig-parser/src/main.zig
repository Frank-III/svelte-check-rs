// svelte-parser-zig
// A Zig-based JavaScript/TypeScript/Svelte parser and checker

const std = @import("std");
const Allocator = std.mem.Allocator;

// Module exports
pub const lexer = @import("lexer.zig");
pub const tables = @import("js_lexer_tables.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const svelte = @import("svelte.zig");
pub const checker = @import("checker.zig");

// Type aliases for convenience
pub const Lexer = lexer.Lexer;
pub const Token = lexer.Token;
pub const T = tables.T;
pub const Expr = ast.Expr;
pub const Stmt = ast.Stmt;
pub const Parser = parser.Parser;
pub const SvelteParser = svelte.SvelteParser;
pub const SvelteFile = svelte.SvelteFile;
pub const Checker = checker.Checker;
pub const Diagnostic = checker.Diagnostic;

// ========== FFI C API ==========

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

pub const SvelteParseResult = extern struct {
    success: bool,
    error_count: u32,
    has_script: bool,
    has_module_script: bool,
    has_style: bool,
    template_node_count: u32,
};

/// Parse a Svelte file and return stats
pub export fn svelte_parser_parse_svelte(
    source_ptr: [*]const u8,
    source_len: usize,
) SvelteParseResult {
    const source = source_ptr[0..source_len];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var svelte_parser = SvelteParser.init(arena.allocator(), source);
    const file = svelte_parser.parse();

    return SvelteParseResult{
        .success = file.errors.len == 0,
        .error_count = @intCast(file.errors.len),
        .has_script = file.instance_script != null,
        .has_module_script = file.module_script != null,
        .has_style = file.styles.len > 0,
        .template_node_count = @intCast(file.template.nodes.len),
    };
}

// ========== CLI ==========

const usage =
    \\Usage: svelte-check-zig [options] <files...>
    \\
    \\Options:
    \\  --help, -h     Show this help
    \\  --version      Show version
    \\  --check        Check files for errors (default)
    \\  --parse        Parse and show AST summary
    \\  --tokens       Show token stream
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try std.io.getStdErr().writeAll(usage);
        std.process.exit(1);
    }

    var mode: enum { check, parse, tokens } = .check;
    var files = std.ArrayList([]const u8).init(allocator);
    defer files.deinit();

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.io.getStdOut().writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            try std.io.getStdOut().writeAll("svelte-check-zig 0.1.0\n");
            return;
        } else if (std.mem.eql(u8, arg, "--check")) {
            mode = .check;
        } else if (std.mem.eql(u8, arg, "--parse")) {
            mode = .parse;
        } else if (std.mem.eql(u8, arg, "--tokens")) {
            mode = .tokens;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try files.append(arg);
        }
    }

    if (files.items.len == 0) {
        try std.io.getStdErr().writeAll("Error: No input files\n");
        std.process.exit(1);
    }

    const stdout = std.io.getStdOut().writer();
    var total_errors: u32 = 0;

    for (files.items) |file_path| {
        const source = std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024) catch |err| {
            try stdout.print("Error reading {s}: {}\n", .{ file_path, err });
            total_errors += 1;
            continue;
        };
        defer allocator.free(source);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const is_svelte = std.mem.endsWith(u8, file_path, ".svelte");

        switch (mode) {
            .tokens => {
                try stdout.print("=== {s} ===\n", .{file_path});
                var lex = Lexer.init(source);
                while (lex.token.tag != .t_end_of_file) {
                    try stdout.print("{s}: \"{s}\"\n", .{ @tagName(lex.token.tag), lex.slice() });
                    lex.advance();
                }
            },
            .parse => {
                try stdout.print("=== {s} ===\n", .{file_path});
                if (is_svelte) {
                    var svelte_parser = SvelteParser.init(arena.allocator(), source);
                    const file = svelte_parser.parse();

                    try stdout.print("Module script: {}\n", .{file.module_script != null});
                    try stdout.print("Instance script: {}\n", .{file.instance_script != null});
                    try stdout.print("Styles: {}\n", .{file.styles.len});
                    try stdout.print("Template nodes: {}\n", .{file.template.nodes.len});
                    try stdout.print("Errors: {}\n", .{file.errors.len});

                    for (file.errors) |err| {
                        try stdout.print("  Error: {s} at {}:{}\n", .{ err.message, err.loc.start, err.loc.end });
                    }
                } else {
                    var p = Parser.init(arena.allocator(), source);
                    const program = p.parseProgram();

                    try stdout.print("Statements: {}\n", .{program.stmts.len});
                    try stdout.print("Errors: {}\n", .{p.errors.items.len});

                    for (p.errors.items) |err| {
                        try stdout.print("  Error: {s} at {}:{}\n", .{ err.message, err.loc.start, err.loc.end });
                    }
                }
            },
            .check => {
                if (is_svelte) {
                    var svelte_parser = SvelteParser.init(arena.allocator(), source);
                    const file = svelte_parser.parse();

                    // Parse errors
                    if (file.errors.len > 0) {
                        try stdout.print("{s}:\n", .{file_path});
                        for (file.errors) |err| {
                            try stdout.print("  error: {s}\n", .{err.message});
                            total_errors += 1;
                        }
                    }

                    // Run checker for semantic diagnostics
                    var chk = Checker.init(arena.allocator(), source);
                    chk.check(&file);

                    const diagnostics = chk.getDiagnostics();
                    if (diagnostics.len > 0) {
                        var printed_header = file.errors.len > 0;
                        for (diagnostics) |diag| {
                            if (!printed_header) {
                                try stdout.print("{s}:\n", .{file_path});
                                printed_header = true;
                            }
                            const severity_str = switch (diag.severity) {
                                .@"error" => "error",
                                .warning => "warning",
                                .hint => "hint",
                            };
                            try stdout.print("  {s}: {s} ({s})\n", .{
                                severity_str,
                                diag.message,
                                @tagName(diag.code),
                            });
                            if (diag.severity == .@"error") {
                                total_errors += 1;
                            }
                        }
                    }
                } else {
                    var p = Parser.init(arena.allocator(), source);
                    _ = p.parseProgram();

                    if (p.errors.items.len > 0) {
                        try stdout.print("{s}:\n", .{file_path});
                        for (p.errors.items) |err| {
                            try stdout.print("  error: {s}\n", .{err.message});
                            total_errors += 1;
                        }
                    }
                }
            },
        }
    }

    if (mode == .check) {
        if (total_errors == 0) {
            try stdout.writeAll("No errors found.\n");
        } else {
            try stdout.print("{} error(s) found.\n", .{total_errors});
            std.process.exit(1);
        }
    }
}

// ========== Tests ==========

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

test "parser integration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = Parser.init(arena.allocator(), "let x = 1 + 2;");
    const program = p.parseProgram();

    try std.testing.expectEqual(@as(usize, 1), program.stmts.len);
}

test "svelte parser integration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var svelte_parser = SvelteParser.init(arena.allocator(),
        \\<script>
        \\  let count = 0;
        \\</script>
        \\<button>{count}</button>
    );
    const file = svelte_parser.parse();

    try std.testing.expect(file.instance_script != null);
    try std.testing.expect(file.template.nodes.len > 0);
}

test "checker integration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var svelte_parser = SvelteParser.init(arena.allocator(),
        \\<script>
        \\  let count = 0;
        \\</script>
        \\<button>{count}</button>
    );
    const file = svelte_parser.parse();

    var chk = Checker.init(arena.allocator(),
        \\<script>
        \\  let count = 0;
        \\</script>
        \\<button>{count}</button>
    );
    chk.check(&file);

    // count is defined and used, should have no errors
    try std.testing.expect(!chk.hasErrors());
}

test "all modules" {
    _ = @import("js_lexer_tables.zig");
    _ = @import("lexer.zig");
    _ = @import("ast.zig");
    _ = @import("parser.zig");
    _ = @import("svelte.zig");
    _ = @import("checker.zig");
}

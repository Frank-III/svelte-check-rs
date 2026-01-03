// Minimal bun compatibility layer for the parser
// This provides the subset of Bun's internal APIs needed by the parser

const std = @import("std");
const builtin = @import("builtin");

pub const Environment = struct {
    pub const isDebug = builtin.mode == .Debug;
    pub const isRelease = !isDebug;
    pub const enable_asan = false;
    pub const isWindows = builtin.os.tag == .windows;
    pub const isLinux = builtin.os.tag == .linux;
    pub const isMac = builtin.os.tag == .macos;
};

pub const default_allocator = std.heap.c_allocator;
pub const z_allocator = std.heap.c_allocator;

pub const CodePoint = u21;

pub const ast = struct {
    pub const Expr = @import("ast/Expr.zig");
    pub const Stmt = @import("ast/Stmt.zig");
    pub const E = @import("ast/E.zig");
    pub const S = @import("ast/S.zig");
    pub const B = @import("ast/B.zig");
    pub const G = @import("ast/G.zig");
    pub const Binding = @import("ast/Binding.zig");
    pub const Op = @import("ast/Op.zig");
    pub const Scope = @import("ast/Scope.zig");
    pub const Symbol = @import("ast/Symbol.zig");

    pub const Span = struct {
        text: []const u8 = "",
        loc: logger.Loc = .{},

        pub fn isEmpty(self: Span) bool {
            return self.text.len == 0;
        }
    };
};

pub const logger = @import("logger.zig");

pub const strings = struct {
    pub fn eql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    pub fn eqlComptime(a: []const u8, comptime b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    pub fn startsWith(haystack: []const u8, needle: []const u8) bool {
        return std.mem.startsWith(u8, haystack, needle);
    }

    pub fn endsWith(haystack: []const u8, needle: []const u8) bool {
        return std.mem.endsWith(u8, haystack, needle);
    }

    pub fn indexOfChar(haystack: []const u8, needle: u8) ?usize {
        return std.mem.indexOfScalar(u8, haystack, needle);
    }

    pub fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
        return std.mem.indexOf(u8, haystack, needle);
    }

    pub fn trim(s: []const u8) []const u8 {
        return std.mem.trim(u8, s, " \t\r\n");
    }

    pub fn toUpper(c: u8) u8 {
        return std.ascii.toUpper(c);
    }

    pub fn toLower(c: u8) u8 {
        return std.ascii.toLower(c);
    }

    pub fn isAlphanumeric(c: u8) bool {
        return std.ascii.isAlphanumeric(c);
    }

    pub fn isDigit(c: u8) bool {
        return std.ascii.isDigit(c);
    }

    pub fn isHexDigit(c: u8) bool {
        return std.ascii.isHex(c);
    }

    pub fn isWhitespace(c: u8) bool {
        return std.ascii.isWhitespace(c);
    }
};

pub const MutableString = struct {
    list: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) MutableString {
        return .{
            .list = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn initEmpty(allocator: std.mem.Allocator) MutableString {
        return init(allocator);
    }

    pub fn deinit(self: *MutableString) void {
        self.list.deinit();
    }

    pub fn appendSlice(self: *MutableString, items: []const u8) !void {
        try self.list.appendSlice(items);
    }

    pub fn append(self: *MutableString, item: u8) !void {
        try self.list.append(item);
    }

    pub fn toOwnedSlice(self: *MutableString) []u8 {
        return self.list.toOwnedSlice() catch &[_]u8{};
    }

    pub fn items(self: *const MutableString) []const u8 {
        return self.list.items;
    }
};

pub const Output = struct {
    pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
        std.debug.panic(fmt, args);
    }

    pub fn prettyFmt(comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
    }
};

pub const js_printer = struct {
    pub const Options = struct {
        pub const Indentation = struct {
            count: u32 = 0,
            char: u8 = ' ',
        };
    };
};

pub fn debugAssert(ok: bool) void {
    if (Environment.isDebug and !ok) {
        @panic("assertion failed");
    }
}

pub fn assert(ok: bool) void {
    if (!ok) {
        @panic("assertion failed");
    }
}

pub fn todo(comptime msg: []const u8) noreturn {
    @panic("TODO: " ++ msg);
}

pub const OOM = error{OutOfMemory};

// Formatting utilities
pub fn fmt(comptime format: []const u8, args: anytype) std.fmt.AllocPrint {
    return std.fmt.allocPrint(default_allocator, format, args) catch @panic("OOM");
}

// Slice utilities
pub fn sliceTo(comptime T: type, slice: []const T, terminator: T) []const T {
    for (slice, 0..) |c, i| {
        if (c == terminator) return slice[0..i];
    }
    return slice;
}

// Type aliases for compatibility
pub const string = []const u8;

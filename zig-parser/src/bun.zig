// Bun compatibility layer for the parser
// Provides the subset of Bun's internal APIs needed by the lexer/parser

const std = @import("std");
const builtin = @import("builtin");

// Re-export standard library types
pub const Allocator = std.mem.Allocator;

// Environment detection
pub const Environment = struct {
    pub const isDebug = builtin.mode == .Debug;
    pub const isRelease = !isDebug;
    pub const enable_asan = false;
    pub const isWindows = builtin.os.tag == .windows;
    pub const isLinux = builtin.os.tag == .linux;
    pub const isMac = builtin.os.tag == .macos;
    pub const allow_assert = isDebug;
};

// Allocators
pub const default_allocator = std.heap.c_allocator;

// Unicode code point type
pub const CodePoint = u21;

// Assertions
pub inline fn assert(ok: bool) void {
    if (!ok) unreachable;
}

pub inline fn debugAssert(ok: bool) void {
    if (Environment.isDebug and !ok) unreachable;
}

pub inline fn assertWithLocation(ok: bool, src: std.builtin.SourceLocation) void {
    _ = src;
    if (!ok) unreachable;
}

// Bit set
pub const bit_set = struct {
    pub fn IntegerBitSet(comptime size: usize) type {
        return std.bit_set.IntegerBitSet(size);
    }
};

// Output/panic
pub const Output = struct {
    pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
        std.debug.panic(fmt, args);
    }
};

// Mutable string buffer
pub const MutableString = struct {
    list: std.ArrayList(u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator, initial_size: usize) !MutableString {
        var list = std.ArrayList(u8).init(allocator);
        if (initial_size > 0) {
            try list.ensureTotalCapacity(initial_size);
        }
        return .{ .list = list, .allocator = allocator };
    }

    pub fn initCopy(allocator: Allocator, slice: []const u8) !MutableString {
        var self = try init(allocator, slice.len);
        try self.list.appendSlice(slice);
        return self;
    }

    pub fn deinit(self: *MutableString) void {
        self.list.deinit();
    }

    pub fn append(self: *MutableString, char: u8) !void {
        try self.list.append(char);
    }

    pub fn appendSlice(self: *MutableString, slice: []const u8) !void {
        try self.list.appendSlice(slice);
    }

    pub fn toOwnedSlice(self: *MutableString) ![]u8 {
        return self.list.toOwnedSlice();
    }

    pub fn items(self: *const MutableString) []const u8 {
        return self.list.items;
    }

    pub fn len(self: *const MutableString) usize {
        return self.list.items.len;
    }
};

// Handle OOM by returning the error
pub fn handleOom(result: anytype) @TypeOf(result) {
    return result;
}

// Number parsing
pub fn parseDouble(text: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, text) catch null;
}

// String utilities
pub const strings = struct {
    pub const ascii_vector_size = 16;
    pub const CodePoint = u21;
    pub const unicode_replacement: CodePoint = 0xFFFD;
    pub const AsciiVector = @Vector(ascii_vector_size, u8);
    pub const AsciiVectorU1 = @Vector(ascii_vector_size, u1);
    pub const max_16_ascii: AsciiVector = @splat(127);

    pub fn eql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    pub fn eqlComptime(a: []const u8, comptime b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    pub fn startsWith(haystack: []const u8, needle: []const u8) bool {
        return std.mem.startsWith(u8, haystack, needle);
    }

    pub fn hasPrefixComptime(haystack: []const u8, comptime needle: []const u8) bool {
        return std.mem.startsWith(u8, haystack, needle);
    }

    pub fn hasPrefixWithWordBoundary(haystack: []const u8, needle: []const u8) bool {
        if (!std.mem.startsWith(u8, haystack, needle)) return false;
        if (haystack.len == needle.len) return true;
        const next = haystack[needle.len];
        return !isIdentifierPart(next);
    }

    pub fn indexOfChar(haystack: []const u8, needle: u8) ?usize {
        return std.mem.indexOfScalar(u8, haystack, needle);
    }

    pub fn indexOfAny(haystack: []const u8, needles: []const u8) ?usize {
        for (haystack, 0..) |c, i| {
            for (needles) |n| {
                if (c == n) return i;
            }
        }
        return null;
    }

    pub fn indexOfSpaceOrNewlineOrNonASCII(text: []const u8, start: usize) ?usize {
        var i = start;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (c == ' ' or c == '\n' or c == '\r' or c == '\t' or c > 127) {
                return i;
            }
        }
        return null;
    }

    pub fn firstNonASCII16(text: []const u16) ?usize {
        for (text, 0..) |c, i| {
            if (c > 127) return i;
        }
        return null;
    }

    pub fn copyU16IntoU8(dest: []u8, src: []const u16) void {
        for (src, 0..) |c, i| {
            if (i >= dest.len) break;
            dest[i] = if (c <= 255) @intCast(c) else '?';
        }
    }

    pub fn toUTF8AllocWithType(allocator: Allocator, js: []const u16) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        for (js) |c| {
            if (c < 0x80) {
                try result.append(@intCast(c));
            } else if (c < 0x800) {
                try result.append(@intCast(0xC0 | (c >> 6)));
                try result.append(@intCast(0x80 | (c & 0x3F)));
            } else {
                try result.append(@intCast(0xE0 | (c >> 12)));
                try result.append(@intCast(0x80 | ((c >> 6) & 0x3F)));
                try result.append(@intCast(0x80 | (c & 0x3F)));
            }
        }
        return result.toOwnedSlice();
    }

    pub fn isIdentifierStart(c: u21) bool {
        if (c < 128) {
            return switch (@as(u8, @intCast(c))) {
                'a'...'z', 'A'...'Z', '_', '$' => true,
                else => false,
            };
        }
        return false;
    }

    pub fn isIdentifierPart(c: u21) bool {
        if (c < 128) {
            return switch (@as(u8, @intCast(c))) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '$' => true,
                else => false,
            };
        }
        return false;
    }

    pub fn isWhitespace(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\n', '\r', 0x0B, 0x0C => true,
            else => false,
        };
    }

    pub fn isNewline(c: u8) bool {
        return c == '\n' or c == '\r';
    }

    pub fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    pub fn isHexDigit(c: u8) bool {
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    pub fn hexToInt(c: u8) u8 {
        if (c >= '0' and c <= '9') return c - '0';
        if (c >= 'a' and c <= 'f') return c - 'a' + 10;
        if (c >= 'A' and c <= 'F') return c - 'A' + 10;
        return 0;
    }

    // WTF-8 decoding
    pub fn wtf8ByteSequenceLengthWithInvalid(first_byte: u8) u3 {
        if (first_byte < 0x80) return 1;
        if (first_byte < 0xC0) return 1; // Invalid continuation byte
        if (first_byte < 0xE0) return 2;
        if (first_byte < 0xF0) return 3;
        if (first_byte < 0xF8) return 4;
        return 1; // Invalid
    }

    pub fn decodeWTF8RuneTMultibyte(bytes: *const [4]u8, len: u3, comptime T: type, replacement: T) T {
        _ = replacement;
        return switch (len) {
            2 => @as(T, @intCast(((@as(u21, bytes[0]) & 0x1F) << 6) | (@as(u21, bytes[1]) & 0x3F))),
            3 => @as(T, @intCast(((@as(u21, bytes[0]) & 0x0F) << 12) | ((@as(u21, bytes[1]) & 0x3F) << 6) | (@as(u21, bytes[2]) & 0x3F))),
            4 => @as(T, @intCast(((@as(u21, bytes[0]) & 0x07) << 18) | ((@as(u21, bytes[1]) & 0x3F) << 12) | ((@as(u21, bytes[2]) & 0x3F) << 6) | (@as(u21, bytes[3]) & 0x3F))),
            else => @as(T, bytes[0]),
        };
    }

    // Codepoint iterator for UTF-8/WTF-8 strings
    pub const CodepointIterator = struct {
        bytes: []const u8,
        i: usize,

        pub fn init(bytes: []const u8) CodepointIterator {
            return .{ .bytes = bytes, .i = 0 };
        }

        pub fn next(self: *CodepointIterator, cursor: *Cursor) bool {
            if (self.i >= self.bytes.len) return false;
            const first = self.bytes[self.i];
            const len = wtf8ByteSequenceLengthWithInvalid(first);
            cursor.i = self.i;
            cursor.width = len;
            if (self.i + len > self.bytes.len) {
                cursor.c = unicode_replacement;
                self.i = self.bytes.len;
                return true;
            }
            if (len == 1) {
                cursor.c = first;
            } else {
                var buf: [4]u8 = undefined;
                for (0..len) |j| {
                    buf[j] = self.bytes[self.i + j];
                }
                cursor.c = decodeWTF8RuneTMultibyte(&buf, len, CodePoint, unicode_replacement);
            }
            self.i += len;
            return true;
        }

        pub const Cursor = struct {
            c: CodePoint = 0,
            i: usize = 0,
            width: u3 = 0,
        };
    };
};

// Highway SIMD utilities (fallback to scalar)
pub const highway = struct {
    pub fn indexOfNewlineOrNonASCIIOrHashOrAt(text: []const u8) ?usize {
        for (text, 0..) |c, i| {
            if (c == '\n' or c == '\r' or c == '#' or c == '@' or c > 127) {
                return i;
            }
        }
        return null;
    }

    pub fn indexOfInterestingCharacterInStringLiteral(text: []const u8, quote: u8) ?usize {
        for (text, 0..) |c, i| {
            if (c == quote or c == '\\' or c == '\n' or c == '\r') {
                return i;
            }
        }
        return null;
    }
};

// Logger types
pub const logger = struct {
    pub const Loc = struct {
        start: i32 = 0,

        pub const Empty = Loc{ .start = -1 };

        pub fn toUsize(self: Loc) ?usize {
            if (self.start < 0) return null;
            return @intCast(self.start);
        }
    };

    pub const Range = struct {
        loc: Loc = .{},
        len: u32 = 0,
    };

    pub const Source = struct {
        contents: []const u8,
        path: []const u8 = "",

        pub fn initPathString(path: []const u8, contents: []const u8) Source {
            return .{ .contents = contents, .path = path };
        }
    };

    pub const Log = struct {
        errors: std.ArrayList(Msg),
        warnings: std.ArrayList(Msg),
        allocator: Allocator,

        pub fn init(allocator: Allocator) Log {
            return .{
                .errors = std.ArrayList(Msg).init(allocator),
                .warnings = std.ArrayList(Msg).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Log) void {
            self.errors.deinit();
            self.warnings.deinit();
        }

        pub fn addError(self: *Log, source: *const Source, loc: Loc, msg: []const u8) !void {
            _ = source;
            _ = loc;
            try self.errors.append(.{ .text = msg });
        }

        pub fn addWarning(self: *Log, source: *const Source, loc: Loc, msg: []const u8) !void {
            _ = source;
            _ = loc;
            try self.warnings.append(.{ .text = msg });
        }

        pub fn hasErrors(self: *const Log) bool {
            return self.errors.items.len > 0;
        }
    };

    pub const Msg = struct {
        text: []const u8,
    };
};

// AST types (forward declarations - will be in separate file)
pub const ast = struct {
    pub const Span = struct {
        text: []const u8 = "",
        loc: logger.Loc = .{},

        pub fn isEmpty(self: Span) bool {
            return self.text.len == 0;
        }
    };
};

// JS Printer types
pub const js_printer = struct {
    pub const Options = struct {
        pub const Indentation = struct {
            count: u32 = 0,
            char: u8 = ' ',
        };
    };
};

// Comptime string map (use std.StaticStringMap)
pub fn ComptimeStringMap(comptime V: type, comptime kvs: anytype) type {
    return std.StaticStringMap(V).initComptime(kvs);
}

// Feature flags
pub const FeatureFlags = struct {
    pub const is_macro_enabled = false;
};

test "bun compat - MutableString" {
    var ms = try MutableString.init(std.testing.allocator, 0);
    defer ms.deinit();

    try ms.appendSlice("hello");
    try std.testing.expectEqualStrings("hello", ms.items());
}

test "bun compat - strings" {
    try std.testing.expect(strings.isIdentifierStart('a'));
    try std.testing.expect(strings.isIdentifierStart('_'));
    try std.testing.expect(!strings.isIdentifierStart('0'));
    try std.testing.expect(strings.isIdentifierPart('0'));
}

test "bun compat - parseDouble" {
    try std.testing.expectEqual(@as(f64, 42.0), parseDouble("42").?);
    try std.testing.expectEqual(@as(f64, 3.14), parseDouble("3.14").?);
    try std.testing.expect(parseDouble("not a number") == null);
}

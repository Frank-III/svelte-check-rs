// CSS Parser
// Parses CSS stylesheets and extracts selectors, properties, and at-rules

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");

const Loc = ast.Loc;

/// CSS Stylesheet
pub const Stylesheet = struct {
    rules: []Rule,
    errors: []Error,
};

/// CSS Rule
pub const Rule = union(enum) {
    style_rule: *StyleRule,
    at_rule: *AtRule,
};

/// Style rule with selector and declarations
pub const StyleRule = struct {
    selectors: []Selector,
    declarations: []Declaration,
    loc: Loc,
};

/// Selector (e.g., ".class", "#id", "div")
pub const Selector = struct {
    text: []const u8,
    parts: []SelectorPart,
    loc: Loc,
};

/// Part of a selector
pub const SelectorPart = struct {
    kind: Kind,
    name: []const u8,
    loc: Loc,

    pub const Kind = enum {
        element, // div, span, etc.
        class, // .class
        id, // #id
        pseudo_class, // :hover, :focus
        pseudo_element, // ::before, ::after
        attribute, // [attr], [attr=value]
        universal, // *
        combinator, // >, +, ~, space
    };
};

/// CSS Declaration (property: value)
pub const Declaration = struct {
    property: []const u8,
    value: []const u8,
    important: bool,
    loc: Loc,
};

/// At-rule (@media, @keyframes, etc.)
pub const AtRule = struct {
    name: []const u8,
    prelude: []const u8,
    block: ?[]Rule,
    loc: Loc,
};

pub const Error = struct {
    message: []const u8,
    loc: Loc,
};

/// CSS Parser
pub const CssParser = struct {
    source: []const u8,
    index: usize,
    allocator: Allocator,
    errors: std.ArrayList(Error),

    pub fn init(allocator: Allocator, source: []const u8) CssParser {
        return .{
            .source = source,
            .index = 0,
            .allocator = allocator,
            .errors = std.ArrayList(Error).init(allocator),
        };
    }

    pub fn deinit(self: *CssParser) void {
        self.errors.deinit();
    }

    fn create(self: *CssParser, comptime T: type, value: T) *T {
        const ptr = self.allocator.create(T) catch @panic("OOM");
        ptr.* = value;
        return ptr;
    }

    fn alloc(self: *CssParser, comptime T: type, n: usize) []T {
        return self.allocator.alloc(T, n) catch @panic("OOM");
    }

    fn loc(self: *CssParser, start: usize) Loc {
        return .{
            .start = @intCast(start),
            .end = @intCast(self.index),
        };
    }

    fn remaining(self: *CssParser) []const u8 {
        return if (self.index < self.source.len) self.source[self.index..] else "";
    }

    fn peek(self: *CssParser) ?u8 {
        return if (self.index < self.source.len) self.source[self.index] else null;
    }

    fn advance(self: *CssParser) void {
        if (self.index < self.source.len) self.index += 1;
    }

    fn advanceBy(self: *CssParser, n: usize) void {
        self.index = @min(self.index + n, self.source.len);
    }

    fn startsWith(self: *CssParser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.remaining(), prefix);
    }

    fn skipWhitespace(self: *CssParser) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.advance();
            } else if (c == '/' and self.index + 1 < self.source.len and self.source[self.index + 1] == '*') {
                // Skip comment
                self.advanceBy(2);
                while (self.index + 1 < self.source.len) {
                    if (self.source[self.index] == '*' and self.source[self.index + 1] == '/') {
                        self.advanceBy(2);
                        break;
                    }
                    self.advance();
                }
            } else {
                break;
            }
        }
    }

    fn addError(self: *CssParser, message: []const u8, location: Loc) void {
        self.errors.append(.{ .message = message, .loc = location }) catch {};
    }

    /// Parse a complete stylesheet
    pub fn parse(self: *CssParser) Stylesheet {
        var rules = std.ArrayList(Rule).init(self.allocator);

        while (self.index < self.source.len) {
            self.skipWhitespace();
            if (self.index >= self.source.len) break;

            if (self.peek() == '@') {
                if (self.parseAtRule()) |at_rule| {
                    rules.append(.{ .at_rule = at_rule }) catch {};
                }
            } else {
                if (self.parseStyleRule()) |style_rule| {
                    rules.append(.{ .style_rule = style_rule }) catch {};
                }
            }
        }

        return .{
            .rules = rules.toOwnedSlice() catch &[_]Rule{},
            .errors = self.errors.toOwnedSlice() catch &[_]Error{},
        };
    }

    fn parseAtRule(self: *CssParser) ?*AtRule {
        const start = self.index;
        self.advance(); // Skip @

        // Parse at-rule name
        const name_start = self.index;
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '{' or c == ';') break;
            self.advance();
        }
        const name = self.source[name_start..self.index];

        self.skipWhitespace();

        // Parse prelude
        const prelude_start = self.index;
        var brace_depth: u32 = 0;
        while (self.peek()) |c| {
            if (c == '{') {
                if (brace_depth == 0) break;
                brace_depth += 1;
            } else if (c == '}') {
                if (brace_depth > 0) brace_depth -= 1;
            } else if (c == ';' and brace_depth == 0) {
                break;
            }
            self.advance();
        }
        const prelude = std.mem.trim(u8, self.source[prelude_start..self.index], " \t\n\r");

        // Parse block or semicolon
        var block: ?[]Rule = null;
        if (self.peek() == '{') {
            self.advance();
            var nested_rules = std.ArrayList(Rule).init(self.allocator);

            while (self.index < self.source.len) {
                self.skipWhitespace();
                if (self.peek() == '}') {
                    self.advance();
                    break;
                }
                if (self.peek() == '@') {
                    if (self.parseAtRule()) |at_rule| {
                        nested_rules.append(.{ .at_rule = at_rule }) catch {};
                    }
                } else {
                    if (self.parseStyleRule()) |style_rule| {
                        nested_rules.append(.{ .style_rule = style_rule }) catch {};
                    }
                }
            }
            block = nested_rules.toOwnedSlice() catch null;
        } else if (self.peek() == ';') {
            self.advance();
        }

        return self.create(AtRule, .{
            .name = name,
            .prelude = prelude,
            .block = block,
            .loc = self.loc(start),
        });
    }

    fn parseStyleRule(self: *CssParser) ?*StyleRule {
        const start = self.index;

        // Parse selectors
        var selectors = std.ArrayList(Selector).init(self.allocator);
        while (self.index < self.source.len) {
            self.skipWhitespace();
            if (self.peek() == '{') break;

            const sel = self.parseSelector();
            selectors.append(sel) catch {};

            self.skipWhitespace();
            if (self.peek() == ',') {
                self.advance();
            } else {
                break;
            }
        }

        if (selectors.items.len == 0) {
            // Skip to next rule
            while (self.peek()) |c| {
                if (c == '}') {
                    self.advance();
                    break;
                }
                self.advance();
            }
            return null;
        }

        // Parse declaration block
        var declarations = std.ArrayList(Declaration).init(self.allocator);
        if (self.peek() == '{') {
            self.advance();

            while (self.index < self.source.len) {
                self.skipWhitespace();
                if (self.peek() == '}') {
                    self.advance();
                    break;
                }

                if (self.parseDeclaration()) |decl| {
                    declarations.append(decl) catch {};
                }
            }
        }

        return self.create(StyleRule, .{
            .selectors = selectors.toOwnedSlice() catch &[_]Selector{},
            .declarations = declarations.toOwnedSlice() catch &[_]Declaration{},
            .loc = self.loc(start),
        });
    }

    fn parseSelector(self: *CssParser) Selector {
        const start = self.index;
        var parts = std.ArrayList(SelectorPart).init(self.allocator);

        while (self.index < self.source.len) {
            self.skipWhitespace();
            const c = self.peek() orelse break;
            if (c == ',' or c == '{') break;

            const part_start = self.index;

            if (c == '.') {
                // Class selector
                self.advance();
                const name = self.parseIdent();
                parts.append(.{
                    .kind = .class,
                    .name = name,
                    .loc = self.loc(part_start),
                }) catch {};
            } else if (c == '#') {
                // ID selector
                self.advance();
                const name = self.parseIdent();
                parts.append(.{
                    .kind = .id,
                    .name = name,
                    .loc = self.loc(part_start),
                }) catch {};
            } else if (c == ':') {
                self.advance();
                if (self.peek() == ':') {
                    // Pseudo-element
                    self.advance();
                    const name = self.parseIdent();
                    parts.append(.{
                        .kind = .pseudo_element,
                        .name = name,
                        .loc = self.loc(part_start),
                    }) catch {};
                } else {
                    // Pseudo-class
                    const name = self.parseIdent();
                    // Handle function-like pseudo-classes
                    if (self.peek() == '(') {
                        self.advance();
                        var depth: u32 = 1;
                        while (self.peek()) |ch| {
                            if (ch == '(') depth += 1;
                            if (ch == ')') {
                                depth -= 1;
                                if (depth == 0) {
                                    self.advance();
                                    break;
                                }
                            }
                            self.advance();
                        }
                    }
                    parts.append(.{
                        .kind = .pseudo_class,
                        .name = name,
                        .loc = self.loc(part_start),
                    }) catch {};
                }
            } else if (c == '[') {
                // Attribute selector
                self.advance();
                const attr_start = self.index;
                while (self.peek()) |ch| {
                    if (ch == ']') {
                        self.advance();
                        break;
                    }
                    self.advance();
                }
                parts.append(.{
                    .kind = .attribute,
                    .name = self.source[attr_start .. self.index - 1],
                    .loc = self.loc(part_start),
                }) catch {};
            } else if (c == '*') {
                // Universal selector
                self.advance();
                parts.append(.{
                    .kind = .universal,
                    .name = "*",
                    .loc = self.loc(part_start),
                }) catch {};
            } else if (c == '>' or c == '+' or c == '~') {
                // Combinator
                self.advance();
                parts.append(.{
                    .kind = .combinator,
                    .name = self.source[part_start..self.index],
                    .loc = self.loc(part_start),
                }) catch {};
            } else if (isIdentStart(c)) {
                // Element selector
                const name = self.parseIdent();
                parts.append(.{
                    .kind = .element,
                    .name = name,
                    .loc = self.loc(part_start),
                }) catch {};
            } else {
                self.advance();
            }
        }

        return .{
            .text = std.mem.trim(u8, self.source[start..self.index], " \t\n\r"),
            .parts = parts.toOwnedSlice() catch &[_]SelectorPart{},
            .loc = self.loc(start),
        };
    }

    fn parseIdent(self: *CssParser) []const u8 {
        const start = self.index;
        while (self.peek()) |c| {
            if (isIdentChar(c)) {
                self.advance();
            } else {
                break;
            }
        }
        return self.source[start..self.index];
    }

    fn parseDeclaration(self: *CssParser) ?Declaration {
        const start = self.index;

        // Parse property name
        const prop_start = self.index;
        while (self.peek()) |c| {
            if (c == ':' or c == ';' or c == '}') break;
            self.advance();
        }
        const property = std.mem.trim(u8, self.source[prop_start..self.index], " \t\n\r");

        if (property.len == 0 or self.peek() != ':') {
            // Invalid declaration, skip to ; or }
            while (self.peek()) |c| {
                if (c == ';') {
                    self.advance();
                    break;
                }
                if (c == '}') break;
                self.advance();
            }
            return null;
        }

        self.advance(); // Skip :
        self.skipWhitespace();

        // Parse value
        const val_start = self.index;
        var important = false;
        while (self.peek()) |c| {
            if (c == ';' or c == '}') break;
            if (c == '!' and self.startsWith("!important")) {
                important = true;
                self.advanceBy(10);
                break;
            }
            self.advance();
        }
        const value = std.mem.trim(u8, self.source[val_start..self.index], " \t\n\r");

        if (self.peek() == ';') {
            self.advance();
        }

        return .{
            .property = property,
            .value = value,
            .important = important,
            .loc = self.loc(start),
        };
    }
};

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '-' or c > 127;
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// Extract all class names from selectors
pub fn extractClasses(allocator: Allocator, stylesheet: *const Stylesheet) [][]const u8 {
    var classes = std.ArrayList([]const u8).init(allocator);

    for (stylesheet.rules) |rule| {
        switch (rule) {
            .style_rule => |style| {
                for (style.selectors) |sel| {
                    for (sel.parts) |part| {
                        if (part.kind == .class) {
                            classes.append(part.name) catch {};
                        }
                    }
                }
            },
            .at_rule => |at| {
                if (at.block) |block| {
                    for (block) |r| {
                        switch (r) {
                            .style_rule => |style| {
                                for (style.selectors) |sel| {
                                    for (sel.parts) |part| {
                                        if (part.kind == .class) {
                                            classes.append(part.name) catch {};
                                        }
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                }
            },
        }
    }

    return classes.toOwnedSlice() catch &[_][]const u8{};
}

/// Extract all IDs from selectors
pub fn extractIds(allocator: Allocator, stylesheet: *const Stylesheet) [][]const u8 {
    var ids = std.ArrayList([]const u8).init(allocator);

    for (stylesheet.rules) |rule| {
        switch (rule) {
            .style_rule => |style| {
                for (style.selectors) |sel| {
                    for (sel.parts) |part| {
                        if (part.kind == .id) {
                            ids.append(part.name) catch {};
                        }
                    }
                }
            },
            .at_rule => |at| {
                if (at.block) |block| {
                    for (block) |r| {
                        switch (r) {
                            .style_rule => |style| {
                                for (style.selectors) |sel| {
                                    for (sel.parts) |part| {
                                        if (part.kind == .id) {
                                            ids.append(part.name) catch {};
                                        }
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                }
            },
        }
    }

    return ids.toOwnedSlice() catch &[_][]const u8{};
}

// Tests
test "css parser - basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = CssParser.init(arena.allocator(),
        \\.container {
        \\    color: red;
        \\    background: blue;
        \\}
    );
    const stylesheet = parser.parse();

    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
}

test "css parser - selectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = CssParser.init(arena.allocator(),
        \\.class { color: red; }
        \\#id { color: blue; }
        \\div { color: green; }
        \\div.foo#bar { color: yellow; }
    );
    const stylesheet = parser.parse();

    try std.testing.expectEqual(@as(usize, 4), stylesheet.rules.len);
}

test "css parser - at-rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = CssParser.init(arena.allocator(),
        \\@media (min-width: 768px) {
        \\    .container {
        \\        width: 100%;
        \\    }
        \\}
    );
    const stylesheet = parser.parse();

    try std.testing.expectEqual(@as(usize, 1), stylesheet.rules.len);
    try std.testing.expect(stylesheet.rules[0] == .at_rule);
}

test "css parser - extract classes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = CssParser.init(arena.allocator(),
        \\.foo { color: red; }
        \\.bar { color: blue; }
        \\.foo.baz { color: green; }
    );
    const stylesheet = parser.parse();
    const classes = extractClasses(arena.allocator(), &stylesheet);

    try std.testing.expectEqual(@as(usize, 4), classes.len);
}

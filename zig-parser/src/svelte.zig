// Svelte Template Parser
// Parses .svelte files into a structured AST

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");

const Parser = parser_mod.Parser;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Loc = ast.Loc;

/// Svelte file structure
pub const SvelteFile = struct {
    /// Module context script (<script context="module">)
    module_script: ?Script,
    /// Instance script (<script>)
    instance_script: ?Script,
    /// Style blocks
    styles: []Style,
    /// Template fragment
    template: Fragment,
    /// Parse errors
    errors: []Error,
};

pub const Script = struct {
    loc: Loc,
    content: []const u8,
    lang: Lang,
    context: Context,
    /// Parsed statements (if parsing succeeded)
    stmts: []Stmt,

    pub const Lang = enum { javascript, typescript };
    pub const Context = enum { default, module };
};

pub const Style = struct {
    loc: Loc,
    content: []const u8,
    lang: Lang,

    pub const Lang = enum { css, scss, less };
};

pub const Error = struct {
    message: []const u8,
    loc: Loc,
};

/// Template fragment (list of nodes)
pub const Fragment = struct {
    nodes: []Node,
    loc: Loc,
};

/// Template node types
pub const Node = union(enum) {
    text: Text,
    element: *Element,
    component: *Component,
    expression: *ExpressionTag,
    if_block: *IfBlock,
    each_block: *EachBlock,
    await_block: *AwaitBlock,
    key_block: *KeyBlock,
    snippet_block: *SnippetBlock,
    html_tag: *HtmlTag,
    debug_tag: *DebugTag,
    const_tag: *ConstTag,
    render_tag: *RenderTag,
    comment: Comment,
};

pub const Text = struct {
    content: []const u8,
    loc: Loc,
};

pub const Comment = struct {
    content: []const u8,
    loc: Loc,
};

pub const Element = struct {
    name: []const u8,
    attributes: []Attribute,
    children: Fragment,
    self_closing: bool,
    loc: Loc,
};

pub const Component = struct {
    name: []const u8,
    attributes: []Attribute,
    children: Fragment,
    self_closing: bool,
    loc: Loc,
};

pub const Attribute = struct {
    name: []const u8,
    value: ?AttributeValue,
    loc: Loc,
    kind: Kind,

    pub const Kind = enum {
        normal,
        shorthand, // {foo} as attribute
        spread, // {...props}
        directive, // bind:, on:, class:, style:, use:, transition:, animate:, in:, out:
    };
};

pub const AttributeValue = union(enum) {
    text: []const u8,
    expression: Expr,
    quoted: []const u8,
};

pub const ExpressionTag = struct {
    expression: Expr,
    loc: Loc,
};

pub const IfBlock = struct {
    condition: Expr,
    consequent: Fragment,
    alternate: ?Alternate,
    loc: Loc,

    pub const Alternate = union(enum) {
        else_if: *IfBlock,
        else_block: Fragment,
    };
};

pub const EachBlock = struct {
    expression: Expr,
    item: []const u8,
    index: ?[]const u8,
    key: ?Expr,
    body: Fragment,
    else_body: ?Fragment,
    loc: Loc,
};

pub const AwaitBlock = struct {
    expression: Expr,
    pending: ?Fragment,
    then_binding: ?[]const u8,
    then_body: ?Fragment,
    catch_binding: ?[]const u8,
    catch_body: ?Fragment,
    loc: Loc,
};

pub const KeyBlock = struct {
    expression: Expr,
    body: Fragment,
    loc: Loc,
};

pub const SnippetBlock = struct {
    name: []const u8,
    params: [][]const u8,
    body: Fragment,
    loc: Loc,
};

pub const HtmlTag = struct {
    expression: Expr,
    loc: Loc,
};

pub const DebugTag = struct {
    identifiers: [][]const u8,
    loc: Loc,
};

pub const ConstTag = struct {
    binding: []const u8,
    expression: Expr,
    loc: Loc,
};

pub const RenderTag = struct {
    expression: Expr,
    loc: Loc,
};

/// Svelte file parser
pub const SvelteParser = struct {
    source: []const u8,
    index: usize,
    allocator: Allocator,
    errors: std.ArrayList(Error),

    pub fn init(allocator: Allocator, source: []const u8) SvelteParser {
        return .{
            .source = source,
            .index = 0,
            .allocator = allocator,
            .errors = std.ArrayList(Error).init(allocator),
        };
    }

    pub fn deinit(self: *SvelteParser) void {
        self.errors.deinit();
    }

    fn create(self: *SvelteParser, comptime T: type, value: T) *T {
        const ptr = self.allocator.create(T) catch @panic("OOM");
        ptr.* = value;
        return ptr;
    }

    fn alloc(self: *SvelteParser, comptime T: type, n: usize) []T {
        return self.allocator.alloc(T, n) catch @panic("OOM");
    }

    fn loc(self: *SvelteParser, start: usize) Loc {
        return .{
            .start = @intCast(start),
            .end = @intCast(self.index),
        };
    }

    fn remaining(self: *SvelteParser) []const u8 {
        return if (self.index < self.source.len) self.source[self.index..] else "";
    }

    fn peek(self: *SvelteParser) ?u8 {
        return if (self.index < self.source.len) self.source[self.index] else null;
    }

    fn peekAhead(self: *SvelteParser, offset: usize) ?u8 {
        const idx = self.index + offset;
        return if (idx < self.source.len) self.source[idx] else null;
    }

    fn advance(self: *SvelteParser) void {
        if (self.index < self.source.len) self.index += 1;
    }

    fn advanceBy(self: *SvelteParser, n: usize) void {
        self.index = @min(self.index + n, self.source.len);
    }

    fn startsWith(self: *SvelteParser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.remaining(), prefix);
    }

    fn skipWhitespace(self: *SvelteParser) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn addError(self: *SvelteParser, message: []const u8, location: Loc) void {
        self.errors.append(.{ .message = message, .loc = location }) catch {};
    }

    /// Parse a complete Svelte file
    pub fn parse(self: *SvelteParser) SvelteFile {
        var module_script: ?Script = null;
        var instance_script: ?Script = null;
        var styles = std.ArrayList(Style).init(self.allocator);
        var template_nodes = std.ArrayList(Node).init(self.allocator);

        while (self.index < self.source.len) {
            self.skipWhitespace();
            if (self.index >= self.source.len) break;

            if (self.startsWith("<script")) {
                const script = self.parseScript();
                if (script.context == .module) {
                    module_script = script;
                } else {
                    instance_script = script;
                }
            } else if (self.startsWith("<style")) {
                styles.append(self.parseStyle()) catch {};
            } else if (self.startsWith("<!--")) {
                template_nodes.append(.{ .comment = self.parseComment() }) catch {};
            } else if (self.peek() == '<') {
                if (self.peekAhead(1)) |c| {
                    if (c >= 'A' and c <= 'Z') {
                        // Component
                        template_nodes.append(.{ .component = self.parseComponent() }) catch {};
                    } else if (c >= 'a' and c <= 'z') {
                        // Element
                        template_nodes.append(.{ .element = self.parseElement() }) catch {};
                    } else {
                        self.advance();
                    }
                } else {
                    self.advance();
                }
            } else if (self.startsWith("{#")) {
                template_nodes.append(self.parseBlockTag()) catch {};
            } else if (self.startsWith("{@")) {
                template_nodes.append(self.parseSpecialTag()) catch {};
            } else if (self.peek() == '{') {
                template_nodes.append(.{ .expression = self.parseExpressionTag() }) catch {};
            } else {
                // Text content
                template_nodes.append(.{ .text = self.parseText() }) catch {};
            }
        }

        return .{
            .module_script = module_script,
            .instance_script = instance_script,
            .styles = styles.toOwnedSlice() catch &[_]Style{},
            .template = .{
                .nodes = template_nodes.toOwnedSlice() catch &[_]Node{},
                .loc = .{ .start = 0, .end = @intCast(self.source.len) },
            },
            .errors = self.errors.toOwnedSlice() catch &[_]Error{},
        };
    }

    fn parseScript(self: *SvelteParser) Script {
        const start = self.index;
        self.advanceBy(7); // Skip "<script"

        var lang: Script.Lang = .javascript;
        var context: Script.Context = .default;

        // Parse attributes
        while (self.peek()) |c| {
            if (c == '>') break;
            self.skipWhitespace();

            if (self.startsWith("lang=")) {
                self.advanceBy(5);
                if (self.startsWith("\"ts\"") or self.startsWith("'ts'") or
                    self.startsWith("\"typescript\"") or self.startsWith("'typescript'"))
                {
                    lang = .typescript;
                }
                while (self.peek()) |ch| {
                    if (ch == '"' or ch == '\'') {
                        self.advance();
                        break;
                    }
                    self.advance();
                }
                while (self.peek()) |ch| {
                    if (ch == '"' or ch == '\'' or ch == ' ' or ch == '>') break;
                    self.advance();
                }
                if (self.peek() == '"' or self.peek() == '\'') self.advance();
            } else if (self.startsWith("context=")) {
                self.advanceBy(8);
                if (self.startsWith("\"module\"") or self.startsWith("'module'")) {
                    context = .module;
                }
                while (self.peek()) |ch| {
                    if (ch == '"' or ch == '\'') {
                        self.advance();
                        break;
                    }
                    self.advance();
                }
                while (self.peek()) |ch| {
                    if (ch == '"' or ch == '\'' or ch == ' ' or ch == '>') break;
                    self.advance();
                }
                if (self.peek() == '"' or self.peek() == '\'') self.advance();
            } else if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != '>') {
                self.advance();
            }
        }

        _ = self.expect('>');

        // Find script content
        const content_start = self.index;
        while (self.index < self.source.len) {
            if (self.startsWith("</script>")) break;
            self.advance();
        }
        const content = self.source[content_start..self.index];

        // Skip closing tag
        if (self.startsWith("</script>")) {
            self.advanceBy(9);
        }

        // Parse the script content
        var js_parser = Parser.init(self.allocator, content);
        const program = js_parser.parseProgram();

        return .{
            .loc = self.loc(start),
            .content = content,
            .lang = lang,
            .context = context,
            .stmts = program.stmts,
        };
    }

    fn parseStyle(self: *SvelteParser) Style {
        const start = self.index;
        self.advanceBy(6); // Skip "<style"

        var lang: Style.Lang = .css;

        // Parse attributes
        while (self.peek()) |c| {
            if (c == '>') break;
            self.skipWhitespace();

            if (self.startsWith("lang=")) {
                self.advanceBy(5);
                if (self.startsWith("\"scss\"") or self.startsWith("'scss'")) {
                    lang = .scss;
                } else if (self.startsWith("\"less\"") or self.startsWith("'less'")) {
                    lang = .less;
                }
                while (self.peek()) |ch| {
                    if (ch == '"' or ch == '\'' or ch == ' ' or ch == '>') break;
                    self.advance();
                }
                if (self.peek() == '"' or self.peek() == '\'') self.advance();
            } else if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != '>') {
                self.advance();
            }
        }

        _ = self.expect('>');

        // Find style content
        const content_start = self.index;
        while (self.index < self.source.len) {
            if (self.startsWith("</style>")) break;
            self.advance();
        }
        const content = self.source[content_start..self.index];

        // Skip closing tag
        if (self.startsWith("</style>")) {
            self.advanceBy(8);
        }

        return .{
            .loc = self.loc(start),
            .content = content,
            .lang = lang,
        };
    }

    fn parseComment(self: *SvelteParser) Comment {
        const start = self.index;
        self.advanceBy(4); // Skip "<!--"

        const content_start = self.index;
        while (self.index < self.source.len) {
            if (self.startsWith("-->")) break;
            self.advance();
        }
        const content = self.source[content_start..self.index];

        if (self.startsWith("-->")) {
            self.advanceBy(3);
        }

        return .{ .content = content, .loc = self.loc(start) };
    }

    fn parseElement(self: *SvelteParser) *Element {
        const start = self.index;
        self.advance(); // Skip <

        // Parse tag name
        const name_start = self.index;
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '>' or c == '/') break;
            self.advance();
        }
        const name = self.source[name_start..self.index];

        // Parse attributes
        const attrs = self.parseAttributes();

        self.skipWhitespace();

        // Self-closing?
        var self_closing = false;
        if (self.startsWith("/>")) {
            self_closing = true;
            self.advanceBy(2);
            return self.create(Element, .{
                .name = name,
                .attributes = attrs,
                .children = .{ .nodes = &[_]Node{}, .loc = self.loc(self.index) },
                .self_closing = true,
                .loc = self.loc(start),
            });
        }

        _ = self.expect('>');

        // Void elements
        if (isVoidElement(name)) {
            return self.create(Element, .{
                .name = name,
                .attributes = attrs,
                .children = .{ .nodes = &[_]Node{}, .loc = self.loc(self.index) },
                .self_closing = true,
                .loc = self.loc(start),
            });
        }

        // Parse children
        const children = self.parseChildren(name);

        // Closing tag
        if (self.startsWith("</")) {
            self.advanceBy(2);
            while (self.peek()) |c| {
                if (c == '>') break;
                self.advance();
            }
            _ = self.expect('>');
        }

        return self.create(Element, .{
            .name = name,
            .attributes = attrs,
            .children = children,
            .self_closing = self_closing,
            .loc = self.loc(start),
        });
    }

    fn parseComponent(self: *SvelteParser) *Component {
        const start = self.index;
        self.advance(); // Skip <

        // Parse tag name
        const name_start = self.index;
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '>' or c == '/') break;
            self.advance();
        }
        const name = self.source[name_start..self.index];

        // Parse attributes
        const attrs = self.parseAttributes();

        self.skipWhitespace();

        // Self-closing?
        if (self.startsWith("/>")) {
            self.advanceBy(2);
            return self.create(Component, .{
                .name = name,
                .attributes = attrs,
                .children = .{ .nodes = &[_]Node{}, .loc = self.loc(self.index) },
                .self_closing = true,
                .loc = self.loc(start),
            });
        }

        _ = self.expect('>');

        // Parse children
        const children = self.parseChildren(name);

        // Closing tag
        if (self.startsWith("</")) {
            self.advanceBy(2);
            while (self.peek()) |c| {
                if (c == '>') break;
                self.advance();
            }
            _ = self.expect('>');
        }

        return self.create(Component, .{
            .name = name,
            .attributes = attrs,
            .children = children,
            .self_closing = false,
            .loc = self.loc(start),
        });
    }

    fn parseAttributes(self: *SvelteParser) []Attribute {
        var attrs = std.ArrayList(Attribute).init(self.allocator);

        while (true) {
            self.skipWhitespace();
            const c = self.peek() orelse break;
            if (c == '>' or c == '/') break;

            const attr_start = self.index;

            // Spread: {...props}
            if (self.startsWith("{...")) {
                self.advanceBy(4);
                const expr = self.parseExpressionUntil('}');
                _ = self.expect('}');
                attrs.append(.{
                    .name = "",
                    .value = .{ .expression = expr },
                    .loc = self.loc(attr_start),
                    .kind = .spread,
                }) catch {};
                continue;
            }

            // Shorthand: {foo}
            if (c == '{') {
                self.advance();
                const name_start = self.index;
                while (self.peek()) |ch| {
                    if (ch == '}') break;
                    self.advance();
                }
                const attr_name = self.source[name_start..self.index];
                _ = self.expect('}');
                attrs.append(.{
                    .name = attr_name,
                    .value = null,
                    .loc = self.loc(attr_start),
                    .kind = .shorthand,
                }) catch {};
                continue;
            }

            // Regular attribute
            const name_start = self.index;
            while (self.peek()) |ch| {
                if (ch == '=' or ch == ' ' or ch == '>' or ch == '/' or ch == '\n' or ch == '\t') break;
                self.advance();
            }
            const attr_name = self.source[name_start..self.index];

            if (attr_name.len == 0) {
                self.advance();
                continue;
            }

            // Determine kind
            var kind: Attribute.Kind = .normal;
            if (std.mem.startsWith(u8, attr_name, "bind:") or
                std.mem.startsWith(u8, attr_name, "on:") or
                std.mem.startsWith(u8, attr_name, "class:") or
                std.mem.startsWith(u8, attr_name, "style:") or
                std.mem.startsWith(u8, attr_name, "use:") or
                std.mem.startsWith(u8, attr_name, "transition:") or
                std.mem.startsWith(u8, attr_name, "animate:") or
                std.mem.startsWith(u8, attr_name, "in:") or
                std.mem.startsWith(u8, attr_name, "out:"))
            {
                kind = .directive;
            }

            self.skipWhitespace();

            // Value?
            var value: ?AttributeValue = null;
            if (self.peek() == '=') {
                self.advance();
                self.skipWhitespace();

                if (self.peek() == '"' or self.peek() == '\'') {
                    const quote = self.peek().?;
                    self.advance();
                    const val_start = self.index;
                    while (self.peek()) |ch| {
                        if (ch == quote) break;
                        self.advance();
                    }
                    value = .{ .quoted = self.source[val_start..self.index] };
                    _ = self.expect(quote);
                } else if (self.peek() == '{') {
                    self.advance();
                    const expr = self.parseExpressionUntil('}');
                    _ = self.expect('}');
                    value = .{ .expression = expr };
                } else {
                    // Unquoted value
                    const val_start = self.index;
                    while (self.peek()) |ch| {
                        if (ch == ' ' or ch == '>' or ch == '/') break;
                        self.advance();
                    }
                    value = .{ .text = self.source[val_start..self.index] };
                }
            }

            attrs.append(.{
                .name = attr_name,
                .value = value,
                .loc = self.loc(attr_start),
                .kind = kind,
            }) catch {};
        }

        return attrs.toOwnedSlice() catch &[_]Attribute{};
    }

    fn parseChildren(self: *SvelteParser, parent_name: []const u8) Fragment {
        const start = self.index;
        var nodes = std.ArrayList(Node).init(self.allocator);

        while (self.index < self.source.len) {
            // Check for closing tag
            if (self.startsWith("</")) {
                const check_start = self.index + 2;
                var check_end = check_start;
                while (check_end < self.source.len) {
                    if (self.source[check_end] == '>' or self.source[check_end] == ' ') break;
                    check_end += 1;
                }
                if (std.mem.eql(u8, self.source[check_start..check_end], parent_name)) {
                    break;
                }
            }

            if (self.startsWith("<!--")) {
                nodes.append(.{ .comment = self.parseComment() }) catch {};
            } else if (self.peek() == '<') {
                if (self.peekAhead(1)) |c| {
                    if (c >= 'A' and c <= 'Z') {
                        nodes.append(.{ .component = self.parseComponent() }) catch {};
                    } else if (c >= 'a' and c <= 'z') {
                        nodes.append(.{ .element = self.parseElement() }) catch {};
                    } else if (c == '/') {
                        break; // Closing tag
                    } else {
                        nodes.append(.{ .text = self.parseText() }) catch {};
                    }
                } else {
                    break;
                }
            } else if (self.startsWith("{#")) {
                nodes.append(self.parseBlockTag()) catch {};
            } else if (self.startsWith("{:")) {
                break; // Block continuation (handled by parent)
            } else if (self.startsWith("{/")) {
                break; // Block end (handled by parent)
            } else if (self.startsWith("{@")) {
                nodes.append(self.parseSpecialTag()) catch {};
            } else if (self.peek() == '{') {
                nodes.append(.{ .expression = self.parseExpressionTag() }) catch {};
            } else {
                nodes.append(.{ .text = self.parseText() }) catch {};
            }
        }

        return .{
            .nodes = nodes.toOwnedSlice() catch &[_]Node{},
            .loc = self.loc(start),
        };
    }

    fn parseText(self: *SvelteParser) Text {
        const start = self.index;
        while (self.peek()) |c| {
            if (c == '<' or c == '{') break;
            self.advance();
        }
        return .{
            .content = self.source[start..self.index],
            .loc = self.loc(start),
        };
    }

    fn parseExpressionTag(self: *SvelteParser) *ExpressionTag {
        const start = self.index;
        _ = self.expect('{');
        const expr = self.parseExpressionUntil('}');
        _ = self.expect('}');
        return self.create(ExpressionTag, .{
            .expression = expr,
            .loc = self.loc(start),
        });
    }

    fn parseBlockTag(self: *SvelteParser) Node {
        const start = self.index;
        self.advanceBy(2); // Skip "{#"

        // Determine block type
        if (self.startsWith("if")) {
            return .{ .if_block = self.parseIfBlock(start) };
        } else if (self.startsWith("each")) {
            return .{ .each_block = self.parseEachBlock(start) };
        } else if (self.startsWith("await")) {
            return .{ .await_block = self.parseAwaitBlock(start) };
        } else if (self.startsWith("key")) {
            return .{ .key_block = self.parseKeyBlock(start) };
        } else if (self.startsWith("snippet")) {
            return .{ .snippet_block = self.parseSnippetBlock(start) };
        } else {
            // Unknown block
            while (self.peek()) |c| {
                if (c == '}') break;
                self.advance();
            }
            _ = self.expect('}');
            return .{ .text = .{ .content = "", .loc = self.loc(start) } };
        }
    }

    fn parseIfBlock(self: *SvelteParser, start: usize) *IfBlock {
        self.advanceBy(2); // Skip "if"
        self.skipWhitespace();

        const condition = self.parseExpressionUntil('}');
        _ = self.expect('}');

        const consequent = self.parseChildrenUntilBlockEnd();

        var alternate: ?IfBlock.Alternate = null;
        if (self.startsWith("{:else if")) {
            self.advanceBy(9);
            self.skipWhitespace();
            alternate = .{ .else_if = self.parseIfBlock(self.index - 9) };
        } else if (self.startsWith("{:else}")) {
            self.advanceBy(7);
            alternate = .{ .else_block = self.parseChildrenUntilBlockEnd() };
        }

        if (self.startsWith("{/if}")) {
            self.advanceBy(5);
        }

        return self.create(IfBlock, .{
            .condition = condition,
            .consequent = consequent,
            .alternate = alternate,
            .loc = self.loc(start),
        });
    }

    fn parseEachBlock(self: *SvelteParser, start: usize) *EachBlock {
        self.advanceBy(4); // Skip "each"
        self.skipWhitespace();

        // Parse: expression as item, index (key)
        const expr = self.parseExpressionUntil2('}', 'a'); // Until "as"

        // Skip "as"
        self.skipWhitespace();
        if (self.startsWith("as")) {
            self.advanceBy(2);
        }
        self.skipWhitespace();

        // Item binding
        const item_start = self.index;
        while (self.peek()) |c| {
            if (c == ',' or c == '}' or c == '(' or c == ' ') break;
            self.advance();
        }
        const item = self.source[item_start..self.index];

        // Index?
        self.skipWhitespace();
        var index_name: ?[]const u8 = null;
        if (self.peek() == ',') {
            self.advance();
            self.skipWhitespace();
            const idx_start = self.index;
            while (self.peek()) |c| {
                if (c == ')' or c == '}' or c == '(' or c == ' ') break;
                self.advance();
            }
            index_name = self.source[idx_start..self.index];
        }

        // Key?
        self.skipWhitespace();
        var key: ?Expr = null;
        if (self.peek() == '(') {
            self.advance();
            key = self.parseExpressionUntil(')');
            _ = self.expect(')');
        }

        self.skipWhitespace();
        _ = self.expect('}');

        const body = self.parseChildrenUntilBlockEnd();

        var else_body: ?Fragment = null;
        if (self.startsWith("{:else}")) {
            self.advanceBy(7);
            else_body = self.parseChildrenUntilBlockEnd();
        }

        if (self.startsWith("{/each}")) {
            self.advanceBy(7);
        }

        return self.create(EachBlock, .{
            .expression = expr,
            .item = item,
            .index = index_name,
            .key = key,
            .body = body,
            .else_body = else_body,
            .loc = self.loc(start),
        });
    }

    fn parseAwaitBlock(self: *SvelteParser, start: usize) *AwaitBlock {
        self.advanceBy(5); // Skip "await"
        self.skipWhitespace();

        const expr = self.parseExpressionUntil('}');
        _ = self.expect('}');

        var pending: ?Fragment = null;
        var then_binding: ?[]const u8 = null;
        var then_body: ?Fragment = null;
        var catch_binding: ?[]const u8 = null;
        var catch_body: ?Fragment = null;

        // Check for inline then
        if (!self.startsWith("{:then") and !self.startsWith("{:catch") and !self.startsWith("{/await}")) {
            pending = self.parseChildrenUntilBlockEnd();
        }

        if (self.startsWith("{:then")) {
            self.advanceBy(6);
            self.skipWhitespace();
            if (self.peek() != '}') {
                const binding_start = self.index;
                while (self.peek()) |c| {
                    if (c == '}') break;
                    self.advance();
                }
                then_binding = self.source[binding_start..self.index];
            }
            _ = self.expect('}');
            then_body = self.parseChildrenUntilBlockEnd();
        }

        if (self.startsWith("{:catch")) {
            self.advanceBy(7);
            self.skipWhitespace();
            if (self.peek() != '}') {
                const binding_start = self.index;
                while (self.peek()) |c| {
                    if (c == '}') break;
                    self.advance();
                }
                catch_binding = self.source[binding_start..self.index];
            }
            _ = self.expect('}');
            catch_body = self.parseChildrenUntilBlockEnd();
        }

        if (self.startsWith("{/await}")) {
            self.advanceBy(8);
        }

        return self.create(AwaitBlock, .{
            .expression = expr,
            .pending = pending,
            .then_binding = then_binding,
            .then_body = then_body,
            .catch_binding = catch_binding,
            .catch_body = catch_body,
            .loc = self.loc(start),
        });
    }

    fn parseKeyBlock(self: *SvelteParser, start: usize) *KeyBlock {
        self.advanceBy(3); // Skip "key"
        self.skipWhitespace();

        const expr = self.parseExpressionUntil('}');
        _ = self.expect('}');

        const body = self.parseChildrenUntilBlockEnd();

        if (self.startsWith("{/key}")) {
            self.advanceBy(6);
        }

        return self.create(KeyBlock, .{
            .expression = expr,
            .body = body,
            .loc = self.loc(start),
        });
    }

    fn parseSnippetBlock(self: *SvelteParser, start: usize) *SnippetBlock {
        self.advanceBy(7); // Skip "snippet"
        self.skipWhitespace();

        // Name
        const name_start = self.index;
        while (self.peek()) |c| {
            if (c == '(' or c == '}' or c == ' ') break;
            self.advance();
        }
        const name = self.source[name_start..self.index];

        // Params
        var params = std.ArrayList([]const u8).init(self.allocator);
        if (self.peek() == '(') {
            self.advance();
            while (self.peek()) |c| {
                if (c == ')') break;
                self.skipWhitespace();
                const param_start = self.index;
                while (self.peek()) |ch| {
                    if (ch == ',' or ch == ')') break;
                    self.advance();
                }
                const param = std.mem.trim(u8, self.source[param_start..self.index], " \t\n\r");
                if (param.len > 0) {
                    params.append(param) catch {};
                }
                if (self.peek() == ',') self.advance();
            }
            _ = self.expect(')');
        }
        _ = self.expect('}');

        const body = self.parseChildrenUntilBlockEnd();

        if (self.startsWith("{/snippet}")) {
            self.advanceBy(10);
        }

        return self.create(SnippetBlock, .{
            .name = name,
            .params = params.toOwnedSlice() catch &[_][]const u8{},
            .body = body,
            .loc = self.loc(start),
        });
    }

    fn parseSpecialTag(self: *SvelteParser) Node {
        const start = self.index;
        self.advanceBy(2); // Skip "{@"

        if (self.startsWith("html")) {
            self.advanceBy(4);
            self.skipWhitespace();
            const expr = self.parseExpressionUntil('}');
            _ = self.expect('}');
            return .{
                .html_tag = self.create(HtmlTag, .{
                    .expression = expr,
                    .loc = self.loc(start),
                }),
            };
        } else if (self.startsWith("debug")) {
            self.advanceBy(5);
            self.skipWhitespace();
            var idents = std.ArrayList([]const u8).init(self.allocator);
            while (self.peek()) |c| {
                if (c == '}') break;
                self.skipWhitespace();
                const id_start = self.index;
                while (self.peek()) |ch| {
                    if (ch == ',' or ch == '}' or ch == ' ') break;
                    self.advance();
                }
                if (self.index > id_start) {
                    idents.append(self.source[id_start..self.index]) catch {};
                }
                if (self.peek() == ',') self.advance();
            }
            _ = self.expect('}');
            return .{
                .debug_tag = self.create(DebugTag, .{
                    .identifiers = idents.toOwnedSlice() catch &[_][]const u8{},
                    .loc = self.loc(start),
                }),
            };
        } else if (self.startsWith("const")) {
            self.advanceBy(5);
            self.skipWhitespace();
            const binding_start = self.index;
            while (self.peek()) |c| {
                if (c == '=') break;
                self.advance();
            }
            const binding = std.mem.trim(u8, self.source[binding_start..self.index], " \t\n\r");
            _ = self.expect('=');
            self.skipWhitespace();
            const expr = self.parseExpressionUntil('}');
            _ = self.expect('}');
            return .{
                .const_tag = self.create(ConstTag, .{
                    .binding = binding,
                    .expression = expr,
                    .loc = self.loc(start),
                }),
            };
        } else if (self.startsWith("render")) {
            self.advanceBy(6);
            self.skipWhitespace();
            const expr = self.parseExpressionUntil('}');
            _ = self.expect('}');
            return .{
                .render_tag = self.create(RenderTag, .{
                    .expression = expr,
                    .loc = self.loc(start),
                }),
            };
        } else {
            // Unknown special tag
            while (self.peek()) |c| {
                if (c == '}') break;
                self.advance();
            }
            _ = self.expect('}');
            return .{ .text = .{ .content = "", .loc = self.loc(start) } };
        }
    }

    fn parseChildrenUntilBlockEnd(self: *SvelteParser) Fragment {
        const start = self.index;
        var nodes = std.ArrayList(Node).init(self.allocator);

        while (self.index < self.source.len) {
            if (self.startsWith("{:") or self.startsWith("{/")) {
                break;
            }

            if (self.startsWith("<!--")) {
                nodes.append(.{ .comment = self.parseComment() }) catch {};
            } else if (self.peek() == '<') {
                if (self.peekAhead(1)) |c| {
                    if (c >= 'A' and c <= 'Z') {
                        nodes.append(.{ .component = self.parseComponent() }) catch {};
                    } else if (c >= 'a' and c <= 'z') {
                        nodes.append(.{ .element = self.parseElement() }) catch {};
                    } else {
                        nodes.append(.{ .text = self.parseText() }) catch {};
                    }
                } else {
                    break;
                }
            } else if (self.startsWith("{#")) {
                nodes.append(self.parseBlockTag()) catch {};
            } else if (self.startsWith("{@")) {
                nodes.append(self.parseSpecialTag()) catch {};
            } else if (self.peek() == '{') {
                nodes.append(.{ .expression = self.parseExpressionTag() }) catch {};
            } else {
                nodes.append(.{ .text = self.parseText() }) catch {};
            }
        }

        return .{
            .nodes = nodes.toOwnedSlice() catch &[_]Node{},
            .loc = self.loc(start),
        };
    }

    fn parseExpressionUntil(self: *SvelteParser, end: u8) Expr {
        const expr_start = self.index;
        var depth: u32 = 0;

        while (self.peek()) |c| {
            if (c == end and depth == 0) break;
            if (c == '{' or c == '(' or c == '[') depth += 1;
            if (c == '}' or c == ')' or c == ']') {
                if (depth > 0) depth -= 1 else break;
            }
            self.advance();
        }

        const expr_content = self.source[expr_start..self.index];
        var js_parser = Parser.init(self.allocator, expr_content);
        return js_parser.parseExpr();
    }

    fn parseExpressionUntil2(self: *SvelteParser, end: u8, keyword_start: u8) Expr {
        const expr_start = self.index;
        var depth: u32 = 0;

        while (self.peek()) |c| {
            if (c == end and depth == 0) break;
            // Check for keyword (like "as" in each)
            if (c == ' ' and depth == 0) {
                if (self.peekAhead(1) == keyword_start and self.peekAhead(2) == 's' and self.peekAhead(3) == ' ') {
                    break;
                }
            }
            if (c == '{' or c == '(' or c == '[') depth += 1;
            if (c == '}' or c == ')' or c == ']') {
                if (depth > 0) depth -= 1 else break;
            }
            self.advance();
        }

        const expr_content = std.mem.trim(u8, self.source[expr_start..self.index], " \t\n\r");
        var js_parser = Parser.init(self.allocator, expr_content);
        return js_parser.parseExpr();
    }

    fn expect(self: *SvelteParser, char: u8) bool {
        if (self.peek() == char) {
            self.advance();
            return true;
        }
        return false;
    }
};

fn isVoidElement(name: []const u8) bool {
    const void_elements = [_][]const u8{
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    };
    for (void_elements) |ve| {
        if (std.mem.eql(u8, name, ve)) return true;
    }
    return false;
}

// Tests
test "svelte parser - basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = SvelteParser.init(arena.allocator(),
        \\<script>
        \\  let count = 0;
        \\</script>
        \\
        \\<button onclick={() => count++}>
        \\  Count: {count}
        \\</button>
    );
    const result = parser.parse();

    try std.testing.expect(result.instance_script != null);
    try std.testing.expect(result.template.nodes.len > 0);
}

test "svelte parser - if block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = SvelteParser.init(arena.allocator(),
        \\{#if condition}
        \\  <p>True</p>
        \\{:else}
        \\  <p>False</p>
        \\{/if}
    );
    const result = parser.parse();

    try std.testing.expect(result.template.nodes.len > 0);
    try std.testing.expect(result.template.nodes[0] == .if_block);
}

test "svelte parser - each block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = SvelteParser.init(arena.allocator(),
        \\{#each items as item, i (item.id)}
        \\  <li>{item.name}</li>
        \\{/each}
    );
    const result = parser.parse();

    try std.testing.expect(result.template.nodes.len > 0);
    try std.testing.expect(result.template.nodes[0] == .each_block);
}

test "svelte parser - component" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = SvelteParser.init(arena.allocator(),
        \\<MyComponent prop={value} on:click={handler} />
    );
    const result = parser.parse();

    try std.testing.expect(result.template.nodes.len > 0);
    try std.testing.expect(result.template.nodes[0] == .component);
}

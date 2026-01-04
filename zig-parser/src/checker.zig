// Svelte Diagnostics
// Checks for errors and warnings in Svelte files

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const svelte = @import("svelte.zig");

const Expr = ast.Expr;
const Stmt = ast.Stmt;
const SvelteFile = svelte.SvelteFile;
const Node = svelte.Node;
const Fragment = svelte.Fragment;

pub const Severity = enum {
    @"error",
    warning,
    hint,
};

pub const Diagnostic = struct {
    severity: Severity,
    message: []const u8,
    loc: ast.Loc,
    code: Code,

    pub const Code = enum {
        // Errors
        undefined_variable,
        undefined_component,
        missing_closing_tag,
        invalid_block_syntax,
        invalid_attribute,
        type_error,

        // Warnings
        unused_variable,
        unused_import,
        unused_css_selector,
        missing_key_in_each,
        missing_alt_attribute,
        empty_block,
        unreachable_code,

        // Hints
        prefer_const,
        simplify_expression,
    };
};

/// Scope for tracking variable declarations
const Scope = struct {
    parent: ?*Scope,
    variables: std.StringHashMap(VarInfo),
    kind: Kind,

    const Kind = enum {
        module,
        function,
        block,
        each_block,
        snippet,
    };

    const VarInfo = struct {
        loc: ast.Loc,
        kind: VarKind,
        used: bool = false,
        is_prop: bool = false,
        is_state: bool = false,
    };

    const VarKind = enum {
        k_var,
        k_let,
        k_const,
        k_param,
        k_import,
        k_function,
        k_class,
    };

    fn init(allocator: Allocator, parent: ?*Scope, kind: Kind) Scope {
        return .{
            .parent = parent,
            .variables = std.StringHashMap(VarInfo).init(allocator),
            .kind = kind,
        };
    }

    fn deinit(self: *Scope) void {
        self.variables.deinit();
    }

    fn declare(self: *Scope, name: []const u8, info: VarInfo) void {
        self.variables.put(name, info) catch {};
    }

    fn lookup(self: *Scope, name: []const u8) ?*VarInfo {
        if (self.variables.getPtr(name)) |info| {
            return info;
        }
        if (self.parent) |parent| {
            return parent.lookup(name);
        }
        return null;
    }

    fn markUsed(self: *Scope, name: []const u8) void {
        if (self.variables.getPtr(name)) |info| {
            info.used = true;
            return;
        }
        if (self.parent) |parent| {
            parent.markUsed(name);
        }
    }
};

/// Checker for Svelte diagnostics
pub const Checker = struct {
    allocator: Allocator,
    diagnostics: std.ArrayList(Diagnostic),
    scope: *Scope,
    scopes: std.ArrayList(*Scope),
    source: []const u8,

    // Known Svelte globals
    const svelte_globals = [_][]const u8{
        "$state",
        "$derived",
        "$effect",
        "$props",
        "$bindable",
        "$inspect",
        "$host",
        "$$props",
        "$$restProps",
        "$$slots",
    };

    // Known DOM globals
    const dom_globals = [_][]const u8{
        "window",
        "document",
        "console",
        "setTimeout",
        "setInterval",
        "clearTimeout",
        "clearInterval",
        "fetch",
        "URL",
        "URLSearchParams",
        "JSON",
        "Math",
        "Date",
        "Array",
        "Object",
        "String",
        "Number",
        "Boolean",
        "Map",
        "Set",
        "WeakMap",
        "WeakSet",
        "Promise",
        "Error",
        "undefined",
        "null",
        "true",
        "false",
        "NaN",
        "Infinity",
        "globalThis",
        "self",
        "navigator",
        "location",
        "history",
        "localStorage",
        "sessionStorage",
        "requestAnimationFrame",
        "cancelAnimationFrame",
        "alert",
        "confirm",
        "prompt",
        "event",
    };

    pub fn init(allocator: Allocator, source: []const u8) Checker {
        var scopes = std.ArrayList(*Scope).init(allocator);
        const root_scope = allocator.create(Scope) catch @panic("OOM");
        root_scope.* = Scope.init(allocator, null, .module);
        scopes.append(root_scope) catch {};

        return .{
            .allocator = allocator,
            .diagnostics = std.ArrayList(Diagnostic).init(allocator),
            .scope = root_scope,
            .scopes = scopes,
            .source = source,
        };
    }

    pub fn deinit(self: *Checker) void {
        for (self.scopes.items) |scope| {
            scope.deinit();
            self.allocator.destroy(scope);
        }
        self.scopes.deinit();
        self.diagnostics.deinit();
    }

    fn pushScope(self: *Checker, kind: Scope.Kind) void {
        const new_scope = self.allocator.create(Scope) catch @panic("OOM");
        new_scope.* = Scope.init(self.allocator, self.scope, kind);
        self.scopes.append(new_scope) catch {};
        self.scope = new_scope;
    }

    fn popScope(self: *Checker) void {
        if (self.scope.parent) |parent| {
            self.scope = parent;
        }
    }

    fn addDiagnostic(self: *Checker, severity: Severity, code: Diagnostic.Code, message: []const u8, loc: ast.Loc) void {
        self.diagnostics.append(.{
            .severity = severity,
            .message = message,
            .loc = loc,
            .code = code,
        }) catch {};
    }

    fn isGlobal(name: []const u8) bool {
        for (svelte_globals) |g| {
            if (std.mem.eql(u8, name, g)) return true;
        }
        for (dom_globals) |g| {
            if (std.mem.eql(u8, name, g)) return true;
        }
        return false;
    }

    /// Check a complete Svelte file
    pub fn check(self: *Checker, file: *const SvelteFile) void {
        // First pass: collect declarations from script
        if (file.module_script) |script| {
            self.collectDeclarations(script.stmts);
        }
        if (file.instance_script) |script| {
            self.collectDeclarations(script.stmts);
        }

        // Second pass: check template for undefined references
        self.checkFragment(&file.template);

        // Third pass: report unused variables
        self.checkUnusedVariables();
    }

    fn collectDeclarations(self: *Checker, stmts: []const Stmt) void {
        for (stmts) |stmt| {
            self.collectStmtDeclarations(&stmt);
        }
    }

    fn collectStmtDeclarations(self: *Checker, stmt: *const Stmt) void {
        switch (stmt.data) {
            .s_var => |var_decl| {
                for (var_decl.decls) |decl| {
                    self.collectBindingDeclarations(&decl.binding, switch (var_decl.kind) {
                        .k_var => .k_var,
                        .k_let => .k_let,
                        .k_const => .k_const,
                        .k_using, .k_await_using => .k_const,
                    });
                }
            },
            .s_function => |func_decl| {
                self.scope.declare(func_decl.name, .{
                    .loc = stmt.loc,
                    .kind = .k_function,
                });
            },
            .s_class => |class_decl| {
                self.scope.declare(class_decl.name, .{
                    .loc = stmt.loc,
                    .kind = .k_class,
                });
            },
            .s_import => |import_stmt| {
                if (import_stmt.default) |name| {
                    self.scope.declare(name, .{
                        .loc = stmt.loc,
                        .kind = .k_import,
                    });
                }
                if (import_stmt.namespace) |name| {
                    self.scope.declare(name, .{
                        .loc = stmt.loc,
                        .kind = .k_import,
                    });
                }
                for (import_stmt.items) |item| {
                    const name = item.alias orelse item.name;
                    self.scope.declare(name, .{
                        .loc = stmt.loc,
                        .kind = .k_import,
                    });
                }
            },
            .s_block => |block| {
                self.pushScope(.block);
                for (block) |s| {
                    self.collectStmtDeclarations(&s);
                }
                self.popScope();
            },
            else => {},
        }
    }

    fn collectBindingDeclarations(self: *Checker, binding: *const ast.Binding, kind: Scope.VarKind) void {
        switch (binding.data) {
            .b_identifier => |name| {
                if (name.len > 0) {
                    self.scope.declare(name, .{
                        .loc = binding.loc,
                        .kind = kind,
                    });
                }
            },
            .b_array => |items| {
                for (items) |item| {
                    self.collectBindingDeclarations(&item.binding, kind);
                }
            },
            .b_object => |items| {
                for (items) |item| {
                    self.collectBindingDeclarations(&item.value, kind);
                }
            },
        }
    }

    fn checkFragment(self: *Checker, fragment: *const Fragment) void {
        for (fragment.nodes) |node| {
            self.checkNode(&node);
        }
    }

    fn checkNode(self: *Checker, node: *const Node) void {
        switch (node.*) {
            .text, .comment => {},
            .element => |elem| {
                self.checkElement(elem);
            },
            .component => |comp| {
                self.checkComponent(comp);
            },
            .expression => |expr_tag| {
                self.checkExpr(&expr_tag.expression);
            },
            .if_block => |if_block| {
                self.checkIfBlock(if_block);
            },
            .each_block => |each_block| {
                self.checkEachBlock(each_block);
            },
            .await_block => |await_block| {
                self.checkAwaitBlock(await_block);
            },
            .key_block => |key_block| {
                self.checkExpr(&key_block.expression);
                self.checkFragment(&key_block.body);
            },
            .snippet_block => |snippet| {
                self.pushScope(.snippet);
                for (snippet.params) |param| {
                    self.scope.declare(param, .{
                        .loc = snippet.loc,
                        .kind = .k_param,
                    });
                }
                self.checkFragment(&snippet.body);
                self.popScope();
            },
            .html_tag => |html_tag| {
                self.checkExpr(&html_tag.expression);
            },
            .debug_tag => |debug_tag| {
                for (debug_tag.identifiers) |ident| {
                    self.checkIdentifier(ident, debug_tag.loc);
                }
            },
            .const_tag => |const_tag| {
                self.checkExpr(&const_tag.expression);
                self.scope.declare(const_tag.binding, .{
                    .loc = const_tag.loc,
                    .kind = .k_const,
                });
            },
            .render_tag => |render_tag| {
                self.checkExpr(&render_tag.expression);
            },
        }
    }

    fn checkElement(self: *Checker, elem: *const svelte.Element) void {
        // Check for missing alt on img
        if (std.mem.eql(u8, elem.name, "img")) {
            var has_alt = false;
            for (elem.attributes) |attr| {
                if (std.mem.eql(u8, attr.name, "alt")) {
                    has_alt = true;
                    break;
                }
            }
            if (!has_alt) {
                self.addDiagnostic(.warning, .missing_alt_attribute, "img element should have an alt attribute", elem.loc);
            }
        }

        // Check attributes
        for (elem.attributes) |attr| {
            if (attr.value) |value| {
                switch (value) {
                    .expression => |expr| self.checkExpr(&expr),
                    else => {},
                }
            }
        }

        // Check children
        self.checkFragment(&elem.children);
    }

    fn checkComponent(self: *Checker, comp: *const svelte.Component) void {
        // Check if component is defined
        self.checkIdentifier(comp.name, comp.loc);

        // Check attributes
        for (comp.attributes) |attr| {
            if (attr.value) |value| {
                switch (value) {
                    .expression => |expr| self.checkExpr(&expr),
                    else => {},
                }
            }
        }

        // Check children
        self.checkFragment(&comp.children);
    }

    fn checkIfBlock(self: *Checker, if_block: *const svelte.IfBlock) void {
        self.checkExpr(&if_block.condition);

        // Check for empty blocks
        if (if_block.consequent.nodes.len == 0) {
            self.addDiagnostic(.warning, .empty_block, "empty if block", if_block.loc);
        }

        self.checkFragment(&if_block.consequent);

        if (if_block.alternate) |alt| {
            switch (alt) {
                .else_if => |nested| self.checkIfBlock(nested),
                .else_block => |block| {
                    if (block.nodes.len == 0) {
                        self.addDiagnostic(.warning, .empty_block, "empty else block", if_block.loc);
                    }
                    self.checkFragment(&block);
                },
            }
        }
    }

    fn checkEachBlock(self: *Checker, each: *const svelte.EachBlock) void {
        self.checkExpr(&each.expression);

        // Warn if no key provided
        if (each.key == null) {
            self.addDiagnostic(.hint, .missing_key_in_each, "each block should have a key for better performance", each.loc);
        }

        // Create scope for loop variables
        self.pushScope(.each_block);
        self.scope.declare(each.item, .{
            .loc = each.loc,
            .kind = .k_const,
        });
        if (each.index) |idx| {
            self.scope.declare(idx, .{
                .loc = each.loc,
                .kind = .k_const,
            });
        }

        if (each.key) |key| {
            self.checkExpr(&key);
        }

        self.checkFragment(&each.body);
        self.popScope();

        if (each.else_body) |else_body| {
            self.checkFragment(&else_body);
        }
    }

    fn checkAwaitBlock(self: *Checker, await_block: *const svelte.AwaitBlock) void {
        self.checkExpr(&await_block.expression);

        if (await_block.pending) |pending| {
            self.checkFragment(&pending);
        }

        if (await_block.then_body) |then_body| {
            self.pushScope(.block);
            if (await_block.then_binding) |binding| {
                self.scope.declare(binding, .{
                    .loc = await_block.loc,
                    .kind = .k_const,
                });
            }
            self.checkFragment(&then_body);
            self.popScope();
        }

        if (await_block.catch_body) |catch_body| {
            self.pushScope(.block);
            if (await_block.catch_binding) |binding| {
                self.scope.declare(binding, .{
                    .loc = await_block.loc,
                    .kind = .k_const,
                });
            }
            self.checkFragment(&catch_body);
            self.popScope();
        }
    }

    fn checkExpr(self: *Checker, expr: *const Expr) void {
        switch (expr.data) {
            .e_identifier => |ident| {
                self.checkIdentifier(ident.name, expr.loc);
            },
            .e_binary => |binary| {
                self.checkExpr(binary.left);
                self.checkExpr(binary.right);
            },
            .e_unary => |unary| {
                self.checkExpr(unary.operand);
            },
            .e_conditional => |cond| {
                self.checkExpr(cond.test);
                self.checkExpr(cond.consequent);
                self.checkExpr(cond.alternate);
            },
            .e_call => |call| {
                self.checkExpr(call.target);
                for (call.args) |arg| {
                    self.checkExpr(&arg);
                }
            },
            .e_member => |member| {
                self.checkExpr(member.target);
            },
            .e_index => |index| {
                self.checkExpr(index.target);
                self.checkExpr(index.index);
            },
            .e_array => |array| {
                for (array.items) |item| {
                    self.checkExpr(&item);
                }
            },
            .e_object => |obj| {
                for (obj.properties) |prop| {
                    if (prop.key) |key| self.checkExpr(key);
                    if (prop.value) |value| self.checkExpr(value);
                }
            },
            .e_arrow => |arrow| {
                self.pushScope(.function);
                for (arrow.params) |param| {
                    self.collectBindingDeclarations(&param, .k_param);
                }
                switch (arrow.body) {
                    .expr => |e| self.checkExpr(e),
                    .block => |stmts| {
                        for (stmts) |stmt| {
                            self.checkStmt(&stmt);
                        }
                    },
                }
                self.popScope();
            },
            .e_function => |func| {
                self.pushScope(.function);
                for (func.params) |param| {
                    self.collectBindingDeclarations(&param, .k_param);
                }
                for (func.body) |stmt| {
                    self.checkStmt(&stmt);
                }
                self.popScope();
            },
            .e_assign => |assign| {
                self.checkExpr(assign.target);
                self.checkExpr(assign.value);
            },
            .e_spread => |spread| {
                self.checkExpr(spread);
            },
            .e_await => |await_expr| {
                self.checkExpr(await_expr);
            },
            .e_yield => |yield| {
                if (yield.value) |value| {
                    self.checkExpr(value);
                }
            },
            .e_paren => |paren| {
                self.checkExpr(paren);
            },
            .e_sequence => |seq| {
                for (seq) |e| {
                    self.checkExpr(&e);
                }
            },
            .e_new => |new| {
                self.checkExpr(new.target);
                for (new.args) |arg| {
                    self.checkExpr(&arg);
                }
            },
            .e_template => |template| {
                if (template.tag) |tag| {
                    self.checkExpr(tag);
                }
                for (template.parts) |part| {
                    if (part.expr) |e| {
                        self.checkExpr(e);
                    }
                }
            },
            else => {},
        }
    }

    fn checkStmt(self: *Checker, stmt: *const Stmt) void {
        switch (stmt.data) {
            .s_var => |var_decl| {
                for (var_decl.decls) |decl| {
                    self.collectBindingDeclarations(&decl.binding, switch (var_decl.kind) {
                        .k_var => .k_var,
                        .k_let => .k_let,
                        .k_const => .k_const,
                        else => .k_const,
                    });
                    if (decl.value) |value| {
                        self.checkExpr(value);
                    }
                }
            },
            .s_expr => |expr| {
                self.checkExpr(expr);
            },
            .s_if => |if_stmt| {
                self.checkExpr(if_stmt.test);
                self.checkStmt(if_stmt.consequent);
                if (if_stmt.alternate) |alt| {
                    self.checkStmt(alt);
                }
            },
            .s_return => |ret| {
                if (ret) |expr| {
                    self.checkExpr(expr);
                }
            },
            .s_throw => |throw| {
                self.checkExpr(throw);
            },
            .s_block => |block| {
                self.pushScope(.block);
                for (block) |s| {
                    self.checkStmt(&s);
                }
                self.popScope();
            },
            else => {},
        }
    }

    fn checkIdentifier(self: *Checker, name: []const u8, loc: ast.Loc) void {
        if (name.len == 0) return;

        // Check if it's a global
        if (isGlobal(name)) return;

        // Check if defined in scope
        if (self.scope.lookup(name)) |info| {
            info.used = true;
            return;
        }

        // Undefined variable
        self.addDiagnostic(.@"error", .undefined_variable, "undefined variable", loc);
    }

    fn checkUnusedVariables(self: *Checker) void {
        for (self.scopes.items) |scope| {
            var iter = scope.variables.iterator();
            while (iter.next()) |entry| {
                const info = entry.value_ptr;
                if (!info.used and info.kind != .k_import) {
                    // Don't warn about variables starting with _
                    if (entry.key_ptr.*.len > 0 and entry.key_ptr.*[0] == '_') continue;

                    self.addDiagnostic(.warning, .unused_variable, "unused variable", info.loc);
                }
            }
        }
    }

    /// Get all diagnostics
    pub fn getDiagnostics(self: *const Checker) []const Diagnostic {
        return self.diagnostics.items;
    }

    /// Check if there are any errors
    pub fn hasErrors(self: *const Checker) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }

    /// Count errors
    pub fn errorCount(self: *const Checker) u32 {
        var count: u32 = 0;
        for (self.diagnostics.items) |d| {
            if (d.severity == .@"error") count += 1;
        }
        return count;
    }

    /// Count warnings
    pub fn warningCount(self: *const Checker) u32 {
        var count: u32 = 0;
        for (self.diagnostics.items) |d| {
            if (d.severity == .warning) count += 1;
        }
        return count;
    }
};

// Tests
test "checker - basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\<script>
        \\  let count = 0;
        \\</script>
        \\<button>{count}</button>
    ;

    var svelte_parser = svelte.SvelteParser.init(arena.allocator(), source);
    const file = svelte_parser.parse();

    var checker = Checker.init(arena.allocator(), source);
    defer checker.deinit();
    checker.check(&file);

    // Should have no errors (count is defined and used)
    try std.testing.expect(!checker.hasErrors());
}

test "checker - undefined variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\<script>
        \\  let x = 0;
        \\</script>
        \\<p>{undefined_var}</p>
    ;

    var svelte_parser = svelte.SvelteParser.init(arena.allocator(), source);
    const file = svelte_parser.parse();

    var checker = Checker.init(arena.allocator(), source);
    defer checker.deinit();
    checker.check(&file);

    // Should have error for undefined_var
    try std.testing.expect(checker.hasErrors());
}

test "checker - each block scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\<script>
        \\  let items = [];
        \\</script>
        \\{#each items as item}
        \\  <p>{item}</p>
        \\{/each}
    ;

    var svelte_parser = svelte.SvelteParser.init(arena.allocator(), source);
    const file = svelte_parser.parse();

    var checker = Checker.init(arena.allocator(), source);
    defer checker.deinit();
    checker.check(&file);

    // Should have no errors (item is defined in each scope)
    try std.testing.expect(!checker.hasErrors());
}

test "checker - missing alt on img" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\<img src="test.png" />
    ;

    var svelte_parser = svelte.SvelteParser.init(arena.allocator(), source);
    const file = svelte_parser.parse();

    var checker = Checker.init(arena.allocator(), source);
    defer checker.deinit();
    checker.check(&file);

    // Should have warning for missing alt
    try std.testing.expect(checker.warningCount() > 0);
}

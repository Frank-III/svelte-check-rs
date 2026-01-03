// JavaScript/TypeScript Parser
// Uses Pratt parsing for expression precedence

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer_mod = @import("lexer.zig");
const ast = @import("ast.zig");
const tables = @import("js_lexer_tables.zig");

const Lexer = lexer_mod.Lexer;
const T = tables.T;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Binding = ast.Binding;
const Loc = ast.Loc;
const BinaryOp = ast.BinaryOp;
const UnaryOp = ast.UnaryOp;
const AssignOp = ast.AssignOp;

pub const Parser = struct {
    lexer: Lexer,
    allocator: Allocator,
    errors: std.ArrayList(Error),

    pub const Error = struct {
        message: []const u8,
        loc: Loc,
    };

    pub fn init(allocator: Allocator, source: []const u8) Parser {
        return .{
            .lexer = Lexer.init(source),
            .allocator = allocator,
            .errors = std.ArrayList(Error).init(allocator),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.errors.deinit();
    }

    // Allocator helpers
    fn create(self: *Parser, comptime T_: type, value: T_) *T_ {
        const ptr = self.allocator.create(T_) catch @panic("OOM");
        ptr.* = value;
        return ptr;
    }

    fn alloc(self: *Parser, comptime T_: type, n: usize) []T_ {
        return self.allocator.alloc(T_, n) catch @panic("OOM");
    }

    // Error handling
    fn addError(self: *Parser, message: []const u8, loc: Loc) void {
        self.errors.append(.{ .message = message, .loc = loc }) catch {};
    }

    fn unexpected(self: *Parser) void {
        self.addError("unexpected token", self.loc());
    }

    // Token utilities
    fn loc(self: *Parser) Loc {
        return .{ .start = self.lexer.token.loc.start, .end = self.lexer.token.loc.end };
    }

    fn advance(self: *Parser) void {
        self.lexer.advance();
    }

    fn token(self: *Parser) T {
        return self.lexer.token.tag;
    }

    fn slice(self: *Parser) []const u8 {
        return self.lexer.slice();
    }

    fn expect(self: *Parser, tag: T) bool {
        if (self.token() == tag) {
            self.advance();
            return true;
        }
        return false;
    }

    fn expectOrError(self: *Parser, tag: T, message: []const u8) bool {
        if (self.expect(tag)) return true;
        self.addError(message, self.loc());
        return false;
    }

    // ========== Expression Parsing (Pratt) ==========

    pub fn parseExpr(self: *Parser) Expr {
        return self.parseExprWithPrec(0);
    }

    fn parseExprWithPrec(self: *Parser, min_prec: u8) Expr {
        var left = self.parsePrefix();

        while (true) {
            const prec = self.infixPrecedence();
            if (prec < min_prec) break;

            left = self.parseInfix(left, prec);
        }

        return left;
    }

    fn parsePrefix(self: *Parser) Expr {
        const start = self.loc();

        return switch (self.token()) {
            // Literals
            .t_null => blk: {
                self.advance();
                break :blk Expr.init(.e_null, start);
            },
            .t_true => blk: {
                self.advance();
                break :blk Expr.init(.{ .e_boolean = true }, start);
            },
            .t_false => blk: {
                self.advance();
                break :blk Expr.init(.{ .e_boolean = false }, start);
            },
            .t_numeric_literal => blk: {
                const text = self.slice();
                const num = std.fmt.parseFloat(f64, text) catch 0.0;
                self.advance();
                break :blk Expr.init(.{ .e_number = num }, start);
            },
            .t_big_integer_literal => blk: {
                const text = self.slice();
                self.advance();
                break :blk Expr.init(.{ .e_bigint = text }, start);
            },
            .t_string_literal => blk: {
                const text = self.slice();
                self.advance();
                // Remove quotes
                const unquoted = if (text.len >= 2) text[1 .. text.len - 1] else text;
                break :blk Expr.init(.{ .e_string = unquoted }, start);
            },
            .t_no_substitution_template_literal => blk: {
                const text = self.slice();
                self.advance();
                const unquoted = if (text.len >= 2) text[1 .. text.len - 1] else text;
                break :blk Expr.init(.{ .e_string = unquoted }, start);
            },

            // Identifiers
            .t_identifier => blk: {
                const name = self.slice();
                self.advance();
                const ident = self.create(Expr.Identifier, .{ .name = name });
                break :blk Expr.init(.{ .e_identifier = ident }, start);
            },
            .t_this => blk: {
                self.advance();
                break :blk Expr.init(.e_this, start);
            },
            .t_super => blk: {
                self.advance();
                break :blk Expr.init(.e_super, start);
            },

            // Unary prefix operators
            .t_exclamation => self.parseUnaryPrefix(.not),
            .t_tilde => self.parseUnaryPrefix(.bitwise_not),
            .t_plus => self.parseUnaryPrefix(.pos),
            .t_minus => self.parseUnaryPrefix(.neg),
            .t_plus_plus => self.parseUnaryPrefix(.pre_inc),
            .t_minus_minus => self.parseUnaryPrefix(.pre_dec),
            .t_typeof => self.parseUnaryPrefix(.typeof),
            .t_void => self.parseUnaryPrefix(.void),
            .t_delete => self.parseUnaryPrefix(.delete),

            // Await/yield
            .t_await => blk: {
                self.advance();
                const operand = self.create(Expr, self.parseExprWithPrec(15));
                break :blk Expr.init(.{ .e_await = operand }, start);
            },
            .t_yield => blk: {
                self.advance();
                const delegate = self.expect(.t_asterisk);
                const value = if (self.token() != .t_semicolon and self.token() != .t_close_paren and self.token() != .t_comma)
                    self.create(Expr, self.parseExpr())
                else
                    null;
                const yield = self.create(Expr.Yield, .{ .value = value, .delegate = delegate });
                break :blk Expr.init(.{ .e_yield = yield }, start);
            },

            // Grouping / arrow function params
            .t_open_paren => self.parseParenOrArrow(),

            // Array literal
            .t_open_bracket => self.parseArrayLiteral(),

            // Object literal
            .t_open_brace => self.parseObjectLiteral(),

            // Function expression
            .t_function => self.parseFunctionExpr(false),
            .t_async => blk: {
                self.advance();
                if (self.token() == .t_function) {
                    break :blk self.parseFunctionExpr(true);
                }
                // async arrow: async (x) => ...
                // For now, treat as identifier
                const ident = self.create(Expr.Identifier, .{ .name = "async" });
                break :blk Expr.init(.{ .e_identifier = ident }, start);
            },

            // Class expression
            .t_class => self.parseClassExpr(),

            // New
            .t_new => blk: {
                self.advance();
                const target = self.create(Expr, self.parseExprWithPrec(18)); // High precedence
                var args: []Expr = &[_]Expr{};
                if (self.expect(.t_open_paren)) {
                    args = self.parseArguments();
                }
                const new = self.create(Expr.New, .{ .target = target, .args = args });
                break :blk Expr.init(.{ .e_new = new }, start);
            },

            // Spread in array/object
            .t_dot_dot_dot => blk: {
                self.advance();
                const operand = self.create(Expr, self.parseExprWithPrec(2));
                break :blk Expr.init(.{ .e_spread = operand }, start);
            },

            else => blk: {
                self.unexpected();
                self.advance();
                break :blk Expr.init(.e_missing, start);
            },
        };
    }

    fn parseUnaryPrefix(self: *Parser, op: UnaryOp) Expr {
        const start = self.loc();
        self.advance();
        const operand = self.create(Expr, self.parseExprWithPrec(15)); // Unary has high precedence
        const unary = self.create(Expr.Unary, .{ .op = op, .operand = operand });
        return Expr.init(.{ .e_unary = unary }, start);
    }

    fn infixPrecedence(self: *Parser) u8 {
        return switch (self.token()) {
            // Postfix
            .t_plus_plus, .t_minus_minus => 17,
            // Call/member
            .t_open_paren, .t_open_bracket, .t_dot, .t_question_dot => 19,
            // Exponentiation (right-assoc)
            .t_asterisk_asterisk => 14,
            // Multiplicative
            .t_asterisk, .t_slash, .t_percent => 13,
            // Additive
            .t_plus, .t_minus => 12,
            // Shift
            .t_less_than_less_than, .t_greater_than_greater_than, .t_greater_than_greater_than_greater_than => 11,
            // Relational
            .t_less_than, .t_less_than_equals, .t_greater_than, .t_greater_than_equals, .t_instanceof, .t_in => 10,
            // Equality
            .t_equals_equals, .t_exclamation_equals, .t_equals_equals_equals, .t_exclamation_equals_equals => 9,
            // Bitwise
            .t_ampersand => 8,
            .t_caret => 7,
            .t_bar => 6,
            // Logical
            .t_ampersand_ampersand => 5,
            .t_bar_bar, .t_question_question => 4,
            // Ternary
            .t_question => 3,
            // Assignment
            .t_equals, .t_plus_equals, .t_minus_equals, .t_asterisk_equals, .t_slash_equals, .t_percent_equals, .t_asterisk_asterisk_equals, .t_less_than_less_than_equals, .t_greater_than_greater_than_equals, .t_greater_than_greater_than_greater_than_equals, .t_ampersand_equals, .t_bar_equals, .t_caret_equals, .t_ampersand_ampersand_equals, .t_bar_bar_equals, .t_question_question_equals => 2,
            // Comma
            .t_comma => 1,
            else => 0,
        };
    }

    fn parseInfix(self: *Parser, left: Expr, prec: u8) Expr {
        const start = left.loc;
        const tok = self.token();

        return switch (tok) {
            // Postfix increment/decrement
            .t_plus_plus => blk: {
                self.advance();
                const unary = self.create(Expr.Unary, .{
                    .op = .post_inc,
                    .operand = self.create(Expr, left),
                });
                break :blk Expr.init(.{ .e_unary = unary }, start);
            },
            .t_minus_minus => blk: {
                self.advance();
                const unary = self.create(Expr.Unary, .{
                    .op = .post_dec,
                    .operand = self.create(Expr, left),
                });
                break :blk Expr.init(.{ .e_unary = unary }, start);
            },

            // Call
            .t_open_paren => blk: {
                self.advance();
                const args = self.parseArguments();
                const call = self.create(Expr.Call, .{
                    .target = self.create(Expr, left),
                    .args = args,
                });
                break :blk Expr.init(.{ .e_call = call }, start);
            },

            // Member access
            .t_dot => blk: {
                self.advance();
                const name = self.slice();
                if (!self.expect(.t_identifier)) {
                    self.addError("expected identifier after '.'", self.loc());
                }
                const member = self.create(Expr.Member, .{
                    .target = self.create(Expr, left),
                    .name = name,
                });
                break :blk Expr.init(.{ .e_member = member }, start);
            },

            // Computed member access
            .t_open_bracket => blk: {
                self.advance();
                const index_expr = self.parseExpr();
                _ = self.expectOrError(.t_close_bracket, "expected ']'");
                const index = self.create(Expr.Index, .{
                    .target = self.create(Expr, left),
                    .index = self.create(Expr, index_expr),
                });
                break :blk Expr.init(.{ .e_index = index }, start);
            },

            // Optional chaining
            .t_question_dot => blk: {
                self.advance();
                if (self.token() == .t_open_paren) {
                    // Optional call
                    self.advance();
                    const args = self.parseArguments();
                    const call = self.create(Expr.Call, .{
                        .target = self.create(Expr, left),
                        .args = args,
                        .optional = true,
                    });
                    break :blk Expr.init(.{ .e_call = call }, start);
                } else if (self.token() == .t_open_bracket) {
                    // Optional computed member
                    self.advance();
                    const index_expr = self.parseExpr();
                    _ = self.expectOrError(.t_close_bracket, "expected ']'");
                    const index = self.create(Expr.Index, .{
                        .target = self.create(Expr, left),
                        .index = self.create(Expr, index_expr),
                        .optional = true,
                    });
                    break :blk Expr.init(.{ .e_index = index }, start);
                } else {
                    // Optional member
                    const name = self.slice();
                    if (!self.expect(.t_identifier)) {
                        self.addError("expected identifier after '?.'", self.loc());
                    }
                    const member = self.create(Expr.Member, .{
                        .target = self.create(Expr, left),
                        .name = name,
                        .optional = true,
                    });
                    break :blk Expr.init(.{ .e_member = member }, start);
                }
            },

            // Ternary conditional
            .t_question => blk: {
                self.advance();
                const consequent = self.parseExprWithPrec(2);
                _ = self.expectOrError(.t_colon, "expected ':' in conditional");
                const alternate = self.parseExprWithPrec(2);
                const cond = self.create(Expr.Conditional, .{
                    .test = self.create(Expr, left),
                    .consequent = self.create(Expr, consequent),
                    .alternate = self.create(Expr, alternate),
                });
                break :blk Expr.init(.{ .e_conditional = cond }, start);
            },

            // Binary operators
            .t_asterisk_asterisk => self.parseBinaryExpr(left, .pow, prec, true),
            .t_asterisk => self.parseBinaryExpr(left, .mul, prec, false),
            .t_slash => self.parseBinaryExpr(left, .div, prec, false),
            .t_percent => self.parseBinaryExpr(left, .rem, prec, false),
            .t_plus => self.parseBinaryExpr(left, .add, prec, false),
            .t_minus => self.parseBinaryExpr(left, .sub, prec, false),
            .t_less_than_less_than => self.parseBinaryExpr(left, .shl, prec, false),
            .t_greater_than_greater_than => self.parseBinaryExpr(left, .shr, prec, false),
            .t_greater_than_greater_than_greater_than => self.parseBinaryExpr(left, .ushr, prec, false),
            .t_less_than => self.parseBinaryExpr(left, .lt, prec, false),
            .t_less_than_equals => self.parseBinaryExpr(left, .lte, prec, false),
            .t_greater_than => self.parseBinaryExpr(left, .gt, prec, false),
            .t_greater_than_equals => self.parseBinaryExpr(left, .gte, prec, false),
            .t_instanceof => self.parseBinaryExpr(left, .instanceof, prec, false),
            .t_in => self.parseBinaryExpr(left, .in, prec, false),
            .t_equals_equals => self.parseBinaryExpr(left, .eq, prec, false),
            .t_exclamation_equals => self.parseBinaryExpr(left, .neq, prec, false),
            .t_equals_equals_equals => self.parseBinaryExpr(left, .strict_eq, prec, false),
            .t_exclamation_equals_equals => self.parseBinaryExpr(left, .strict_neq, prec, false),
            .t_ampersand => self.parseBinaryExpr(left, .bitwise_and, prec, false),
            .t_caret => self.parseBinaryExpr(left, .bitwise_xor, prec, false),
            .t_bar => self.parseBinaryExpr(left, .bitwise_or, prec, false),
            .t_ampersand_ampersand => self.parseBinaryExpr(left, .logical_and, prec, false),
            .t_bar_bar => self.parseBinaryExpr(left, .logical_or, prec, false),
            .t_question_question => self.parseBinaryExpr(left, .nullish_coalesce, prec, false),
            .t_comma => self.parseBinaryExpr(left, .comma, prec, false),

            // Assignment operators
            .t_equals => self.parseAssignment(left, .assign),
            .t_plus_equals => self.parseAssignment(left, .add_assign),
            .t_minus_equals => self.parseAssignment(left, .sub_assign),
            .t_asterisk_equals => self.parseAssignment(left, .mul_assign),
            .t_slash_equals => self.parseAssignment(left, .div_assign),
            .t_percent_equals => self.parseAssignment(left, .rem_assign),
            .t_asterisk_asterisk_equals => self.parseAssignment(left, .pow_assign),
            .t_less_than_less_than_equals => self.parseAssignment(left, .shl_assign),
            .t_greater_than_greater_than_equals => self.parseAssignment(left, .shr_assign),
            .t_greater_than_greater_than_greater_than_equals => self.parseAssignment(left, .ushr_assign),
            .t_ampersand_equals => self.parseAssignment(left, .bitwise_and_assign),
            .t_bar_equals => self.parseAssignment(left, .bitwise_or_assign),
            .t_caret_equals => self.parseAssignment(left, .bitwise_xor_assign),
            .t_ampersand_ampersand_equals => self.parseAssignment(left, .logical_and_assign),
            .t_bar_bar_equals => self.parseAssignment(left, .logical_or_assign),
            .t_question_question_equals => self.parseAssignment(left, .nullish_assign),

            else => left,
        };
    }

    fn parseBinaryExpr(self: *Parser, left: Expr, op: BinaryOp, prec: u8, right_assoc: bool) Expr {
        const start = left.loc;
        self.advance();
        const next_prec = if (right_assoc) prec else prec + 1;
        const right = self.parseExprWithPrec(next_prec);
        const binary = self.create(Expr.Binary, .{
            .op = op,
            .left = self.create(Expr, left),
            .right = self.create(Expr, right),
        });
        return Expr.init(.{ .e_binary = binary }, start);
    }

    fn parseAssignment(self: *Parser, left: Expr, op: AssignOp) Expr {
        const start = left.loc;
        self.advance();
        const right = self.parseExprWithPrec(2); // Right-associative
        const assign = self.create(Expr.Assign, .{
            .op = op,
            .target = self.create(Expr, left),
            .value = self.create(Expr, right),
        });
        return Expr.init(.{ .e_assign = assign }, start);
    }

    fn parseArguments(self: *Parser) []Expr {
        var args = std.ArrayList(Expr).init(self.allocator);

        while (self.token() != .t_close_paren and self.token() != .t_end_of_file) {
            args.append(self.parseExprWithPrec(2)) catch {}; // Above comma
            if (!self.expect(.t_comma)) break;
        }
        _ = self.expectOrError(.t_close_paren, "expected ')'");

        return args.toOwnedSlice() catch &[_]Expr{};
    }

    fn parseParenOrArrow(self: *Parser) Expr {
        const start = self.loc();
        self.advance(); // Skip (

        // Empty parens - must be arrow
        if (self.token() == .t_close_paren) {
            self.advance();
            if (self.token() == .t_equals_greater_than) {
                return self.parseArrowBody(start, &[_]Binding{}, false);
            }
            // () with no arrow - error
            self.addError("unexpected '()'", start);
            return Expr.init(.e_missing, start);
        }

        // Parse first expression
        const first = self.parseExpr();

        // Check for comma (sequence or arrow params)
        if (self.token() == .t_comma) {
            // Could be sequence or arrow params
            var exprs = std.ArrayList(Expr).init(self.allocator);
            exprs.append(first) catch {};

            while (self.expect(.t_comma)) {
                if (self.token() == .t_close_paren) break;
                exprs.append(self.parseExpr()) catch {};
            }
            _ = self.expectOrError(.t_close_paren, "expected ')'");

            if (self.token() == .t_equals_greater_than) {
                // Arrow function
                const bindings = self.exprsToBindings(exprs.items);
                return self.parseArrowBody(start, bindings, false);
            }

            // Sequence expression
            return Expr.init(.{ .e_sequence = exprs.toOwnedSlice() catch &[_]Expr{} }, start);
        }

        _ = self.expectOrError(.t_close_paren, "expected ')'");

        if (self.token() == .t_equals_greater_than) {
            // Arrow function with single param
            var bindings: [1]Binding = undefined;
            bindings[0] = self.exprToBinding(first);
            const owned = self.alloc(Binding, 1);
            owned[0] = bindings[0];
            return self.parseArrowBody(start, owned, false);
        }

        // Parenthesized expression
        const inner = self.create(Expr, first);
        return Expr.init(.{ .e_paren = inner }, start);
    }

    fn parseArrowBody(self: *Parser, start: Loc, params: []Binding, is_async: bool) Expr {
        _ = self.expect(.t_equals_greater_than);

        const body: Expr.ArrowBody = if (self.token() == .t_open_brace) blk: {
            break :blk .{ .block = self.parseBlock() };
        } else blk: {
            break :blk .{ .expr = self.create(Expr, self.parseExprWithPrec(2)) };
        };

        const arrow = self.create(Expr.Arrow, .{
            .params = params,
            .body = body,
            .is_async = is_async,
        });
        return Expr.init(.{ .e_arrow = arrow }, start);
    }

    fn exprsToBindings(self: *Parser, exprs: []Expr) []Binding {
        const bindings = self.alloc(Binding, exprs.len);
        for (exprs, 0..) |e, i| {
            bindings[i] = self.exprToBinding(e);
        }
        return bindings;
    }

    fn exprToBinding(self: *Parser, expr: Expr) Binding {
        return switch (expr.data) {
            .e_identifier => |ident| Binding{
                .data = .{ .b_identifier = ident.name },
                .loc = expr.loc,
            },
            else => Binding{
                .data = .{ .b_identifier = "" },
                .loc = expr.loc,
            },
        };
    }

    fn parseArrayLiteral(self: *Parser) Expr {
        const start = self.loc();
        self.advance(); // Skip [

        var items = std.ArrayList(Expr).init(self.allocator);
        var has_spread = false;

        while (self.token() != .t_close_bracket and self.token() != .t_end_of_file) {
            if (self.token() == .t_comma) {
                // Elision
                items.append(Expr.init(.e_missing, self.loc())) catch {};
                self.advance();
                continue;
            }
            if (self.token() == .t_dot_dot_dot) {
                has_spread = true;
            }
            items.append(self.parseExprWithPrec(2)) catch {};
            if (!self.expect(.t_comma)) break;
        }
        _ = self.expectOrError(.t_close_bracket, "expected ']'");

        const array = self.create(Expr.Array, .{
            .items = items.toOwnedSlice() catch &[_]Expr{},
            .has_spread = has_spread,
        });
        return Expr.init(.{ .e_array = array }, start);
    }

    fn parseObjectLiteral(self: *Parser) Expr {
        const start = self.loc();
        self.advance(); // Skip {

        var props = std.ArrayList(Expr.Property).init(self.allocator);

        while (self.token() != .t_close_brace and self.token() != .t_end_of_file) {
            props.append(self.parseProperty()) catch {};
            if (!self.expect(.t_comma)) break;
        }
        _ = self.expectOrError(.t_close_brace, "expected '}'");

        const obj = self.create(Expr.Object, .{
            .properties = props.toOwnedSlice() catch &[_]Expr.Property{},
        });
        return Expr.init(.{ .e_object = obj }, start);
    }

    fn parseProperty(self: *Parser) Expr.Property {
        // Spread
        if (self.token() == .t_dot_dot_dot) {
            self.advance();
            return .{
                .key = null,
                .value = self.create(Expr, self.parseExprWithPrec(2)),
                .kind = .spread,
            };
        }

        // Get/set
        var kind: Expr.Property.Kind = .normal;
        if (self.token() == .t_identifier) {
            const name = self.slice();
            if (std.mem.eql(u8, name, "get") or std.mem.eql(u8, name, "set")) {
                // Lookahead to see if it's a getter/setter
                // For now, simplified
                kind = if (std.mem.eql(u8, name, "get")) .get else .set;
            }
        }

        // Computed key
        var computed = false;
        var key: ?*Expr = null;

        if (self.token() == .t_open_bracket) {
            computed = true;
            self.advance();
            key = self.create(Expr, self.parseExpr());
            _ = self.expectOrError(.t_close_bracket, "expected ']'");
        } else if (self.token() == .t_identifier or self.token() == .t_string_literal or self.token() == .t_numeric_literal) {
            const k_start = self.loc();
            const k_name = self.slice();
            self.advance();
            const ident = self.create(Expr.Identifier, .{ .name = k_name });
            key = self.create(Expr, Expr.init(.{ .e_identifier = ident }, k_start));
        }

        // Shorthand property
        if (self.token() != .t_colon and self.token() != .t_open_paren) {
            return .{
                .key = key,
                .value = key,
                .shorthand = true,
            };
        }

        // Method
        if (self.token() == .t_open_paren) {
            const func = self.parseFunctionExpr(false);
            return .{
                .key = key,
                .value = self.create(Expr, func),
                .method = true,
                .computed = computed,
            };
        }

        // Regular property
        _ = self.expect(.t_colon);
        return .{
            .key = key,
            .value = self.create(Expr, self.parseExprWithPrec(2)),
            .computed = computed,
            .kind = kind,
        };
    }

    fn parseFunctionExpr(self: *Parser, is_async: bool) Expr {
        const start = self.loc();
        _ = self.expect(.t_function);

        const is_generator = self.expect(.t_asterisk);

        var name: ?[]const u8 = null;
        if (self.token() == .t_identifier) {
            name = self.slice();
            self.advance();
        }

        _ = self.expectOrError(.t_open_paren, "expected '('");
        const params = self.parseParams();
        _ = self.expectOrError(.t_close_paren, "expected ')'");

        const body = self.parseBlock();

        const func = self.create(Expr.Function, .{
            .name = name,
            .params = params,
            .body = body,
            .is_async = is_async,
            .is_generator = is_generator,
        });
        return Expr.init(.{ .e_function = func }, start);
    }

    fn parseParams(self: *Parser) []Binding {
        var params = std.ArrayList(Binding).init(self.allocator);

        while (self.token() != .t_close_paren and self.token() != .t_end_of_file) {
            params.append(self.parseBinding()) catch {};
            if (!self.expect(.t_comma)) break;
        }

        return params.toOwnedSlice() catch &[_]Binding{};
    }

    fn parseBinding(self: *Parser) Binding {
        const start = self.loc();

        // Rest parameter
        if (self.token() == .t_dot_dot_dot) {
            self.advance();
        }

        return switch (self.token()) {
            .t_identifier => blk: {
                const name = self.slice();
                self.advance();
                // Default value
                if (self.expect(.t_equals)) {
                    _ = self.parseExprWithPrec(2);
                }
                break :blk Binding{
                    .data = .{ .b_identifier = name },
                    .loc = start,
                };
            },
            .t_open_bracket => self.parseArrayBinding(),
            .t_open_brace => self.parseObjectBinding(),
            else => Binding{
                .data = .{ .b_identifier = "" },
                .loc = start,
            },
        };
    }

    fn parseArrayBinding(self: *Parser) Binding {
        const start = self.loc();
        self.advance(); // Skip [

        var items = std.ArrayList(Binding.ArrayItem).init(self.allocator);

        while (self.token() != .t_close_bracket and self.token() != .t_end_of_file) {
            if (self.token() == .t_comma) {
                self.advance();
                continue;
            }
            const binding = self.parseBinding();
            var default: ?*Expr = null;
            if (self.expect(.t_equals)) {
                default = self.create(Expr, self.parseExprWithPrec(2));
            }
            items.append(.{ .binding = binding, .default = default }) catch {};
            if (!self.expect(.t_comma)) break;
        }
        _ = self.expectOrError(.t_close_bracket, "expected ']'");

        return Binding{
            .data = .{ .b_array = items.toOwnedSlice() catch &[_]Binding.ArrayItem{} },
            .loc = start,
        };
    }

    fn parseObjectBinding(self: *Parser) Binding {
        const start = self.loc();
        self.advance(); // Skip {

        var items = std.ArrayList(Binding.ObjectItem).init(self.allocator);

        while (self.token() != .t_close_brace and self.token() != .t_end_of_file) {
            // Rest
            if (self.token() == .t_dot_dot_dot) {
                self.advance();
                const binding = self.parseBinding();
                items.append(.{ .key = null, .value = binding, .shorthand = true }) catch {};
                break;
            }

            // Key
            var key: ?*Expr = null;
            var computed = false;
            var shorthand = false;

            if (self.token() == .t_open_bracket) {
                computed = true;
                self.advance();
                key = self.create(Expr, self.parseExpr());
                _ = self.expectOrError(.t_close_bracket, "expected ']'");
            } else {
                const k_start = self.loc();
                const name = self.slice();
                self.advance();
                const ident = self.create(Expr.Identifier, .{ .name = name });
                key = self.create(Expr, Expr.init(.{ .e_identifier = ident }, k_start));
            }

            // Shorthand or with value
            var binding: Binding = undefined;
            var default: ?*Expr = null;

            if (self.token() == .t_colon) {
                self.advance();
                binding = self.parseBinding();
            } else {
                shorthand = true;
                if (key) |k| {
                    if (k.data == .e_identifier) {
                        binding = Binding{
                            .data = .{ .b_identifier = k.data.e_identifier.name },
                            .loc = k.loc,
                        };
                    } else {
                        binding = Binding{ .data = .{ .b_identifier = "" }, .loc = start };
                    }
                } else {
                    binding = Binding{ .data = .{ .b_identifier = "" }, .loc = start };
                }
            }

            if (self.expect(.t_equals)) {
                default = self.create(Expr, self.parseExprWithPrec(2));
            }

            items.append(.{
                .key = key,
                .value = binding,
                .default = default,
                .shorthand = shorthand,
                .computed = computed,
            }) catch {};

            if (!self.expect(.t_comma)) break;
        }
        _ = self.expectOrError(.t_close_brace, "expected '}'");

        return Binding{
            .data = .{ .b_object = items.toOwnedSlice() catch &[_]Binding.ObjectItem{} },
            .loc = start,
        };
    }

    fn parseClassExpr(self: *Parser) Expr {
        const start = self.loc();
        _ = self.expect(.t_class);

        var name: ?[]const u8 = null;
        if (self.token() == .t_identifier) {
            name = self.slice();
            self.advance();
        }

        var extends: ?*Expr = null;
        if (self.expect(.t_extends)) {
            extends = self.create(Expr, self.parseExprWithPrec(18));
        }

        _ = self.expectOrError(.t_open_brace, "expected '{'");
        const members = self.parseClassMembers();
        _ = self.expectOrError(.t_close_brace, "expected '}'");

        const class = self.create(Expr.Class, .{
            .name = name,
            .extends = extends,
            .members = members,
        });
        return Expr.init(.{ .e_class = class }, start);
    }

    fn parseClassMembers(self: *Parser) []Expr.ClassMember {
        var members = std.ArrayList(Expr.ClassMember).init(self.allocator);

        while (self.token() != .t_close_brace and self.token() != .t_end_of_file) {
            // Skip semicolons
            if (self.expect(.t_semicolon)) continue;

            var is_static = false;
            if (self.token() == .t_static) {
                is_static = true;
                self.advance();
            }

            // Get/set
            var kind: Expr.ClassMember.Kind = .field;
            if (self.token() == .t_identifier) {
                const name = self.slice();
                if (std.mem.eql(u8, name, "get")) {
                    kind = .getter;
                    self.advance();
                } else if (std.mem.eql(u8, name, "set")) {
                    kind = .setter;
                    self.advance();
                }
            }

            // Key
            var computed = false;
            var key: *Expr = undefined;
            const k_start = self.loc();

            if (self.token() == .t_open_bracket) {
                computed = true;
                self.advance();
                key = self.create(Expr, self.parseExpr());
                _ = self.expectOrError(.t_close_bracket, "expected ']'");
            } else {
                const name = self.slice();
                self.advance();
                const ident = self.create(Expr.Identifier, .{ .name = name });
                key = self.create(Expr, Expr.init(.{ .e_identifier = ident }, k_start));
            }

            // Method or field
            var value: ?*Expr = null;
            if (self.token() == .t_open_paren) {
                kind = .method;
                value = self.create(Expr, self.parseFunctionExpr(false));
            } else if (self.expect(.t_equals)) {
                value = self.create(Expr, self.parseExprWithPrec(2));
            }

            members.append(.{
                .key = key,
                .value = value,
                .kind = kind,
                .is_static = is_static,
                .computed = computed,
            }) catch {};

            _ = self.expect(.t_semicolon);
        }

        return members.toOwnedSlice() catch &[_]Expr.ClassMember{};
    }

    // ========== Statement Parsing ==========

    pub fn parseStmt(self: *Parser) Stmt {
        const start = self.loc();

        return switch (self.token()) {
            .t_semicolon => blk: {
                self.advance();
                break :blk Stmt.init(.s_empty, start);
            },
            .t_open_brace => Stmt.init(.{ .s_block = self.parseBlock() }, start),
            .t_var => self.parseVarStmt(.k_var),
            .t_let => self.parseVarStmt(.k_let),
            .t_const => self.parseVarStmt(.k_const),
            .t_if => self.parseIfStmt(),
            .t_switch => self.parseSwitchStmt(),
            .t_for => self.parseForStmt(),
            .t_while => self.parseWhileStmt(),
            .t_do => self.parseDoWhileStmt(),
            .t_try => self.parseTryStmt(),
            .t_return => blk: {
                self.advance();
                const value = if (self.token() != .t_semicolon and self.token() != .t_close_brace)
                    self.create(Expr, self.parseExpr())
                else
                    null;
                _ = self.expect(.t_semicolon);
                break :blk Stmt.init(.{ .s_return = value }, start);
            },
            .t_throw => blk: {
                self.advance();
                const value = self.create(Expr, self.parseExpr());
                _ = self.expect(.t_semicolon);
                break :blk Stmt.init(.{ .s_throw = value }, start);
            },
            .t_break => blk: {
                self.advance();
                const label = if (self.token() == .t_identifier) b: {
                    const l = self.slice();
                    self.advance();
                    break :b l;
                } else null;
                _ = self.expect(.t_semicolon);
                break :blk Stmt.init(.{ .s_break = label }, start);
            },
            .t_continue => blk: {
                self.advance();
                const label = if (self.token() == .t_identifier) b: {
                    const l = self.slice();
                    self.advance();
                    break :b l;
                } else null;
                _ = self.expect(.t_semicolon);
                break :blk Stmt.init(.{ .s_continue = label }, start);
            },
            .t_debugger => blk: {
                self.advance();
                _ = self.expect(.t_semicolon);
                break :blk Stmt.init(.s_debugger, start);
            },
            .t_function => self.parseFunctionStmt(false),
            .t_async => blk: {
                self.advance();
                if (self.token() == .t_function) {
                    break :blk self.parseFunctionStmt(true);
                }
                // Expression statement starting with async
                const ident = self.create(Expr.Identifier, .{ .name = "async" });
                const expr = self.create(Expr, self.parseExprWithPrec(0));
                _ = expr;
                break :blk Stmt.init(.{ .s_expr = self.create(Expr, Expr.init(.{ .e_identifier = ident }, start)) }, start);
            },
            .t_class => self.parseClassStmt(),
            .t_import => self.parseImportStmt(),
            .t_export => self.parseExportStmt(),
            else => blk: {
                // Expression statement
                const expr = self.create(Expr, self.parseExpr());
                _ = self.expect(.t_semicolon);
                break :blk Stmt.init(.{ .s_expr = expr }, start);
            },
        };
    }

    fn parseBlock(self: *Parser) []Stmt {
        _ = self.expect(.t_open_brace);
        var stmts = std.ArrayList(Stmt).init(self.allocator);

        while (self.token() != .t_close_brace and self.token() != .t_end_of_file) {
            stmts.append(self.parseStmt()) catch {};
        }
        _ = self.expectOrError(.t_close_brace, "expected '}'");

        return stmts.toOwnedSlice() catch &[_]Stmt{};
    }

    fn parseVarStmt(self: *Parser, kind: Stmt.VarDecl.Kind) Stmt {
        const start = self.loc();
        self.advance();

        var decls = std.ArrayList(Stmt.Decl).init(self.allocator);

        while (true) {
            const binding = self.parseBinding();
            var value: ?*Expr = null;
            if (self.expect(.t_equals)) {
                value = self.create(Expr, self.parseExprWithPrec(2));
            }
            decls.append(.{ .binding = binding, .value = value }) catch {};
            if (!self.expect(.t_comma)) break;
        }
        _ = self.expect(.t_semicolon);

        const var_decl = self.create(Stmt.VarDecl, .{
            .kind = kind,
            .decls = decls.toOwnedSlice() catch &[_]Stmt.Decl{},
        });
        return Stmt.init(.{ .s_var = var_decl }, start);
    }

    fn parseIfStmt(self: *Parser) Stmt {
        const start = self.loc();
        _ = self.expect(.t_if);
        _ = self.expectOrError(.t_open_paren, "expected '('");
        const test_expr = self.create(Expr, self.parseExpr());
        _ = self.expectOrError(.t_close_paren, "expected ')'");
        const consequent = self.create(Stmt, self.parseStmt());
        var alternate: ?*Stmt = null;
        if (self.expect(.t_else)) {
            alternate = self.create(Stmt, self.parseStmt());
        }
        const if_stmt = self.create(Stmt.If, .{
            .test = test_expr,
            .consequent = consequent,
            .alternate = alternate,
        });
        return Stmt.init(.{ .s_if = if_stmt }, start);
    }

    fn parseSwitchStmt(self: *Parser) Stmt {
        const start = self.loc();
        _ = self.expect(.t_switch);
        _ = self.expectOrError(.t_open_paren, "expected '('");
        const test_expr = self.create(Expr, self.parseExpr());
        _ = self.expectOrError(.t_close_paren, "expected ')'");
        _ = self.expectOrError(.t_open_brace, "expected '{'");

        var cases = std.ArrayList(Stmt.Case).init(self.allocator);

        while (self.token() != .t_close_brace and self.token() != .t_end_of_file) {
            var test: ?*Expr = null;
            if (self.expect(.t_case)) {
                test = self.create(Expr, self.parseExpr());
            } else if (self.expect(.t_default)) {
                // default case
            } else {
                break;
            }
            _ = self.expectOrError(.t_colon, "expected ':'");

            var body = std.ArrayList(Stmt).init(self.allocator);
            while (self.token() != .t_case and self.token() != .t_default and self.token() != .t_close_brace and self.token() != .t_end_of_file) {
                body.append(self.parseStmt()) catch {};
            }

            cases.append(.{
                .test = test,
                .body = body.toOwnedSlice() catch &[_]Stmt{},
            }) catch {};
        }
        _ = self.expectOrError(.t_close_brace, "expected '}'");

        const switch_stmt = self.create(Stmt.Switch, .{
            .test = test_expr,
            .cases = cases.toOwnedSlice() catch &[_]Stmt.Case{},
        });
        return Stmt.init(.{ .s_switch = switch_stmt }, start);
    }

    fn parseForStmt(self: *Parser) Stmt {
        const start = self.loc();
        _ = self.expect(.t_for);
        _ = self.expectOrError(.t_open_paren, "expected '('");

        // Check for for-in/for-of
        const has_await = self.expect(.t_await);
        _ = has_await;

        // Init
        var init: ?Stmt.ForInit = null;
        var kind: Stmt.VarDecl.Kind = .k_var;

        if (self.token() == .t_var or self.token() == .t_let or self.token() == .t_const) {
            kind = switch (self.token()) {
                .t_var => .k_var,
                .t_let => .k_let,
                .t_const => .k_const,
                else => .k_var,
            };
            self.advance();
            const binding = self.parseBinding();

            // Check for in/of
            if (self.token() == .t_in) {
                self.advance();
                const target = self.create(Expr, self.parseExpr());
                _ = self.expectOrError(.t_close_paren, "expected ')'");
                const body = self.create(Stmt, self.parseStmt());
                const for_in = self.create(Stmt.ForIn, .{
                    .kind = kind,
                    .binding = binding,
                    .value = null,
                    .target = target,
                    .body = body,
                });
                return Stmt.init(.{ .s_for_in = for_in }, start);
            }
            if (self.token() == .t_of or (self.token() == .t_identifier and std.mem.eql(u8, self.slice(), "of"))) {
                self.advance();
                const target = self.create(Expr, self.parseExpr());
                _ = self.expectOrError(.t_close_paren, "expected ')'");
                const body = self.create(Stmt, self.parseStmt());
                const for_of = self.create(Stmt.ForOf, .{
                    .kind = kind,
                    .binding = binding,
                    .value = null,
                    .target = target,
                    .body = body,
                    .is_await = has_await,
                });
                return Stmt.init(.{ .s_for_of = for_of }, start);
            }

            // Regular for with var decl
            var decls = std.ArrayList(Stmt.Decl).init(self.allocator);
            var value: ?*Expr = null;
            if (self.expect(.t_equals)) {
                value = self.create(Expr, self.parseExprWithPrec(2));
            }
            decls.append(.{ .binding = binding, .value = value }) catch {};
            while (self.expect(.t_comma)) {
                const b = self.parseBinding();
                var v: ?*Expr = null;
                if (self.expect(.t_equals)) {
                    v = self.create(Expr, self.parseExprWithPrec(2));
                }
                decls.append(.{ .binding = b, .value = v }) catch {};
            }
            init = .{ .decl = self.create(Stmt.VarDecl, .{
                .kind = kind,
                .decls = decls.toOwnedSlice() catch &[_]Stmt.Decl{},
            }) };
        } else if (self.token() != .t_semicolon) {
            init = .{ .expr = self.create(Expr, self.parseExpr()) };
        }

        _ = self.expectOrError(.t_semicolon, "expected ';'");
        var test: ?*Expr = null;
        if (self.token() != .t_semicolon) {
            test = self.create(Expr, self.parseExpr());
        }
        _ = self.expectOrError(.t_semicolon, "expected ';'");
        var update: ?*Expr = null;
        if (self.token() != .t_close_paren) {
            update = self.create(Expr, self.parseExpr());
        }
        _ = self.expectOrError(.t_close_paren, "expected ')'");
        const body = self.create(Stmt, self.parseStmt());

        const for_stmt = self.create(Stmt.For, .{
            .init = init,
            .test = test,
            .update = update,
            .body = body,
        });
        return Stmt.init(.{ .s_for = for_stmt }, start);
    }

    fn parseWhileStmt(self: *Parser) Stmt {
        const start = self.loc();
        _ = self.expect(.t_while);
        _ = self.expectOrError(.t_open_paren, "expected '('");
        const test_expr = self.create(Expr, self.parseExpr());
        _ = self.expectOrError(.t_close_paren, "expected ')'");
        const body = self.create(Stmt, self.parseStmt());
        const while_stmt = self.create(Stmt.While, .{
            .test = test_expr,
            .body = body,
        });
        return Stmt.init(.{ .s_while = while_stmt }, start);
    }

    fn parseDoWhileStmt(self: *Parser) Stmt {
        const start = self.loc();
        _ = self.expect(.t_do);
        const body = self.create(Stmt, self.parseStmt());
        _ = self.expectOrError(.t_while, "expected 'while'");
        _ = self.expectOrError(.t_open_paren, "expected '('");
        const test_expr = self.create(Expr, self.parseExpr());
        _ = self.expectOrError(.t_close_paren, "expected ')'");
        _ = self.expect(.t_semicolon);
        const do_while = self.create(Stmt.DoWhile, .{
            .body = body,
            .test = test_expr,
        });
        return Stmt.init(.{ .s_do_while = do_while }, start);
    }

    fn parseTryStmt(self: *Parser) Stmt {
        const start = self.loc();
        _ = self.expect(.t_try);
        const body = self.parseBlock();

        var catch_binding: ?Binding = null;
        var catch_body: ?[]Stmt = null;
        if (self.expect(.t_catch)) {
            if (self.expect(.t_open_paren)) {
                catch_binding = self.parseBinding();
                _ = self.expectOrError(.t_close_paren, "expected ')'");
            }
            catch_body = self.parseBlock();
        }

        var finally_body: ?[]Stmt = null;
        if (self.expect(.t_finally)) {
            finally_body = self.parseBlock();
        }

        const try_stmt = self.create(Stmt.Try, .{
            .body = body,
            .catch_binding = catch_binding,
            .catch_body = catch_body,
            .finally_body = finally_body,
        });
        return Stmt.init(.{ .s_try = try_stmt }, start);
    }

    fn parseFunctionStmt(self: *Parser, is_async: bool) Stmt {
        const start = self.loc();
        _ = self.expect(.t_function);

        const is_generator = self.expect(.t_asterisk);

        const name = self.slice();
        if (!self.expect(.t_identifier)) {
            self.addError("expected function name", self.loc());
        }

        _ = self.expectOrError(.t_open_paren, "expected '('");
        const params = self.parseParams();
        _ = self.expectOrError(.t_close_paren, "expected ')'");

        const body = self.parseBlock();

        const func_decl = self.create(Stmt.FunctionDecl, .{
            .name = name,
            .func = .{
                .name = name,
                .params = params,
                .body = body,
                .is_async = is_async,
                .is_generator = is_generator,
            },
        });
        return Stmt.init(.{ .s_function = func_decl }, start);
    }

    fn parseClassStmt(self: *Parser) Stmt {
        const start = self.loc();
        _ = self.expect(.t_class);

        const name = self.slice();
        if (!self.expect(.t_identifier)) {
            self.addError("expected class name", self.loc());
        }

        var extends: ?*Expr = null;
        if (self.expect(.t_extends)) {
            extends = self.create(Expr, self.parseExprWithPrec(18));
        }

        _ = self.expectOrError(.t_open_brace, "expected '{'");
        const members = self.parseClassMembers();
        _ = self.expectOrError(.t_close_brace, "expected '}'");

        const class_decl = self.create(Stmt.ClassDecl, .{
            .name = name,
            .class = .{
                .name = name,
                .extends = extends,
                .members = members,
            },
        });
        return Stmt.init(.{ .s_class = class_decl }, start);
    }

    fn parseImportStmt(self: *Parser) Stmt {
        const start = self.loc();
        _ = self.expect(.t_import);

        var default_name: ?[]const u8 = null;
        var namespace: ?[]const u8 = null;
        var items = std.ArrayList(Stmt.ImportItem).init(self.allocator);

        // import "path"
        if (self.token() == .t_string_literal) {
            const path = self.slice();
            self.advance();
            _ = self.expect(.t_semicolon);
            const import_stmt = self.create(Stmt.Import, .{
                .default = null,
                .namespace = null,
                .items = &[_]Stmt.ImportItem{},
                .path = path,
            });
            return Stmt.init(.{ .s_import = import_stmt }, start);
        }

        // Default import
        if (self.token() == .t_identifier) {
            default_name = self.slice();
            self.advance();

            if (self.expect(.t_comma)) {
                // Continue to namespace or named
            } else if (self.token() == .t_from or (self.token() == .t_identifier and std.mem.eql(u8, self.slice(), "from"))) {
                self.advance();
                const path = self.slice();
                _ = self.expect(.t_string_literal);
                _ = self.expect(.t_semicolon);
                const import_stmt = self.create(Stmt.Import, .{
                    .default = default_name,
                    .namespace = null,
                    .items = &[_]Stmt.ImportItem{},
                    .path = path,
                });
                return Stmt.init(.{ .s_import = import_stmt }, start);
            }
        }

        // Namespace import: * as name
        if (self.expect(.t_asterisk)) {
            if (self.expect(.t_as)) {
                namespace = self.slice();
                _ = self.expect(.t_identifier);
            }
        }

        // Named imports: { a, b as c }
        if (self.expect(.t_open_brace)) {
            while (self.token() != .t_close_brace and self.token() != .t_end_of_file) {
                const item_name = self.slice();
                self.advance();
                var alias: ?[]const u8 = null;
                if (self.expect(.t_as)) {
                    alias = self.slice();
                    self.advance();
                }
                items.append(.{ .name = item_name, .alias = alias }) catch {};
                if (!self.expect(.t_comma)) break;
            }
            _ = self.expectOrError(.t_close_brace, "expected '}'");
        }

        // from "path"
        if (self.token() == .t_from or (self.token() == .t_identifier and std.mem.eql(u8, self.slice(), "from"))) {
            self.advance();
        }
        const path = self.slice();
        _ = self.expect(.t_string_literal);
        _ = self.expect(.t_semicolon);

        const import_stmt = self.create(Stmt.Import, .{
            .default = default_name,
            .namespace = namespace,
            .items = items.toOwnedSlice() catch &[_]Stmt.ImportItem{},
            .path = path,
        });
        return Stmt.init(.{ .s_import = import_stmt }, start);
    }

    fn parseExportStmt(self: *Parser) Stmt {
        const start = self.loc();
        _ = self.expect(.t_export);

        // export default
        if (self.expect(.t_default)) {
            const value: Stmt.ExportDefaultValue = switch (self.token()) {
                .t_function => .{ .func = b: {
                    const func = self.parseFunctionStmt(false);
                    break :b func.data.s_function;
                } },
                .t_class => .{ .class = b: {
                    const cls = self.parseClassStmt();
                    break :b cls.data.s_class;
                } },
                else => .{ .expr = self.create(Expr, self.parseExpr()) },
            };
            _ = self.expect(.t_semicolon);
            const export_default = self.create(Stmt.ExportDefault, .{ .value = value });
            return Stmt.init(.{ .s_export_default = export_default }, start);
        }

        // export { ... }
        if (self.expect(.t_open_brace)) {
            var items = std.ArrayList(Stmt.ExportItem).init(self.allocator);
            while (self.token() != .t_close_brace and self.token() != .t_end_of_file) {
                const item_name = self.slice();
                self.advance();
                var alias: ?[]const u8 = null;
                if (self.expect(.t_as)) {
                    alias = self.slice();
                    self.advance();
                }
                items.append(.{ .name = item_name, .alias = alias }) catch {};
                if (!self.expect(.t_comma)) break;
            }
            _ = self.expectOrError(.t_close_brace, "expected '}'");

            var from_path: ?[]const u8 = null;
            if (self.token() == .t_from or (self.token() == .t_identifier and std.mem.eql(u8, self.slice(), "from"))) {
                self.advance();
                from_path = self.slice();
                _ = self.expect(.t_string_literal);
            }
            _ = self.expect(.t_semicolon);

            const export_stmt = self.create(Stmt.Export, .{
                .items = items.toOwnedSlice() catch &[_]Stmt.ExportItem{},
                .from_path = from_path,
            });
            return Stmt.init(.{ .s_export = export_stmt }, start);
        }

        // export * from "..."
        if (self.expect(.t_asterisk)) {
            if (self.token() == .t_from or (self.token() == .t_identifier and std.mem.eql(u8, self.slice(), "from"))) {
                self.advance();
            }
            const from_path = self.slice();
            _ = self.expect(.t_string_literal);
            _ = self.expect(.t_semicolon);
            const export_stmt = self.create(Stmt.Export, .{
                .items = &[_]Stmt.ExportItem{},
                .from_path = from_path,
            });
            return Stmt.init(.{ .s_export = export_stmt }, start);
        }

        // export var/let/const/function/class
        const decl = self.parseStmt();
        return decl; // The statement already handles itself
    }

    // ========== Program Parsing ==========

    pub fn parseProgram(self: *Parser) ast.Program {
        var stmts = std.ArrayList(Stmt).init(self.allocator);

        while (self.token() != .t_end_of_file) {
            stmts.append(self.parseStmt()) catch {};
        }

        return .{
            .stmts = stmts.toOwnedSlice() catch &[_]Stmt{},
            .source = self.lexer.source,
        };
    }
};

// Tests
test "parser - literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "42");
    const expr = parser.parseExpr();
    try std.testing.expectEqual(Expr.Data.e_number, std.meta.activeTag(expr.data));
}

test "parser - binary expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "1 + 2 * 3");
    const expr = parser.parseExpr();
    // Should be: 1 + (2 * 3) due to precedence
    try std.testing.expectEqual(Expr.Data.e_binary, std.meta.activeTag(expr.data));
    try std.testing.expectEqual(BinaryOp.add, expr.data.e_binary.op);
}

test "parser - function call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "foo(1, 2)");
    const expr = parser.parseExpr();
    try std.testing.expectEqual(Expr.Data.e_call, std.meta.activeTag(expr.data));
}

test "parser - arrow function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "(x) => x + 1");
    const expr = parser.parseExpr();
    try std.testing.expectEqual(Expr.Data.e_arrow, std.meta.activeTag(expr.data));
}

test "parser - var statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "let x = 42;");
    const stmt = parser.parseStmt();
    try std.testing.expectEqual(Stmt.Data.s_var, std.meta.activeTag(stmt.data));
}

test "parser - if statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "if (x) { y; } else { z; }");
    const stmt = parser.parseStmt();
    try std.testing.expectEqual(Stmt.Data.s_if, std.meta.activeTag(stmt.data));
}

test "parser - program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
        \\const x = 1;
        \\function add(a, b) {
        \\    return a + b;
        \\}
    );
    const program = parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), program.stmts.len);
}

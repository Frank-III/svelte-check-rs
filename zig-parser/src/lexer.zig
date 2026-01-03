const std = @import("std");
const tables = @import("js_lexer_tables.zig");

pub const T = tables.T;
pub const Keywords = tables.Keywords;

pub const Loc = struct {
    start: u32,
    end: u32,

    pub fn slice(self: Loc, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

pub const Token = struct {
    tag: T,
    loc: Loc,
};

pub const Lexer = struct {
    source: []const u8,
    index: u32,
    token: Token,
    line: u32,
    line_start: u32,

    pub fn init(source: []const u8) Lexer {
        var self = Lexer{
            .source = source,
            .index = 0,
            .token = .{
                .tag = .t_end_of_file,
                .loc = .{ .start = 0, .end = 0 },
            },
            .line = 1,
            .line_start = 0,
        };
        self.advance();
        return self;
    }

    pub fn advance(self: *Lexer) void {
        self.skipWhitespaceAndComments();

        const start = self.index;

        if (self.index >= self.source.len) {
            self.token = .{
                .tag = .t_end_of_file,
                .loc = .{ .start = start, .end = start },
            };
            return;
        }

        const c = self.source[self.index];

        self.token = switch (c) {
            'a'...'z', 'A'...'Z', '_', '$' => self.scanIdentifierOrKeyword(),
            '0'...'9' => self.scanNumber(),
            '"', '\'' => self.scanString(),
            '`' => self.scanTemplateLiteral(),
            '#' => self.scanPrivateIdentifier(),
            '{' => self.singleChar(.t_open_brace),
            '}' => self.singleChar(.t_close_brace),
            '(' => self.singleChar(.t_open_paren),
            ')' => self.singleChar(.t_close_paren),
            '[' => self.singleChar(.t_open_bracket),
            ']' => self.singleChar(.t_close_bracket),
            ';' => self.singleChar(.t_semicolon),
            ',' => self.singleChar(.t_comma),
            ':' => self.singleChar(.t_colon),
            '~' => self.singleChar(.t_tilde),
            '@' => self.singleChar(.t_at),
            '.' => self.scanDot(),
            '+' => self.scanPlus(),
            '-' => self.scanMinus(),
            '*' => self.scanAsterisk(),
            '/' => self.scanSlash(),
            '%' => self.scanPercent(),
            '=' => self.scanEquals(),
            '!' => self.scanExclamation(),
            '<' => self.scanLessThan(),
            '>' => self.scanGreaterThan(),
            '&' => self.scanAmpersand(),
            '|' => self.scanBar(),
            '^' => self.scanCaret(),
            '?' => self.scanQuestion(),
            else => blk: {
                self.index += 1;
                break :blk Token{
                    .tag = .t_syntax_error,
                    .loc = .{ .start = start, .end = self.index },
                };
            },
        };
    }

    fn singleChar(self: *Lexer, tag: T) Token {
        const start = self.index;
        self.index += 1;
        return Token{
            .tag = tag,
            .loc = .{ .start = start, .end = self.index },
        };
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            switch (c) {
                ' ', '\t', '\r' => self.index += 1,
                '\n' => {
                    self.index += 1;
                    self.line += 1;
                    self.line_start = self.index;
                },
                '/' => {
                    if (self.index + 1 < self.source.len) {
                        const next = self.source[self.index + 1];
                        if (next == '/') {
                            self.index += 2;
                            while (self.index < self.source.len and self.source[self.index] != '\n') {
                                self.index += 1;
                            }
                        } else if (next == '*') {
                            self.index += 2;
                            while (self.index + 1 < self.source.len) {
                                if (self.source[self.index] == '\n') {
                                    self.line += 1;
                                    self.line_start = self.index + 1;
                                }
                                if (self.source[self.index] == '*' and self.source[self.index + 1] == '/') {
                                    self.index += 2;
                                    break;
                                }
                                self.index += 1;
                            }
                        } else {
                            return;
                        }
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn scanIdentifierOrKeyword(self: *Lexer) Token {
        const start = self.index;
        self.index += 1;

        while (self.index < self.source.len) {
            const c = self.source[self.index];
            switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '$' => self.index += 1,
                else => break,
            }
        }

        const text = self.source[start..self.index];
        const tag = Keywords.get(text) orelse .t_identifier;

        return Token{
            .tag = tag,
            .loc = .{ .start = start, .end = self.index },
        };
    }

    fn scanPrivateIdentifier(self: *Lexer) Token {
        const start = self.index;
        self.index += 1; // Skip #

        while (self.index < self.source.len) {
            const c = self.source[self.index];
            switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '$' => self.index += 1,
                else => break,
            }
        }

        return Token{
            .tag = .t_private_identifier,
            .loc = .{ .start = start, .end = self.index },
        };
    }

    fn scanNumber(self: *Lexer) Token {
        const start = self.index;

        // Check for hex, octal, binary
        if (self.source[self.index] == '0' and self.index + 1 < self.source.len) {
            const next = self.source[self.index + 1];
            if (next == 'x' or next == 'X') {
                self.index += 2;
                while (self.index < self.source.len) {
                    const c = self.source[self.index];
                    switch (c) {
                        '0'...'9', 'a'...'f', 'A'...'F', '_' => self.index += 1,
                        else => break,
                    }
                }
                return self.checkBigInt(start);
            } else if (next == 'o' or next == 'O') {
                self.index += 2;
                while (self.index < self.source.len) {
                    const c = self.source[self.index];
                    switch (c) {
                        '0'...'7', '_' => self.index += 1,
                        else => break,
                    }
                }
                return self.checkBigInt(start);
            } else if (next == 'b' or next == 'B') {
                self.index += 2;
                while (self.index < self.source.len) {
                    const c = self.source[self.index];
                    switch (c) {
                        '0', '1', '_' => self.index += 1,
                        else => break,
                    }
                }
                return self.checkBigInt(start);
            }
        }

        // Decimal
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            switch (c) {
                '0'...'9', '_' => self.index += 1,
                else => break,
            }
        }

        // Decimal point
        if (self.index < self.source.len and self.source[self.index] == '.') {
            if (self.index + 1 < self.source.len) {
                const next = self.source[self.index + 1];
                if (next >= '0' and next <= '9') {
                    self.index += 1;
                    while (self.index < self.source.len) {
                        const c = self.source[self.index];
                        switch (c) {
                            '0'...'9', '_' => self.index += 1,
                            else => break,
                        }
                    }
                }
            }
        }

        // Exponent
        if (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == 'e' or c == 'E') {
                self.index += 1;
                if (self.index < self.source.len) {
                    const sign = self.source[self.index];
                    if (sign == '+' or sign == '-') {
                        self.index += 1;
                    }
                }
                while (self.index < self.source.len) {
                    const d = self.source[self.index];
                    switch (d) {
                        '0'...'9', '_' => self.index += 1,
                        else => break,
                    }
                }
            }
        }

        return self.checkBigInt(start);
    }

    fn checkBigInt(self: *Lexer, start: u32) Token {
        if (self.index < self.source.len and self.source[self.index] == 'n') {
            self.index += 1;
            return Token{
                .tag = .t_big_integer_literal,
                .loc = .{ .start = start, .end = self.index },
            };
        }
        return Token{
            .tag = .t_numeric_literal,
            .loc = .{ .start = start, .end = self.index },
        };
    }

    fn scanString(self: *Lexer) Token {
        const start = self.index;
        const quote = self.source[self.index];
        self.index += 1;

        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == quote) {
                self.index += 1;
                break;
            } else if (c == '\\' and self.index + 1 < self.source.len) {
                self.index += 2;
            } else if (c == '\n' or c == '\r') {
                break; // Unterminated string
            } else {
                self.index += 1;
            }
        }

        return Token{
            .tag = .t_string_literal,
            .loc = .{ .start = start, .end = self.index },
        };
    }

    fn scanTemplateLiteral(self: *Lexer) Token {
        const start = self.index;
        self.index += 1; // Skip opening backtick

        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == '`') {
                self.index += 1;
                return Token{
                    .tag = .t_no_substitution_template_literal,
                    .loc = .{ .start = start, .end = self.index },
                };
            } else if (c == '\\' and self.index + 1 < self.source.len) {
                self.index += 2;
            } else if (c == '$' and self.index + 1 < self.source.len and self.source[self.index + 1] == '{') {
                self.index += 2;
                return Token{
                    .tag = .t_template_head,
                    .loc = .{ .start = start, .end = self.index },
                };
            } else {
                if (c == '\n') {
                    self.line += 1;
                    self.line_start = self.index + 1;
                }
                self.index += 1;
            }
        }

        return Token{
            .tag = .t_no_substitution_template_literal,
            .loc = .{ .start = start, .end = self.index },
        };
    }

    fn scanDot(self: *Lexer) Token {
        const start = self.index;
        self.index += 1;

        if (self.index + 1 < self.source.len and
            self.source[self.index] == '.' and
            self.source[self.index + 1] == '.')
        {
            self.index += 2;
            return Token{ .tag = .t_dot_dot_dot, .loc = .{ .start = start, .end = self.index } };
        }

        // Check for number starting with .
        if (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c >= '0' and c <= '9') {
                // It's a number like .5
                while (self.index < self.source.len) {
                    const d = self.source[self.index];
                    switch (d) {
                        '0'...'9', '_' => self.index += 1,
                        else => break,
                    }
                }
                return Token{ .tag = .t_numeric_literal, .loc = .{ .start = start, .end = self.index } };
            }
        }

        return Token{ .tag = .t_dot, .loc = .{ .start = start, .end = self.index } };
    }

    fn scanPlus(self: *Lexer) Token {
        const start = self.index;
        self.index += 1;

        if (self.index < self.source.len) {
            switch (self.source[self.index]) {
                '+' => {
                    self.index += 1;
                    return Token{ .tag = .t_plus_plus, .loc = .{ .start = start, .end = self.index } };
                },
                '=' => {
                    self.index += 1;
                    return Token{ .tag = .t_plus_equals, .loc = .{ .start = start, .end = self.index } };
                },
                else => {},
            }
        }

        return Token{ .tag = .t_plus, .loc = .{ .start = start, .end = self.index } };
    }

    fn scanMinus(self: *Lexer) Token {
        const start = self.index;
        self.index += 1;

        if (self.index < self.source.len) {
            switch (self.source[self.index]) {
                '-' => {
                    self.index += 1;
                    return Token{ .tag = .t_minus_minus, .loc = .{ .start = start, .end = self.index } };
                },
                '=' => {
                    self.index += 1;
                    return Token{ .tag = .t_minus_equals, .loc = .{ .start = start, .end = self.index } };
                },
                else => {},
            }
        }

        return Token{ .tag = .t_minus, .loc = .{ .start = start, .end = self.index } };
    }

    fn scanAsterisk(self: *Lexer) Token {
        const start = self.index;
        self.index += 1;

        if (self.index < self.source.len) {
            if (self.source[self.index] == '*') {
                self.index += 1;
                if (self.index < self.source.len and self.source[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .t_asterisk_asterisk_equals, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .t_asterisk_asterisk, .loc = .{ .start = start, .end = self.index } };
            } else if (self.source[self.index] == '=') {
                self.index += 1;
                return Token{ .tag = .t_asterisk_equals, .loc = .{ .start = start, .end = self.index } };
            }
        }

        return Token{ .tag = .t_asterisk, .loc = .{ .start = start, .end = self.index } };
    }

    fn scanSlash(self: *Lexer) Token {
        const start = self.index;
        self.index += 1;

        if (self.index < self.source.len and self.source[self.index] == '=') {
            self.index += 1;
            return Token{ .tag = .t_slash_equals, .loc = .{ .start = start, .end = self.index } };
        }

        return Token{ .tag = .t_slash, .loc = .{ .start = start, .end = self.index } };
    }

    fn scanPercent(self: *Lexer) Token {
        const start = self.index;
        self.index += 1;

        if (self.index < self.source.len and self.source[self.index] == '=') {
            self.index += 1;
            return Token{ .tag = .t_percent_equals, .loc = .{ .start = start, .end = self.index } };
        }

        return Token{ .tag = .t_percent, .loc = .{ .start = start, .end = self.index } };
    }

    fn scanEquals(self: *Lexer) Token {
        const start = self.index;
        self.index += 1;

        if (self.index < self.source.len) {
            if (self.source[self.index] == '=') {
                self.index += 1;
                if (self.index < self.source.len and self.source[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .t_equals_equals_equals, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .t_equals_equals, .loc = .{ .start = start, .end = self.index } };
            } else if (self.source[self.index] == '>') {
                self.index += 1;
                return Token{ .tag = .t_equals_greater_than, .loc = .{ .start = start, .end = self.index } };
            }
        }

        return Token{ .tag = .t_equals, .loc = .{ .start = start, .end = self.index } };
    }

    fn scanExclamation(self: *Lexer) Token {
        const start = self.index;
        self.index += 1;

        if (self.index < self.source.len and self.source[self.index] == '=') {
            self.index += 1;
            if (self.index < self.source.len and self.source[self.index] == '=') {
                self.index += 1;
                return Token{ .tag = .t_exclamation_equals_equals, .loc = .{ .start = start, .end = self.index } };
            }
            return Token{ .tag = .t_exclamation_equals, .loc = .{ .start = start, .end = self.index } };
        }

        return Token{ .tag = .t_exclamation, .loc = .{ .start = start, .end = self.index } };
    }

    fn scanLessThan(self: *Lexer) Token {
        const start = self.index;
        self.index += 1;

        if (self.index < self.source.len) {
            if (self.source[self.index] == '<') {
                self.index += 1;
                if (self.index < self.source.len and self.source[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .t_less_than_less_than_equals, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .t_less_than_less_than, .loc = .{ .start = start, .end = self.index } };
            } else if (self.source[self.index] == '=') {
                self.index += 1;
                return Token{ .tag = .t_less_than_equals, .loc = .{ .start = start, .end = self.index } };
            }
        }

        return Token{ .tag = .t_less_than, .loc = .{ .start = start, .end = self.index } };
    }

    fn scanGreaterThan(self: *Lexer) Token {
        const start = self.index;
        self.index += 1;

        if (self.index < self.source.len) {
            if (self.source[self.index] == '>') {
                self.index += 1;
                if (self.index < self.source.len) {
                    if (self.source[self.index] == '>') {
                        self.index += 1;
                        if (self.index < self.source.len and self.source[self.index] == '=') {
                            self.index += 1;
                            return Token{ .tag = .t_greater_than_greater_than_greater_than_equals, .loc = .{ .start = start, .end = self.index } };
                        }
                        return Token{ .tag = .t_greater_than_greater_than_greater_than, .loc = .{ .start = start, .end = self.index } };
                    } else if (self.source[self.index] == '=') {
                        self.index += 1;
                        return Token{ .tag = .t_greater_than_greater_than_equals, .loc = .{ .start = start, .end = self.index } };
                    }
                }
                return Token{ .tag = .t_greater_than_greater_than, .loc = .{ .start = start, .end = self.index } };
            } else if (self.source[self.index] == '=') {
                self.index += 1;
                return Token{ .tag = .t_greater_than_equals, .loc = .{ .start = start, .end = self.index } };
            }
        }

        return Token{ .tag = .t_greater_than, .loc = .{ .start = start, .end = self.index } };
    }

    fn scanAmpersand(self: *Lexer) Token {
        const start = self.index;
        self.index += 1;

        if (self.index < self.source.len) {
            if (self.source[self.index] == '&') {
                self.index += 1;
                if (self.index < self.source.len and self.source[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .t_ampersand_ampersand_equals, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .t_ampersand_ampersand, .loc = .{ .start = start, .end = self.index } };
            } else if (self.source[self.index] == '=') {
                self.index += 1;
                return Token{ .tag = .t_ampersand_equals, .loc = .{ .start = start, .end = self.index } };
            }
        }

        return Token{ .tag = .t_ampersand, .loc = .{ .start = start, .end = self.index } };
    }

    fn scanBar(self: *Lexer) Token {
        const start = self.index;
        self.index += 1;

        if (self.index < self.source.len) {
            if (self.source[self.index] == '|') {
                self.index += 1;
                if (self.index < self.source.len and self.source[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .t_bar_bar_equals, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .t_bar_bar, .loc = .{ .start = start, .end = self.index } };
            } else if (self.source[self.index] == '=') {
                self.index += 1;
                return Token{ .tag = .t_bar_equals, .loc = .{ .start = start, .end = self.index } };
            }
        }

        return Token{ .tag = .t_bar, .loc = .{ .start = start, .end = self.index } };
    }

    fn scanCaret(self: *Lexer) Token {
        const start = self.index;
        self.index += 1;

        if (self.index < self.source.len and self.source[self.index] == '=') {
            self.index += 1;
            return Token{ .tag = .t_caret_equals, .loc = .{ .start = start, .end = self.index } };
        }

        return Token{ .tag = .t_caret, .loc = .{ .start = start, .end = self.index } };
    }

    fn scanQuestion(self: *Lexer) Token {
        const start = self.index;
        self.index += 1;

        if (self.index < self.source.len) {
            if (self.source[self.index] == '?') {
                self.index += 1;
                if (self.index < self.source.len and self.source[self.index] == '=') {
                    self.index += 1;
                    return Token{ .tag = .t_question_question_equals, .loc = .{ .start = start, .end = self.index } };
                }
                return Token{ .tag = .t_question_question, .loc = .{ .start = start, .end = self.index } };
            } else if (self.source[self.index] == '.') {
                if (self.index + 1 < self.source.len) {
                    const next = self.source[self.index + 1];
                    if (next < '0' or next > '9') {
                        self.index += 1;
                        return Token{ .tag = .t_question_dot, .loc = .{ .start = start, .end = self.index } };
                    }
                }
            }
        }

        return Token{ .tag = .t_question, .loc = .{ .start = start, .end = self.index } };
    }

    // Utility methods
    pub fn slice(self: *const Lexer) []const u8 {
        return self.token.loc.slice(self.source);
    }

    pub fn expect(self: *Lexer, tag: T) bool {
        if (self.token.tag == tag) {
            self.advance();
            return true;
        }
        return false;
    }
};

// Tests
test "lexer basics" {
    var lex = Lexer.init("let x = 42;");

    try std.testing.expectEqual(T.t_let, lex.token.tag);
    lex.advance();
    try std.testing.expectEqual(T.t_identifier, lex.token.tag);
    try std.testing.expectEqualStrings("x", lex.slice());
    lex.advance();
    try std.testing.expectEqual(T.t_equals, lex.token.tag);
    lex.advance();
    try std.testing.expectEqual(T.t_numeric_literal, lex.token.tag);
    try std.testing.expectEqualStrings("42", lex.slice());
    lex.advance();
    try std.testing.expectEqual(T.t_semicolon, lex.token.tag);
    lex.advance();
    try std.testing.expectEqual(T.t_end_of_file, lex.token.tag);
}

test "lexer operators" {
    var lex = Lexer.init("a === b !== c");

    try std.testing.expectEqual(T.t_identifier, lex.token.tag);
    lex.advance();
    try std.testing.expectEqual(T.t_equals_equals_equals, lex.token.tag);
    lex.advance();
    try std.testing.expectEqual(T.t_identifier, lex.token.tag);
    lex.advance();
    try std.testing.expectEqual(T.t_exclamation_equals_equals, lex.token.tag);
}

test "lexer strings" {
    var lex = Lexer.init("\"hello\" 'world'");

    try std.testing.expectEqual(T.t_string_literal, lex.token.tag);
    try std.testing.expectEqualStrings("\"hello\"", lex.slice());
    lex.advance();
    try std.testing.expectEqual(T.t_string_literal, lex.token.tag);
    try std.testing.expectEqualStrings("'world'", lex.slice());
}

test "lexer template literal" {
    var lex = Lexer.init("`hello`");
    try std.testing.expectEqual(T.t_no_substitution_template_literal, lex.token.tag);
}

test "lexer comments" {
    var lex = Lexer.init("a // comment\nb /* block */ c");

    try std.testing.expectEqual(T.t_identifier, lex.token.tag);
    try std.testing.expectEqualStrings("a", lex.slice());
    lex.advance();
    try std.testing.expectEqual(T.t_identifier, lex.token.tag);
    try std.testing.expectEqualStrings("b", lex.slice());
    lex.advance();
    try std.testing.expectEqual(T.t_identifier, lex.token.tag);
    try std.testing.expectEqualStrings("c", lex.slice());
}

test "lexer arrow function" {
    var lex = Lexer.init("(x) => x + 1");

    try std.testing.expectEqual(T.t_open_paren, lex.token.tag);
    lex.advance();
    try std.testing.expectEqual(T.t_identifier, lex.token.tag);
    lex.advance();
    try std.testing.expectEqual(T.t_close_paren, lex.token.tag);
    lex.advance();
    try std.testing.expectEqual(T.t_equals_greater_than, lex.token.tag);
}

test "lexer private identifier" {
    var lex = Lexer.init("#privateField");
    try std.testing.expectEqual(T.t_private_identifier, lex.token.tag);
    try std.testing.expectEqualStrings("#privateField", lex.slice());
}

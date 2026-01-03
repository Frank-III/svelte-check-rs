const std = @import("std");
const Allocator = std.mem.Allocator;

/// Source location
pub const Loc = struct {
    start: u32,
    end: u32,

    pub const empty = Loc{ .start = 0, .end = 0 };

    pub fn slice(self: Loc, source: []const u8) []const u8 {
        if (self.start >= source.len) return "";
        const e = @min(self.end, @as(u32, @intCast(source.len)));
        return source[self.start..e];
    }
};

/// Reference to a symbol
pub const Ref = struct {
    index: u32,
    source_index: u32 = 0,

    pub const none = Ref{ .index = std.math.maxInt(u32) };

    pub fn isNone(self: Ref) bool {
        return self.index == std.math.maxInt(u32);
    }
};

/// Binary operators
pub const BinaryOp = enum {
    // Arithmetic
    add,
    sub,
    mul,
    div,
    rem,
    pow,

    // Bitwise
    bitwise_and,
    bitwise_or,
    bitwise_xor,
    shl,
    shr,
    ushr,

    // Comparison
    lt,
    lte,
    gt,
    gte,
    eq,
    neq,
    strict_eq,
    strict_neq,

    // Logical
    logical_and,
    logical_or,
    nullish_coalesce,

    // Other
    in,
    instanceof,
    comma,

    pub fn precedence(self: BinaryOp) u8 {
        return switch (self) {
            .comma => 1,
            .logical_or, .nullish_coalesce => 4,
            .logical_and => 5,
            .bitwise_or => 6,
            .bitwise_xor => 7,
            .bitwise_and => 8,
            .eq, .neq, .strict_eq, .strict_neq => 9,
            .lt, .lte, .gt, .gte, .in, .instanceof => 10,
            .shl, .shr, .ushr => 11,
            .add, .sub => 12,
            .mul, .div, .rem => 13,
            .pow => 14,
        };
    }

    pub fn isRightAssociative(self: BinaryOp) bool {
        return self == .pow;
    }
};

/// Unary operators
pub const UnaryOp = enum {
    neg,
    pos,
    not,
    bitwise_not,
    typeof,
    void,
    delete,
    pre_inc,
    pre_dec,
    post_inc,
    post_dec,
};

/// Assignment operators
pub const AssignOp = enum {
    assign,
    add_assign,
    sub_assign,
    mul_assign,
    div_assign,
    rem_assign,
    pow_assign,
    shl_assign,
    shr_assign,
    ushr_assign,
    bitwise_and_assign,
    bitwise_or_assign,
    bitwise_xor_assign,
    logical_and_assign,
    logical_or_assign,
    nullish_assign,
};

/// Expression node
pub const Expr = struct {
    data: Data,
    loc: Loc,

    pub const Data = union(enum) {
        // Literals
        e_null,
        e_undefined,
        e_boolean: bool,
        e_number: f64,
        e_bigint: []const u8,
        e_string: []const u8,
        e_template: *Template,
        e_regex: *Regex,
        e_array: *Array,
        e_object: *Object,

        // Identifiers
        e_identifier: *Identifier,
        e_this,
        e_super,

        // Operators
        e_unary: *Unary,
        e_binary: *Binary,
        e_conditional: *Conditional,
        e_assign: *Assign,

        // Member access
        e_index: *Index,
        e_member: *Member,
        e_optional_chain: *OptionalChain,

        // Calls
        e_call: *Call,
        e_new: *New,

        // Functions
        e_function: *Function,
        e_arrow: *Arrow,
        e_class: *Class,

        // Other
        e_spread: *Expr,
        e_await: *Expr,
        e_yield: *Yield,
        e_paren: *Expr,
        e_sequence: []Expr,

        // JSX
        e_jsx_element: *JsxElement,

        // Error
        e_missing,
    };

    pub const Identifier = struct {
        name: []const u8,
        ref: Ref = Ref.none,
    };

    pub const Unary = struct {
        op: UnaryOp,
        operand: *Expr,
    };

    pub const Binary = struct {
        op: BinaryOp,
        left: *Expr,
        right: *Expr,
    };

    pub const Conditional = struct {
        test: *Expr,
        consequent: *Expr,
        alternate: *Expr,
    };

    pub const Assign = struct {
        op: AssignOp,
        target: *Expr,
        value: *Expr,
    };

    pub const Index = struct {
        target: *Expr,
        index: *Expr,
        optional: bool = false,
    };

    pub const Member = struct {
        target: *Expr,
        name: []const u8,
        optional: bool = false,
    };

    pub const OptionalChain = struct {
        expr: *Expr,
    };

    pub const Call = struct {
        target: *Expr,
        args: []Expr,
        optional: bool = false,
    };

    pub const New = struct {
        target: *Expr,
        args: []Expr,
    };

    pub const Array = struct {
        items: []Expr,
        has_spread: bool = false,
    };

    pub const Object = struct {
        properties: []Property,
    };

    pub const Property = struct {
        key: ?*Expr,
        value: ?*Expr,
        kind: Kind = .normal,
        computed: bool = false,
        shorthand: bool = false,
        method: bool = false,

        pub const Kind = enum {
            normal,
            get,
            set,
            spread,
        };
    };

    pub const Template = struct {
        tag: ?*Expr,
        parts: []TemplatePart,
    };

    pub const TemplatePart = struct {
        value: []const u8,
        expr: ?*Expr,
    };

    pub const Regex = struct {
        pattern: []const u8,
        flags: []const u8,
    };

    pub const Function = struct {
        name: ?[]const u8,
        params: []Binding,
        body: []Stmt,
        is_async: bool = false,
        is_generator: bool = false,
    };

    pub const Arrow = struct {
        params: []Binding,
        body: ArrowBody,
        is_async: bool = false,
    };

    pub const ArrowBody = union(enum) {
        expr: *Expr,
        block: []Stmt,
    };

    pub const Class = struct {
        name: ?[]const u8,
        extends: ?*Expr,
        members: []ClassMember,
    };

    pub const ClassMember = struct {
        key: *Expr,
        value: ?*Expr,
        kind: Kind,
        is_static: bool = false,
        computed: bool = false,

        pub const Kind = enum {
            field,
            method,
            getter,
            setter,
        };
    };

    pub const Yield = struct {
        value: ?*Expr,
        delegate: bool = false,
    };

    pub const JsxElement = struct {
        tag: *Expr,
        attrs: []JsxAttr,
        children: []Expr,
        self_closing: bool = false,
    };

    pub const JsxAttr = struct {
        name: []const u8,
        value: ?*Expr,
        spread: bool = false,
    };

    pub fn init(data: Data, loc: Loc) Expr {
        return .{ .data = data, .loc = loc };
    }
};

/// Binding (destructuring pattern)
pub const Binding = struct {
    data: Data,
    loc: Loc,

    pub const Data = union(enum) {
        b_identifier: []const u8,
        b_array: []ArrayItem,
        b_object: []ObjectItem,
    };

    pub const ArrayItem = struct {
        binding: Binding,
        default: ?*Expr = null,
    };

    pub const ObjectItem = struct {
        key: ?*Expr,
        value: Binding,
        default: ?*Expr = null,
        shorthand: bool = false,
        computed: bool = false,
    };
};

/// Statement node
pub const Stmt = struct {
    data: Data,
    loc: Loc,

    pub const Data = union(enum) {
        // Declarations
        s_var: *VarDecl,
        s_function: *FunctionDecl,
        s_class: *ClassDecl,

        // Control flow
        s_block: []Stmt,
        s_if: *If,
        s_switch: *Switch,
        s_for: *For,
        s_for_in: *ForIn,
        s_for_of: *ForOf,
        s_while: *While,
        s_do_while: *DoWhile,
        s_try: *Try,
        s_with: *With,

        // Jumps
        s_break: ?[]const u8,
        s_continue: ?[]const u8,
        s_return: ?*Expr,
        s_throw: *Expr,
        s_labeled: *Labeled,

        // Other
        s_expr: *Expr,
        s_empty,
        s_debugger,

        // Module
        s_import: *Import,
        s_export: *Export,
        s_export_default: *ExportDefault,
    };

    pub const VarDecl = struct {
        kind: Kind,
        decls: []Decl,

        pub const Kind = enum {
            k_var,
            k_let,
            k_const,
            k_using,
            k_await_using,
        };
    };

    pub const Decl = struct {
        binding: Binding,
        value: ?*Expr,
    };

    pub const FunctionDecl = struct {
        name: []const u8,
        func: Expr.Function,
    };

    pub const ClassDecl = struct {
        name: []const u8,
        class: Expr.Class,
    };

    pub const If = struct {
        test: *Expr,
        consequent: *Stmt,
        alternate: ?*Stmt,
    };

    pub const Switch = struct {
        test: *Expr,
        cases: []Case,
    };

    pub const Case = struct {
        test: ?*Expr, // null for default
        body: []Stmt,
    };

    pub const For = struct {
        init: ?ForInit,
        test: ?*Expr,
        update: ?*Expr,
        body: *Stmt,
    };

    pub const ForInit = union(enum) {
        expr: *Expr,
        decl: *VarDecl,
    };

    pub const ForIn = struct {
        kind: VarDecl.Kind,
        binding: Binding,
        value: ?*Expr,
        target: *Expr,
        body: *Stmt,
    };

    pub const ForOf = struct {
        kind: VarDecl.Kind,
        binding: Binding,
        value: ?*Expr,
        target: *Expr,
        body: *Stmt,
        is_await: bool = false,
    };

    pub const While = struct {
        test: *Expr,
        body: *Stmt,
    };

    pub const DoWhile = struct {
        body: *Stmt,
        test: *Expr,
    };

    pub const Try = struct {
        body: []Stmt,
        catch_binding: ?Binding,
        catch_body: ?[]Stmt,
        finally_body: ?[]Stmt,
    };

    pub const With = struct {
        object: *Expr,
        body: *Stmt,
    };

    pub const Labeled = struct {
        label: []const u8,
        stmt: *Stmt,
    };

    pub const Import = struct {
        default: ?[]const u8,
        namespace: ?[]const u8,
        items: []ImportItem,
        path: []const u8,
    };

    pub const ImportItem = struct {
        name: []const u8,
        alias: ?[]const u8,
    };

    pub const Export = struct {
        items: []ExportItem,
        from_path: ?[]const u8,
    };

    pub const ExportItem = struct {
        name: []const u8,
        alias: ?[]const u8,
    };

    pub const ExportDefault = struct {
        value: ExportDefaultValue,
    };

    pub const ExportDefaultValue = union(enum) {
        expr: *Expr,
        func: *FunctionDecl,
        class: *ClassDecl,
    };

    pub fn init(data: Data, loc: Loc) Stmt {
        return .{ .data = data, .loc = loc };
    }
};

/// Program (top-level)
pub const Program = struct {
    stmts: []Stmt,
    source: []const u8,
};

// Tests
test "ast types" {
    const loc = Loc{ .start = 0, .end = 5 };
    const expr = Expr.init(.e_null, loc);
    try std.testing.expectEqual(Loc{ .start = 0, .end = 5 }, expr.loc);
}

test "binary op precedence" {
    try std.testing.expect(BinaryOp.mul.precedence() > BinaryOp.add.precedence());
    try std.testing.expect(BinaryOp.add.precedence() > BinaryOp.eq.precedence());
    try std.testing.expect(BinaryOp.eq.precedence() > BinaryOp.logical_and.precedence());
}

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Lexer = @import("ast/Lexer.zig");
const Token = Lexer.Token;

pub const Parser = @import("ast/Parser.zig");

const Number = @import("vm/value/number.zig").Number;

// SOURCE FILE POSITIONS

pub const Pos = struct {
    raw: usize = 0,
    row: usize = 0,
    col: usize = 0,

    // Returns the position after this one.
    pub inline fn next(pos: Pos) Pos {
        return .{
            .raw = pos.raw + 1,
            .row = pos.row,
            .col = pos.col + 1,
        };
    }

    pub inline fn format(self: Pos, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try std.fmt.format(writer, "{}:{}", .{ self.row, self.col });
    }
};

pub const Span = struct { Pos, Pos };

// ABSTRACT SYNTAX TREE

// STATEMENTS
pub const BlockStatement = union(enum) {
    call: Call,
    function: Function,
    constant: Constant,
    variable: Variable,
    assignment: Assignment,
};

pub const Block = std.ArrayList(BlockStatement);

// OPERANDS

pub const LiteralOperand = union(enum) {
    null,
    undefined,
    bool: bool,
    char: u21,
    string: String,
    number: Number,

    const Self = @This();

    pub inline fn fromToken(token: Token) ?Self {
        return switch (token) {
            Token.null => Self.null,
            Token.undefined => Self.undefined,
            Token.bool => |b| .{ .bool = b },
            Token.char => |char| .{ .char = char },
            Token.string => |string| .{ .string = string.data },
            Token.number => |number| .{ .number = number },
            else => null,
        };
    }
};

pub const String = struct {
    text: []const u8 = "",
    managed: bool = false,
};

pub const Template = struct {
    strings: []String,
    exprs: []Expression,
};

pub const NonLiteralOperand = union(enum) {
    template: Template,
    identifier: []const u8,
    field_access: FieldAccess,
    index_access: IndexAccess,
    call: Call,

    const Self = @This();

    pub inline fn fromToken(token: Token) ?Self {
        return if (token == Token.identifier) .{ .identifier = token.identifier } else null;
    }
};

pub const Operand = union(enum) {
    literal: LiteralOperand,
    non_literal: NonLiteralOperand,

    const Self = @This();

    pub fn fromToken(token: Token) ?Self {
        if (LiteralOperand.fromToken(token)) |e| {
            return .{ .literal = e };
        } else if (NonLiteralOperand.fromToken(token)) |e| {
            return .{ .non_literal = e };
        } else return null;
    }
};

// EXPRESSIONS

pub const Expression = union(enum) {
    operation: *Operation,
    operand: *Operand,
    logical_not: *Expression,
    bitwise_not: *Expression,
};

// OPERATIONS

pub const Comparator = enum(u8) {
    // zig fmt: off
    eq, ne,
    gt, lt,
    gt_eq, lt_eq,
    // zig fmt: on

    pub inline fn toString(op: Operator) []const u8 {
        return switch (op) {
            .eq => "==",
            .ne => "!=",

            .gt => ">",
            .lt => "<",

            .gt_eq => ">=",
            .lt_eq => "<=",
        };
    }
};

pub const Chainer = enum(u8) { @"and", @"or" };

pub const Operator = enum(u8) {
    // zig fmt: off
    sum, sub,
    div, mul, mod,
    ls, rls, ras,
    bw_and, bw_or, bw_xor,
    // zig fmt: on

    const Self = @This();

    pub inline fn toString(op: Operator) []const u8 {
        return switch (op) {
            .sum => "+",
            .sub => "-",

            .div => "/",
            .mul => "*",
            .mod => "%",

            .ls => "<<",
            .rls => ">>",
            .ras => ">>>",

            .bw_and => "&",
            .bw_or => "|",
            .bw_xor => "^",
        };
    }

    pub inline fn fromSymbol(symbol: u8) ?Self {
        return switch (symbol) {
            '+' => .sum,
            '-' => .sub,
            '/' => .div,
            '*' => .mul,
            '%' => .mod,
            '&' => .bw_and,
            '|' => .bw_or,
            '^' => .bw_xor,
            else => null,
        };
    }
};

pub const Operation = struct {
    lhs: Expression,
    op: union(enum) {
        cmp: Comparator,
        math: Operator,
        chain: Chainer,
    },
    rhs: Expression,
};

// TYPES
pub const PointerType = struct {
    constant: bool = false,
    slice: bool = false,
    expression: *Type = undefined,
};

pub const ArrayType = struct {
    size: usize = 0,
    expression: *Type = undefined,
};

pub const Type = union(enum) {
    single: NonLiteralOperand,
    ptr: PointerType,
    array: ArrayType,
    func: FunctionType,
};

// CONSTANT DECLARATION
pub const Constant = struct {
    typ: ?Type = undefined,
    val: Expression = undefined,
    public: bool = false,
};

// VARIABLE DECLARATION
pub const Variable = struct {
    typ: ?Type = null,
    val: ?Expression = null,
    public: bool = false,
};

// VARIABLE ASSIGNMENT
pub const Assignment = struct {
    variable: NonLiteralOperand = undefined,
    operator: ?Operator = null,
    expression: Expression = undefined,
};

pub const IndexAccess = struct {
    object: *Operand = undefined,
    index: Expression = undefined,
};

// FUNCTIONS
pub const Parameters = std.StringArrayHashMap(?Type);

pub const FunctionType = struct {
    params: Parameters,
    typ: ?*Type = null,
};

pub const Function = struct {
    typ: FunctionType,
    body: Block,
};

pub const FunctionDefinition = struct {
    func: Function,
    name: []const u8 = "",
    public: bool = false,
};

pub const Call = struct {
    callee: *Operand = undefined,
    args: std.ArrayList(Expression) = undefined,
};

// OBJECTS
pub const ObjectStatement = union(enum) {
    function: Function,
    field: Field,
};

// OBJECTS - FIELDS
pub const FieldAccess = struct {
    object: *Operand = undefined,
    field: []const u8 = "",
};

pub const Field = struct {
    name: []const u8 = "",
    typ: Type = undefined,
    default: ?*Expression = null,
    public: bool = false,
};

// OBJECTS - STRUCT
pub const Struct = struct {
    fields: std.StringHashMap(Field),
    methods: std.StringHashMap(Function),
};

// OBJECTS - ENUM
pub const EnumOption = union(enum) {
    empty,
};

pub const Enum = struct {
    options: std.StringHashMap(EnumOption),
    methods: std.StringHashMap(Function),
};

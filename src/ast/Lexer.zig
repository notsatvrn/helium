const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const parseUnsigned = std.fmt.parseUnsigned;
const parseInt = std.fmt.parseInt;
const parseFloat = std.fmt.parseFloat;

const utftools = @import("utftools");
const code_point = @import("code_point");
const CodePoint = code_point.CodePoint;
const GenCatData = @import("GenCatData");

const Module = @import("../Module.zig");
const Logger = @import("../log.zig").Logger;
const NumberType = @import("../interp/value/number.zig").NumberType;
const BuiltinType = @import("../interp/type.zig").BuiltinType;

const util = @import("../util.zig");
const getOptional = util.getOptional;
const isNumberChar = util.isNumberChar;
const isHexadecimalChar = util.isHexadecimalChar;
const isLineSeparator = util.isLineSeparator;

const ast = @import("../ast.zig");
const Pos = ast.Pos;
const Span = ast.Span;

// A lexer token.
pub const Token = union(enum) {
    // values
    null,
    undefined,
    bool: bool,
    char: u21,
    number: Number,
    string: String,

    // other
    symbol: u21,
    keyword: Keyword,
    builtin_type: BuiltinType,
    identifier: []const u8,
    doc_comment: DocComment,

    pub const Number = struct {
        buf: []const u8 = "",
        base: u8 = 10,
        typ: ?NumberType = null,
    };

    pub const String = struct {
        buf: []const u8 = "",
        managed: bool = true,
    };

    // zig fmt: off
    pub const Keyword = enum {
        as, // casting

        @"and", @"or", // boolean operations

        throw,    // raise error
        @"try",   // try function which raises errors
        @"catch", // catch error
        assert,   // raise error if condition not true
                  // in a function which doesn't throw errors, this will crash the program!

        @"if",     // define conditional if statement
        @"else",   // define conditional else statement
        @"switch", // define switch statement

        @"pub",   // publicize declaration
        @"const", // declare constant variable
        @"var",   // declare mutable variable

        func,      // define function
        @"return", // return from function
        @"defer",  // execute statement when function returns
        ref,       // get reference to param instead of copying

        @"struct", // define struct
        @"enum",   // define enum
        @"union",  // define union
        interface, // define interface

        loop,        // define infinite loop
        @"while",    // define while loop
        @"for",      // define for loop
        @"break",    // loop break
        @"continue", // loop continue

        mod, // define a module
        use, // use a module

        pub const string_map = util.mkStringMap(Keyword);
    };
    // zig fmt: on

    pub const DocComment = struct {
        buf: []const u8 = "",
        top_level: bool = false,
    };

    // Convert from a word representing a token (if possible).
    pub fn fromWord(string: []const u8) ?Token {
        if (std.mem.eql(u8, string, "null")) return .null;
        if (std.mem.eql(u8, string, "undefined")) return .undefined;
        if (std.mem.eql(u8, string, "true")) return .{ .bool = true };
        if (std.mem.eql(u8, string, "false")) return .{ .bool = false };
        if (string.len > 0 and !isNumberChar(string[0])) {
            if (Keyword.string_map.get(string)) |kw| return .{ .keyword = kw };
            if (BuiltinType.string_map.get(string)) |t| return .{ .builtin_type = t };
            return .{ .identifier = string };
        } else return null;
    }

    // Write a token to a writer.
    pub fn write(self: Token, writer: anytype) !void {
        return switch (self) {
            .null => try writer.writeAll("null"),
            .undefined => try writer.writeAll("undefined"),
            .bool => |v| try writer.print("bool: {}", .{v}),
            .char => |v| {
                try writer.writeAll("char: '");
                try utftools.writeCodepointToUtf8(v, writer);
                try writer.writeByte('\'');
            },
            .number => |v| {
                try writer.print("number: {s} (base {})", .{ v.buf, v.base });
                if (v.typ) |t| try writer.print(" ({s})", .{@tagName(t)});
            },
            .string => |v| {
                try writer.print("string: \"{s}\"", .{v.buf});
                if (v.managed) try writer.writeAll(" (managed)");
            },

            .symbol => |v| {
                try writer.writeAll("symbol: ");
                try utftools.writeCodepointToUtf8(v, writer);
            },
            .keyword => |v| try writer.print("keyword: {s}", .{@tagName(v)}),
            .builtin_type => |v| try writer.print("built-in type: {s}", .{@tagName(v)}),
            .identifier => |v| try writer.print("identifier: {s}", .{v}),
            .doc_comment => |v| {
                try writer.print("doc comment: \"{s}\"", .{v.buf});
                if (v.top_level) try writer.writeAll(" (top-level)");
            },
        };
    }

    // Convert a token to string representation.
    pub inline fn toString(self: Token, allocator: Allocator) ![]const u8 {
        var arraylist = std.ArrayList(u8).init(allocator);
        try self.write(arraylist.writer());
        return arraylist.toOwnedSlice();
    }

    // Is the token the end of an expression or an expression itself?
    pub fn isExpression(self: Token) bool {
        return switch (self) {
            .symbol => |symbol| switch (symbol) {
                ')' => true, // End of function call or expression in parenthesis.
                else => false,
            },

            else => true,
        };
    }
};

pub const LocatedToken = struct {
    span: Span,
    token: Token,
};

pub const Tokens = std.ArrayList(LocatedToken);

pub fn deinitTokens(tokens: []LocatedToken, allocator: Allocator) void {
    for (tokens) |token|
        if (token.token == .string and token.token.string.managed)
            allocator.free(token.token.string.buf);

    allocator.free(tokens);
}

// Non-decimal representation characters in numbers.
inline fn numberBaseCharToBase(char: u21) ?u8 {
    return switch (char) {
        'b', 'B' => 2,
        'o', 'O' => 8,
        'x', 'X' => 16,
        else => null,
    };
}

// All valid symbols which mean there's a new token.
inline fn isSeparatingSymbol(char: u21) bool {
    return switch (char) {
        '&', // logical/bitwise and
        '|', // logical/bitwise or
        '!', // logical not
        '~', // bitwise not
        '^', // bitwise xor
        '<', // less than comparison operator / left shift
        '>', // greater than comparison operator / right shift
        '*', // reference / multiplication operator / comment
        '/', // division operator / comment
        '{', // open block / array
        '(', // open tuple / arguments
        '[', // open array slicer
        '}', // close block / array
        ')', // close tuple / arguments
        ']', // close array slicer
        ':', // explicit types / ternary selection
        ',', // separate arguments and array items
        '=', // set & equals comparison operator
        '%', // modulus operator
        '+', // addition operator
        '-', // subtraction operator
        '?', // ternary operator
        '@', // builtins / annotations
        ';', // statement separator
        => true,
        else => false,
    };
}

// All valid symbols.
inline fn isSymbol(char: u21) bool {
    return char == '.' or isSeparatingSymbol(char);
}

pub const State = enum { string, char, number, none };

// the actual lexer

allocator: Allocator,

output: Tokens,

mod: *Module,
data: []const u8,
pos: Pos = .{},
last: Pos = .{},
start: Pos = .{},

iter: code_point.Iterator,
gcd: GenCatData,
current: CodePoint,
word: []const u8 = "",
basic: bool = true,

logger: Logger(.lexer),
failed: bool = false,

const Self = @This();

// Initializes a new lexer.
pub fn init(mod: *Module) !Self {
    var iter = code_point.Iterator{ .bytes = mod.data.buf };
    const current = iter.next();
    return .{
        .allocator = mod.allocator,
        .output = Tokens.init(mod.allocator),
        .mod = mod,
        .data = mod.data.buf,
        .iter = iter,
        .gcd = try GenCatData.init(mod.allocator),
        .current = current orelse undefined,
        .logger = Logger(.lexer).init(mod.allocator, mod),
    };
}

// De-initializes the lexer.
// This should only be run after the output of the lexer is done being used.
pub fn deinit(self: *Self) void {
    self.gcd.deinit();
    self.output.deinit();
    self.logger.deinit();
}

// Clears the lexer, making it available to parse again.
pub fn clear(self: *Self, free: bool) void {
    if (free) self.output.clearAndFree() else self.output.clearRetainingCapacity();

    self.pos = .{};
    self.last = .{};
    self.start = .{};

    self.iter.i = 0;
    self.current = self.iter.next() orelse undefined;
    self.word = "";
    self.basic = true;
}

// Lexes the entire queue.
pub inline fn finish(self: *Self) ![]LocatedToken {
    while (!self.finished()) try self.next();
    return self.output.toOwnedSlice();
}

// Returns the last token the lexer outputted.
pub inline fn getLastToken(self: *Self) ?LocatedToken {
    if (self.output.items.len == 0) return null;
    return self.output.items[self.output.items.len - 1];
}

// Adds the current word to the output.
pub fn addWord(self: *Self, comptime symbol: bool) !void {
    if (self.word.len != 0) {
        self.word.ptr = @ptrCast(&self.data[self.start.raw]);

        if (Token.fromWord(self.word)) |token|
            try self.output.append(.{ .span = .{ self.start, self.last }, .token = token });

        self.word.len = 0;
    }

    if (symbol) try self.output.append(.{
        .span = .{ self.pos, self.pos },
        .token = .{ .symbol = self.current.code },
    });
}

// Moves the lexer position, and sets the current and next characters.
// Skips separator characters.
pub fn advance(self: *Self) !void {
    self.current = self.iter.next() orelse {
        self.pos.raw += 1;
        self.pos.col += 1;
        return;
    };

    self.last = self.pos;
    self.pos.raw = self.current.offset;
    self.pos.col += self.current.len;

    var separators: u32 = 0;
    var separators_this_line: u32 = 0;
    var new_lines: u32 = 0;

    while (self.isSeparator(self.current.code)) : (separators += self.current.len) {
        separators_this_line += self.current.len;

        if (self.current.code == '\n') {
            new_lines += 1;
            separators_this_line = 0;
        }

        if (separators == 0 and self.basic) try self.addWord(false);

        self.current = self.iter.next() orelse undefined;
    }

    if (separators != 0) {
        self.pos.raw += separators;
        self.pos.col += separators;
        if (new_lines != 0) {
            self.pos.row += new_lines;
            self.pos.col = separators_this_line;
        }
        self.start = self.pos;
    }
}

pub inline fn peek(self: *Self) CodePoint {
    return self.iter.peek() orelse undefined;
}

pub inline fn finished(self: Self) bool {
    return (self.pos.raw >= self.data.len or self.failed);
}

inline fn isSeparator(self: *Self, char: u21) bool {
    return isLineSeparator(char) or (self.basic and self.gcd.isSeparator(self.current.code));
}

inline fn fatal(self: *Self, comptime fmt: []const u8, args: anytype, span: ?Span, hi: ?Pos) !void {
    try self.logger.err(fmt, args, span, hi);
    self.failed = true;
}

inline fn tokenizeNumber(self: *Self, explicit_sign_number: bool) !void {
    self.basic = false;
    defer self.basic = true;

    var span = Span{ self.pos, self.pos };
    var out = Token.Number{};

    const obase = numberBaseCharToBase(self.peek().code);
    out.base = if (self.current.code == '0') obase orelse 10 else 10;
    if (out.base != 10) {
        try self.advance();
        try self.advance();
    }

    const after_base = self.pos.raw;

    var state = NumberType.u64;
    var exponent_reached = false;
    var sign_reached = false;
    var explicit_type_char: ?CodePoint = null;

    if (explicit_sign_number) {
        state = NumberType.i64;
        try self.advance();
    }

    while (!self.finished()) : (try self.advance()) {
        span[1] = self.pos;
        num: switch (self.current.code) {
            '0'...'9', '_' => {},
            'f' => continue :num if (out.base == 10) 'i' else 'F',
            'n', 'i', 'u' => {
                explicit_type_char = self.current;
                break;
            },
            'a'...'d', 'A'...'D', 'F' => if (out.base != 16)
                return self.fatal("hex char in base {} number.", .{out.base}, span, self.pos),
            'e', 'E' => switch (out.base) {
                16 => {},
                10 => if (state == .f64) {
                    if (!exponent_reached) {
                        exponent_reached = true;
                    } else return self.fatal("hex char in float exponent.", .{}, span, self.pos);
                } else return self.fatal("hex char in base 10 number (not known to be float yet).", .{}, span, self.pos),
                else => return self.fatal("hex char in base {} number.", .{out.base}, span, self.pos),
            },
            '+', '-' => if (exponent_reached) {
                if (sign_reached) break;
                sign_reached = true;
            } else unreachable,
            '.' => {
                if (state == NumberType.f64 or out.base != 10) break;
                state = NumberType.f64;
            },
            else => return self.fatal("unexpected character in number.", .{}, span, self.pos),
        }

        if (exponent_reached and (self.peek().code == '+' or self.peek().code == '-')) continue;

        if (isSeparatingSymbol(self.peek().code) or self.isSeparator(self.peek().code)) {
            try self.advance();
            break;
        }
    }

    out.buf = self.data[after_base..self.pos.raw];
    var explicit_type_span = Span{ self.pos, self.pos };
    var err = false;

    if (explicit_type_char) |char| get_type: {
        while (!self.finished()) {
            if (isSymbol(self.current.code) or self.isSeparator(self.current.code)) break;
            explicit_type_span[1] = self.pos;
            try self.advance();
        }

        const type_string = self.data[explicit_type_span[0].raw..self.pos.raw];

        if (type_string.len > 1) {
            out.typ = NumberType.string_map.get(type_string);
            if (out.typ == null) {
                try self.logger.err("unknown type.", .{}, explicit_type_span, null);
                err = true;
                break :get_type;
            }
        } else out.typ = switch (char.code) {
            'n' => .bigint,
            'i' => .i64,
            'u' => .u64,
            'f' => .f64,
            else => unreachable,
        };

        span[1] = explicit_type_span[1];

        if ((char.code == 'i' or char.code == 'n') and state == .f64) {
            try self.logger.err("floating-point numbers cannot become signed integers.", .{}, span, explicit_type_span[0]);
            err = true;
        } else if (char.code == 'u') {
            if (state == .i64 and out.buf[0] == '-') {
                try self.logger.err("unsigned integers cannot be negative.", .{}, span, explicit_type_span[0]);
                err = true;
            } else if (state == .f64) {
                try self.logger.err("floating-point numbers cannot become unsigned integers.", .{}, span, explicit_type_span[0]);
                err = true;
            }
        }
    }

    try self.output.append(.{ .span = span, .token = .{ .number = out } });
}

inline fn parseEscapeSequence(self: *Self, comptime exit: u8) !u21 {
    return switch (self.peek().code) {
        'n', 'r', 't', '\\', exit => {
            try self.advance();
            return switch (self.current.code) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                exit => exit,
                else => unreachable,
            };
        },
        'x' => {
            try self.advance(); // Advance past '\'.
            try self.advance(); // Advance past 'x'.

            if (self.data.len <= self.pos.raw + 1) {
                while (!self.finished()) try self.advance();
                try self.logger.err("unexpected end of file.", .{}, .{ self.pos, self.pos }, null);
                return 0xFFFD;
            }

            const hex_start = self.pos;
            const chars: [2]u8 = .{
                @truncate(self.current.code),
                @truncate(self.peek().code),
            };
            try self.advance();

            return parseUnsigned(u8, &chars, 16) catch {
                try self.logger.err("bad hexadecimal number.", .{}, .{ hex_start, self.pos }, null); // Overflow is unreachable.
                return 0xFFFD;
            };
        },
        'u' => {
            const esc_seq_start = self.pos;
            try self.advance(); // Advance past '\'.
            try self.advance(); // Advance past 'u'.

            var fail_pos = Pos{};

            if (self.current.code == '{') parse: {
                try self.advance(); // Advance past '{'.

                const esc_char_start = self.pos;
                var idx: usize = 5;

                while (!self.finished()) : (try self.advance()) {
                    if (self.current.code == '}') break;

                    if (!isHexadecimalChar(self.current.code)) {
                        fail_pos = self.pos;
                        break :parse;
                    } else if (self.isSeparator(self.peek().code)) {
                        fail_pos = self.pos.next();
                        break :parse;
                    }

                    if (idx == 0) {
                        while (!self.finished() and self.current.code != '}') try self.advance();
                        try self.logger.err("escape sequence is too large.", .{}, .{ esc_seq_start, self.pos }, null);
                        return 0xFFFD;
                    }
                    idx -%= 1;
                }

                if (self.finished()) {
                    try self.logger.err("unexpected end of file.", .{}, .{ self.pos, self.pos }, null);
                    return 0xFFFD;
                }

                const char = parseUnsigned(u24, self.data[esc_char_start.raw..self.pos.raw], 16) catch unreachable;
                if (char > 0x10FFFF) {
                    try self.logger.err("escape sequence is too large.", .{}, .{ esc_seq_start, self.pos }, null);
                    return 0xFFFD;
                } else return @truncate(char);
            }

            while (!self.finished() and isHexadecimalChar(self.peek().code)) try self.advance();
            try self.advance();
            try self.logger.err("invalid escape sequence.", .{}, .{ esc_seq_start, fail_pos }, fail_pos);
            return 0xFFFD;
        },
        else => {
            try self.logger.err("invalid escape sequence.", .{}, .{ self.pos, self.pos }, null);
            return 0xFFFD;
        },
    };
}

// Lex characters into the next token(s).
pub fn next(self: *Self) !void {
    if (self.finished()) return;

    const initial_len = self.output.items.len;

    while (!self.finished() and initial_len == self.output.items.len) : (try self.advance()) {
        if (self.word.len == 0) self.start = self.pos;
        var explicit_sign_number = (self.current.code == '+' or self.current.code == '-') and isNumberChar(self.peek().code);

        // Explicitly +/- numbers; we must ensure the last token was not an expression.
        if (explicit_sign_number) {
            var last_token = self.getLastToken();
            if (last_token == null) return self.fatal("invalid syntax.", .{}, .{ self.pos, self.pos }, null);
            explicit_sign_number = explicit_sign_number and !last_token.?.token.isExpression();
        }

        if (self.word.len == 0 and (isNumberChar(self.current.code) or explicit_sign_number))
            return self.tokenizeNumber(explicit_sign_number);

        switch (self.current.code) {
            '"' => { // String parser.
                self.basic = false;
                defer self.basic = true;

                const start = self.pos;
                try self.advance();
                const inner_start = self.pos.raw;
                var last = self.pos.raw;

                var buffer = std.ArrayList(u8).init(self.allocator);
                var out = Token.String{};

                while (!self.finished()) : (try self.advance()) {
                    if (self.current.code == '"') {
                        if (last == inner_start) {
                            out.buf = self.data[last..self.pos.raw];
                            out.managed = false;
                        } else {
                            try buffer.appendSlice(self.data[last..self.pos.raw]);
                            out.buf = try buffer.toOwnedSlice();
                        }
                        break;
                    } else if (self.current.code == '\\') {
                        try buffer.appendSlice(self.data[last..self.pos.raw]);
                        const c = try self.parseEscapeSequence('"');
                        try utftools.writeCodepointToUtf8(c, buffer.writer());
                        last = self.peek().offset;
                    }
                }

                try self.output.append(.{
                    .span = .{ start, self.pos },
                    .token = .{ .string = out },
                });
            },
            '\'' => { // Character parser.
                self.basic = false;
                defer self.basic = true;

                const start = self.pos;
                var char: ?u21 = null;

                try self.advance();
                if (self.current.code == '\'') {
                    try self.logger.err("empty characters not allowed.", .{}, .{ start, self.pos }, null);
                } else if (self.current.code == '\\') {
                    char = try self.parseEscapeSequence('\'');
                    try self.advance();
                } else if (self.peek().code == '\'') {
                    char = self.current.code;
                    try self.advance();
                }

                if (self.current.code != '\'') {
                    while (!self.finished() and self.current.code != '\'') try self.advance();
                    try self.logger.err("character is too large.", .{}, .{ start, self.pos }, null);
                    try self.logger.info("strings are defined with double quotes.", .{}, null, null);
                }

                try self.output.append(.{
                    .span = .{ start, self.pos },
                    .token = .{ .char = char orelse 0xFFFD },
                });
            },
            // Division or comment.
            '/' => if (self.peek().code == '/' or self.peek().code == '*') {
                var span = Span{ self.pos, self.pos };
                var start = self.pos;
                try self.advance();
                var doc = false;
                var out = Token.DocComment{};

                switch (self.current.code) {
                    // Single-line comment.
                    '/' => {
                        if (isLineSeparator(self.peek().code)) continue;
                        try self.advance();
                        doc = self.current.code == '/';
                        out.top_level = self.current.code == '!';
                        if (isLineSeparator(self.peek().code)) continue;
                        if (doc or out.top_level) try self.advance();

                        start = self.pos;
                        while (!isLineSeparator(self.peek().code)) try self.advance();
                        span[1] = self.pos;
                    },
                    // Multi-line comment.
                    '*' => {
                        try self.advance();
                        doc = self.current.code == '*';
                        if (doc) try self.advance();

                        start = self.pos;
                        while (!(self.current.code == '*' and self.peek().code == '/')) : (try self.advance()) span[1] = self.pos;
                        try self.advance();
                    },
                    else => unreachable,
                }

                if (out.top_level and (self.output.items.len != 0 or self.word.len != 0))
                    return self.fatal("top-level doc comment must be at the start of the file.", .{}, span, null);

                out.buf = self.data[start.raw .. span[1].raw + 1];

                if (doc or out.top_level) try self.output.append(.{
                    .span = span,
                    .token = .{ .doc_comment = out },
                });
            } else try self.addWord(true), // Symbol.
            else => if (!isSymbol(self.current.code)) {
                self.word.len +%= self.current.len;
            } else try self.addWord(true), // Symbol.
        }
    }
}

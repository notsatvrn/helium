const std = @import("std");
const util = @import("../util.zig");

pub const TypeDesc = union(enum) {
    builtin: BuiltinType,
    external: u31,

    pub inline fn toU32(self: TypeDesc) u32 {
        return switch (self) {
            .builtin => |v| @as(u32, @intFromEnum(v)) << 1,
            .external => |v| @as(u32, 1) | (@as(u32, v) << 1),
        };
    }

    pub inline fn fromU64(int: u64) TypeDesc {
        if ((int & 1) == 1) return .{ .external = @truncate(int >> 1) };
        return .{ .builtin = @enumFromInt(@as(u8, @truncate(int >> 1))) };
    }
};

pub const TypeSet = struct {
    inner: std.AutoHashMap(u64, void),

    pub inline fn contains(self: TypeSet, desc: TypeDesc) bool {
        return self.inner.contains(desc.toU64());
    }

    pub inline fn containsBuiltin(self: TypeSet, builtin: BuiltinType) bool {
        return self.contains(.{ .builtin = builtin });
    }

    pub inline fn count(self: TypeSet) usize {
        return self.inner.count();
    }

    pub inline fn put(self: *TypeSet, desc: TypeDesc) !void {
        return self.inner.put(desc.toU64(), void{});
    }

    pub inline fn remove(self: *TypeSet, desc: TypeDesc) bool {
        return self.inner.remove(desc.toU64());
    }
};

// ALL TYPES

pub const Types = enum { builtin, structured, collection, reference };
pub const Type = union(Types) {
    builtin: BuiltinType,
    structured: StructuredType,
    collection: CollectionType,
    reference: ReferenceType,

    pub inline fn eql(self: Type, other: Type) bool {
        if (@as(Types, self) != @as(Types, other)) return false;
        return switch (self) {
            .builtin => |v| v == other.builtin,
            .structured => |v| v.eql(other.structured),
            .collection => |v| v.eql(other.collection),
            .reference => |v| v.eql(other.reference),
        };
    }
};

// BUILT-IN TYPES

// zig fmt: off

pub const BuiltinType = enum(u8) {
    bigint = 0x16,
    i128   = 0x15,
    i64    = 0x14,
    i32    = 0x13,
    i16    = 0x12,
    i8     = 0x11,
    u128   = 0x05,
    u64    = 0x04,
    u32    = 0x03,
    u16    = 0x02,
    u8     = 0x01,
    f64    = 0x24,
    f32    = 0x23,
    f16    = 0x22,

    int   = 0x10,
    uint  = 0x00,
    float = 0x20,
    
    number = 0x30,
    string = 0x40,
    char   = 0x45,
    bool   = 0x50,
    void   = 0x60,
    type   = 0x70,
    func   = 0x80,
    
    any = 0xFF,

    pub const string_map = util.mkStringMap(BuiltinType);
};

// zig fmt: on

// STRUCTURED TYPES

pub const StructuredTypes = enum { @"struct", @"enum", @"union" };
pub const StructuredType = union(StructuredTypes) {
    @"struct": StructType,
    @"enum": EnumType,
    @"union": UnionType,
};

pub const StructType = struct {
    values: std.StaticStringMap(Type),
};

pub const EnumType = struct {
    values: std.StaticStringMap(void),
};

pub const UnionType = struct {
    values: std.StaticStringMap(Type),
};

// COLLECTION TYPES

pub const CollectionTypes = enum { list, set, map };
pub const CollectionType = union(CollectionTypes) {
    list: ListType,
    set: SetType,
    map: MapType,
};

pub const ListType = struct {
    item: *const Type,
};

pub const SetType = struct {
    item: *const Type,
};

pub const MapType = struct {
    key: *const Type,
    value: *const Type,
};

// REFERENCES

pub const ReferenceTypes = enum { constant, mutable };
pub const ReferenceType = union(ReferenceTypes) {
    constant: *const Type,
    mutable: *const Type,
};

const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx");
const tcc = @import("tcc");
const cy = @import("../cyber.zig");
const c = @import("../capi.zig");
const cli = @import("../cli.zig");
const rt = cy.rt;
const Value = cy.Value;
const builtins = @import("../builtins/builtins.zig");
const bindings = @import("../builtins/bindings.zig");
const prepareThrowSymbol = bindings.prepareThrowSymbol;
const Symbol = bindings.Symbol;
const os = @import("os.zig");
const sema = cy.sema;
const bt = cy.types.BuiltinTypes;
const types = cy.types;

const log = cy.log.scoped(.ffi);

const DumpCGen = builtin.mode == .Debug and false;

const CType = union(enum) {
    sym: Symbol,
    object: cy.TypeId,
    arr: struct {
        child: *CType,
        n: u32,
    },

    fn deinit(self: CType, alloc: std.mem.Allocator) void {
        if (self == .arr) {
            self.arr.child.deinit(alloc);
            alloc.destroy(self.arr.child);
        }
    }
};

const CStructInfo = struct {
    type: cy.TypeId,
    fields: []const CType,
};

pub const FFI = struct {
    /// Ordered to handle C decl rules.
    cstructs: std.ArrayListUnmanaged(CStructInfo),

    typeToCStruct: std.AutoHashMapUnmanaged(cy.TypeId, u32),

    carrays: std.ArrayListUnmanaged(CType),
    carrayMap: std.StringHashMapUnmanaged(u32),

    cfuncs: std.ArrayListUnmanaged(CFuncData),

    /// Managed ExternFunc or Objects.
    managed: std.ArrayListUnmanaged(Value),

    CArrayT: cy.TypeId,

    fn toCType(self: *FFI, vm: *cy.VM, spec: Value) !CType {
        if (spec.isObjectType(self.CArrayT)) {
            const nField = try vm.ensureField("n");
            const n: u32 = @intCast((try vm.getField(spec, nField)).asBoxInt());
            const elemField = try vm.ensureField("elem");
            const elem = try vm.getField(spec, elemField);
            const child = try vm.alloc.create(CType);
            child.* = try self.toElemCType(vm, elem);
            const res = CType{ .arr = .{ .child = child, .n = n }};
            try self.ensureArray(vm.alloc, res);
            return res;
        } else {
            return self.toElemCType(vm, spec);
        }
    }

    fn toElemCType(self: *FFI, vm: *cy.VM, spec: Value) !CType {
        if (spec.isObjectType(bt.Type)) {
            const typeId = spec.asHeapObject().type.type;
            if (self.typeToCStruct.contains(typeId)) {
                return CType{ .object = typeId };
            } else {
                const name = try vm.getOrBufPrintValueStr(&cy.tempBuf, spec);
                log.tracev("CStruct not declared for: {s}", .{name});
                return error.InvalidArgument;
            }
        } else if (spec.isSymbol()) {
            const sym = try std.meta.intToEnum(Symbol, spec.asSymbolId());
            return CType{ .sym = sym };
        }
        return error.InvalidArgument;
    }

    fn ensureArray(self: *FFI, alloc: std.mem.Allocator, arrT: CType) !void {
        const elemName = try fmtBaseTypeName(&cy.tempBuf, arrT.arr.child.*);
        const key = try std.fmt.allocPrint(alloc, "{s}[{}]", .{elemName, arrT.arr.n});
        if (!self.carrayMap.contains(key)) {
            const id = self.carrays.items.len;
            try self.carrays.append(alloc, arrT);
            try self.carrayMap.put(alloc, key, @intCast(id));
        } else {
            alloc.free(key);
        }
    }
};

pub fn allocFFI(vm: *cy.VM) !Value {
    const cli_data = vm.getData(*cli.CliData, "cli");
    const ffi: *FFI = @ptrCast(try cy.heap.allocHostNoCycObject(vm, cli_data.FFIT, @sizeOf(FFI)));
    ffi.* = .{
        .cstructs = .{},
        .typeToCStruct = .{},
        .carrays = .{},
        .carrayMap = .{},
        .cfuncs = .{},
        .managed = .{},
        .CArrayT = cli_data.CArrayT,
    };
    return Value.initHostNoCycPtr(ffi);
}

pub fn ffiGetChildren(_: ?*c.VM, obj: ?*anyopaque) callconv(.C) c.ValueSlice {
    const ffi: *FFI = @ptrCast(@alignCast(obj));
    return Value.toSliceC(ffi.managed.items);
}

pub fn ffiFinalizer(vm_: ?*c.VM, obj: ?*anyopaque) callconv(.C) void {
    const vm: *cy.VM = @ptrCast(@alignCast(vm_));

    const alloc = vm.alloc;
    var ffi: *FFI = @ptrCast(@alignCast(obj));

    for (ffi.cstructs.items) |cstruct| {
        for (cstruct.fields) |field| {
            field.deinit(alloc);
        }
        alloc.free(cstruct.fields);
    }
    ffi.cstructs.deinit(alloc);
    ffi.typeToCStruct.deinit(alloc);

    ffi.carrays.deinit(alloc);

    var iter = ffi.carrayMap.keyIterator();
    while (iter.next()) |key| {
        alloc.free(key.*);
    }
    ffi.carrayMap.deinit(alloc);

    for (ffi.cfuncs.items) |func| {
        alloc.free(func.namez);
        for (func.params) |param| {
            param.deinit(alloc);
        }
        alloc.free(func.params);
    }
    ffi.cfuncs.deinit(alloc);

    ffi.managed.deinit(alloc);
}

const CGen = struct {
    ffi: *FFI,

    pub fn genHeaders(_: CGen, w: anytype) !void {
        try w.print(
            \\#define bool _Bool
            \\#define int64_t long long
            \\#define uint64_t unsigned long long
            // TODO: Check for 32bit addressing.
            \\#define size_t uint64_t
            \\#define int8_t signed char
            \\#define uint8_t unsigned char
            \\#define int16_t short
            \\#define uint16_t unsigned short
            \\#define int32_t int
            \\#define uint32_t unsigned int
            \\#define PointerMask 0xFFFE000000000000
            \\typedef struct ZAllocator {{
            \\    void* ptr;
            \\    void* vtable;
            \\}} ZAllocator;
            \\typedef struct VMC {{
            \\    uint8_t* pc;
            \\    uint64_t* fp;
            \\}} VMC;
            \\typedef struct VM {{
            \\    ZAllocator alloc;
            \\    VMC c;
            \\}} VM;
            \\extern void _cyRelease(VM*, uint64_t);
            \\extern void* icyGetPtr(VM*, uint64_t);
            \\extern void* _cyGetFuncPtr(VM*, uint64_t);
            \\extern uint64_t icyAllocObject(VM*, uint32_t);
            \\extern uint64_t icyAllocList(VM*, uint64_t*, uint32_t);
            \\extern uint64_t cy_alloc_int(VM*, int64_t);
            \\extern int64_t cy_as_boxint(uint64_t);
            \\extern uint64_t icyAllocCyPointer(VM*, void*);
            \\extern uint64_t _cyCallFunc(VM*, uint64_t, uint64_t*, uint8_t);
            \\extern int printf(char* fmt, ...);
            \\#define CALL_ARG_START 5
            \\uint64_t cy_get_value(VM* vm, size_t idx) {{
            \\    return vm->c.fp[CALL_ARG_START + idx];
            \\}}
            // \\extern void exit(int code);
            \\
        , .{});
    }

    // Generate C structs.
    pub fn genStructDecls(self: CGen, w: anytype) !void {
        for (self.ffi.cstructs.items) |cstruct| {
            try w.print("typedef struct Struct{} {{\n", .{cstruct.type});
            for (cstruct.fields, 0..) |field, i| {
                try w.writeAll("  ");
                const name = try std.fmt.bufPrint(&cy.tempBuf, "f{}", .{i});
                try writeNamedCType(w, field, name);
                try w.writeAll(";\n");
            }
            try w.print("}} Struct{};\n", .{cstruct.type});
        }
    }

    // Generate array conversions declarations.
    pub fn genArrayConvDecls(self: CGen, w: anytype) !void {
        for (self.ffi.carrays.items) |carr| {
            const elemName = try fmtBaseTypeName(&cy.tempBuf, carr.arr.child.*);

            // to{elem}Array{n}
            try w.print("void to{s}Array{}(VM* vm, uint64_t val, ", .{elemName, carr.arr.n});
            try writeCType(w, carr.arr.child.*);
            try w.print("* out);\n", .{});

            // from{elem}Array{n}.
            try w.print("uint64_t from{s}Array{}(VM* vm, ", .{elemName, carr.arr.n});
            try writeCType(w, carr.arr.child.*);
            try w.print(" arr[{}]);\n", .{carr.arr.n});
        }
    }

    // Generate struct conversions.
    pub fn genStructConvs(self: CGen, w: anytype) !void {
        const ffi = self.ffi;
        for (ffi.cstructs.items) |cstruct| {
            // Generate to C struct conv.
            try w.print("Struct{} toStruct{}(VM* vm, uint64_t val) {{\n", .{cstruct.type, cstruct.type});
            // Get pointer to first cyber object field.
            try w.print("  uint64_t* args = (uint64_t*)(val & ~PointerMask) + 1;\n", .{});
            try w.print("  Struct{} res;\n", .{cstruct.type, });
            for (cstruct.fields, 0..) |field, i| {
                if (field == .arr) {
                    const elemName = try fmtBaseTypeName(&cy.tempBuf, field.arr.child.*);
                    try w.print("  to{s}Array{}(vm, args[{}], &res.f{}[0]);", .{elemName, field.arr.n, i, i});
                } else {
                    try w.print("  res.f{} = ", .{i});
                    const val = try std.fmt.bufPrint(&cy.tempBuf, "args[{}]", .{i});
                    try writeToCValue(w, val, field, false);
                    try w.print(";\n", .{});
                }
            }
            try w.print("  return res;\n", .{});
            try w.print("}}\n", .{});

            // Generate from C struct conv.
            try w.print("uint64_t fromStruct{}(VM* vm, Struct{} val) {{\n", .{cstruct.type, cstruct.type});
            try w.print("  uint64_t obj = icyAllocObject(vm, {});\n", .{cstruct.type});
            try w.print("  uint64_t* args = (uint64_t*)(obj & ~PointerMask) + 1;\n", .{});
            var buf: [8]u8 = undefined;
            for (cstruct.fields, 0..) |field, i| {
                // Int and other types.
                try w.print("  args[{}] = ", .{i});
                const argStr = try std.fmt.bufPrint(&buf, "val.f{}", .{i});
                try writeToCyValue(w, argStr, field, false);
                try w.print(";\n", .{});
            }
            try w.print("  return obj;\n", .{});
            try w.print("}}\n", .{});
        }
    }

    // Generate array conversions.
    pub fn genArrayConvs(self: CGen, w: anytype) !void {
        var buf: [16]u8 = undefined;
        for (self.ffi.carrays.items) |carr| {
            const elem = carr.arr.child.*;
            const n = carr.arr.n;
            const elemName = try fmtBaseTypeName(&cy.tempBuf, elem);

            // Generate to{elem}Array{n}. Writes to ptr since arrays can't be returned in C.
            try w.print("void to{s}Array{}(VM* vm, uint64_t val, ", .{elemName, n});
            try writeCType(w, elem);
            try w.print("* out) {{\n", .{});
            try w.print("  uint64_t* args = (uint64_t*)*((uint64_t*)(val & ~PointerMask) + 1);\n", .{});
            for (0..n) |i| {
                try w.print("  out[{}] = ", .{i});
                const val = try std.fmt.bufPrint(&buf, "args[{}]", .{i});
                try writeToCValue(w, val, elem, false);
                try w.writeAll(";\n");
            }
            try w.print("}}\n", .{});

            // Generate from{elem}Array{n}.
            try w.print("uint64_t from{s}Array{}(VM* vm, ", .{elemName, n});
            try writeCType(w, elem);
            try w.print(" arr[{}]) {{\n", .{n});

            try w.print("  uint64_t vals[{}];\n", .{n});
            for (0..n) |i| {
                try w.print("  vals[{}] = ", .{i});
                const cval = try std.fmt.bufPrint(&buf, "arr[{}]", .{i});
                try writeToCyValue(w, cval, elem, false);
                try w.writeAll(";\n");
            }
            try w.print("  return icyAllocList(vm, &vals[0], {});\n", .{n});
            try w.print("}}\n", .{});
        }
    }

    fn genFunc(self: *CGen, vm: *cy.VM, w: anytype, funcInfo: CFuncData, config: BindLibConfig) !void {
        _ = vm;
        var buf: [32]u8 = undefined;
        _ = self;
        const params = funcInfo.params;
        const sym = funcInfo.namez;
        const ret = funcInfo.ret;

        // Emit extern declaration.
        try w.writeAll("extern ");
        try writeCType(w, funcInfo.ret);
        try w.print(" {s}(", .{ sym });
        if (params.len > 0) {
            try writeCType(w, params[0]);
            if (params.len > 1) {
                for (params[1..]) |param| {
                    try w.print(", ", .{});
                    try writeCType(w, param);
                }
            }
        }
        try w.print(");\n", .{});

        const isMethod = !config.gen_table;
        try w.print("uint64_t cy{s}(VM* vm) {{\n", .{sym});
        if (isMethod) {
            try w.print("  uint64_t recv = cy_get_value(vm, 0);\n", .{});
        }

        // Temps.
        if (params.len > 0) {
            for (params, 0..) |param, i| {
                const argIdx = if (isMethod) i + 1 else i;
                if (param == .arr) {
                    const elem = param.arr.child.*;
                    const elemName = try fmtBaseTypeName(&cy.tempBuf, elem);

                    try w.print("  ", .{});
                    const cval = try std.fmt.bufPrint(&buf, "arr{}", .{argIdx});
                    try writeNamedCType(w, param, cval);
                    try w.print(";\n", .{});

                    try w.print("  to{s}Array{}(vm, cy_get_value(vm, {}), &arr{}[0]);\n", .{elemName, param.arr.n, argIdx, argIdx});
                } else {
                    try w.print("  uint64_t arg_{} = cy_get_value(vm, {});\n", .{argIdx, argIdx});
                }
            }
        }

        // Gen call.
        if (ret == .object) {
            try w.print("  Struct{} res = {s}(", .{ret.object, sym});
        } else {
            switch (ret.sym) {
                .char => {
                    try w.print("  int8_t res = {s}(", .{sym});
                },
                .uchar => {
                    try w.print("  uint8_t res = {s}(", .{sym});
                },
                .short => {
                    try w.print("  int16_t res = {s}(", .{sym});
                },
                .ushort => {
                    try w.print("  uint16_t res = {s}(", .{sym});
                },
                .int => {
                    try w.print("  int32_t res = {s}(", .{sym});
                },
                .uint => {
                    try w.print("  uint32_t res = {s}(", .{sym});
                },
                .long => {
                    try w.print("  int64_t res = {s}(", .{sym});
                },
                .ulong => {
                    try w.print("  uint64_t res = {s}(", .{sym});
                },
                .usize => {
                    try w.print("  size_t res = {s}(", .{sym});
                },
                .float => {
                    try w.print("  double res = (double){s}(", .{sym});
                },
                .double => {
                    try w.print("  double res = {s}(", .{sym});
                },
                .charPtr => {
                    try w.print("  char* res = {s}(", .{sym});
                },
                .voidPtr => {
                    try w.print("  void* res = {s}(", .{sym});
                },
                .void => {
                    try w.print("  {s}(", .{sym});
                },
                .bool => {
                    try w.print("  bool res = {s}(", .{sym});
                },
                else => cy.panicFmt("Unsupported return type: {s}", .{ @tagName(ret.sym) }),
            }
        }

        // Gen args.
        if (params.len > 0) {
            var argIdx: usize = if (isMethod) 1 else 0;
            if (params[0] == .arr) {
                try w.print("arr{}", .{argIdx});
            } else {
                const val = try std.fmt.bufPrint(&buf, "arg_{}", .{argIdx});
                try writeToCValue(w, val, params[0], false);
            }

            if (params.len > 1) {
                for (params[1..], 1..) |param, i| {
                    try w.print(", ", .{});
                    argIdx = if (isMethod) i + 1 else i;
                    if (param == .arr) {
                        try w.print("arr{}", .{argIdx});
                    } else {
                        const val = try std.fmt.bufPrint(&buf, "arg_{}", .{argIdx});
                        try writeToCValue(w, val, param, false);
                    }
                }
            }
        }

        // End of args.
        try w.print(");\n", .{});

        // Gen return.
        try w.print("  return ", .{});
        try writeToCyValue(w, "res", ret, false);
        try w.print(";\n", .{});

        try w.print("}}\n", .{});
    }
};

pub fn ffiCbind(vm: *cy.VM) anyerror!Value {
    const alloc = vm.alloc;
    const ffi = vm.getHostObject(*FFI, 0);
    const mt = vm.getValue(1).asHeapObject();
    const typeId = mt.type.type;
    const fieldsList = &vm.getValue(2).asHeapObject().list;

    if (ffi.typeToCStruct.contains(typeId)) {
        log.tracev("Object type already declared.", .{});
        return error.InvalidArgument;
    }
    const id = ffi.cstructs.items.len;
    try ffi.typeToCStruct.put(alloc, typeId, @intCast(id));

    var fieldsBuilder: std.ArrayListUnmanaged(CType) = .{};
    for (fieldsList.items()) |field| {
        try fieldsBuilder.append(alloc, try ffi.toCType(vm, field));
    }

    const fields = try fieldsBuilder.toOwnedSlice(alloc);
    try ffi.cstructs.append(alloc, .{ .type = typeId, .fields = fields });

    return Value.Void;
}

pub fn ffiCfunc(vm: *cy.VM) anyerror!Value {
    const ffi = vm.getHostObject(*FFI, 0);

    const funcArgs = vm.getObject(*cy.heap.List, 2).items();

    const ctypes = try vm.alloc.alloc(CType, funcArgs.len);
    if (funcArgs.len > 0) {
        for (funcArgs, 0..) |arg, i| {
            ctypes[i] = try ffi.toCType(vm, arg);
        }
    }

    const retType = try ffi.toCType(vm, vm.getValue(3));

    const symName = try vm.getOrBufPrintValueStr(&cy.tempBuf, vm.getValue(1));
    try ffi.cfuncs.append(vm.alloc, .{
        .namez = try vm.alloc.dupeZ(u8, symName),
        .params = ctypes,
        .ret = retType,
        .ptr = undefined,
        .funcSigId = undefined,
        .skip = false,
    });

    return Value.Void;
}

pub fn ffiNew(vm: *cy.VM) anyerror!Value {
    // const ffi = args[0].castHostObject(*FFI);

    const csym = try std.meta.intToEnum(Symbol, vm.getSymbol(1));
    const size = try sizeOf(csym);

    const ptr = std.c.malloc(size);
    return Value.initRaw(@intFromPtr(ptr));
}

/// Returns the name of a base type. No arrays.
fn fmtBaseTypeName(buf: []u8, ctype: CType) ![]const u8 {
    switch (ctype) {
        .object => |objectT| {
            return std.fmt.bufPrint(buf, "Struct{}", .{objectT});
        },
        .arr => return error.Unexpected,
        .sym => |sym| {
            return switch (sym) {
                .bool => "Bool",
                .char => "I8",
                .uchar => "U8",
                .short => "I16",
                .ushort => "U16",
                .int => "I32",
                .uint => "U32",
                .long => "I64",
                .ulong => "U64",
                .usize => "Usize",
                .float => "Float",
                .double => "Double",
                .charPtr => "CharPtr",
                .voidPtr => "VoidPtr",
                else => {
                    std.debug.print("Unsupported arg type: {s}\n", .{ @tagName(sym) });
                    return error.InvalidArgument;
                },
            };
        },
    }
}

pub const BindLibConfig = struct {
    /// Whether bindLib generates the binding to an anonymous object type as methods
    /// or a table with functions.
    gen_table: bool = false,
};

fn writeCType(w: anytype, ctype: CType) !void {
    switch (ctype) {
        .object => |objectT| {
            try w.print("Struct{}", .{objectT});
        },
        .arr => |arr| {
            try writeCType(w, arr.child.*);
            try w.print("[{}]", .{ arr.n });
        },
        .sym => |sym| {
            try writeCTypeForCSym(w, sym);
        }
    }
}

/// eg. int a; int a[4];
fn writeNamedCType(w: anytype, ctype: CType, name: []const u8) !void {
    if (ctype == .arr) {
        try writeCType(w, ctype.arr.child.*);
        try w.print(" {s}[{}]", .{ name, ctype.arr.n });
    } else {
        try writeCType(w, ctype);
        try w.print(" {s}", .{name});
    }
}

fn writeToCValue(w: anytype, val: []const u8, ctype: CType, unbox: bool) !void {
    switch (ctype) {
        .object => |objectT| {
            try w.print("toStruct{}(vm, {s})", .{objectT, val});
        },
        .sym => |sym| {
            try writeToCValueForSym(w, val, sym, unbox);
        },
        else => {
            std.debug.print("Unsupported arg type: {s}\n", .{ @tagName(ctype) });
            return error.InvalidArgument;
        }
    }
}

fn writeToCValueForSym(w: anytype, val: []const u8, sym: Symbol, unbox: bool) !void {
    switch (sym) {
        .bool => {
            try w.print("({s} == 0x7FFC000200000001)?1:0", .{val});
        },
        .char => {
            try w.print("(int8_t)({s} & 0xFFFFFFFFFFFF)", .{val});
        },
        .uchar => {
            try w.print("(uint8_t)({s} & 0xFFFFFFFFFFFF)", .{val});
        },
        .short => {
            try w.print("(int16_t)({s} & 0xFFFFFFFFFFFF)", .{val});
        },
        .ushort => {
            try w.print("(uint16_t)({s} & 0xFFFFFFFFFFFF)", .{val});
        },
        .int => {
            if (unbox) {
                try w.print("(int)cy_as_boxint({s})", .{val});
            } else {
                try w.print("(int){s}", .{val});
            }
        },
        .uint => {
            try w.print("(uint32_t)({s} & 0xFFFFFFFFFFFF)", .{val});
        },
        .long => {
            // 48-bit int to 64-bit.
            try w.print("(((int64_t)({s} & 0xFFFFFFFFFFFF) << 16) >> 16)", .{val});
        },
        .ulong => {
            try w.print("(uint64_t)({s} & 0xFFFFFFFFFFFF)", .{val});
        },
        .usize => {
            try w.print("(size_t)({s} & 0xFFFFFFFFFFFF)", .{val});
        },
        .float => {
            try w.print("(float)*(double*)&{s}", .{val});
        },
        .double => {
            try w.print("*(double*)&{s}", .{val});
        },
        .charPtr => {
            if (unbox) {
                try w.print("(char*)icyGetPtr(vm, {s})", .{val});
            } else {
                try w.print("(char*){s}", .{val});
            }
        },
        .voidPtr => {
            if (unbox) {
                try w.print("icyGetPtr(vm, {s})", .{val});
            } else {
                try w.print("(void*){s}", .{val});
            }
        },
        .funcPtr => {
            if (unbox) {
                try w.print("_cyGetFuncPtr(vm, {s})", .{val});
            } else {
                try w.print("(void*){s}", .{val});
            }
        },
        else => {
            std.debug.print("Unsupported arg type: {s}\n", .{ @tagName(sym) });
            return error.InvalidArgument;
        }
    }
}

fn writeToCyValue(w: anytype, cval: []const u8, ctype: CType, must_box: bool) !void {
    switch (ctype) {
        .object => |objectT| {
            try w.print("fromStruct{}(vm, {s})", .{ objectT, cval });
        },
        .arr => |arr| {
            const elemName = try fmtBaseTypeName(&cy.tempBuf, arr.child.*);
            try w.print("from{s}Array{}(vm, {s})", .{elemName, arr.n, cval});
        },
        .sym => |sym| {
            try writeToCyValueForSym(w, cval, sym, must_box);
        },
    }
}

fn writeToCyValueForSym(w: anytype, cval: []const u8, ctype: Symbol, must_box: bool) !void {
    switch (ctype) {
        .char,
        .short,
        .int,
        .ulong,
        .uchar,
        .ushort,
        .uint,
        .usize => {
            if (must_box) {
                try w.print("cy_alloc_int(vm, ((int64_t){s}))", .{cval});
            } else {
                try w.print("((uint64_t){s})", .{cval});
            }
        },
        .long => {
            if (must_box) {
                try w.print("cy_alloc_int(vm, {s})", .{cval});
            } else {
                try w.print("{s}", .{cval});
            }
        },
        .float,
        .double => {
            // Assumes cval is already converted to double.
            try w.print("*(uint64_t*)&{s}", .{cval});
        },
        .charPtr => {
            if (must_box) {
                try w.print("icyAllocCyPointer(vm, {s})", .{cval});
            } else {
                try w.print("((uint64_t){s})", .{cval});
            }
        },
        .voidPtr => {
            if (must_box) {
                try w.print("icyAllocCyPointer(vm, {s})", .{cval});
            } else {
                try w.print("((uint64_t){s})", .{cval});
            }
        },
        .void => {
            try w.print("0x7FFC000100000000", .{});
        },
        .bool => {
            try w.print("({s} == 1) ? 0x7FFC000200000001 : 0x7FFC000200000000", .{cval});
        },
        else => {
            cy.panicFmt("Unsupported arg type: {s}", .{ @tagName(ctype) });
        }
    }
}

fn writeCTypeForCSym(w: anytype, ctype: Symbol) !void {
    const str = switch (ctype) {
        .bool => "bool",
        .char => "int8_t",
        .uchar => "uint8_t",
        .short => "int16_t",
        .ushort => "uint16_t",
        .int => "int",
        .uint => "uint32_t",
        .long => "int64_t",
        .ulong => "uint64_t",
        .usize => "size_t",
        .float => "float",
        .double => "double",
        .charPtr => "char*",
        .voidPtr => "void*",
        .funcPtr => "void*",
        .void => "void",
        else => {
            std.debug.print("Unsupported arg type: {s}\n", .{ @tagName(ctype) });
            return error.InvalidArgument;
        },
    };
    try w.writeAll(str);
}

fn sizeOf(ctype: Symbol) !usize {
    return switch (ctype) {
        .bool => 1,
        .char => 1,
        .uchar => 1,
        .short => 2,
        .ushort => 2,
        .int => 4,
        .uint => 4,
        .long => 8,
        .ulong => 8,
        .usize => 8,
        .float => 4,
        .double => 8,
        .charPtr => 8,
        .voidPtr => 8,
        .funcPtr => 8,
        else => {
            std.debug.print("Unsupported type: {s}\n", .{ @tagName(ctype) });
            return error.InvalidArgument;
        }
    };
}

fn toCyType(vm: *cy.VM, ctype: CType) !types.TypeId {
    switch (ctype) {
        .object => |objectT| return objectT,
        .arr => return bt.ListDyn,
        .sym => |sym| {
            switch (sym) {
                .bool => return bt.Boolean,
                .char => return bt.Integer,
                .uchar => return bt.Integer,
                .short => return bt.Integer,
                .ushort => return bt.Integer,
                .int => return bt.Integer,
                .uint => return bt.Integer,
                .long => return bt.Integer,
                .ulong => return bt.Integer,
                .usize => return bt.Integer,
                .float => return bt.Float,
                .double => return bt.Float,
                .funcPtr,
                .charPtr,
                .voidPtr => {
                    const data = vm.getData(*cy.builtins.BuiltinsData, "builtins");
                    return data.PtrVoid;
                },
                .void => return bt.Void,
                else => {
                    std.debug.print("Unsupported val type: {s}\n", .{ @tagName(sym) });
                    return error.InvalidArgument;
                }
            }
        }
    }
}

pub fn ffiBindLib(vm: *cy.VM, config: BindLibConfig) !Value {
    const ffi = vm.getHostObject(*FFI, 0);

    const bt_data = vm.getData(*cy.builtins.BuiltinsData, "builtins");

    var success = false;

    var lib = try vm.alloc.create(std.DynLib);
    defer {
        if (!success) {
            vm.alloc.destroy(lib);
        }
    }

    const path = vm.getObject(*cy.heap.Object, 1);
    if (path.getValue(0).asInt() == 0) {
        if (builtin.os.tag == .macos) {
            const exe = try std.fs.selfExePathAlloc(vm.alloc);
            defer vm.alloc.free(exe);
            lib.* = try dlopen(exe);
        } else {
            lib.* = try dlopen("");
        }
    } else {
        const path_s = path.getValue(1).asString();
        log.tracev("bindLib {s}", .{path_s});
        lib.* = dlopen(path_s) catch |err| {
            if (err == error.FileNotFound) {
                return rt.prepThrowError(vm, .FileNotFound);
            } else {
                return err;
            }
        };
    }

    // Generate c code.
    var csrc: std.ArrayListUnmanaged(u8) = .{};
    defer csrc.deinit(vm.alloc);
    const w = csrc.writer(vm.alloc);

    var cgen = CGen{ .ffi = ffi };

    try cgen.genHeaders(w);

    try cgen.genStructDecls(w);

    try cgen.genArrayConvDecls(w);

    try cgen.genStructConvs(w);

    try cgen.genArrayConvs(w);

    // Begin func binding generation.

    var tempTypes: std.BoundedArray(sema.FuncParam, 16) = .{};
    for (ffi.cfuncs.items) |*cfunc| {
        // Check that symbol exists.
        cfunc.skip = false;
        const ptr = lib.lookup(*anyopaque, cfunc.namez) orelse {
            log.tracev("Missing sym: '{s}'", .{cfunc.namez});
            // Don't generate function if it is missing from the lib.
            cfunc.skip = true;
            continue;
        };

        // Build function signature.
        tempTypes.len = 0;
        if (!config.gen_table) {
            // Self param.
            const param_t = sema.FuncParam.init(bt.Any);
            try tempTypes.append(param_t);
        }
        for (cfunc.params) |param| {
            const typeId = try toCyType(vm, param);
            const param_t = sema.FuncParam.init(typeId);
            try tempTypes.append(param_t);
        }

        const retType = try toCyType(vm, cfunc.ret);
        const funcSigId = try vm.sema.ensureFuncSig(tempTypes.slice(), retType);

        cfunc.ptr = ptr;
        cfunc.funcSigId = funcSigId;
        try cgen.genFunc(vm, w, cfunc.*, config);
    }

    for (ffi.cstructs.items) |cstruct| {
        // Generate ptrTo[Object].
        const isMethod = !config.gen_table;
        try w.print("uint64_t cyPtrTo{s}(VM* vm) {{\n", .{vm.getTypeName(cstruct.type)});
        if (isMethod) {
            try w.print("  uint64_t ptr = cy_get_value(vm, 1);\n", .{});
        } else {
            try w.print("  uint64_t ptr = cy_get_value(vm, 0);\n", .{});
        }
        try w.print("  uint64_t res = fromStruct{}(vm, *(Struct{}*)ptr);\n", .{cstruct.type, cstruct.type});
        try w.print("  return res;\n", .{});
        try w.print("}}\n", .{});
    }

    try w.writeByte(0);
    if (DumpCGen) {
        std.debug.print("{s}\n", .{csrc.items});
    }

    const state = tcc.tcc_new();
    // Don't include libtcc1.a.
    _ = tcc.tcc_set_options(state, "-nostdlib");
    _ = tcc.tcc_set_output_type(state, tcc.TCC_OUTPUT_MEMORY);

    if (tcc.tcc_compile_string(state, csrc.items.ptr) == -1) {
        cy.panic("Failed to compile c source.");
    }

    // const __floatundisf = @extern(*anyopaque, .{ .name = "__floatundisf", .linkage = .Strong });
    if (builtin.cpu.arch != .aarch64) {
        _ = tcc.tcc_add_symbol(state, "__fixunsdfdi", __fixunsdfdi);
        _ = tcc.tcc_add_symbol(state, "__floatundidf", __floatundidf);
    }
    // _ = tcc.tcc_add_symbol(state, "__floatundisf", __floatundisf);
    _ = tcc.tcc_add_symbol(state, "printf", std.c.printf);
    // _ = tcc.tcc_add_symbol(state, "exit", std.c.exit);
    // _ = tcc.tcc_add_symbol(state, "breakpoint", breakpoint);
    _ = tcc.tcc_add_symbol(state, "_cyRelease", cyRelease);
    _ = tcc.tcc_add_symbol(state, "icyGetPtr", cGetPtr);
    _ = tcc.tcc_add_symbol(state, "cy_as_boxint", cAsBoxInt);
    _ = tcc.tcc_add_symbol(state, "_cyGetFuncPtr", cGetFuncPtr);
    _ = tcc.tcc_add_symbol(state, "icyAllocCyPointer", cAllocCyPointer);
    _ = tcc.tcc_add_symbol(state, "icyAllocObject", cAllocObject);
    _ = tcc.tcc_add_symbol(state, "cy_alloc_int", cAllocInt);
    _ = tcc.tcc_add_symbol(state, "icyAllocList", cAllocList);
    // _ = tcc.tcc_add_symbol(state, "printValue", cPrintValue);
    if (builtin.cpu.arch == .aarch64) {
        _ = tcc.tcc_add_symbol(state, "memmove", memmove);
    }

    // Add binded symbols.
    for (ffi.cfuncs.items) |cfunc| {
        if (cfunc.skip) continue;
        _ = tcc.tcc_add_symbol(state, cfunc.namez.ptr, cfunc.ptr);
    }

    if (tcc.tcc_relocate(state, tcc.TCC_RELOCATE_AUTO) < 0) {
        cy.panic("Failed to relocate compiled code.");
    }

    if (config.gen_table) {
        // Create map with binded C-functions as functions.
        const table = try vm.allocTable();

        const cyState = try cy.heap.allocTccState(vm, state.?, lib);

        var numGenFuncs: u32 = 0;
        for (ffi.cfuncs.items) |cfunc| {
            if (cfunc.skip) continue;
            const symGen = try std.fmt.allocPrint(vm.alloc, "cy{s}\x00", .{cfunc.namez});
            defer vm.alloc.free(symGen);
            const funcPtr = tcc.tcc_get_symbol(state, symGen.ptr) orelse {
                cy.panic("Failed to get symbol.");
            };

            const symKey = try vm.retainOrAllocAstring(cfunc.namez);
            const func = cy.ptrAlignCast(cy.ZHostFuncFn, funcPtr);
            const funcSig = vm.compiler.sema.getFuncSig(cfunc.funcSigId);

            const ptr_t = try cy.vm.getFuncPtrType(vm, cfunc.funcSigId);
            const funcVal = try cy.heap.allocHostFuncPtr(vm, ptr_t, func, @intCast(cfunc.params.len),
                cfunc.funcSigId, cyState, funcSig.info.reqCallTypeCheck);
            try table.asHeapObject().table.set(vm, symKey, funcVal);
            vm.release(symKey);
            vm.release(funcVal);
            numGenFuncs += 1;
        }
        cy.arc.retainInc(vm, cyState, @intCast(numGenFuncs + ffi.cstructs.items.len - 1));
        for (ffi.cstructs.items) |cstruct| {
            const typeName = vm.getTypeName(cstruct.type);
            const symGen = try std.fmt.allocPrint(vm.alloc, "cyPtrTo{s}{u}", .{typeName, 0});
            defer vm.alloc.free(symGen);
            const funcPtr = tcc.tcc_get_symbol(state, symGen.ptr) orelse {
                cy.panic("Failed to get symbol.");
            };

            const symKey = try vm.allocAstringConcat("ptrTo", typeName);
            const func = cy.ptrAlignCast(cy.ZHostFuncFn, funcPtr);

            const funcSigId = try vm.sema.ensureFuncSigRt(&.{ bt_data.PtrVoid }, cstruct.type);
            const ptr_t = try cy.vm.getFuncPtrType(vm, funcSigId);
            const funcVal = try cy.heap.allocHostFuncPtr(vm, ptr_t, func, 1, funcSigId, cyState, false);
            try table.asHeapObject().table.set(vm, symKey, funcVal);
            vm.release(symKey);
            vm.release(funcVal);
        }
        success = true;
        return table;
    } else {
        // Create anonymous struct with binded C-functions as methods.
        const osSym = vm.compiler.chunk_map.get("os").?.sym;
        const sid = try vm.addAnonymousStruct(@ptrCast(osSym), "BindLib", os.nextUniqId, &.{ "tcc" });
        os.nextUniqId += 1;
        const tccField = try vm.ensureField("tcc");
        try vm.addTypeField(sid, tccField, 0, bt.Any);

        const cyState = try cy.heap.allocTccState(vm, state.?, lib);
        for (ffi.cfuncs.items) |cfunc| {
            if (cfunc.skip) continue;
            const cySym = try std.fmt.allocPrint(vm.alloc, "cy{s}\x00", .{cfunc.namez});
            defer vm.alloc.free(cySym);
            const funcPtr = tcc.tcc_get_symbol(state, cySym.ptr) orelse {
                cy.panic("Failed to get symbol.");
            };

            const func = cy.ptrAlignCast(cy.ZHostFuncFn, funcPtr);

            const func_sig = vm.compiler.sema.getFuncSig(cfunc.funcSigId);
            const func_sym = rt.FuncSymbol.initHostFunc(@ptrCast(func), func_sig.info.reqCallTypeCheck, true, func_sig.numParams(), cfunc.funcSigId);
            const group = try vm.addFuncGroup();
            _ = try vm.addGroupFunc(group, cfunc.namez, cfunc.funcSigId, func_sym);
            try @call(.never_inline, cy.VM.setMethodGroup, .{vm, sid, cfunc.namez, group});
        }
        for (ffi.cstructs.items) |cstruct| {
            const typeName = vm.getTypeName(cstruct.type);
            const symGen = try std.fmt.allocPrint(vm.alloc, "cyPtrTo{s}{u}", .{typeName, 0});
            defer vm.alloc.free(symGen);
            const funcPtr = tcc.tcc_get_symbol(state, symGen.ptr) orelse {
                cy.panic("Failed to get symbol.");
            };
            const func = cy.ptrAlignCast(cy.ZHostFuncFn, funcPtr);

            const methodName = try std.fmt.allocPrint(vm.alloc, "ptrTo{s}", .{typeName});
            defer vm.alloc.free(methodName);

            const name_id = try rt.ensureNameSymExt(vm, methodName, true);
            const managed_name = rt.getName(vm, name_id);

            const funcSigId = try vm.sema.ensureFuncSigRt(&.{ bt.Any, bt_data.PtrVoid }, cstruct.type);
            const group = try vm.addFuncGroup();
            const func_sym = rt.FuncSymbol.initHostFunc(@ptrCast(func), true, true, 2, funcSigId);
            _ = try vm.addGroupFunc(group, managed_name, funcSigId, func_sym);
            try @call(.never_inline, cy.VM.setMethodGroup, .{vm, sid, managed_name, group});
        }
        success = true;
        return try vm.allocObjectSmall(sid, &.{cyState});
    }
}

const CFuncData = struct {
    namez: [:0]const u8,
    params: []const CType,
    ret: CType,
    ptr: *anyopaque,
    funcSigId: cy.sema.FuncSigId,
    skip: bool,
};

fn dlopen(path: []const u8) !std.DynLib {
    if (builtin.os.tag == .linux and builtin.link_libc) {
        const path_c = try std.posix.toPosixPath(path);
        // Place the lookup scope of the symbols in this library ahead of the global scope.
        const RTLD_DEEPBIND = 0x00008;
        return std.DynLib{
            .inner = .{
                .handle = std.c.dlopen(&path_c, std.c.RTLD.LAZY | RTLD_DEEPBIND) orelse {
                    return error.FileNotFound;
                },
            },
        };
    } else {
        return std.DynLib.open(path);
    }
}

extern fn __floatundidf(u64) f64;
extern fn __fixunsdfdi(f64) u64;
extern fn memmove(dst: *anyopaque, src: *anyopaque, num: usize) *anyopaque;

fn cyRelease(vm: *cy.VM, val: Value) callconv(.C) void {
    vm.release(val);
}

fn cAsBoxInt(val: Value) callconv(.C) i64 {
    return val.asBoxInt();
}

fn cGetPtr(vm: *cy.VM, val: Value) callconv(.C) ?*anyopaque {
    const valT = val.getTypeId();
    switch (valT) {
        else => {
            const type_e = vm.c.types[valT];
            if (type_e.kind == .int) {
                const addr: usize = @intCast(val.asBoxInt());
                return @ptrFromInt(addr);
            }
            // TODO: Since union types aren't supported yet, check for type miss.
            cy.panicFmt("Expected `pointer`, got type id: `{}`", .{valT});
        },
    }
}

fn cGetFuncPtr(vm: *cy.VM, val: Value) callconv(.C) ?*anyopaque {
    const valT = val.getTypeId();
    switch (valT) {
        else => {
            const type_e = vm.c.types[valT];
            if (type_e.kind == .int) {
                const addr: usize = @intCast(val.asBoxInt());
                return @ptrFromInt(addr);
            }
            // TODO: Since union types aren't supported yet, check for type miss.
            cy.panicFmt("Expected `pointer`, got type id: `{}`", .{valT});
        },
    }
}

fn cAllocCyPointer(vm: *cy.VM, ptr: ?*anyopaque) callconv(.C) Value {
    const bt_data = vm.getData(*cy.builtins.BuiltinsData, "builtins");
    return cy.heap.allocPointer(vm, bt_data.PtrVoid, ptr) catch cy.fatal();
}

fn cAllocInt(vm: *cy.VM, val: i64) callconv(.C) Value {
    return vm.allocInt(val) catch cy.fatal();
}

fn cAllocObject(vm: *cy.VM, id: cy.TypeId) callconv(.C) Value {
    const numFields = vm.compiler.sema.types.items[id].data.object.numFields;
    if (numFields <= 4) {
        return cy.heap.allocEmptyObjectSmall(vm, id) catch cy.fatal();
    } else {
        return cy.heap.allocEmptyObject(vm, id, numFields) catch cy.fatal();
    }
}

fn cAllocList(vm: *cy.VM, elems: [*]Value, n: u32) callconv(.C) Value {
    return cy.heap.allocListDyn(vm, elems[0..n]) catch cy.fatal();
}

fn cyCallFunc(vm: *cy.VM, func: Value, args: [*]const Value, nargs: u8) callconv(.C) Value {
    // TODO: Since the host may decide to ignore an error, force an exit here.
    //       A better approach is to return the error but disable the VM until the error has been acknowledged by the host.
    const res = vm.callFunc(func, args[0..nargs], .{}) catch {
        cy.panic("cyCallFunc error.");
    };
    return res;
}

fn cPrintValue(val: u64) void {
    const v: Value = @bitCast(val);
    v.dump();
}

fn breakpoint() callconv(.C) void {
    @breakpoint();
}

pub fn ffiBindCallback(vm: *cy.VM) anyerror!Value {
    if (!cy.hasFFI) return vm.prepPanic("Unsupported.");

    const ffi = vm.getHostObject(*FFI, 0);
    const func = vm.getValue(1);
    const params = vm.getObject(*cy.heap.List, 2).items();
    const ret = try ffi.toCType(vm, vm.getValue(3));

    var csrc: std.ArrayListUnmanaged(u8) = .{};
    defer csrc.deinit(vm.alloc);
    const w = csrc.writer(vm.alloc);

    const cgen = CGen{ .ffi = ffi };
    try cgen.genHeaders(w);
    try cgen.genStructDecls(w);
    try cgen.genArrayConvDecls(w);
    try cgen.genStructConvs(w);
    try cgen.genArrayConvs(w);

    // Emit C func declaration.
    try writeCType(w, ret);
    try w.print(" cyExternFunc(", .{});
    if (params.len > 0) {
        var ctype = try ffi.toCType(vm, params[0]);
        try writeCType(w, ctype);
        try w.print(" p0", .{});

        if (params.len > 1) {
            for (params[1..], 1..) |param, i| {
                try w.print(", ", .{});
                ctype = try ffi.toCType(vm, param);
                try writeCType(w, ctype);
                try w.print(" p{}", .{i});
            }
        }
    }
    try w.print(") {{\n", .{});

    try w.print("  VM* vm = (VM*)0x{X};\n", .{@intFromPtr(vm)});
    try w.print("  uint64_t args[{}];\n", .{params.len});
    for (params, 0..) |param, i| {
        const ctype = try ffi.toCType(vm, param);
        try w.print("  args[{}] = ", .{i});
        const cval = try std.fmt.bufPrint(&cy.tempBuf, "p{}", .{i});
        try writeToCyValue(w, cval, ctype, true);
        try w.print(";\n", .{});
    }

    try w.print("  int64_t res = _cyCallFunc(vm, 0x{X}, &args[0], {});\n", .{
        func.val,
        params.len,
    });

    // Release temp args.
    for (params, 0..) |_, i| {
        try w.print("  _cyRelease(vm, args[{}]);\n", .{i});
    }

    try w.print("  ", .{});
    try writeCType(w, ret);
    try w.print(" ret = ", .{});
    try writeToCValue(w, "res", ret, true);
    try w.print(";\n", .{});
    try w.print("  _cyRelease(vm, res);\n", .{});
    try w.print("  return ret;\n", .{});
    try w.print("}}\n", .{});

    try w.writeByte(0);
    if (DumpCGen) {
        std.debug.print("{s}\n", .{csrc.items});
    }

    const state = tcc.tcc_new();
    // Don't include libtcc1.a.
    _ = tcc.tcc_set_options(state, "-nostdlib");
    _ = tcc.tcc_set_output_type(state, tcc.TCC_OUTPUT_MEMORY);

    if (tcc.tcc_compile_string(state, csrc.items.ptr) == -1) {
        cy.panic("Failed to compile c source.");
    }

    // const __floatundisf = @extern(*anyopaque, .{ .name = "__floatundisf", .linkage = .Strong });
    if (builtin.cpu.arch != .aarch64) {
        _ = tcc.tcc_add_symbol(state, "__fixunsdfdi", __fixunsdfdi);
        _ = tcc.tcc_add_symbol(state, "__floatundidf", __floatundidf);
    }
    // _ = tcc.tcc_add_symbol(state, "__floatundisf", __floatundisf);
    _ = tcc.tcc_add_symbol(state, "printf", std.c.printf);
    // _ = tcc.tcc_add_symbol(state, "exit", std.c.exit);
    // _ = tcc.tcc_add_symbol(state, "breakpoint", breakpoint);
    _ = tcc.tcc_add_symbol(state, "icyGetPtr", cGetPtr);
    _ = tcc.tcc_add_symbol(state, "cy_as_boxint", cAsBoxInt);
    _ = tcc.tcc_add_symbol(state, "icyAllocCyPointer", cAllocCyPointer);
    _ = tcc.tcc_add_symbol(state, "icyAllocObject", cAllocObject);
    _ = tcc.tcc_add_symbol(state, "icyAllocList", cAllocList);
    _ = tcc.tcc_add_symbol(state, "cy_alloc_int", cAllocInt);
    _ = tcc.tcc_add_symbol(state, "_cyCallFunc", cyCallFunc);
    _ = tcc.tcc_add_symbol(state, "_cyRelease", cyRelease);
    // _ = tcc.tcc_add_symbol(state, "printValue", cPrintValue);
    if (builtin.cpu.arch == .aarch64) {
        _ = tcc.tcc_add_symbol(state, "memmove", memmove);
    }

    if (tcc.tcc_relocate(state, tcc.TCC_RELOCATE_AUTO) < 0) {
        cy.panic("Failed to relocate compiled code.");
    }

    const tccState = try cy.heap.allocTccState(vm, state.?, null);

    const funcPtr = tcc.tcc_get_symbol(state, "cyExternFunc") orelse {
        cy.panic("Failed to get symbol.");
    };

    // Extern func consumes tcc state and retains func.
    vm.retain(func);

    // Create extern func.
    const res = try cy.heap.allocExternFunc(vm, func, funcPtr, tccState);

    // ffi manages the extern func. (So it does not get freed).
    vm.retain(res);
    try ffi.managed.append(vm.alloc, res);

    return res;
}

pub fn ffiBindObjPtr(vm: *cy.VM) anyerror!Value {
    if (!vm.getValue(1).isPointer()) return error.InvalidArgument;

    const ffi = vm.getHostObject(*FFI, 0);
    const obj = vm.getValue(1).asHeapObject();

    // Retain and managed by FFI context.
    vm.retainObject(obj);
    try ffi.managed.append(vm.alloc, vm.getValue(1));
    
    return Value.initRaw(@intFromPtr(obj));
}

pub fn ffiUnbindObjPtr(vm: *cy.VM) anyerror!Value {
    if (!vm.getValue(1).isPointer()) return error.InvalidArgument;

    const ffi = vm.getHostObject(*FFI, 0);
    const val = vm.getValue(1);

    // Linear scan for now.
    for (ffi.managed.items, 0..) |ffiObj, i| {
        if (val.val == ffiObj.val) {
            vm.release(val);
            _ = ffi.managed.swapRemove(i);
            break;
        }
    }

    return Value.Void;
}

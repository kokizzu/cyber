const std = @import("std");
const stdx = @import("stdx");
const t = stdx.testing;
const builtin = @import("builtin");
const cy = @import("cyber.zig");
const rt = cy.rt;
const C = @import("capi.zig");
const fmt = cy.fmt;
const v = fmt.v;
const sema = cy.sema;
const types = cy.types;
const log = cy.log.scoped(.chunk);
const llvm = @import("llvm.zig");
const llvm_gen = @import("llvm_gen.zig");
const bc = @import("bc_gen.zig");
const jitgen = @import("jit/gen.zig");
const X64 = @import("jit/x64.zig");
const ast = cy.ast;

pub const ChunkId = u32;
pub const SymId = u32;
pub const FuncId = u32;

/// A compilation unit.
/// It contains data to compile from source into a module with exported symbols.
pub const Chunk = struct {
    id: ChunkId,
    alloc: std.mem.Allocator,
    compiler: *cy.Compiler,
    sema: *cy.Sema,
    vm: *cy.VM,

    /// Source code. Can be owned depending on `srcOwned`
    src: []const u8,

    /// Read-only view of the AST.
    ast: cy.ast.AstView,

    /// Owned, absolute path to source.
    srcUri: []const u8,

    parser: cy.Parser,

    /// Used for temp string building.
    tempBufU8: std.ArrayListUnmanaged(u8),

    /// Since nodes are currently processed recursively,
    /// set the current node so that error reporting has a better
    /// location context for helper methods that simply return no context errors.
    curNode: ?*ast.Node,

    ///
    /// Sema pass.
    ///
    semaProcs: std.ArrayListUnmanaged(sema.Proc),
    semaBlocks: std.ArrayListUnmanaged(sema.Block),
    capVarDescs: std.AutoHashMapUnmanaged(sema.LocalVarId, sema.CapVarDesc),

    /// Generic stacks.
    dataStack: std.ArrayListUnmanaged(Data),
    dataU8Stack: std.ArrayListUnmanaged(DataU8),
    listDataStack: std.ArrayListUnmanaged(ListData),

    /// Stack for building func signatures. (eg. for nested func calls)
    typeStack: std.ArrayListUnmanaged(types.TypeId),

    valueStack: std.ArrayListUnmanaged(cy.Value),

    /// IR buffer can be swapped in, this will go away when migrating to `Worker`.
    ir: *cy.ir.Buffer,
    own_ir: cy.ir.Buffer,

    /// Maps a IR local to a VM local.
    genIrLocalMapStack: std.ArrayListUnmanaged(u8),

    /// VM locals. From a block's `localStart` offset, this is indexed by the virtual reg 
    /// which includes function prelude regs and params for simplicity.

    /// Slots for locals and temps.
    /// Each procedure has a maximum of 255 registers starting at index 0.
    /// The slot at index 255 isn't used and represents Null.
    /// The slots in the front are reserved for the call convention and params.
    slot_stack: std.ArrayListUnmanaged(bc.Slot),

    /// Local vars.
    varStack: std.ArrayListUnmanaged(sema.LocalVar),
    varShadowStack: std.ArrayListUnmanaged(cy.sema.VarShadow),
    preLoopVarSaveStack: std.ArrayListUnmanaged(cy.sema.PreLoopVarSave),
    assignedVarStack: std.ArrayListUnmanaged(sema.LocalVarId),

    /// Main sema block id.
    mainSemaProcId: sema.ProcId,

    /// Names to chunk syms or using namespace (use imports, use aliases).
    /// Chunk syms have a higher precedence.
    /// This is populated after symbol queries.
    sym_cache: std.StringHashMapUnmanaged(*cy.Sym),

    /// Symbols in the fallback using namespace.
    use_alls: std.ArrayListUnmanaged(*cy.Sym),
    use_global: bool,

    /// Successful module func signature matches are cached.
    funcCheckCache: std.HashMapUnmanaged(sema.ModFuncSigKey, *cy.Func, cy.hash.KeyU96Context, 80),

    /// Object type dependency graph.
    /// This is only needed for default initializers so it is created on demand per chunk.
    typeDeps: std.ArrayListUnmanaged(TypeDepNode),
    typeDepsMap: std.AutoHashMapUnmanaged(*cy.Sym, u32),

    /// Syms owned by this chunk. Does not include field syms.
    syms: std.ArrayListUnmanaged(*cy.Sym),

    /// Functions owned by this chunk.
    /// Includes lambdas which are not linked from a named sym.
    funcs: std.ArrayListUnmanaged(*cy.Func),

    /// Reference the current resolve context.
    resolve_stack: std.ArrayListUnmanaged(sema.ResolveContext),

    arg_stack: std.ArrayListUnmanaged(sema.Argument),

    ///
    /// Codegen pass
    ///
    proc_stack: std.ArrayListUnmanaged(bc.Proc),
    procs: std.ArrayListUnmanaged([]const u8),
    blocks: std.ArrayListUnmanaged(bc.Block),
    blockJumpStack: std.ArrayListUnmanaged(BlockJump),

    regStack: std.ArrayListUnmanaged(u8),
    operandStack: std.ArrayListUnmanaged(u8),

    unwind_stack: std.ArrayListUnmanaged(bc.UnwindEntry),

    curBlock: *bc.Proc,

    /// Shared final code buffer.
    buf: *cy.ByteCodeBuffer,
    jitBuf: *jitgen.CodeBuffer,
    x64Enc: X64.Encoder,

    /// Whether the src is owned by the chunk.
    srcOwned: bool,

    /// This chunk's sym.
    sym: *cy.sym.Chunk,

    /// For binding @host func declarations.
    host_funcs: std.StringHashMapUnmanaged(C.FuncFn),
    func_loader: C.FuncLoaderFn = null,
    /// For binding @host var declarations.
    varLoader: C.VarLoaderFn = null,
    /// For binding @host type declarations.
    host_types: std.StringHashMapUnmanaged(C.HostType),
    type_loader: C.TypeLoaderFn = null,
    /// Run after type declarations are loaded.
    onTypeLoad: C.ModuleOnTypeLoadFn = null,
    /// Run after declarations have been loaded.
    onLoad: C.ModuleOnLoadFn = null,
    /// Run before chunk is destroyed.
    onDestroy: C.ModuleOnDestroyFn = null,
    /// Counter for loading @host vars.
    curHostVarIdx: u32,

    hasStaticInit: bool,

    encoder: cy.ast.Encoder,

    /// For declaring unnamed types.
    /// This does not mean that the id is unique since user defined types may have been declared
    /// before this id is used.
    nextUnnamedId: u32,

    indent: u32,

    /// Funcs deferred to a later sema pass. (eg. func variants, funcs from parent type variants)
    /// Assumed to have resolved signatures.
    deferred_funcs: std.ArrayListUnmanaged(*cy.Func),

    /// LLVM
    tempTypeRefs: if (cy.hasJIT) std.ArrayListUnmanaged(llvm.TypeRef) else void,
    tempValueRefs: if (cy.hasJIT) std.ArrayListUnmanaged(llvm.ValueRef) else void,
    // mod: if (cy.hasJIT) llvm.ModuleRef else void,
    builder: if (cy.hasJIT) llvm.BuilderRef else void,
    ctx: if (cy.hasJIT) llvm.ContextRef else void,
    llvmFuncs: if (cy.hasJIT) []LLVM_Func else void, // One-to-one with `semaFuncDecls`

    /// Chunk owns `srcUri` and `src`.
    pub fn init(self: *Chunk, c: *cy.Compiler, id: ChunkId, srcUri: []const u8, src: []const u8) !void {
        self.* = .{
            .id = id,
            .alloc = c.alloc,
            .compiler = c,
            .sema = &c.sema,
            .vm = c.vm,
            .src = src,
            .ast = undefined,
            .srcUri = srcUri,
            .sym = undefined,
            .parser = undefined,
            .semaProcs = .{},
            .semaBlocks = .{},
            .capVarDescs = .{},
            .proc_stack = .{},
            .procs = .{},
            .blocks = .{},
            .blockJumpStack = .{},
            .assignedVarStack = .{},
            .varShadowStack = .{},
            .varStack = .{},
            .preLoopVarSaveStack = .{},
            .typeStack = .{},
            .valueStack = .{},
            .ir = undefined,
            .own_ir = cy.ir.Buffer.init(),
            .slot_stack = .{},
            .genIrLocalMapStack = .{},
            .dataStack = .{},
            .dataU8Stack = .{},
            .listDataStack = .{},
            .regStack = .{},
            .operandStack = .{},
            .unwind_stack = .{},
            .curBlock = undefined,
            .buf = undefined,
            .jitBuf = undefined,
            .x64Enc = undefined,
            .curNode = null,
            .tempBufU8 = .{},
            .srcOwned = true,
            .mainSemaProcId = cy.NullId,
            .sym_cache = .{},
            .use_alls = .{},
            .use_global = false,
            .funcCheckCache = .{},
            .curHostVarIdx = 0,
            .tempTypeRefs = undefined,
            .tempValueRefs = undefined,
            .builder = undefined,
            .ctx = undefined,
            .llvmFuncs = undefined,
            .typeDeps = .{},
            .typeDepsMap = .{},
            .hasStaticInit = false,
            .encoder = undefined,
            .nextUnnamedId = 1,
            .indent = 0,
            .deferred_funcs = .{},
            .syms = .{},
            .funcs = .{},
            .resolve_stack = .{},
            .arg_stack = .{},
            .host_types = .{},
            .host_funcs = .{},
        };
        self.ir = &self.own_ir;
        try self.parser.init(c.alloc);

        if (cy.hasJIT) {
            self.tempTypeRefs = .{};
            self.tempValueRefs = .{};
            // self.exprResStack = .{};
            // self.exprStack = .{};
            self.llvmFuncs = &.{};
        }
    }

    pub fn deinit(self: *Chunk) void {
        self.tempBufU8.deinit(self.alloc);

        self.host_funcs.deinit(self.alloc);
        self.host_types.deinit(self.alloc);

        for (self.semaBlocks.items) |*b| {
            b.deinit(self.alloc);
        }
        self.semaBlocks.deinit(self.alloc);

        for (self.semaProcs.items) |*sproc| {
            sproc.deinit(self.alloc);
        }
        self.semaProcs.deinit(self.alloc);

        self.proc_stack.deinit(self.alloc);
        self.procs.deinit(self.alloc);
        self.blocks.deinit(self.alloc); 

        self.blockJumpStack.deinit(self.alloc);
        self.assignedVarStack.deinit(self.alloc);
        self.varShadowStack.deinit(self.alloc);
        self.varStack.deinit(self.alloc);
        self.preLoopVarSaveStack.deinit(self.alloc);
        self.regStack.deinit(self.alloc);
        self.operandStack.deinit(self.alloc);
        self.unwind_stack.deinit(self.alloc);
        self.capVarDescs.deinit(self.alloc);

        self.typeStack.deinit(self.alloc);
        self.valueStack.deinit(self.alloc);
        self.own_ir.deinit(self.alloc);
        self.dataStack.deinit(self.alloc);
        self.dataU8Stack.deinit(self.alloc);
        self.listDataStack.deinit(self.alloc);
        self.genIrLocalMapStack.deinit(self.alloc);
        self.slot_stack.deinit(self.alloc);
        self.resolve_stack.deinit(self.alloc);
        self.arg_stack.deinit(self.alloc);

        if (cy.hasJIT) {
            self.tempTypeRefs.deinit(self.alloc);
            self.tempValueRefs.deinit(self.alloc);
            // self.exprResStack.deinit(self.alloc);
            // self.exprStack.deinit(self.alloc);
            self.alloc.free(self.llvmFuncs);
        }

        self.typeDeps.deinit(self.alloc);
        self.typeDepsMap.deinit(self.alloc);

        self.sym_cache.deinit(self.alloc);
        self.use_alls.deinit(self.alloc);

        for (self.funcs.items) |func| {
            self.alloc.destroy(func);
        }
        self.funcs.deinit(self.alloc);

        // Deinit chunk syms. Any retained values must already be freed in case they need to reference syms.
        for (self.syms.items) |sym| {
            sym.destroy(self.vm, self.alloc);
        }
        self.syms.deinit(self.alloc);

        for (self.deferred_funcs.items) |func| {
            self.alloc.destroy(func);
        }
        self.deferred_funcs.deinit(self.alloc);

        // Free source last since nodes, syms depend on it.
        self.alloc.free(self.srcUri);
        self.parser.deinit();
        if (self.srcOwned) {
            self.alloc.free(self.src);
        }
    }

    pub fn fromC(mod: C.Module) *cy.Chunk {
        return @ptrCast(@alignCast(mod.ptr));
    }

    pub fn updateAstView(self: *cy.Chunk, view: cy.ast.AstView) void {
        self.ast = view;
        self.encoder.ast = view;
    }

    pub fn genBlock(self: *cy.Chunk) *bc.Block {
        return &self.blocks.items[self.blocks.items.len-1];
    }

    pub fn block(self: *cy.Chunk) *sema.Block {
        return &self.semaBlocks.items[self.semaBlocks.items.len-1];
    }

    pub fn proc(self: *cy.Chunk) *sema.Proc {
        return &self.semaProcs.items[self.semaProcs.items.len-1];
    }

    pub fn getProcParams(c: *const cy.Chunk, p: *sema.Proc) []const sema.LocalVar {
        return c.varStack.items[p.varStart..p.varStart+p.numParams];
    }

    /// Includes aliases.
    pub fn getProcVars(c: *const cy.Chunk, p: *sema.Proc) []const sema.LocalVar {
        return c.varStack.items[p.varStart+p.numParams..];
    }

    pub fn getNextUniqUnnamedIdent(c: *Chunk, buf: *[16]u8) []const u8 {
        const symMap = c.sym.getMod().symMap;
        var fbuf = std.io.fixedBufferStream(buf);
        const w = fbuf.writer();
        w.writeAll("unnamed") catch cy.fatal();
        while (true) {
            fbuf.pos = "unnamed".len;
            std.fmt.formatInt(c.nextUnnamedId, 10, .lower, .{}, w) catch cy.fatal();
            const name = fbuf.getWritten();
            if (symMap.contains(name)) {
                c.nextUnnamedId += 1;
            } else {
                defer c.nextUnnamedId += 1;
                return name;
            }
        }
    }

    pub inline fn isInStaticInitializer(self: *Chunk) bool {
        return self.compiler.svar_init_stack.items.len > 0;
    }

    pub inline fn semaBlockDepth(self: *Chunk) u32 {
        return @intCast(self.semaProcs.items.len);
    }

    pub fn reserveIfTempLocal(self: *Chunk, local: LocalId) !void {
        if (self.isTempLocal(local)) {
            try self.setReservedTempLocal(local);
        }
    }

    pub fn initGenValue(self: *const Chunk, local: LocalId, vtype: types.TypeId, retained: bool) bc.GenValue {
        if (self.isTempLocal(local)) {
            return bc.GenValue.initTempValue(local, vtype, retained);
        } else {
            return bc.GenValue.initLocalValue(local, vtype, retained);
        }
    }

    /// Given two local values, determine the next destination temp local.
    /// The type of the dest value is left undefined to be set by caller.
    fn nextTempDestValue(self: *cy.Compiler, src1: bc.GenValue, src2: bc.GenValue) !bc.GenValue {
        if (src1.isTempLocal == src2.isTempLocal) {
            if (src1.isTempLocal) {
                const minTempLocal = std.math.min(src1.local, src2.local);
                self.setFirstFreeTempLocal(minTempLocal + 1);
                return bc.GenValue.initTempValue(minTempLocal, undefined);
            } else {
                return bc.GenValue.initTempValue(try self.nextFreeTempLocal(), undefined);
            }
        } else {
            if (src1.isTempLocal) {
                return bc.GenValue.initTempValue(src1.local, undefined);
            } else {
                return bc.GenValue.initTempValue(src2.local, undefined);
            }
        }
    }

    fn genEnsureRequiredType(self: *Chunk, genv: bc.GenValue, requiredType: types.Type) !void {
        if (requiredType.typeT != .any) {
            if (genv.vtype.typeT == requiredType.typeT) {
                return;
            }

            const reqTypeSymId = types.typeToSymbol(requiredType);
            const typeSymId = types.typeToSymbol(genv.vtype);
            if (typeSymId != reqTypeSymId) {
                return self.reportError("Type {} can not be casted to required type {}", &.{v(genv.vtype.typeT), fmt.v(requiredType.typeT)});
            }
        }
    }

    fn canUseVarAsDst(svar: sema.LocalVar) bool {
        // If boxed, the var needs to be copied out of the box.
        // If static selected, the var needs to be copied to a local.
        return !svar.isBoxed and !svar.isStaticAlias;
    }

    pub fn pushTempOperand(self: *Chunk, operand: u8) !void {
        try self.operandStack.append(self.alloc, operand);
    }

    pub fn pushReg(self: *Chunk, reg: u8) !void {
        try self.regStack.append(self.alloc, reg);
    }

    pub fn pushEmptyJumpNotCond(self: *Chunk, condLocal: LocalId) !u32 {
        const start: u32 = @intCast(self.buf.ops.items.len);
        try self.buf.pushOp3(.jumpNotCond, condLocal, 0, 0);
        return start;
    }

    pub fn pushJumpBackCond(self: *Chunk, toPc: usize, condLocal: LocalId) !void {
        const pc = self.buf.ops.items.len;
        try self.buf.pushOp3(.jumpCond, condLocal, 0, 0);
        self.buf.setOpArgU16(pc + 2, @bitCast(-@as(i16, @intCast(pc - toPc))));
    }

    pub fn pushJumpBackTo(self: *Chunk, toPc: usize) !void {
        const pc = self.buf.ops.items.len;
        try self.buf.pushOp2(.jump, 0, 0);
        self.buf.setOpArgU16(pc + 1, @bitCast(-@as(i16, @intCast(pc - toPc))));
    }

    pub fn pushEmptyJump(self: *Chunk) !u32 {
        const start: u32 = @intCast(self.buf.ops.items.len);
        try self.buf.pushOp2(.jump, 0, 0);
        return start;
    }

    pub fn pushEmptyJumpExt(self: *Chunk, desc: ?u32) !u32 {
        const start: u32 = @intCast(self.buf.ops.items.len);
        try self.buf.pushOp2Ext(.jump, 0, 0, desc);
        return start;
    }

    pub fn pushEmptyJumpCond(self: *Chunk, condLocal: LocalId) !u32 {
        const start: u32 = @intCast(self.buf.ops.items.len);
        try self.buf.pushOp3(.jumpCond, condLocal, 0, 0);
        return start;
    }

    pub fn patchJumpToCurPc(self: *Chunk, jumpPc: u32) void {
        self.buf.setOpArgU16(jumpPc + 1, @intCast(self.buf.ops.items.len - jumpPc));
    }

    pub fn patchJumpCondToCurPc(self: *Chunk, jumpPc: u32) void {
        self.buf.setOpArgU16(jumpPc + 2, @intCast(self.buf.ops.items.len - jumpPc));
    }

    pub fn patchJumpNotCondToCurPc(self: *Chunk, jumpPc: u32) void {
        self.buf.setOpArgU16(jumpPc + 2, @intCast(self.buf.ops.items.len - jumpPc));
    }

    /// Patches block breaks. For `if` and `match` blocks.
    /// All other jumps are propagated up the stack by copying to the front.
    /// Returns the adjusted jumpStackStart for this block.
    pub fn patchSubBlockBreakJumps(self: *Chunk, jumpStackStart: usize, breakPc: usize) usize {
        var keepIdx = jumpStackStart;
        for (self.blockJumpStack.items[jumpStackStart..]) |jump| {
            if (jump.jumpT == .subBlockBreak) {
                self.buf.setOpArgU16(jump.pc + 1, @intCast(breakPc - jump.pc));
            } else {
                self.blockJumpStack.items[keepIdx] = jump;
                keepIdx += 1;
            }
        }
        return keepIdx;
    }

    pub fn patchBreaks(self: *Chunk, jumpStackStart: usize, breakPc: usize) usize {
        var keepIdx = jumpStackStart;
        for (self.blockJumpStack.items[jumpStackStart..]) |jump| {
            switch (jump.jumpT) {
                .brk => {
                    if (breakPc > jump.pc) {
                        self.buf.setOpArgU16(jump.pc + 1, @intCast(breakPc - jump.pc));
                    } else {
                        self.buf.setOpArgU16(jump.pc + 1, @bitCast(-@as(i16, @intCast(jump.pc - breakPc))));
                    }
                },
                else => {
                    self.blockJumpStack.items[keepIdx] = jump;
                    keepIdx += 1;
                },
            }
        }
        return keepIdx;
    }

    pub fn patchForBlockJumps(self: *Chunk, jumpStackStart: usize, breakPc: usize, contPc: usize) void {
        for (self.blockJumpStack.items[jumpStackStart..]) |jump| {
            switch (jump.jumpT) {
                .brk => {
                    if (breakPc > jump.pc) {
                        self.buf.setOpArgU16(jump.pc + 1, @intCast(breakPc - jump.pc));
                    } else {
                        self.buf.setOpArgU16(jump.pc + 1, @bitCast(-@as(i16, @intCast(jump.pc - breakPc))));
                    }
                },
                .cont => {
                    if (contPc > jump.pc) {
                        self.buf.setOpArgU16(jump.pc + 1, @intCast(contPc - jump.pc));
                    } else {
                        self.buf.setOpArgU16(jump.pc + 1, @bitCast(-@as(i16, @intCast(jump.pc - contPc))));
                    }
                },
            }
        }
    }

    pub fn getMaxUsedRegisters(self: *Chunk) u8 {
        return self.curBlock.max_slots;
    }

    pub fn blockNumLocals(self: *Chunk) usize {
        return sema.curBlock(self).locals.items.len + sema.curBlock(self).params.items.len;
    }

    pub fn genGetVarPtr(self: *const Chunk, id: sema.LocalVarId) ?*sema.LocalVar {
        if (id != cy.NullId) {
            return &self.vars.items[id];
        } else {
            return null;
        }
    }

    pub fn genGetVar(self: *const Chunk, id: sema.LocalVarId) ?sema.LocalVar {
        if (id != cy.NullId) {
            return self.vars.items[id];
        } else {
            return null;
        }
    }

    pub fn unescapeString(self: *Chunk, literal: []const u8) ![]const u8 {
        try self.tempBufU8.resize(self.alloc, literal.len);
        return cy.sema.unescapeString(self.tempBufU8.items, literal, false);
    }

    pub fn dumpLocals(self: *const Chunk, sproc: *sema.Proc) !void {
        if (cy.Trace) {
            rt.print(self.vm, "Locals:\n");
            const params = self.getProcParams(sproc);
            for (params) |svar| {
                const typeId: types.TypeId = svar.vtype.id;
                rt.printFmt(self.vm, "{} (param), local: {}, dyn: {}, rtype: {}, lifted: {}\n", &.{
                    v(svar.name()), v(svar.local), v(svar.vtype.dynamic), v(typeId),
                    v(svar.inner.local.lifted),
                });
            }
            const vars = self.getProcVars(sproc);
            for (vars) |svar| {
                const typeId: types.TypeId = svar.vtype.id;
                rt.printFmt(self.vm, "{}, local: {}, dyn: {}, rtype: {}, lifted: {}\n", &.{
                    v(svar.name()), v(svar.local), v(svar.vtype.dynamic), v(typeId),
                    v(svar.inner.local.lifted),
                });
            }
        }
    }

    pub fn reportError(self: *Chunk, msg: []const u8, opt_node: ?*ast.Node) error{OutOfMemory, CompileError} {
        const pos = if (opt_node) |node| node.pos() else null;
        try self.compiler.addReport(.compile_err, msg, self.id, pos);
        return error.CompileError;
    }

    pub fn reportErrorFmt(self: *Chunk, format: []const u8, args: []const fmt.FmtValue, opt_node: ?*ast.Node) error{CompileError, OutOfMemory, FormatError} {
        const pos = if (opt_node) |node| node.pos() else null;
        try self.compiler.addReportFmt(.compile_err, format, args, self.id, pos);
        return error.CompileError;
    }

    /// An optional debug sym is only included in Trace builds.
    pub fn pushOptionalDebugSym(c: *Chunk, node: *ast.Node) !void {
        if (cy.Trace or c.compiler.vm.config.gen_all_debug_syms) {
            try c.buf.pushFailableDebugSym(
                c.buf.ops.items.len, c.id, node.pos(), c.curBlock.id,
                cy.fiber.UnwindKey.initNull(),
            );
        }
    }

    pub fn pushFailableDebugSym(self: *Chunk, node: *ast.Node) !void {
        const key = try bc.getLastUnwindKey(self);
        try self.buf.pushFailableDebugSym(
            self.buf.ops.items.len, self.id, node.pos(), self.curBlock.id,
            key,
        );
    }

    fn pushFailableDebugSymAt(self: *Chunk, pc: usize, node: *ast.Node, unwindTempIdx: u32) !void {
        try self.buf.pushFailableDebugSym(pc, self.id, node, self.curBlock.frameLoc, unwindTempIdx);
    }

    pub fn fmtExtraDesc(self: *Chunk, comptime format: []const u8, vals: anytype) !u32 {
        // Behind a comptime flag since it's doing allocation.
        if (cy.Trace) {
            const idx = self.buf.instDescExtras.items.len;
            const text = try std.fmt.allocPrint(self.alloc, format, vals);
            try self.buf.instDescExtras.append(self.alloc, .{
                .text = text,
            });
            return @intCast(idx);
        } else {
            return cy.NullId;
        }
    }

    /// An instruction that can fail (can throw or panic).
    pub fn pushFCode(c: *Chunk, code: cy.OpCode, args: []const u8, node: *ast.Node) !void {
        log.tracev("pushFCode: {s} {}", .{@tagName(code), c.buf.ops.items.len});
        try c.pushFailableDebugSym(node);
        try c.buf.pushOpSliceExt(code, args, null);
    }

    pub fn pushCode(c: *Chunk, code: cy.OpCode, args: []const u8, node: *ast.Node) !void {
        log.tracev("pushCode: {s} {}", .{@tagName(code), c.buf.ops.items.len});
        try c.pushOptionalDebugSym(node);
        try c.buf.pushOpSliceExt(code, args, null);
    }

    pub fn pushCodeExt(c: *Chunk, code: cy.OpCode, args: []const u8, node: *ast.Node, desc: ?u32) !void {
        log.tracev("pushCode: {s} {}", .{@tagName(code), c.buf.ops.items.len});
        try c.pushOptionalDebugSym(node);
        try c.buf.pushOpSliceExt(code, args, desc);
    }

    pub fn pushCodeBytes(c: *Chunk, bytes: []const u8) !void {
        try c.buf.pushOperands(bytes);
    }

    pub usingnamespace cy.sym.ChunkExt;
    pub usingnamespace cy.module.ChunkExt;
    pub usingnamespace cy.types.ChunkExt;
    pub usingnamespace cy.sema.ChunkExt;
    pub usingnamespace jitgen.ChunkExt;
};

test "chunk internals." {
    if (builtin.mode == .ReleaseFast) {
        try t.eq(@sizeOf(Data), 4);
    } else {
        try t.eq(@sizeOf(Data), 4);
    }
}

const BlockJumpType = enum {
    /// Breaks out of a for loop, while loop, or switch stmt.
    brk,
    /// Continues a for loop or while loop.
    cont,
};

const BlockJump = struct {
    jumpT: BlockJumpType,
    pc: u32,
};

const ReservedTempLocal = struct {
    local: LocalId,
};

const LocalId = u8;

pub const LLVM_Func = struct {
    typeRef: llvm.TypeRef,
    funcRef: llvm.ValueRef,
};

pub const TypeDepNode = struct {
    visited: bool,
    hasCircularDep: bool,
    hasUnsupported: bool,
};

pub const ListData = union {
    pc: u32,
    node: ?*ast.Node,
    constIdx: u16,
    jumpToEndPc: u32,
};

pub const DataU8 = extern union {
    irLocal: u8,
    boxed: bool,
};

pub const Data = union {
    placeholder: u32,
};

pub fn pushData(c: *cy.Chunk, data: Data) !void {
    try c.dataStack.append(c.alloc, data);
}

pub fn popData(c: *cy.Chunk) Data {
    return c.dataStack.pop();
}
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const cy = @import("cyber.zig");
const os_mod = @import("std/os.zig");
const test_mod = @import("std/test.zig");
const cache = @import("cache.zig");
const C = @import("capi.zig");
const zErrFunc = cy.builtins.zErrFunc;
const v = cy.fmt.v;
const log = cy.log.scoped(.cli);
const rt = cy.rt;

const builtins = std.ComptimeStringMap(void, .{
    .{"core"},
    .{"math"},
    .{"cy"},
});

const Src = @embedFile("std/cli.cy");

const func = cy.hostFuncEntry;
const funcs = [_]C.HostFuncEntry{
    func("replReadLine",     zErrFunc(replReadLine)),
};

const cli_res = C.ModuleLoaderResult{
    .src = Src,
    .srcLen = Src.len,
    .funcs = C.toSlice(C.HostFuncEntry, &funcs),
    .func_loader = null,
    .onLoad = null,
    .onReceipt = null,
    .types = C.NullSlice,
    .varLoader = null,
    .type_loader = null,
    .onDestroy = null,
    .onTypeLoad = null,
};

const os_res = C.ModuleLoaderResult{
    .src = os_mod.Src,
    .srcLen = os_mod.Src.len,
    .varLoader = os_mod.varLoader,
    .funcs = C.toSlice(C.HostFuncEntry, &os_mod.funcs),
    .func_loader = null,
    .types = C.toSlice(C.HostTypeEntry, &os_mod.types),
    .type_loader = null,
    .onTypeLoad = os_mod.onTypeLoad,
    .onLoad = os_mod.onLoad,
    .onReceipt = null,
    .onDestroy = null,
};

const test_res = C.ModuleLoaderResult{
    .src = test_mod.Src,
    .srcLen = test_mod.Src.len,
    .funcs = C.toSlice(C.HostFuncEntry, &test_mod.funcs),
    .func_loader = null,
    .onLoad = test_mod.onLoad,
    .onReceipt = null,
    .varLoader = null,
    .types = C.NullSlice,
    .type_loader = null,
    .onDestroy = null,
    .onTypeLoad = null,
};

const stdMods = std.ComptimeStringMap(C.ModuleLoaderResult, .{
    .{"cli", cli_res},
    .{"os", os_res},
    .{"test", test_res},
});

pub export fn clSetupForCLI(vm: *C.VM) void {
    C.setResolver(@ptrCast(vm), resolve);
    C.setModuleLoader(@ptrCast(vm), loader);
    C.setPrinter(@ptrCast(vm), print);
    C.setErrorPrinter(@ptrCast(vm), err);
    C.setLog(logFn);
}

fn logFn(str: C.Str) callconv(.C) void {
    if (cy.isWasmFreestanding) {
        os_mod.hostFileWrite(2, str.buf, str.len);
        os_mod.hostFileWrite(2, "\n", 1);
    } else {
        const w = std.io.getStdErr().writer();
        w.writeAll(C.fromStr(str)) catch cy.fatal();
        w.writeByte('\n') catch cy.fatal();
    }
}

fn err(_: ?*C.VM, str: C.Str) callconv(.C) void {
    if (C.silent()) {
        return;
    }
    if (cy.isWasmFreestanding) {
        os_mod.hostFileWrite(2, str.buf, str.len);
    } else {
        const w = std.io.getStdErr().writer();
        w.writeAll(C.fromStr(str)) catch cy.fatal();
    }
}

fn print(_: ?*C.VM, str: C.Str) callconv(.C) void {
    if (cy.isWasmFreestanding) {
        os_mod.hostFileWrite(1, str.buf, str.len);
    } else {
        // Temporarily redirect to error for tests to avoid hanging the Zig runner.
        if (builtin.is_test) {
            const w = std.io.getStdErr().writer();
            const slice = C.fromStr(str);
            w.writeAll(slice) catch cy.fatal();
            return;
        }

        const w = std.io.getStdOut().writer();
        const slice = C.fromStr(str);
        w.writeAll(slice) catch cy.fatal();
    }
}

pub fn loader(vm_: ?*C.VM, spec_: C.Str, out_: [*c]C.ModuleLoaderResult) callconv(.C) bool {
    const vm: *cy.VM = @ptrCast(@alignCast(vm_));
    const out: *C.ModuleLoaderResult = out_;
    const spec = C.fromStr(spec_);
    if (builtins.get(spec) != null) {
        return C.defaultModuleLoader(vm_, spec_, out);
    }
    if (stdMods.get(spec)) |res| {
        out.* = res;
        return true;
    }

    if (cy.isWasm) {
        return false;
    }

    const alloc = vm.alloc;

    // Load from file or http.
    var src: []const u8 = undefined;
    if (std.mem.startsWith(u8, spec, "http://") or std.mem.startsWith(u8, spec, "https://")) {
        src = loadUrl(vm, alloc, spec) catch |e| {
            if (e == error.HandledError) {
                return false;
            } else {
                const msg = cy.fmt.allocFormat(alloc, "Can not load `{}`. {}", &.{v(spec), v(e)}) catch return false;
                defer alloc.free(msg);
                C.reportApiError(@ptrCast(vm), C.toStr(msg));
                return false;
            }
        };
    } else {
        src = std.fs.cwd().readFileAlloc(alloc, spec, 1e10) catch |e| {
            const msg = cy.fmt.allocFormat(alloc, "Can not load `{}`. {}", &.{v(spec), v(e)}) catch return false;
            defer alloc.free(msg);
            C.reportApiError(@ptrCast(vm), C.toStr(msg));
            return false;
        };
    }

    out.*.src = src.ptr;
    out.*.srcLen = src.len;
    out.*.onReceipt = onModuleReceipt;
    return true;
}

fn onModuleReceipt(vm_: ?*C.VM, res_: [*c]C.ModuleLoaderResult) callconv(.C) void {
    const vm: *C.VM = @ptrCast(vm_);
    const res: *C.ModuleLoaderResult = res_;
    C.free(vm, C.toStr(res.src[0..res.srcLen]));
}

fn resolve(vm_: ?*C.VM, params: C.ResolverParams) callconv(.C) bool {
    const vm: *cy.VM = @ptrCast(@alignCast(vm_));
    const uri = C.fromStr(params.uri);
    if (builtins.get(uri) != null) {
        params.resUri.* = uri.ptr;
        params.resUriLen.* = uri.len;
        return true;
    }
    if (stdMods.get(uri) != null) {
        params.resUri.* = uri.ptr;
        params.resUriLen.* = uri.len;
        return true;
    }

    if (cy.isWasm) {
        return false;
    }

    var cur_uri: ?[]const u8 = null;
    if (params.chunkId != cy.NullId) {
        cur_uri = C.fromStr(params.curUri);
    }

    const alloc = vm.alloc;
    const r_uri = zResolve(vm, alloc, params.chunkId, params.buf[0..params.bufLen], cur_uri, uri) catch |e| {
        if (e == error.HandledError) {
            return false;
        } else {
            const msg = cy.fmt.allocFormat(alloc, "Resolve module `{}`, error: `{}`", &.{v(uri), v(e)}) catch return false;
            defer alloc.free(msg);
            C.reportApiError(@ptrCast(vm), C.toStr(msg));
            return false;
        }
    };

    params.resUri.* = r_uri.ptr;
    params.resUriLen.* = r_uri.len;
    return true;
}

fn zResolve(vm: *cy.VM, alloc: std.mem.Allocator, chunkId: cy.ChunkId, buf: []u8, cur_uri_opt: ?[]const u8, spec: []const u8) ![]const u8 {
    _ = chunkId;
    if (std.mem.startsWith(u8, spec, "http://") or std.mem.startsWith(u8, spec, "https://")) {
        const uri = try std.Uri.parse(spec);
        if (std.mem.endsWith(u8, uri.host.?, "github.com")) {
            if (std.mem.count(u8, uri.path, "/") == 2 and uri.path[uri.path.len-1] != '/') {
                var fbuf = std.io.fixedBufferStream(buf);
                const w = fbuf.writer();

                try w.writeAll(uri.scheme);
                try w.writeAll("://raw.githubusercontent.com");
                try w.writeAll(uri.path);
                try w.writeAll("/master/mod.cy");
                std.debug.print("{s}\n", .{fbuf.getWritten()});
                return fbuf.getWritten();
            }
        }
        return spec;
    }

    var pathBuf: [4096]u8 = undefined;
    var fbuf = std.io.fixedBufferStream(&pathBuf);
    if (cur_uri_opt) |cur_uri| b: {
        // Create path from the current script.
        // There should always be a parent directory since `curUri` should be absolute when dealing with file modules.
        const dir = std.fs.path.dirname(cur_uri) orelse {
            // Likely from an in-memory chunk uri such as `main` or `input` (repl).
            _ = try fbuf.write(spec);
            break :b;
        };
        try fbuf.writer().print("{s}/{s}", .{dir, spec});
    } else {
        _ = try fbuf.write(spec);
    }
    const path = fbuf.getWritten();

    // Get canonical path.
    const absPath = std.fs.cwd().realpath(path, buf) catch |e| {
        if (e == error.FileNotFound) {
            var msg = try cy.fmt.allocFormat(alloc, "Import path does not exist: `{}`", &.{v(path)});
            if (builtin.os.tag == .windows) {
                _ = std.mem.replaceScalar(u8, msg, '/', '\\');
            }
            defer alloc.free(msg);
            C.reportApiError(@ptrCast(vm), C.toStr(msg));
            return error.HandledError;
        } else {
            return e;
        }
    };
    return absPath;
}

fn loadUrl(vm: *cy.VM, alloc: std.mem.Allocator, url: []const u8) ![]const u8 {
    const specGroup = try cache.getSpecHashGroup(alloc, url);
    defer specGroup.deinit(alloc);

    if (vm.config.reload) {
        // Remove cache entry.
        try specGroup.markEntryBySpecForRemoval(url);
    } else {
        // First check local cache.
        if (try specGroup.findEntryBySpec(url)) |entry| {
            var found = true;
            const src = cache.allocSpecFileContents(alloc, entry) catch |e| b: {
                if (e == error.FileNotFound) {
                    // Fallthrough.
                    found = false;
                    break :b "";
                } else {
                    return e;
                }
            };
            if (found) {
                if (C.verbose()) {
                    const cachePath = try cache.allocSpecFilePath(alloc, entry);
                    defer alloc.free(cachePath);
                    rt.logZFmt("Using cached `{s}` at `{s}`", .{url, cachePath});
                }
                return src;
            }
        }
    }

    const client = vm.httpClient;

    if (C.verbose()) {
        rt.logZFmt("Fetching `{s}`.", .{url});
    }

    const uri = try std.Uri.parse(url);
    var req = client.request(.GET, uri, .{ .allocator = vm.alloc }) catch |e| {
        if (e == error.UnknownHostName) {
            const msg = try cy.fmt.allocFormat(alloc, "Can not connect to `{}`.", &.{v(uri.host.?)});
            defer alloc.free(msg);
            C.reportApiError(@ptrCast(vm), C.toStr(msg));
            return error.HandledError;
        } else {
            return e;
        }
    };
    defer client.deinitRequest(&req);

    try client.startRequest(&req);
    try client.waitRequest(&req);

    switch (req.response.status) {
        .ok => {
            // Whitelisted status codes.
        },
        else => {
            // Stop immediately.
            const e = try cy.fmt.allocFormat(alloc, "Can not load `{}`. Response code: {}", &.{v(url), v(req.response.status)});
            defer alloc.free(e);
            C.reportApiError(@ptrCast(vm), C.toStr(e));
            return error.HandledError;
        },
    }

    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(alloc);
    var readBuf: [4096]u8 = undefined;
    var read: usize = readBuf.len;

    while (read == readBuf.len) {
        read = try client.readAll(&req, &readBuf);
        try buf.appendSlice(alloc, readBuf[0..read]);
    }

    // Cache to local.
    const entry = try cache.saveNewSpecFile(alloc, specGroup, url, buf.items);
    entry.deinit(alloc);

    return try buf.toOwnedSlice(alloc);
}

pub const use_ln = builtin.os.tag != .windows and builtin.os.tag != .wasi;
const ln = @import("linenoise");

pub fn replReadLine(vm: *cy.VM, args: [*]const cy.Value, _: u8) anyerror!cy.Value {
    const prefix = try vm.alloc.dupeZ(u8, args[0].asString());
    defer vm.alloc.free(prefix);
    if (use_ln) {
        const line = try LnReadLine.read(undefined, prefix);
        defer LnReadLine.free(undefined, line);
        return vm.allocString(line);
    } else {
        var read_line = FallbackReadLine{
            .alloc = vm.alloc,
        };
        const line = try FallbackReadLine.read(&read_line, prefix);
        defer FallbackReadLine.free(&read_line, line);
        return vm.allocString(line);
    }
}

pub const LnReadLine = struct {
    pub fn read(ptr: *anyopaque, prefix: [:0]const u8) anyerror![]const u8 {
        _ = ptr;
        var linez = ln.linenoise(prefix);
        if (linez == null) {
            return error.EndOfInput;
        }
        _ = ln.linenoiseHistoryAdd(linez);
        return std.mem.sliceTo(linez, 0);
    }

    pub fn free(ptr: *anyopaque, line: []const u8) void {
        _ = ptr;
        ln.linenoiseFree(@constCast(line.ptr));
    }
};

pub const FallbackReadLine = struct {
    alloc: std.mem.Allocator,

    pub fn read(ptr: *anyopaque, prefix: [:0]const u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try std.io.getStdOut().writeAll(prefix);
        return std.io.getStdIn().reader().readUntilDelimiterAlloc(self.alloc, '\n', 10e8);
    }

    pub fn free(ptr: *anyopaque, line: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.alloc.free(line);
    }
};
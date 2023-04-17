const Bundler = bun.Bundler;
const GenerateNodeModulesBundle = @This();
const bun = @import("bun");
const from = bun.from;
const string = bun.string;
const Output = bun.Output;
const Global = bun.Global;
const Environment = bun.Environment;
const strings = bun.strings;
const MutableString = bun.MutableString;
const stringZ = bun.stringZ;
const default_allocator = bun.default_allocator;
const StoredFileDescriptorType = bun.StoredFileDescriptorType;
const FeatureFlags = bun.FeatureFlags;
const C = bun.C;
const std = @import("std");
const lex = @import("../js_lexer.zig");
const Logger = @import("../logger.zig");
const options = @import("../options.zig");
const js_parser = bun.js_parser;
const json_parser = @import("../json_parser.zig");
const js_printer = @import("../js_printer.zig");
const js_ast = @import("../js_ast.zig");
const linker = @import("../linker.zig");
const Ref = @import("../ast/base.zig").Ref;
const Define = @import("../defines.zig").Define;
const DebugOptions = @import("../cli.zig").Command.DebugOptions;
const ThreadPoolLib = @import("../thread_pool.zig");
const ThreadlocalArena = @import("../mimalloc_arena.zig").Arena;
const BabyList = @import("../baby_list.zig").BabyList;
const panicky = @import("../panic_handler.zig");
const Fs = @import("../fs.zig");
const schema = @import("../api/schema.zig");
const Api = schema.Api;
const _resolver = @import("../resolver/resolver.zig");
const sync = bun.ThreadPool;
const ImportRecord = bun.ImportRecord;
const ImportKind = bun.ImportKind;
const allocators = @import("../allocators.zig");
const MimeType = @import("../http/mime_type.zig");
const resolve_path = @import("../resolver/resolve_path.zig");
const runtime = @import("../runtime.zig");
const Timer = @import("../system_timer.zig");
const PackageJSON = @import("../resolver/package_json.zig").PackageJSON;
const MacroRemap = @import("../resolver/package_json.zig").MacroMap;
const DebugLogs = _resolver.DebugLogs;
const NodeModuleBundle = @import("../node_module_bundle.zig").NodeModuleBundle;
const Router = @import("../router.zig");
const isPackagePath = _resolver.isPackagePath;
const Lock = @import("../lock.zig").Lock;
const NodeFallbackModules = @import("../node_fallbacks.zig");
const CacheEntry = @import("../cache.zig").FsCacheEntry;
const Analytics = @import("../analytics/analytics_thread.zig");
const URL = @import("../url.zig").URL;
const Report = @import("../report.zig");
const Linker = linker.Linker;
const Resolver = _resolver.Resolver;
const TOML = @import("../toml/toml_parser.zig").TOML;
const EntryPoints = @import("./entry_points.zig");
const ThisBundler = @import("../bundler.zig").Bundler;
const wyhash = std.hash.Wyhash.hash;
const Dependency = js_ast.Dependency;
const JSAst = js_ast.Ast;
const Loader = options.Loader;
const Index = @import("../ast/base.zig").Index;
const Batcher = bun.Batcher;
const Symbol = js_ast.Symbol;
const EventLoop = bun.JSC.AnyEventLoop;
const MultiArrayList = bun.MultiArrayList;
const Stmt = js_ast.Stmt;
const Expr = js_ast.Expr;
const E = js_ast.E;
const S = js_ast.S;
const G = js_ast.G;
const B = js_ast.B;
const Binding = js_ast.Binding;
const AutoBitSet = bun.bit_set.AutoBitSet;
const renamer = bun.renamer;
const Scope = js_ast.Scope;
const JSC = bun.JSC;
const debugTreeShake = Output.scoped(.TreeShake, true);
const BitSet = bun.bit_set.DynamicBitSetUnmanaged;

pub const ThreadPool = struct {
    pool: ThreadPoolLib = undefined,
    // Hardcode 512 as max number of threads for now.
    workers: [512]Worker = undefined,
    workers_used: std.atomic.Atomic(u32) = std.atomic.Atomic(u32).init(0),
    cpu_count: u32 = 0,
    started_workers: std.atomic.Atomic(u32) = std.atomic.Atomic(u32).init(0),
    stopped_workers: std.atomic.Atomic(u32) = std.atomic.Atomic(u32).init(0),
    completed_count: std.atomic.Atomic(u32) = std.atomic.Atomic(u32).init(0),
    pending_count: std.atomic.Atomic(u32) = std.atomic.Atomic(u32).init(0),

    v2: *BundleV2 = undefined,

    const debug = Output.scoped(.ThreadPool, false);

    pub fn go(this: *ThreadPool, allocator: std.mem.Allocator, comptime Function: anytype) !ThreadPoolLib.ConcurrentFunction(Function) {
        return this.pool.go(allocator, Function);
    }

    pub fn start(this: *ThreadPool, v2: *BundleV2) !void {
        v2.bundler.env.loadProcess();
        this.v2 = v2;

        this.cpu_count = @truncate(u32, @max(std.Thread.getCpuCount() catch 2, 2));

        if (v2.bundler.env.map.get("GOMAXPROCS")) |max_procs| {
            if (std.fmt.parseInt(u32, max_procs, 10)) |cpu_count| {
                this.cpu_count = @max(cpu_count, 2);
            } else |_| {}
        }

        this.cpu_count = @min(this.cpu_count, @truncate(u32, this.workers.len - 1));

        this.pool = ThreadPoolLib.init(.{
            .max_threads = this.cpu_count,
        });
        this.pool.on_thread_spawn = Worker.onSpawn;
        this.pool.threadpool_context = this;
        var workers_used: u32 = 0;
        while (workers_used < this.cpu_count) : (workers_used += 1) {
            try this.workers[workers_used].init(v2);
        }

        if (workers_used > 0)
            this.pool.forceSpawn();
        debug("allocated {d} workers", .{this.cpu_count});
    }

    pub const Worker = struct {
        thread_id: std.Thread.Id,
        thread: std.Thread,
        heap: ThreadlocalArena = ThreadlocalArena{},
        allocator: std.mem.Allocator,
        ctx: *BundleV2,

        data: *WorkerData = undefined,
        quit: bool = false,

        ast_memory_allocator: js_ast.ASTMemoryAllocator = undefined,

        has_notify_started: bool = false,
        has_created: bool = false,
        pub fn get() *Worker {
            var worker = @ptrCast(
                *ThreadPool.Worker,
                @alignCast(
                    @alignOf(*ThreadPool.Worker),
                    ThreadPoolLib.Thread.current.?.ctx.?,
                ),
            );
            if (!worker.has_created) {
                worker.create();
            }

            return worker;
        }

        pub const WorkerData = struct {
            log: *Logger.Log,
            estimated_input_lines_of_code: usize = 0,
            macro_context: js_ast.Macro.MacroContext,
            bundler: Bundler = undefined,

            pub fn deinit(this: *WorkerData, allocator: std.mem.Allocator) void {
                allocator.destroy(this);
            }
        };

        pub fn init(worker: *Worker, v2: *BundleV2) !void {
            worker.ctx = v2;
        }

        pub fn onSpawn(ctx: ?*anyopaque) ?*anyopaque {
            var pool = @ptrCast(*ThreadPool, @alignCast(@alignOf(*ThreadPool), ctx.?));

            const id = pool.workers_used.fetchAdd(1, .Monotonic);
            pool.workers[id].run();
            return &pool.workers[id];
        }

        pub fn notifyStarted(this: *Worker) void {
            if (!this.has_notify_started) {
                this.has_notify_started = true;
                _ = this.v2.pool.started_workers.fetchAdd(1, .Release);
                std.Thread.Futex.wake(&this.v2.pool.started_workers, std.math.maxInt(u32));
            }
        }

        fn create(this: *Worker) void {
            this.has_created = true;
            Output.Source.configureThread();
            this.thread_id = std.Thread.getCurrentId();
            this.heap = ThreadlocalArena.init() catch unreachable;
            this.allocator = this.heap.allocator();
            var allocator = this.allocator;

            this.ast_memory_allocator = .{ .allocator = this.allocator };
            this.ast_memory_allocator.push();

            this.data = allocator.create(WorkerData) catch unreachable;
            this.data.* = WorkerData{
                .log = allocator.create(Logger.Log) catch unreachable,
                .estimated_input_lines_of_code = 0,
                .macro_context = undefined,
            };
            this.data.log.* = Logger.Log.init(allocator);
            this.data.bundler = this.ctx.bundler.*;
            this.data.bundler.setLog(this.data.log);
            this.data.bundler.setAllocator(allocator);
            this.data.bundler.linker.resolver = &this.data.bundler.resolver;
            this.data.bundler.macro_context = js_ast.Macro.MacroContext.init(&this.data.bundler);
            this.data.macro_context = this.data.bundler.macro_context.?;

            const CacheSet = @import("../cache.zig");

            this.data.bundler.resolver.caches = CacheSet.Set.init(this.allocator);
        }

        pub fn run(this: *Worker) void {
            if (!this.has_created) {
                this.create();
            }

            // no funny business mr. cache

        }
    };
};

const Watcher = bun.JSC.NewHotReloader(BundleV2, EventLoop, true);

pub const BundleV2 = struct {
    bundler: *Bundler,
    client_bundler: *Bundler,
    server_bundler: *Bundler,
    graph: Graph = Graph{},
    linker: LinkerContext = LinkerContext{ .loop = undefined },
    bun_watcher: ?*Watcher.Watcher = null,

    const debug = Output.scoped(.Bundle, false);

    pub inline fn loop(this: *BundleV2) *EventLoop {
        return &this.linker.loop;
    }

    pub fn findReachableFiles(this: *BundleV2) ![]Index {
        const Visitor = struct {
            reachable: std.ArrayList(Index),
            visited: bun.bit_set.DynamicBitSet = undefined,
            all_import_records: []ImportRecord.List,
            redirects: []?u32,
            redirect_map: PathToSourceIndexMap,

            // Find all files reachable from all entry points. This order should be
            // deterministic given that the entry point order is deterministic, since the
            // returned order is the postorder of the graph traversal and import record
            // order within a given file is deterministic.
            pub fn visit(v: *@This(), source_index: Index) void {
                if (source_index.isInvalid()) return;
                if (v.visited.isSet(source_index.get())) {
                    return;
                }
                v.visited.set(source_index.get());

                const import_record_list_id = source_index;
                // when there are no import records, v index will be invalid
                if (import_record_list_id.get() < v.all_import_records.len) {
                    var import_records = v.all_import_records[import_record_list_id.get()].slice();
                    for (import_records) |*import_record| {
                        const other_source = import_record.source_index;
                        if (other_source.isValid()) {
                            if (v.redirects[other_source.get()]) |redirect_id| {
                                var other_import_records = v.all_import_records[other_source.get()].slice();
                                const other_import_record = &other_import_records[redirect_id];
                                import_record.source_index = other_import_record.source_index;
                                import_record.path = other_import_record.path;
                            }

                            v.visit(import_record.source_index);
                        }
                    }

                    // Redirects replace the source file with another file
                    if (v.redirects[source_index.get()]) |redirect_id| {
                        const redirect_source_index = v.all_import_records[source_index.get()].slice()[redirect_id].source_index.get();
                        v.visit(Index.source(redirect_source_index));
                        return;
                    }
                }

                // Each file must come after its dependencies
                v.reachable.append(source_index) catch unreachable;
            }
        };

        var visitor = Visitor{
            .reachable = try std.ArrayList(Index).initCapacity(this.graph.allocator, this.graph.entry_points.items.len + 1),
            .visited = try bun.bit_set.DynamicBitSet.initEmpty(this.graph.allocator, this.graph.input_files.len),
            .redirects = this.graph.ast.items(.redirect_import_record_index),
            .all_import_records = this.graph.ast.items(.import_records),
            .redirect_map = this.graph.path_to_source_index_map,
        };
        defer visitor.visited.deinit();

        for (this.graph.entry_points.items) |entry_point| {
            visitor.visit(entry_point);
        }

        // if (comptime Environment.allow_assert) {
        //     Output.prettyln("Reachable count: {d} / {d}", .{ visitor.reachable.items.len, this.graph.input_files.len });
        // }

        return visitor.reachable.toOwnedSlice();
    }

    pub fn waitForParse(this: *BundleV2) void {
        while (this.graph.parse_pending > 0) {
            this.loop().tick(this);
        }

        debug("Parsed {d} files, producing {d} ASTs", .{ this.graph.input_files.len, this.graph.ast.len });
    }

    pub fn enqueueItem(
        this: *BundleV2,
        hash: ?u64,
        batch: *ThreadPoolLib.Batch,
        resolve: _resolver.Result,
    ) !?Index.Int {
        var result = resolve;
        var path = result.path() orelse return null;

        const loader = this.bundler.options.loaders.get(path.name.ext) orelse .file;

        var entry = try this.graph.path_to_source_index_map.getOrPut(this.graph.allocator, hash orelse wyhash(0, path.text));
        if (entry.found_existing) {
            return null;
        }
        this.graph.parse_pending += 1;
        const source_index = Index.source(this.graph.input_files.len);
        if (path.pretty.ptr == path.text.ptr) {
            // TODO: outbase
            const rel = bun.path.relative(this.bundler.fs.top_level_dir, path.text);
            if (rel.len > 0 and rel[0] != '.') {
                path.pretty = rel;
            }
        }
        path.* = try path.dupeAlloc(this.graph.allocator);
        entry.value_ptr.* = source_index.get();
        this.graph.ast.append(this.graph.allocator, js_ast.Ast.empty) catch unreachable;

        try this.graph.input_files.append(this.graph.allocator, .{
            .source = .{
                .path = path.*,
                .key_path = path.*,
                .contents = "",
                .index = source_index,
            },
            .loader = loader,
            .side_effects = resolve.primary_side_effects_data,
        });
        var task = try this.graph.allocator.create(ParseTask);
        task.* = ParseTask.init(&result, source_index);
        task.loader = loader;
        task.jsx = this.bundler.options.jsx;
        task.task.node.next = null;
        task.tree_shaking = this.linker.options.tree_shaking;
        batch.push(ThreadPoolLib.Batch.from(&task.task));
        return source_index.get();
    }

    pub fn generate(
        bundler: *ThisBundler,
        allocator: std.mem.Allocator,
        estimated_input_lines_of_code: *usize,
        package_bundle_map: options.BundlePackage.Map,
        event_loop: EventLoop,
        unique_key: u64,
        enable_reloading: bool,
    ) !std.ArrayList(options.OutputFile) {
        _ = try bundler.fs.fs.openTmpDir();
        bundler.resetStore();
        try bundler.configureDefines();
        _ = estimated_input_lines_of_code;
        _ = package_bundle_map;

        var generator = try allocator.create(BundleV2);
        bundler.options.mark_bun_builtins_as_external = bundler.options.platform.isBun();
        bundler.resolver.opts.mark_bun_builtins_as_external = bundler.options.platform.isBun();

        var this = generator;

        defer allocator.destroy(generator);
        generator.* = BundleV2{
            .bundler = bundler,
            .client_bundler = bundler,
            .server_bundler = bundler,
            .graph = .{
                .pool = undefined,
                .heap = try ThreadlocalArena.init(),
                .allocator = undefined,
            },
            .linker = .{
                .loop = event_loop,
                .graph = .{
                    .allocator = undefined,
                },
            },
        };
        generator.linker.graph.allocator = generator.graph.heap.allocator();
        generator.graph.allocator = generator.linker.graph.allocator;
        generator.bundler.allocator = generator.graph.allocator;
        generator.bundler.resolver.allocator = generator.graph.allocator;
        generator.bundler.linker.allocator = generator.graph.allocator;
        generator.bundler.log.msgs.allocator = generator.graph.allocator;
        generator.linker.resolver = &generator.bundler.resolver;
        generator.linker.graph.code_splitting = bundler.options.code_splitting;
        generator.graph.code_splitting = bundler.options.code_splitting;
        var pool = try generator.graph.allocator.create(ThreadPool);
        if (enable_reloading) {
            Watcher.enableHotModuleReloading(generator);
        }
        // errdefer pool.destroy();
        errdefer generator.graph.heap.deinit();

        pool.* = ThreadPool{};
        generator.graph.pool = pool;

        var batch = ThreadPoolLib.Batch{};

        try pool.start(this);

        {
            // Add the runtime
            try this.graph.input_files.append(allocator, Graph.InputFile{
                .source = ParseTask.runtime_source,
                .loader = .js,
                .side_effects = _resolver.SideEffects.no_side_effects__pure_data,
            });

            // try this.graph.entry_points.append(allocator, Index.runtime);
            this.graph.ast.append(this.graph.allocator, js_ast.Ast.empty) catch unreachable;
            this.graph.path_to_source_index_map.put(this.graph.allocator, bun.hash("bun:wrap"), Index.runtime.get()) catch unreachable;
            var runtime_parse_task = try this.graph.allocator.create(ParseTask);
            runtime_parse_task.* = ParseTask.runtime;
            runtime_parse_task.task.node.next = null;
            runtime_parse_task.tree_shaking = true;
            runtime_parse_task.loader = .js;
            this.graph.parse_pending += 1;
            batch.push(ThreadPoolLib.Batch.from(&runtime_parse_task.task));
        }

        if (bundler.router) |router| {
            defer this.bundler.resetStore();
            Analytics.Features.filesystem_router = true;

            const entry_points = try router.getEntryPoints();
            try this.graph.entry_points.ensureUnusedCapacity(this.graph.allocator, entry_points.len);
            try this.graph.input_files.ensureUnusedCapacity(this.graph.allocator, entry_points.len);
            try this.graph.path_to_source_index_map.ensureUnusedCapacity(this.graph.allocator, @truncate(u32, entry_points.len));

            for (entry_points) |entry_point| {
                const resolved = bundler.resolveEntryPoint(entry_point) catch continue;
                if (try this.enqueueItem(null, &batch, resolved)) |source_index| {
                    this.graph.entry_points.append(this.graph.allocator, Index.source(source_index)) catch unreachable;
                } else {}
            }
        } else {}

        {
            // Setup entry points
            try this.graph.entry_points.ensureUnusedCapacity(this.graph.allocator, bundler.options.entry_points.len);
            try this.graph.input_files.ensureUnusedCapacity(this.graph.allocator, bundler.options.entry_points.len);
            try this.graph.path_to_source_index_map.ensureUnusedCapacity(this.graph.allocator, @truncate(u32, bundler.options.entry_points.len));

            defer this.bundler.resetStore();
            for (bundler.options.entry_points) |entry_point| {
                const resolved = bundler.resolveEntryPoint(entry_point) catch continue;
                if (try this.enqueueItem(null, &batch, resolved)) |source_index| {
                    this.graph.entry_points.append(this.graph.allocator, Index.source(source_index)) catch unreachable;
                } else {}
            }
        }

        this.graph.pool.pool.schedule(batch);
        this.waitForParse();

        if (this.bundler.log.msgs.items.len > 0) {
            return error.BuildFailed;
        }

        this.linker.allocator = this.bundler.allocator;
        this.linker.graph.allocator = this.bundler.allocator;
        this.linker.graph.ast = try this.graph.ast.clone(this.linker.allocator);
        var ast = this.linker.graph.ast.slice();
        for (ast.items(.module_scope)) |*new_module_scope| {
            for (new_module_scope.children.slice()) |new_child| {
                new_child.parent = new_module_scope;
            }
        }

        var chunks = try this.linker.link(
            this,
            this.graph.entry_points.items,
            this.graph.use_directive_entry_points,
            try this.findReachableFiles(),
            unique_key,
        );

        const output_files = try this.linker.generateChunksInParallel(chunks);

        return output_files;
    }

    pub fn onParseTaskComplete(parse_result: *ParseTask.Result, this: *BundleV2) void {
        var graph = &this.graph;
        var batch = ThreadPoolLib.Batch{};
        var diff: isize = -1;

        defer graph.parse_pending = if (diff > 0)
            graph.parse_pending + @intCast(usize, diff)
        else
            graph.parse_pending - @intCast(usize, -diff);
        switch (parse_result.value) {
            .empty => |empty_result| {
                var input_files = graph.input_files.slice();
                var side_effects = input_files.items(.side_effects);
                side_effects[empty_result.source_index.get()] = .no_side_effects__empty_ast;
                if (comptime Environment.allow_assert) {
                    debug("onParse({d}, {s}) = empty", .{
                        empty_result.source_index.get(),
                        input_files.items(.source)[empty_result.source_index.get()].path.text,
                    });
                }

                if (this.bun_watcher != null) {
                    if (empty_result.watcher_data.fd > 0) {
                        this.bun_watcher.?.addFile(
                            empty_result.watcher_data.fd,
                            input_files.items(.source)[empty_result.source_index.get()].path.text,
                            bun.hash32(input_files.items(.source)[empty_result.source_index.get()].path.text),
                            graph.input_files.items(.loader)[empty_result.source_index.get()],
                            empty_result.watcher_data.dir_fd,
                            null,
                            false,
                        ) catch {};
                    }
                }
            },
            .success => |*result| {
                result.log.appendTo(this.bundler.log) catch unreachable;

                {
                    // to minimize contention, we add watcher here
                    if (this.bun_watcher != null) {
                        if (result.watcher_data.fd > 0) {
                            this.bun_watcher.?.addFile(
                                result.watcher_data.fd,
                                result.source.path.text,
                                bun.hash32(result.source.path.text),
                                result.source.path.loader(&this.bundler.options.loaders) orelse options.Loader.file,
                                result.watcher_data.dir_fd,
                                result.watcher_data.package_json,
                                false,
                            ) catch {};
                        }
                    }

                    var input_files = graph.input_files.slice();
                    input_files.items(.source)[result.source.index.get()] = result.source;
                    debug("onParse({d}, {s}) = {d} imports, {d} exports", .{
                        result.source.index.get(),
                        result.source.path.text,
                        result.ast.import_records.len,
                        result.ast.named_exports.count(),
                    });
                }

                var iter = result.resolve_queue.iterator();

                while (iter.next()) |entry| {
                    const hash = entry.key_ptr.*;
                    const value = entry.value_ptr.*;

                    var existing = graph.path_to_source_index_map.getOrPut(graph.allocator, hash) catch unreachable;

                    // If the same file is imported and required, and those point to different files
                    // Automatically rewrite it to the secondary one
                    if (value.secondary_path_for_commonjs_interop) |secondary_path| {
                        const secondary_hash = bun.hash(secondary_path.text);
                        if (graph.path_to_source_index_map.get(secondary_hash)) |secondary| {
                            existing.found_existing = true;
                            existing.value_ptr.* = secondary;
                        }
                    }

                    if (!existing.found_existing) {
                        var new_input_file = Graph.InputFile{
                            .source = Logger.Source.initEmptyFile(entry.value_ptr.path.text),
                            .side_effects = value.side_effects,
                        };
                        new_input_file.source.index = Index.source(graph.input_files.len);
                        new_input_file.source.path = entry.value_ptr.path;
                        new_input_file.source.key_path = new_input_file.source.path;
                        // graph.source_index_map.put(graph.allocator, new_input_file.source.index.get, new_input_file.source) catch unreachable;
                        existing.value_ptr.* = new_input_file.source.index.get();
                        entry.value_ptr.source_index = new_input_file.source.index;
                        graph.input_files.append(graph.allocator, new_input_file) catch unreachable;
                        graph.ast.append(graph.allocator, js_ast.Ast.empty) catch unreachable;
                        batch.push(ThreadPoolLib.Batch.from(&entry.value_ptr.task));

                        diff += 1;
                    }
                }

                var import_records = result.ast.import_records.clone(this.graph.allocator) catch unreachable;
                for (import_records.slice(), 0..) |*record, i| {
                    if (graph.path_to_source_index_map.get(wyhash(0, record.path.text))) |source_index| {
                        record.source_index.value = source_index;

                        if (result.ast.redirect_import_record_index) |compare| {
                            if (compare == @truncate(u32, i)) {
                                graph.path_to_source_index_map.put(
                                    graph.allocator,
                                    bun.hash(result.source.path.text),
                                    source_index,
                                ) catch unreachable;
                            }
                        }
                    }
                }
                result.ast.import_records = import_records;

                graph.ast.set(result.source.index.get(), result.ast);
                if (result.use_directive != .none) {
                    graph.use_directive_entry_points.append(
                        graph.allocator,
                        .{
                            .source_index = result.source.index.get(),
                            .use_directive = result.use_directive,
                        },
                    ) catch unreachable;
                }
                // schedule as early as possible
                graph.pool.pool.schedule(batch);
            },
            .err => |*err| {
                if (comptime Environment.allow_assert) {
                    debug("onParse() = err", .{});
                }

                if (err.log.msgs.items.len > 0) {
                    err.log.appendTo(this.bundler.log) catch unreachable;
                } else {
                    this.bundler.log.addErrorFmt(
                        null,
                        Logger.Loc.Empty,
                        this.bundler.allocator,
                        "{s} while {s}",
                        .{ @errorName(err.err), @tagName(err.step) },
                    ) catch unreachable;
                }
            },
        }
    }
};

const UseDirective = js_ast.UseDirective;

const ParseTask = struct {
    path: Fs.Path,
    secondary_path_for_commonjs_interop: ?Fs.Path = null,
    contents_or_fd: union(enum) {
        fd: struct {
            dir: StoredFileDescriptorType,
            file: StoredFileDescriptorType,
        },
        contents: string,
    },
    side_effects: _resolver.SideEffects,
    loader: ?Loader = null,
    jsx: options.JSX.Pragma,
    source_index: Index = Index.invalid,
    task: ThreadPoolLib.Task = .{ .callback = &callback },
    tree_shaking: bool = false,
    known_platform: ?options.Platform = null,
    module_type: options.ModuleType = .unknown,

    const debug = Output.scoped(.ParseTask, false);

    pub const ResolveQueue = std.AutoArrayHashMap(u64, ParseTask);

    pub fn init(resolve_result: *const _resolver.Result, source_index: ?Index) ParseTask {
        return .{
            .path = resolve_result.path_pair.primary,
            .contents_or_fd = .{
                .fd = .{
                    .dir = resolve_result.dirname_fd,
                    .file = resolve_result.file_fd,
                },
            },
            .side_effects = resolve_result.primary_side_effects_data,
            .jsx = resolve_result.jsx,
            .source_index = source_index orelse Index.invalid,
            .module_type = resolve_result.module_type,
        };
    }

    pub const runtime = ParseTask{
        .path = Fs.Path.initWithNamespace("runtime", "bun:runtime"),
        .side_effects = _resolver.SideEffects.no_side_effects__pure_data,
        .jsx = options.JSX.Pragma{
            .parse = false,
            // .supports_react_refresh = false,
        },
        .contents_or_fd = .{
            .contents = @as(string, @embedFile("../runtime.js")),
        },
        .source_index = Index.runtime,
        .loader = Loader.js,
    };
    pub const runtime_source = Logger.Source{
        .path = ParseTask.runtime.path,
        .key_path = ParseTask.runtime.path,
        .contents = ParseTask.runtime.contents_or_fd.contents,
        .index = Index.runtime,
    };

    pub const Result = struct {
        task: EventLoop.Task = undefined,

        value: union(Tag) {
            err: Error,
            success: Success,
            empty: struct {
                source_index: Index,

                watcher_data: WatcherData = .{},
            },
        },

        const WatcherData = struct {
            fd: bun.StoredFileDescriptorType = 0,
            dir_fd: bun.StoredFileDescriptorType = 0,
            package_json: ?*PackageJSON = null,
        };

        pub const Success = struct {
            ast: js_ast.Ast,
            resolve_queue: ResolveQueue,
            source: Logger.Source,
            log: Logger.Log,

            use_directive: UseDirective = .none,
            watcher_data: WatcherData = .{},
            side_effects: ?_resolver.SideEffects = null,
        };

        pub const Error = struct {
            err: anyerror,
            step: Step,
            log: Logger.Log,

            pub const Step = enum {
                pending,
                read_file,
                parse,
                resolve,
            };
        };

        pub const Tag = enum {
            success,
            err,
            empty,
        };
    };

    threadlocal var override_file_path_buf: [bun.MAX_PATH_BYTES]u8 = undefined;

    fn getEmptyAST(log: *Logger.Log, bundler: *Bundler, opts: js_parser.Parser.Options, allocator: std.mem.Allocator, source: Logger.Source) !js_ast.Ast {
        const root = Expr.init(E.Undefined, E.Undefined{}, Logger.Loc.Empty);
        return (try js_parser.newLazyExportAST(allocator, bundler.options.define, opts, log, root, &source, "")).?;
    }

    fn getAST(
        log: *Logger.Log,
        bundler: *Bundler,
        opts: js_parser.Parser.Options,
        allocator: std.mem.Allocator,
        resolver: *Resolver,
        source: Logger.Source,
        loader: Loader,
    ) !js_ast.Ast {
        switch (loader) {
            .jsx, .tsx, .js, .ts => {
                return if (try resolver.caches.js.parse(
                    bundler.allocator,
                    opts,
                    bundler.options.define,
                    log,
                    &source,
                )) |res|
                    res.ast
                else
                    try getEmptyAST(log, bundler, opts, allocator, source);
            },
            .json => {
                const root = (try resolver.caches.json.parseJSON(log, source, allocator)) orelse Expr.init(E.Object, E.Object{}, Logger.Loc.Empty);
                return (try js_parser.newLazyExportAST(allocator, bundler.options.define, opts, log, root, &source, "")).?;
            },
            .toml => {
                const root = try TOML.parse(&source, log, allocator);
                return (try js_parser.newLazyExportAST(allocator, bundler.options.define, opts, log, root, &source, "")).?;
            },
            .text => {
                const root = Expr.init(E.String, E.String{
                    .data = source.contents,
                    .prefer_template = true,
                }, Logger.Loc{ .start = 0 });
                return (try js_parser.newLazyExportAST(allocator, bundler.options.define, opts, log, root, &source, "")).?;
            },
            else => {
                const root = Expr.init(E.String, E.String{
                    .data = source.path.text,
                }, Logger.Loc{ .start = 0 });
                return (try js_parser.newLazyExportAST(allocator, bundler.options.define, opts, log, root, &source, "")).?;
            },
        }
    }

    fn run_(
        task: *ParseTask,
        this: *ThreadPool.Worker,
        step: *ParseTask.Result.Error.Step,
        log: *Logger.Log,
    ) anyerror!?Result.Success {
        var allocator = this.allocator;

        var data = this.data;
        var bundler = &data.bundler;
        errdefer bundler.resetStore();
        var resolver: *Resolver = &bundler.resolver;
        var file_path = task.path;
        step.* = .read_file;

        var entry: CacheEntry = switch (task.contents_or_fd) {
            .fd => brk: {
                if (bundler.options.framework) |framework| {
                    if (framework.override_modules_hashes.len > 0) {
                        const package_relative_path_hash = wyhash(0, file_path.pretty);
                        if (std.mem.indexOfScalar(
                            u64,
                            framework.override_modules_hashes,
                            package_relative_path_hash,
                        )) |index| {
                            const relative_path = [_]string{
                                framework.resolved_dir,
                                framework.override_modules.values[index],
                            };
                            var override_path = bundler.fs.absBuf(
                                &relative_path,
                                &override_file_path_buf,
                            );
                            override_file_path_buf[override_path.len] = 0;
                            var override_pathZ = override_file_path_buf[0..override_path.len :0];
                            debug("{s} -> {s}", .{ file_path.text, override_path });
                            break :brk try resolver.caches.fs.readFile(
                                bundler.fs,
                                override_pathZ,
                                0,
                                false,
                                null,
                            );
                        }
                    }
                }

                if (strings.eqlComptime(file_path.namespace, "node"))
                    break :brk CacheEntry{
                        .contents = NodeFallbackModules.contentsFromPath(file_path.text) orelse "",
                    };

                break :brk try resolver.caches.fs.readFile(
                    bundler.fs,
                    file_path.text,
                    task.contents_or_fd.fd.dir,
                    false,
                    if (task.contents_or_fd.fd.file > 0)
                        task.contents_or_fd.fd.file
                    else
                        null,
                );
            },
            .contents => |contents| CacheEntry{
                .contents = contents,
                .fd = 0,
            },
        };

        errdefer if (task.contents_or_fd == .fd) entry.deinit(allocator);

        if (entry.fd > 2) task.contents_or_fd = .{
            .fd = .{
                .file = entry.fd,
                .dir = bun.invalid_fd,
            },
        };
        step.* = .parse;

        const is_empty = entry.contents.len == 0 or (entry.contents.len < 33 and strings.trim(entry.contents, " \n\r").len == 0);

        const use_directive = if (!is_empty and this.ctx.bundler.options.react_server_components)
            UseDirective.parse(entry.contents)
        else
            .none;

        var source = Logger.Source{
            .path = file_path,
            .key_path = file_path,
            .index = task.source_index,
            .contents = entry.contents,
            .contents_is_recycled = false,
        };

        const source_dir = file_path.sourceDir();
        const loader = task.loader orelse file_path.loader(&bundler.options.loaders) orelse options.Loader.file;
        const platform = use_directive.platform(task.known_platform orelse bundler.options.platform);

        var resolve_queue = ResolveQueue.init(bun.default_allocator);
        // TODO: server ESM condition

        errdefer resolve_queue.clearAndFree();

        var opts = js_parser.Parser.Options.init(task.jsx, loader);
        opts.legacy_transform_require_to_import = false;
        opts.can_import_from_bundle = false;
        opts.features.allow_runtime = !source.index.isRuntime();
        opts.features.dynamic_require = platform.isBun();
        opts.warn_about_unbundled_modules = false;
        opts.macro_context = &this.data.macro_context;
        opts.bundle = true;
        opts.features.top_level_await = true;
        opts.features.jsx_optimization_inline = platform.isBun() and (bundler.options.jsx_optimization_inline orelse !task.jsx.development);
        opts.features.auto_import_jsx = task.jsx.parse and bundler.options.auto_import_jsx;
        opts.features.trim_unused_imports = loader.isTypeScript() or (bundler.options.trim_unused_imports orelse false);
        opts.features.inlining = bundler.options.minify_syntax;
        opts.features.minify_syntax = bundler.options.minify_syntax;

        opts.tree_shaking = task.tree_shaking;
        opts.module_type = task.module_type;
        opts.features.unwrap_commonjs_packages = bundler.options.unwrap_commonjs_packages;

        task.jsx.parse = loader.isJSX();

        var ast: js_ast.Ast = if (!is_empty)
            try getAST(log, bundler, opts, allocator, resolver, source, loader)
        else
            try getEmptyAST(log, bundler, opts, allocator, source);

        ast.platform = platform;
        if (ast.parts.len <= 1) {
            task.side_effects = _resolver.SideEffects.no_side_effects__empty_ast;
        }

        var estimated_resolve_queue_count: usize = 0;
        for (ast.import_records.slice()) |*import_record| {
            if (import_record.is_internal) {
                import_record.tag = .runtime;
                import_record.source_index = Index.runtime;
            }

            if (import_record.is_unused) {
                import_record.source_index = Index.invalid;
            }

            // Don't resolve the runtime
            if (import_record.is_internal or import_record.is_unused) {
                continue;
            }
            estimated_resolve_queue_count += 1;
        }

        try resolve_queue.ensureUnusedCapacity(estimated_resolve_queue_count);
        var last_error: ?anyerror = null;
        for (ast.import_records.slice()) |*import_record| {
            // Don't resolve the runtime
            if (import_record.is_unused or import_record.is_internal) {
                continue;
            }

            if (platform.isBun()) {
                if (JSC.HardcodedModule.Aliases.get(import_record.path.text)) |replacement| {
                    import_record.path.text = replacement.path;
                    import_record.tag = replacement.tag;
                    import_record.source_index = Index.invalid;
                    continue;
                }

                if (JSC.DisabledModule.has(import_record.path.text)) {
                    import_record.path.is_disabled = true;
                    import_record.do_commonjs_transform_in_printer = true;
                    import_record.source_index = Index.invalid;
                    continue;
                }

                if (bundler.options.rewrite_jest_for_tests) {
                    if (strings.eqlComptime(
                        import_record.path.text,
                        "@jest/globals",
                    ) or strings.eqlComptime(
                        import_record.path.text,
                        "vitest",
                    )) {
                        import_record.path.namespace = "bun";
                        import_record.tag = .bun_test;
                        import_record.path.text = "test";
                        continue;
                    }
                }

                if (strings.hasPrefixComptime(import_record.path.text, "bun:")) {
                    import_record.path = Fs.Path.init(import_record.path.text["bun:".len..]);
                    import_record.path.namespace = "bun";
                    import_record.source_index = Index.invalid;

                    if (strings.eqlComptime(import_record.path.text, "test")) {
                        import_record.tag = .bun_test;
                    }

                    // don't link bun
                    continue;
                }
            }

            if (resolver.resolve(source_dir, import_record.path.text, import_record.kind)) |_resolved_import| {
                var resolve_result = _resolved_import;
                // if there were errors, lets go ahead and collect them all
                if (last_error != null) continue;

                var path: *Fs.Path = resolve_result.path() orelse {
                    import_record.path.is_disabled = true;
                    import_record.source_index = Index.invalid;

                    continue;
                };

                if (resolve_result.is_external) {
                    continue;
                }

                var resolve_entry = try resolve_queue.getOrPut(wyhash(0, path.text));
                if (resolve_entry.found_existing) {
                    import_record.path = resolve_entry.value_ptr.path;

                    continue;
                }

                if (path.pretty.ptr == path.text.ptr) {
                    // TODO: outbase
                    const rel = bun.path.relative(bundler.fs.top_level_dir, path.text);
                    if (rel.len > 0 and rel[0] != '.') {
                        path.pretty = rel;
                    }
                }

                var secondary_path_to_copy: ?Fs.Path = null;
                if (resolve_result.path_pair.secondary) |*secondary| {
                    if (!secondary.is_disabled and
                        secondary != path and
                        !strings.eqlLong(secondary.text, path.text, true))
                    {
                        secondary_path_to_copy = try secondary.dupeAlloc(allocator);
                    }
                }

                path.* = try path.dupeAlloc(allocator);
                import_record.path = path.*;
                debug("created ParseTask: {s}", .{path.text});

                resolve_entry.value_ptr.* = ParseTask.init(&resolve_result, null);
                resolve_entry.value_ptr.secondary_path_for_commonjs_interop = secondary_path_to_copy;

                if (use_directive != .none) {
                    resolve_entry.value_ptr.known_platform = platform;
                } else if (task.known_platform) |known_platform| {
                    resolve_entry.value_ptr.known_platform = known_platform;
                }

                resolve_entry.value_ptr.jsx.development = task.jsx.development;

                if (resolve_entry.value_ptr.loader == null) {
                    resolve_entry.value_ptr.loader = path.loader(&bundler.options.loaders);
                    resolve_entry.value_ptr.tree_shaking = task.tree_shaking;
                }
            } else |err| {
                // Disable failing packages from being printed.
                // This may cause broken code to write.
                // However, doing this means we tell them all the resolve errors
                // Rather than just the first one.
                import_record.path.is_disabled = true;

                switch (err) {
                    error.ModuleNotFound => {
                        const addError = Logger.Log.addResolveErrorWithTextDupe;

                        if (!import_record.handles_import_errors) {
                            last_error = err;
                            if (isPackagePath(import_record.path.text)) {
                                if (platform.isWebLike() and options.ExternalModules.isNodeBuiltin(import_record.path.text)) {
                                    try addError(
                                        log,
                                        &source,
                                        import_record.range,
                                        this.allocator,
                                        "Could not resolve Node.js builtin: \"{s}\".",
                                        .{import_record.path.text},
                                        import_record.kind,
                                    );
                                } else {
                                    try addError(
                                        log,
                                        &source,
                                        import_record.range,
                                        this.allocator,
                                        "Could not resolve: \"{s}\". Maybe you need to \"bun install\"?",
                                        .{import_record.path.text},
                                        import_record.kind,
                                    );
                                }
                            } else {
                                try addError(
                                    log,
                                    &source,
                                    import_record.range,
                                    this.allocator,
                                    "Could not resolve: \"{s}\"",
                                    .{
                                        import_record.path.text,
                                    },
                                    import_record.kind,
                                );
                            }
                        }
                    },
                    // assume other errors are already in the log
                    else => {
                        last_error = err;
                    },
                }
            }
        }

        if (last_error) |err| {
            debug("failed with error: {s}", .{@errorName(err)});
            return err;
        }

        // Allow the AST to outlive this call
        _ = js_ast.Expr.Data.Store.toOwnedSlice();
        _ = js_ast.Stmt.Data.Store.toOwnedSlice();

        // never a react client component if RSC is not enabled.
        std.debug.assert(use_directive == .none or bundler.options.react_server_components);

        step.* = .resolve;
        ast.platform = platform;

        return Result.Success{
            .ast = ast,
            .source = source,
            .resolve_queue = resolve_queue,
            .log = log.*,
            .use_directive = use_directive,
            .watcher_data = .{
                .fd = if (task.contents_or_fd == .fd) task.contents_or_fd.fd.file else 0,
                .dir_fd = if (task.contents_or_fd == .fd) task.contents_or_fd.fd.dir else 0,
            },
        };
    }

    pub fn callback(this: *ThreadPoolLib.Task) void {
        run(@fieldParentPtr(ParseTask, "task", this));
    }

    fn run(this: *ParseTask) void {
        var worker = @ptrCast(
            *ThreadPool.Worker,
            @alignCast(
                @alignOf(*ThreadPool.Worker),
                ThreadPoolLib.Thread.current.?.ctx.?,
            ),
        );
        var step: ParseTask.Result.Error.Step = .pending;
        var log = Logger.Log.init(worker.allocator);
        std.debug.assert(this.source_index.isValid()); // forgot to set source_index
        defer {
            if (comptime FeatureFlags.help_catch_memory_issues) {
                worker.heap.gc(false);
            }
        }
        var result = bun.default_allocator.create(Result) catch unreachable;
        result.* = .{
            .value = brk: {
                if (run_(
                    this,
                    worker,
                    &step,
                    &log,
                )) |ast_or_null| {
                    if (ast_or_null) |ast| {
                        break :brk .{ .success = ast };
                    } else {
                        log.deinit();
                        break :brk .{
                            .empty = .{
                                .source_index = this.source_index,
                                .watcher_data = .{
                                    .fd = if (this.contents_or_fd == .fd) this.contents_or_fd.fd.file else 0,
                                    .dir_fd = if (this.contents_or_fd == .fd) this.contents_or_fd.fd.dir else 0,
                                },
                            },
                        };
                    }
                } else |err| {
                    if (err == error.EmptyAST) {
                        log.deinit();
                        break :brk .{
                            .empty = .{
                                .source_index = this.source_index,
                                .watcher_data = .{
                                    .fd = if (this.contents_or_fd == .fd) this.contents_or_fd.fd.file else 0,
                                    .dir_fd = if (this.contents_or_fd == .fd) this.contents_or_fd.fd.dir else 0,
                                },
                            },
                        };
                    }
                    break :brk .{
                        .err = .{
                            .err = err,
                            .step = step,
                            .log = log,
                        },
                    };
                }
            },
        };

        worker.ctx.loop().enqueueTaskConcurrent(
            Result,
            BundleV2,
            result,
            BundleV2.onParseTaskComplete,
            .task,
        );
    }
};

const IdentityContext = @import("../identity_context.zig").IdentityContext;

const RefVoidMap = std.ArrayHashMapUnmanaged(Ref, void, Ref.ArrayHashCtx, false);
const RefVoidMapManaged = std.ArrayHashMap(Ref, void, Ref.ArrayHashCtx, false);
const RefImportData = std.ArrayHashMapUnmanaged(Ref, ImportData, Ref.ArrayHashCtx, false);
const ResolvedExports = bun.StringArrayHashMapUnmanaged(ExportData);
const TopLevelSymbolToParts = js_ast.Ast.TopLevelSymbolToParts;

pub const WrapKind = enum(u2) {
    none = 0,
    cjs = 1,
    esm = 2,
};

pub const ImportData = struct {
    // This is an array of intermediate statements that re-exported this symbol
    // in a chain before getting to the final symbol. This can be done either with
    // "export * from" or "export {} from". If this is done with "export * from"
    // then this may not be the result of a single chain but may instead form
    // a diamond shape if this same symbol was re-exported multiple times from
    // different files.
    re_exports: Dependency.List = Dependency.List{},

    data: ImportTracker = .{},
};

pub const ExportData = struct {
    // Export star resolution happens first before import resolution. That means
    // it cannot yet determine if duplicate names from export star resolution are
    // ambiguous (point to different symbols) or not (point to the same symbol).
    // This issue can happen in the following scenario:
    //
    //   // entry.js
    //   export * from './a'
    //   export * from './b'
    //
    //   // a.js
    //   export * from './c'
    //
    //   // b.js
    //   export {x} from './c'
    //
    //   // c.js
    //   export let x = 1, y = 2
    //
    // In this case "entry.js" should have two exports "x" and "y", neither of
    // which are ambiguous. To handle this case, ambiguity resolution must be
    // deferred until import resolution time. That is done using this array.
    potentially_ambiguous_export_star_refs: BabyList(ImportData) = .{},

    // This is the file that the named export above came from. This will be
    // different from the file that contains this object if this is a re-export.
    data: ImportTracker = .{},
};

pub const JSMeta = struct {
    /// This is only for TypeScript files. If an import symbol is in this map, it
    /// means the import couldn't be found and doesn't actually exist. This is not
    /// an error in TypeScript because the import is probably just a type.
    ///
    /// Normally we remove all unused imports for TypeScript files during parsing,
    /// which automatically removes type-only imports. But there are certain re-
    /// export situations where it's impossible to tell if an import is a type or
    /// not:
    ///
    ///   import {typeOrNotTypeWhoKnows} from 'path';
    ///   export {typeOrNotTypeWhoKnows};
    ///
    /// Really people should be using the TypeScript "isolatedModules" flag with
    /// bundlers like this one that compile TypeScript files independently without
    /// type checking. That causes the TypeScript type checker to emit the error
    /// "Re-exporting a type when the '--isolatedModules' flag is provided requires
    /// using 'export type'." But we try to be robust to such code anyway.
    probably_typescript_type: RefVoidMap = .{},

    /// Imports are matched with exports in a separate pass from when the matched
    /// exports are actually bound to the imports. Here "binding" means adding non-
    /// local dependencies on the parts in the exporting file that declare the
    /// exported symbol to all parts in the importing file that use the imported
    /// symbol.
    ///
    /// This must be a separate pass because of the "probably TypeScript type"
    /// check above. We can't generate the part for the export namespace until
    /// we've matched imports with exports because the generated code must omit
    /// type-only imports in the export namespace code. And we can't bind exports
    /// to imports until the part for the export namespace is generated since that
    /// part needs to participate in the binding.
    ///
    /// This array holds the deferred imports to bind so the pass can be split
    /// into two separate passes.
    imports_to_bind: RefImportData = .{},

    /// This includes both named exports and re-exports.
    ///
    /// Named exports come from explicit export statements in the original file,
    /// and are copied from the "NamedExports" field in the AST.
    ///
    /// Re-exports come from other files and are the result of resolving export
    /// star statements (i.e. "export * from 'foo'").
    resolved_exports: ResolvedExports = .{},
    resolved_export_star: ExportData = ExportData{},

    /// Never iterate over "resolvedExports" directly. Instead, iterate over this
    /// array. Some exports in that map aren't meant to end up in generated code.
    /// This array excludes these exports and is also sorted, which avoids non-
    /// determinism due to random map iteration order.
    sorted_and_filtered_export_aliases: []const string = &[_]string{},

    /// This is merged on top of the corresponding map from the parser in the AST.
    /// You should call "TopLevelSymbolToParts" to access this instead of accessing
    /// it directly.
    top_level_symbol_to_parts_overlay: TopLevelSymbolToParts = .{},

    /// If this is an entry point, this array holds a reference to one free
    /// temporary symbol for each entry in "sortedAndFilteredExportAliases".
    /// These may be needed to store copies of CommonJS re-exports in ESM.
    cjs_export_copies: []const Ref = &[_]Ref{},

    /// The index of the automatically-generated part used to represent the
    /// CommonJS or ESM wrapper. This part is empty and is only useful for tree
    /// shaking and code splitting. The wrapper can't be inserted into the part
    /// because the wrapper contains other parts, which can't be represented by
    /// the current part system. Only wrapped files have one of these.
    wrapper_part_index: Index = Index.invalid,

    /// The index of the automatically-generated part used to handle entry point
    /// specific stuff. If a certain part is needed by the entry point, it's added
    /// as a dependency of this part. This is important for parts that are marked
    /// as removable when unused and that are not used by anything else. Only
    /// entry point files have one of these.
    entry_point_part_index: Index = Index.invalid,

    flags: Flags = .{},

    pub const Flags = packed struct {
        /// This is true if this file is affected by top-level await, either by having
        /// a top-level await inside this file or by having an import/export statement
        /// that transitively imports such a file. It is forbidden to call "require()"
        /// on these files since they are evaluated asynchronously.
        is_async_or_has_async_dependency: bool = false,

        /// If true, we need to insert "var exports = {};". This is the case for ESM
        /// files when the import namespace is captured via "import * as" and also
        /// when they are the target of a "require()" call.
        needs_exports_variable: bool = false,

        /// If true, the "__export(exports, { ... })" call will be force-included even
        /// if there are no parts that reference "exports". Otherwise this call will
        /// be removed due to the tree shaking pass. This is used when for entry point
        /// files when code related to the current output format needs to reference
        /// the "exports" variable.
        force_include_exports_for_entry_point: bool = false,

        /// This is set when we need to pull in the "__export" symbol in to the part
        /// at "nsExportPartIndex". This can't be done in "createExportsForFile"
        /// because of concurrent map hazards. Instead, it must be done later.
        needs_export_symbol_from_runtime: bool = false,

        /// Wrapped files must also ensure that their dependencies are wrapped. This
        /// flag is used during the traversal that enforces this invariant, and is used
        /// to detect when the fixed point has been reached.
        did_wrap_dependencies: bool = false,

        wrap: WrapKind = WrapKind.none,
    };
};

pub const Graph = struct {
    entry_points: std.ArrayListUnmanaged(Index) = .{},
    ast: MultiArrayList(JSAst) = .{},

    input_files: InputFile.List = .{},

    code_splitting: bool = false,

    pool: *ThreadPool = undefined,

    heap: ThreadlocalArena = ThreadlocalArena{},
    /// Main thread only!!
    allocator: std.mem.Allocator = undefined,

    parse_pending: usize = 0,

    /// Stable source index mapping
    source_index_map: std.AutoArrayHashMapUnmanaged(Index.Int, Ref.Int) = .{},

    /// Stable source index mapping
    path_to_source_index_map: PathToSourceIndexMap = .{},

    use_directive_entry_points: UseDirective.List = .{},

    const_values: std.HashMapUnmanaged(Ref, Expr, Ref.HashCtx, 80) = .{},

    pub const InputFile = struct {
        source: Logger.Source,
        loader: options.Loader = options.Loader.file,
        side_effects: _resolver.SideEffects = _resolver.SideEffects.has_side_effects,
        additional_files: BabyList(Index.Int) = .{},

        pub const List = MultiArrayList(InputFile);
    };
};

const PathToSourceIndexMap = std.HashMapUnmanaged(u64, Index.Int, IdentityContext(u64), 80);

const EntryPoint = struct {
    // This may be an absolute path or a relative path. If absolute, it will
    // eventually be turned into a relative path by computing the path relative
    // to the "outbase" directory. Then this relative path will be joined onto
    // the "outdir" directory to form the final output path for this entry point.
    output_path: bun.PathString = bun.PathString.empty,

    // This is the source index of the entry point. This file must have a valid
    // entry point kind (i.e. not "none").
    source_index: Index.Int = 0,

    // Manually specified output paths are ignored when computing the default
    // "outbase" directory, which is computed as the lowest common ancestor of
    // all automatically generated output paths.
    output_path_was_auto_generated: bool = false,

    pub const List = MultiArrayList(EntryPoint);

    pub const Kind = enum {
        none,
        user_specified,
        dynamic_import,

        /// Created via an import of a "use client" file
        react_client_component,

        /// Created via an import of a "use server" file
        react_server_component,

        pub inline fn isEntryPoint(this: Kind) bool {
            return this != .none;
        }

        pub inline fn isUserSpecifiedEntryPoint(this: Kind) bool {
            return this == .user_specified;
        }

        pub inline fn isServerEntryPoint(this: Kind) bool {
            return this == .user_specified or this == .react_server_component;
        }

        pub fn isReactReference(this: Kind) bool {
            return this == .react_client_component or this == .react_server_component;
        }

        pub fn useDirective(this: Kind) UseDirective {
            return switch (this) {
                .react_client_component => .@"use client",
                .react_server_component => .@"use server",
                else => .none,
            };
        }
    };
};

const AstSourceIDMapping = struct {
    id: Index.Int,
    source_index: Index.Int,
};

const LinkerGraph = struct {
    const debug = Output.scoped(.LinkerGraph, false);

    files: File.List = .{},
    files_live: BitSet = undefined,
    entry_points: EntryPoint.List = .{},
    symbols: js_ast.Symbol.Map = .{},

    allocator: std.mem.Allocator,

    code_splitting: bool = false,

    // This is an alias from Graph
    // it is not a clone!
    ast: MultiArrayList(js_ast.Ast) = .{},
    meta: MultiArrayList(JSMeta) = .{},

    reachable_files: []Index = &[_]Index{},

    stable_source_indices: []const u32 = &[_]u32{},

    react_client_component_boundary: BitSet = .{},
    react_server_component_boundary: BitSet = .{},
    has_client_components: bool = false,
    has_server_components: bool = false,

    const_values: std.HashMapUnmanaged(Ref, Expr, Ref.HashCtx, 80) = .{},

    pub fn init(allocator: std.mem.Allocator, file_count: usize) !LinkerGraph {
        return LinkerGraph{
            .allocator = allocator,
            .files_live = try BitSet.initEmpty(allocator, file_count),
        };
    }

    pub fn useDirectiveBoundary(this: *const LinkerGraph, source_index: Index.Int) UseDirective {
        if (this.react_client_component_boundary.bit_length > 0) {
            if (this.react_client_component_boundary.isSet(source_index)) {
                return .@"use client";
            }
        }

        if (this.react_server_component_boundary.bit_length > 0) {
            if (this.react_server_component_boundary.isSet(source_index)) {
                return .@"use server";
            }
        }

        return .none;
    }

    pub fn runtimeFunction(this: *const LinkerGraph, name: string) Ref {
        return this.ast.items(.named_exports)[Index.runtime.value].get(name).?.ref;
    }

    pub fn generateNewSymbol(this: *LinkerGraph, source_index: u32, kind: Symbol.Kind, original_name: string) Ref {
        var source_symbols = &this.symbols.symbols_for_source.slice()[source_index];

        var ref = Ref.init(
            @truncate(Ref.Int, source_symbols.len),
            @truncate(Ref.Int, source_index),
            false,
        );
        ref.tag = .symbol;

        // TODO: will this crash on resize due to using threadlocal mimalloc heap?
        source_symbols.push(
            this.allocator,
            .{
                .kind = kind,
                .original_name = original_name,
            },
        ) catch unreachable;

        this.ast.items(.module_scope)[source_index].generated.push(this.allocator, ref) catch unreachable;
        return ref;
    }

    pub fn generateRuntimeSymbolImportAndUse(
        graph: *LinkerGraph,
        source_index: Index.Int,
        entry_point_part_index: Index,
        name: []const u8,
        count: u32,
    ) !void {
        if (count > 0) debug("generateRuntimeSymbolImportAndUse({s}) for {d}", .{ name, source_index });

        const ref = graph.runtimeFunction(name);
        try graph.generateSymbolImportAndUse(
            source_index,
            entry_point_part_index.get(),
            ref,
            count,
            Index.runtime,
        );
    }

    pub fn addPartToFile(
        graph: *LinkerGraph,
        id: u32,
        part: js_ast.Part,
    ) !u32 {
        var parts: *js_ast.Part.List = &graph.ast.items(.parts)[id];
        const part_id = @truncate(u32, parts.len);
        try parts.push(graph.allocator, part);
        var top_level_symbol_to_parts_overlay: ?*TopLevelSymbolToParts = null;

        const Iterator = struct {
            graph: *LinkerGraph,
            id: u32,
            top_level_symbol_to_parts_overlay: *?*TopLevelSymbolToParts,
            part_id: u32,

            pub fn next(self: *@This(), ref: Ref) void {
                var overlay = brk: {
                    if (self.top_level_symbol_to_parts_overlay.*) |out| {
                        break :brk out;
                    }

                    var out = &self.graph.meta.items(.top_level_symbol_to_parts_overlay)[self.id];

                    self.top_level_symbol_to_parts_overlay.* = out;
                    break :brk out;
                };

                var entry = overlay.getOrPut(self.graph.allocator, ref) catch unreachable;
                if (!entry.found_existing) {
                    if (self.graph.ast.items(.top_level_symbols_to_parts)[self.id].get(ref)) |original_parts| {
                        var list = std.ArrayList(u32).init(self.graph.allocator);
                        list.ensureTotalCapacityPrecise(original_parts.len + 1) catch unreachable;
                        list.appendSliceAssumeCapacity(original_parts.slice());
                        list.appendAssumeCapacity(self.part_id);

                        entry.value_ptr.* = BabyList(u32).init(list.items);
                    } else {
                        entry.value_ptr.* = bun.from(
                            BabyList(u32),
                            self.graph.allocator,
                            &[_]u32{
                                self.part_id,
                            },
                        ) catch unreachable;
                    }
                } else {
                    entry.value_ptr.push(self.graph.allocator, self.part_id) catch unreachable;
                }
            }
        };

        var ctx = Iterator{
            .graph = graph,
            .id = id,
            .part_id = part_id,
            .top_level_symbol_to_parts_overlay = &top_level_symbol_to_parts_overlay,
        };

        js_ast.DeclaredSymbol.forEachTopLevelSymbol(&parts.ptr[part_id].declared_symbols, &ctx, Iterator.next);

        return part_id;
    }
    pub fn generateSymbolImportAndUse(
        g: *LinkerGraph,
        source_index: u32,
        part_index: u32,
        ref: Ref,
        use_count: u32,
        source_index_to_import_from: Index,
    ) !void {
        if (use_count == 0) return;

        // Mark this symbol as used by this part
        var parts_list = g.ast.items(.parts)[source_index].slice();
        var part: *js_ast.Part = &parts_list[part_index];
        var uses = part.symbol_uses;
        var entry = uses.getOrPut(g.allocator, ref) catch unreachable;
        if (entry.found_existing) {
            entry.value_ptr.count_estimate += use_count;
        } else {
            entry.value_ptr.* = .{ .count_estimate = use_count };
        }
        part.symbol_uses = uses;

        const exports_ref = g.ast.items(.exports_ref)[source_index];
        const module_ref = g.ast.items(.module_ref)[source_index];
        if (!exports_ref.isNull() and ref.eql(exports_ref)) {
            g.ast.items(.uses_exports_ref)[source_index] = true;
        }

        if (!module_ref.isNull() and ref.eql(module_ref)) {
            g.ast.items(.uses_module_ref)[source_index] = true;
        }

        // null ref shouldn't be there.
        std.debug.assert(!ref.isEmpty());

        // Track that this specific symbol was imported
        if (source_index_to_import_from.get() != source_index) {
            var to_bind = &g.meta.items(.imports_to_bind)[source_index];
            try to_bind.put(g.allocator, ref, .{
                .data = .{
                    .source_index = source_index_to_import_from,
                    .import_ref = ref,
                },
            });
        }

        // Pull in all parts that declare this symbol
        var dependencies = &part.dependencies;
        const part_ids = g.topLevelSymbolToParts(source_index_to_import_from.get(), ref);
        try dependencies.ensureUnusedCapacity(g.allocator, part_ids.len);
        const old_len = dependencies.len;
        dependencies.len += @truncate(u32, part_ids.len);
        var new_dependencies = dependencies.slice()[old_len..];
        for (part_ids, new_dependencies) |part_id, *dependency| {
            dependency.* = .{
                .source_index = source_index_to_import_from,
                .part_index = @truncate(u32, part_id),
            };
        }
    }

    pub fn topLevelSymbolToParts(g: *LinkerGraph, id: u32, ref: Ref) []u32 {
        if (g.meta.items(.top_level_symbol_to_parts_overlay)[id].get(ref)) |overlay| {
            return overlay.slice();
        }

        if (g.ast.items(.top_level_symbols_to_parts)[id].get(ref)) |list| {
            return list.slice();
        }

        return &.{};
    }

    pub fn load(
        this: *LinkerGraph,
        entry_points: []const Index,
        sources: []const Logger.Source,
        use_directive_entry_points: UseDirective.List,
    ) !void {
        try this.files.ensureTotalCapacity(this.allocator, sources.len);
        this.files.zero();
        this.files_live = try BitSet.initEmpty(
            this.allocator,
            sources.len,
        );
        this.files.len = sources.len;
        var files = this.files.slice();

        var entry_point_kinds = files.items(.entry_point_kind);
        {
            var kinds = std.mem.sliceAsBytes(entry_point_kinds);
            @memset(kinds.ptr, 0, kinds.len);
        }

        // Setup entry points
        {
            try this.entry_points.ensureTotalCapacity(this.allocator, entry_points.len + use_directive_entry_points.len);
            this.entry_points.len = entry_points.len;
            var source_indices = this.entry_points.items(.source_index);

            var path_strings: []bun.PathString = this.entry_points.items(.output_path);
            {
                var output_was_auto_generated = std.mem.sliceAsBytes(this.entry_points.items(.output_path_was_auto_generated));
                @memset(output_was_auto_generated.ptr, 0, output_was_auto_generated.len);
            }

            for (entry_points, path_strings, source_indices) |i, *path_string, *source_index| {
                const source = sources[i.get()];
                if (comptime Environment.allow_assert) {
                    std.debug.assert(source.index.get() == i.get());
                }
                entry_point_kinds[source.index.get()] = EntryPoint.Kind.user_specified;
                path_string.* = bun.PathString.init(source.path.text);
                source_index.* = source.index.get();
            }

            var import_records_list: []ImportRecord.List = this.ast.items(.import_records);
            try this.meta.ensureTotalCapacity(this.allocator, import_records_list.len);
            this.meta.len = this.ast.len;
            this.meta.zero();

            if (use_directive_entry_points.len > 0) {
                this.react_client_component_boundary = BitSet.initEmpty(this.allocator, this.files.len) catch unreachable;
                this.react_server_component_boundary = BitSet.initEmpty(this.allocator, this.files.len) catch unreachable;
                var any_server = false;
                var any_client = false;

                // Loop #1: populate the list of files that are react client components
                for (use_directive_entry_points.items(.use_directive), use_directive_entry_points.items(.source_index)) |use, source_id| {
                    if (use == .@"use client") {
                        any_client = true;
                        this.react_client_component_boundary.set(source_id);
                    } else if (use == .@"use server") {
                        any_server = true;
                        this.react_server_component_boundary.set(source_id);
                    }
                }

                if (any_client or any_server) {

                    // Loop #2: For each import in the entire module graph
                    for (this.reachable_files) |source_id| {
                        const use_directive = this.useDirectiveBoundary(source_id.get());
                        // If the reachable file has a "use client"; at the top
                        for (import_records_list[source_id.get()].slice()) |*import_record| {
                            const source_index_ = import_record.source_index;
                            if (source_index_.isValid()) {
                                const source_index = import_record.source_index.get();

                                // and the import path refers to a server entry point
                                if (import_record.tag == .none) {
                                    const other = this.useDirectiveBoundary(source_index);

                                    if (use_directive.boundering(other)) |boundary| {

                                        // That import is a React Server Component reference.
                                        switch (boundary) {
                                            .@"use client" => {
                                                import_record.module_id = bun.hash32(sources[source_index].path.pretty);
                                                import_record.tag = .react_client_component;
                                                import_record.path.namespace = "client";
                                                import_record.print_namespace_in_path = true;

                                                // TODO: to make chunking work better for client components
                                                // we should create a virtual module for each server entry point that corresponds to a client component
                                                // This virtual module do the equivalent of
                                                //
                                                //    export * as id$function from "$id$";
                                                //
                                                //
                                                if (entry_point_kinds[source_index] == .none) {
                                                    if (comptime Environment.allow_assert)
                                                        debug("Adding client component entry point for {s}", .{sources[source_index].path.text});

                                                    try this.entry_points.append(this.allocator, .{
                                                        .source_index = source_index,
                                                        .output_path = bun.PathString.init(sources[source_index].path.text),
                                                        .output_path_was_auto_generated = true,
                                                    });
                                                    entry_point_kinds[source_index] = .react_client_component;
                                                }
                                            },
                                            .@"use server" => {
                                                import_record.module_id = bun.hash32(sources[source_index].path.pretty);
                                                import_record.tag = .react_server_component;
                                                import_record.path.namespace = "server";
                                                import_record.print_namespace_in_path = true;

                                                if (entry_point_kinds[source_index] == .none) {
                                                    if (comptime Environment.allow_assert)
                                                        debug("Adding server component entry point for {s}", .{sources[source_index].path.text});

                                                    try this.entry_points.append(this.allocator, .{
                                                        .source_index = source_index,
                                                        .output_path = bun.PathString.init(sources[source_index].path.text),
                                                        .output_path_was_auto_generated = true,
                                                    });
                                                    entry_point_kinds[source_index] = .react_server_component;
                                                }
                                            },
                                            else => unreachable,
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    this.react_client_component_boundary = .{};
                    this.react_server_component_boundary = .{};
                }
            }
        }

        // Setup files
        {
            var stable_source_indices = try this.allocator.alloc(Index, sources.len + 1);

            // set it to max value so that if we access an invalid one, it crashes
            @memset(std.mem.sliceAsBytes(stable_source_indices).ptr, 255, std.mem.sliceAsBytes(stable_source_indices).len);

            for (this.reachable_files, 0..) |source_index, i| {
                stable_source_indices[source_index.get()] = Index.source(i);
            }

            const file = LinkerGraph.File{};
            // TODO: verify this outputs efficient code
            std.mem.set(
                @TypeOf(file.distance_from_entry_point),
                files.items(.distance_from_entry_point),
                file.distance_from_entry_point,
            );
            this.stable_source_indices = @ptrCast([]const u32, stable_source_indices);
        }

        {
            var input_symbols = js_ast.Symbol.Map.initList(js_ast.Symbol.NestedList.init(this.ast.items(.symbols)));
            var symbols = input_symbols.symbols_for_source.clone(this.allocator) catch @panic("Out of memory");
            for (symbols.slice(), input_symbols.symbols_for_source.slice()) |*dest, src| {
                dest.* = src.clone(this.allocator) catch @panic("Out of memory");
            }
            this.symbols = js_ast.Symbol.Map.initList(symbols);
        }

        {
            var const_values = this.const_values;
            var count: usize = 0;

            for (this.ast.items(.const_values)) |const_value| {
                count += const_value.count();
            }

            if (count > 0) {
                try const_values.ensureTotalCapacity(this.allocator, @truncate(u32, count));
                for (this.ast.items(.const_values)) |const_value| {
                    for (const_value.keys(), const_value.values()) |key, value| {
                        const_values.putAssumeCapacityNoClobber(key, value);
                    }
                }
            }

            this.const_values = const_values;
        }

        var in_resolved_exports: []ResolvedExports = this.meta.items(.resolved_exports);
        var src_resolved_exports: []js_ast.Ast.NamedExports = this.ast.items(.named_exports);
        for (src_resolved_exports, in_resolved_exports, 0..) |src, *dest, source_index| {
            var resolved = ResolvedExports{};
            resolved.ensureTotalCapacity(this.allocator, src.count()) catch unreachable;
            for (src.keys(), src.values()) |key, value| {
                resolved.putAssumeCapacityNoClobber(
                    key,
                    .{
                        .data = .{
                            .import_ref = value.ref,
                            .name_loc = value.alias_loc,
                            .source_index = Index.source(source_index),
                        },
                    },
                );
            }
            dest.* = resolved;
        }
    }

    pub const File = struct {
        entry_bits: AutoBitSet = undefined,

        input_file: Index = Index.source(0),

        /// The minimum number of links in the module graph to get from an entry point
        /// to this file
        distance_from_entry_point: u32 = std.math.maxInt(u32),

        /// If "entryPointKind" is not "entryPointNone", this is the index of the
        /// corresponding entry point chunk.
        entry_point_chunk_index: u32 = 0,

        /// This file is an entry point if and only if this is not "entryPointNone".
        /// Note that dynamically-imported files are allowed to also be specified by
        /// the user as top-level entry points, so some dynamically-imported files
        /// may be "entryPointUserSpecified" instead of "entryPointDynamicImport".
        entry_point_kind: EntryPoint.Kind = .none,

        pub fn isEntryPoint(this: *const File) bool {
            return this.entry_point_kind.isEntryPoint();
        }

        pub fn isUserSpecifiedEntryPoint(this: *const File) bool {
            return this.entry_point_kind.isUserSpecifiedEntryPoint();
        }

        pub const List = MultiArrayList(File);
    };
};

const LinkerContext = struct {
    const debug = Output.scoped(.LinkerCtx, false);

    parse_graph: *Graph = undefined,
    graph: LinkerGraph = undefined,
    allocator: std.mem.Allocator = undefined,
    log: *Logger.Log = undefined,

    resolver: *Resolver = undefined,
    cycle_detector: std.ArrayList(ImportTracker) = undefined,
    swap_cycle_detector: std.ArrayList(ImportTracker) = undefined,

    /// We may need to refer to the "__esm" and/or "__commonJS" runtime symbols
    cjs_runtime_ref: Ref = Ref.None,
    esm_runtime_ref: Ref = Ref.None,

    /// We may need to refer to the CommonJS "module" symbol for exports
    unbound_module_ref: Ref = Ref.None,

    options: LinkerOptions = LinkerOptions{},

    wait_group: ThreadPoolLib.WaitGroup = undefined,

    ambiguous_result_pool: std.ArrayList(MatchImport) = undefined,

    loop: EventLoop,

    /// string buffer containing pre-formatted unique keys
    unique_key_buf: []u8 = "",

    /// string buffer containing prefix for each unique keys
    unique_key_prefix: string = "",

    pub const LinkerOptions = struct {
        output_format: options.OutputFormat = .esm,
        ignore_dce_annotations: bool = false,
        tree_shaking: bool = true,
        minify_whitespace: bool = false,
        minify_syntax: bool = false,

        mode: Mode = Mode.bundle,

        public_path: []const u8 = "",

        pub const Mode = enum {
            passthrough,
            bundle,
        };
    };

    fn isExternalDynamicImport(this: *LinkerContext, record: *const ImportRecord, source_index: u32) bool {
        return this.graph.code_splitting and
            record.kind == .dynamic and
            this.graph.files.items(.entry_point_kind)[record.source_index.get()].isEntryPoint() and
            record.source_index.get() != source_index;
    }

    inline fn shouldCallRuntimeRequire(format: options.OutputFormat) bool {
        return format != .cjs;
    }

    pub fn shouldIncludePart(c: *LinkerContext, source_index: Index.Int, part: js_ast.Part) bool {
        // As an optimization, ignore parts containing a single import statement to
        // an internal non-wrapped file. These will be ignored anyway and it's a
        // performance hit to spin up a goroutine only to discover this later.
        if (part.stmts.len == 1) {
            if (part.stmts[0].data == .s_import) {
                const record = c.graph.ast.items(.import_records)[source_index].at(part.stmts[0].data.s_import.import_record_index);
                if (record.tag.isReactReference())
                    return true;

                if (record.source_index.isValid() and c.graph.meta.items(.flags)[record.source_index.get()].wrap == .none) {
                    return false;
                }
            }
        }

        return true;
    }

    fn load(
        this: *LinkerContext,
        bundle: *BundleV2,
        entry_points: []Index,
        use_directive_entry_points: UseDirective.List,
        reachable: []Index,
    ) !void {
        this.parse_graph = &bundle.graph;

        this.graph.code_splitting = bundle.bundler.options.code_splitting;
        this.log = bundle.bundler.log;

        this.resolver = &bundle.bundler.resolver;
        this.cycle_detector = std.ArrayList(ImportTracker).init(this.allocator);
        this.swap_cycle_detector = std.ArrayList(ImportTracker).init(this.allocator);

        this.graph.reachable_files = reachable;

        const sources: []const Logger.Source = this.parse_graph.input_files.items(.source);

        try this.graph.load(entry_points, sources, use_directive_entry_points);
        this.wait_group.init();
        this.ambiguous_result_pool = std.ArrayList(MatchImport).init(this.allocator);

        var runtime_named_exports = &this.graph.ast.items(.named_exports)[Index.runtime.get()];

        this.esm_runtime_ref = runtime_named_exports.get("__esm").?.ref;
        this.cjs_runtime_ref = runtime_named_exports.get("__commonJS").?.ref;
    }

    pub noinline fn link(
        this: *LinkerContext,
        bundle: *BundleV2,
        entry_points: []Index,
        use_directive_entry_points: UseDirective.List,
        reachable: []Index,
        unique_key: u64,
    ) ![]Chunk {
        try this.load(
            bundle,
            entry_points,
            use_directive_entry_points,
            reachable,
        );

        try this.scanImportsAndExports();

        // Stop now if there were errors
        if (this.log.hasErrors()) {
            return &[_]Chunk{};
        }

        try this.treeShakingAndCodeSplitting();

        const chunks = try this.computeChunks(unique_key);

        try this.computeCrossChunkDependencies(chunks);

        this.graph.symbols.followAll();

        return chunks;
    }

    pub noinline fn computeChunks(
        this: *LinkerContext,
        unique_key: u64,
    ) ![]Chunk {
        var stack_fallback = std.heap.stackFallback(4096, this.allocator);
        var stack_all = stack_fallback.get();
        var arena = std.heap.ArenaAllocator.init(stack_all);
        defer arena.deinit();

        var temp_allocator = arena.allocator();
        var js_chunks = bun.StringArrayHashMap(Chunk).init(this.allocator);
        try js_chunks.ensureUnusedCapacity(this.graph.entry_points.len);

        const entry_source_indices = this.graph.entry_points.items(.source_index);

        // Create chunks for entry points
        for (entry_source_indices, 0..) |source_index, entry_id_| {
            const entry_bit = @truncate(Chunk.EntryPoint.ID, entry_id_);

            var entry_bits = &this.graph.files.items(.entry_bits)[source_index];
            entry_bits.set(entry_bit);

            // Create a chunk for the entry point here to ensure that the chunk is
            // always generated even if the resulting file is empty
            var js_chunk_entry = try js_chunks.getOrPut(try temp_allocator.dupe(u8, entry_bits.bytes(this.graph.entry_points.len)));

            js_chunk_entry.value_ptr.* = .{
                .entry_point = .{
                    .entry_point_id = entry_bit,
                    .source_index = source_index,
                    .is_entry_point = true,
                },
                .entry_bits = entry_bits.*,
                .content = .{
                    .javascript = .{},
                },
            };
        }
        var file_entry_bits: []AutoBitSet = this.graph.files.items(.entry_bits);

        const Handler = struct {
            chunks: []Chunk,
            allocator: std.mem.Allocator,
            source_id: u32,
            pub fn next(c: *@This(), chunk_id: usize) void {
                _ = c.chunks[chunk_id].files_with_parts_in_chunk.getOrPut(c.allocator, @truncate(u32, c.source_id)) catch unreachable;
            }
        };

        // Figure out which JS files are in which chunk
        for (this.graph.reachable_files) |source_index| {
            if (this.graph.files_live.isSet(source_index.get())) {
                const entry_bits: *const AutoBitSet = &file_entry_bits[source_index.get()];

                if (this.graph.code_splitting) {
                    var js_chunk_entry = try js_chunks.getOrPut(
                        try temp_allocator.dupe(u8, entry_bits.bytes(this.graph.entry_points.len)),
                    );

                    if (!js_chunk_entry.found_existing) {
                        js_chunk_entry.value_ptr.* = .{
                            .entry_bits = entry_bits.*,
                            .entry_point = .{
                                .source_index = source_index.get(),
                            },
                            .content = .{
                                .javascript = .{},
                            },
                        };
                    }

                    _ = js_chunk_entry.value_ptr.files_with_parts_in_chunk.getOrPut(this.allocator, @truncate(u32, source_index.get())) catch unreachable;
                } else {
                    var handler = Handler{
                        .chunks = js_chunks.values(),
                        .allocator = this.allocator,
                        .source_id = source_index.get(),
                    };
                    entry_bits.forEach(Handler, &handler, Handler.next);
                }
            }
        }

        js_chunks.sort(strings.StringArrayByIndexSorter.init(try temp_allocator.dupe(string, js_chunks.keys())));

        var chunks: []Chunk = js_chunks.values();

        var entry_point_chunk_indices: []u32 = this.graph.files.items(.entry_point_chunk_index);
        // Map from the entry point file to this chunk. We will need this later if
        // a file contains a dynamic import to this entry point, since we'll need
        // to look up the path for this chunk to use with the import.
        for (chunks, 0..) |*chunk, chunk_id| {
            if (chunk.entry_point.is_entry_point) {
                entry_point_chunk_indices[chunk.entry_point.source_index] = @truncate(u32, chunk_id);
            }
        }

        // Determine the order of JS files (and parts) within the chunk ahead of time
        try this.findAllImportedPartsInJSOrder(temp_allocator, chunks);

        const unique_key_item_len = std.fmt.count("{any}C{d:0>8}", .{ bun.fmt.hexIntLower(unique_key), chunks.len });
        var unique_key_builder = try bun.StringBuilder.initCapacity(this.allocator, unique_key_item_len * chunks.len);
        this.unique_key_buf = unique_key_builder.allocatedSlice();

        errdefer {
            unique_key_builder.deinit(this.allocator);
            this.unique_key_buf = "";
        }

        for (chunks, 0..) |*chunk, chunk_id| {

            // Assign a unique key to each chunk. This key encodes the index directly so
            // we can easily recover it later without needing to look it up in a map. The
            // last 8 numbers of the key are the chunk index.
            chunk.unique_key = unique_key_builder.fmt("{any}C{d:0>8}", .{ bun.fmt.hexIntLower(unique_key), chunk_id });
            if (this.unique_key_prefix.len == 0)
                this.unique_key_prefix = chunk.unique_key[0..std.fmt.count("{any}", .{bun.fmt.hexIntLower(unique_key)})];

            if (chunk.entry_point.is_entry_point) {
                chunk.template = PathTemplate.file;
                if (this.resolver.opts.entry_names.len > 0)
                    chunk.template.data = this.resolver.opts.entry_names;
                const pathname = Fs.PathName.init(this.graph.entry_points.items(.output_path)[chunk.entry_point.entry_point_id].slice());
                chunk.template.placeholder.name = pathname.base;
                chunk.template.placeholder.ext = "js";
                chunk.template.placeholder.dir = pathname.dir;
            } else {
                chunk.template = PathTemplate.chunk;
            }
        }

        return chunks;
    }

    pub fn findAllImportedPartsInJSOrder(this: *LinkerContext, temp_allocator: std.mem.Allocator, chunks: []Chunk) !void {
        var part_ranges_shared = std.ArrayList(PartRange).init(temp_allocator);
        var parts_prefix_shared = std.ArrayList(PartRange).init(temp_allocator);
        defer part_ranges_shared.deinit();
        defer parts_prefix_shared.deinit();
        for (chunks) |*chunk| {
            try this.findImportedPartsInJSOrder(
                chunk,
                &part_ranges_shared,
                &parts_prefix_shared,
            );
        }
    }

    pub fn findImportedPartsInJSOrder(
        this: *LinkerContext,
        chunk: *Chunk,
        part_ranges_shared: *std.ArrayList(PartRange),
        parts_prefix_shared: *std.ArrayList(PartRange),
    ) !void {
        var chunk_order_array = try std.ArrayList(Chunk.Order).initCapacity(this.allocator, chunk.files_with_parts_in_chunk.count());
        defer chunk_order_array.deinit();
        var distances = this.graph.files.items(.distance_from_entry_point);
        for (chunk.files_with_parts_in_chunk.keys()) |source_index| {
            chunk_order_array.appendAssumeCapacity(
                .{
                    .source_index = source_index,
                    .distance = distances[source_index],

                    .tie_breaker = this.graph.stable_source_indices[source_index],
                },
            );
        }

        Chunk.Order.sort(chunk_order_array.items);

        const Visitor = struct {
            entry_bits: *const AutoBitSet,
            flags: []const JSMeta.Flags,
            parts: []BabyList(js_ast.Part),
            import_records: []BabyList(ImportRecord),
            files: std.ArrayList(Index.Int) = undefined,
            part_ranges: std.ArrayList(PartRange) = undefined,
            visited: std.AutoHashMap(Index.Int, void) = undefined,
            parts_prefix: std.ArrayList(PartRange) = undefined,
            c: *LinkerContext,
            entry_point: Chunk.EntryPoint,

            fn appendOrExtendRange(
                ranges: *std.ArrayList(PartRange),
                source_index: Index.Int,
                part_index: Index.Int,
            ) void {
                if (ranges.items.len > 0) {
                    var last_range = &ranges.items[ranges.items.len - 1];
                    if (last_range.source_index.get() == source_index and last_range.part_index_end == part_index) {
                        last_range.part_index_end += 1;
                        return;
                    }
                }

                ranges.append(.{
                    .source_index = Index.init(source_index),
                    .part_index_begin = part_index,
                    .part_index_end = part_index + 1,
                }) catch unreachable;
            }

            // Traverse the graph using this stable order and linearize the files with
            // dependencies before dependents
            pub fn visit(
                v: *@This(),
                source_index: Index.Int,
                comptime with_react_server_components: UseDirective.Flags,
                comptime with_code_splitting: bool,
            ) void {
                if (source_index == Index.invalid.value) return;
                const visited_entry = v.visited.getOrPut(source_index) catch unreachable;
                if (visited_entry.found_existing) return;

                var is_file_in_chunk = if (comptime with_code_splitting)
                    // when code splitting, include the file in the chunk if ALL of the entry points overlap
                    v.entry_bits.eql(&v.c.graph.files.items(.entry_bits)[source_index])
                else
                    // when NOT code splitting, include the file in the chunk if ANY of the entry points overlap
                    v.entry_bits.hasIntersection(&v.c.graph.files.items(.entry_bits)[source_index]);

                if (comptime with_react_server_components.is_client or with_react_server_components.is_server) {
                    if (is_file_in_chunk and
                        v.entry_point.is_entry_point and
                        v.entry_point.source_index != source_index)
                    {
                        if (comptime with_react_server_components.is_client) {
                            if (v.c.graph.react_client_component_boundary.isSet(source_index)) {
                                if (!v.c.graph.react_client_component_boundary.isSet(v.entry_point.source_index)) {
                                    return;
                                }
                            }
                        }

                        if (comptime with_react_server_components.is_server) {
                            if (v.c.graph.react_server_component_boundary.isSet(source_index)) {
                                if (!v.c.graph.react_server_component_boundary.isSet(v.entry_point.source_index)) {
                                    return;
                                }
                            }
                        }
                    }
                }

                // Wrapped files can't be split because they are all inside the wrapper
                const can_be_split = v.flags[source_index].wrap == .none;

                const parts = v.parts[source_index].slice();
                if (can_be_split and is_file_in_chunk and parts[js_ast.namespace_export_part_index].is_live) {
                    appendOrExtendRange(&v.part_ranges, source_index, js_ast.namespace_export_part_index);
                }

                const records = v.import_records[source_index].slice();

                for (parts, 0..) |part, part_index_| {
                    const part_index = @truncate(u32, part_index_);
                    const is_part_in_this_chunk = is_file_in_chunk and part.is_live;
                    for (part.import_record_indices.slice()) |record_id| {
                        const record: *const ImportRecord = &records[record_id];
                        if (record.source_index.isValid() and (record.kind == .stmt or is_part_in_this_chunk)) {
                            if (v.c.isExternalDynamicImport(record, source_index)) {
                                // Don't follow import() dependencies
                                continue;
                            }

                            v.visit(record.source_index.get(), with_react_server_components, with_code_splitting);
                        }
                    }

                    // Then include this part after the files it imports
                    if (is_part_in_this_chunk) {
                        is_file_in_chunk = true;

                        if (can_be_split and
                            part_index != js_ast.namespace_export_part_index and
                            v.c.shouldIncludePart(source_index, part))
                        {
                            var js_parts = if (source_index == Index.runtime.value)
                                &v.parts_prefix
                            else
                                &v.part_ranges;

                            appendOrExtendRange(js_parts, source_index, part_index);
                        }
                    }
                }

                if (is_file_in_chunk) {
                    v.files.append(source_index) catch unreachable;

                    // CommonJS files are all-or-nothing so all parts must be contiguous
                    if (!can_be_split) {
                        v.parts_prefix.append(
                            .{
                                .source_index = Index.init(source_index),
                                .part_index_begin = 0,
                                .part_index_end = @truncate(u32, parts.len),
                            },
                        ) catch unreachable;
                    }
                }
            }
        };

        part_ranges_shared.clearRetainingCapacity();
        parts_prefix_shared.clearRetainingCapacity();

        var visitor = Visitor{
            .files = std.ArrayList(Index.Int).init(this.allocator),
            .part_ranges = part_ranges_shared.*,
            .parts_prefix = parts_prefix_shared.*,
            .visited = std.AutoHashMap(Index.Int, void).init(this.allocator),
            .flags = this.graph.meta.items(.flags),
            .parts = this.graph.ast.items(.parts),
            .import_records = this.graph.ast.items(.import_records),
            .entry_bits = chunk.entryBits(),
            .c = this,
            .entry_point = chunk.entry_point,
        };
        defer {
            part_ranges_shared.* = visitor.part_ranges;
            parts_prefix_shared.* = visitor.parts_prefix;
            visitor.visited.deinit();
        }

        switch (this.graph.code_splitting) {
            inline else => |with_code_splitting| switch (this.graph.react_client_component_boundary.bit_length > 0) {
                inline else => |with_client| switch (this.graph.react_server_component_boundary.bit_length > 0) {
                    inline else => |with_server| {
                        visitor.visit(
                            Index.runtime.value,
                            .{
                                .is_server = with_server,
                                .is_client = with_client,
                            },
                            with_code_splitting,
                        );
                        for (chunk_order_array.items) |order| {
                            visitor.visit(
                                order.source_index,
                                .{
                                    .is_server = with_server,
                                    .is_client = with_client,
                                },
                                with_code_splitting,
                            );
                        }
                    },
                },
            },
        }

        var parts_in_chunk_order = try this.allocator.alloc(PartRange, visitor.part_ranges.items.len + visitor.parts_prefix.items.len);
        bun.concat(
            PartRange,
            parts_in_chunk_order,
            &.{ visitor.parts_prefix.items, visitor.part_ranges.items },
        );
        chunk.content.javascript.files_in_chunk_order = visitor.files.items;

        chunk.content.javascript.parts_in_chunk_in_order = parts_in_chunk_order;
    }

    pub fn generateNamedExportInFile(this: *LinkerContext, source_index: Index.Int, module_ref: Ref, name: []const u8, alias: []const u8) !struct { Ref, u32 } {
        const ref = this.graph.generateNewSymbol(source_index, .other, name);
        const part_index = this.graph.addPartToFile(source_index, .{
            .declared_symbols = js_ast.DeclaredSymbol.List.fromSlice(
                this.allocator,
                &[_]js_ast.DeclaredSymbol{
                    .{ .ref = ref, .is_top_level = true },
                },
            ) catch unreachable,
            .can_be_removed_if_unused = true,
        }) catch unreachable;

        try this.graph.generateSymbolImportAndUse(source_index, part_index, module_ref, 1, Index.init(source_index));
        var top_level = &this.graph.meta.items(.top_level_symbol_to_parts_overlay)[source_index];
        var parts_list = this.allocator.alloc(u32, 1) catch unreachable;
        parts_list[0] = part_index;

        top_level.put(this.allocator, ref, BabyList(u32).init(parts_list)) catch unreachable;

        var resolved_exports = &this.graph.meta.items(.resolved_exports)[source_index];
        resolved_exports.put(this.allocator, alias, ExportData{
            .data = ImportTracker{
                .source_index = Index.init(source_index),
                .import_ref = ref,
            },
        }) catch unreachable;
        return .{ ref, part_index };
    }

    fn generateCodeForLazyExport(this: *LinkerContext, source_index: Index.Int) !void {
        const exports_kind = this.graph.ast.items(.exports_kind)[source_index];
        var parts = &this.graph.ast.items(.parts)[source_index];

        if (parts.len < 1) {
            @panic("Internal error: expected at least one part for lazy export");
        }

        var part: *js_ast.Part = &parts.ptr[1];

        if (part.stmts.len == 0) {
            @panic("Internal error: expected at least one statement in the lazy export");
        }

        const stmt: Stmt = part.stmts[0];
        if (stmt.data != .s_lazy_export) {
            @panic("Internal error: expected top-level lazy export statement");
        }

        const expr = Expr{
            .data = stmt.data.s_lazy_export,
            .loc = stmt.loc,
        };
        const module_ref = this.graph.ast.items(.module_ref)[source_index];

        switch (exports_kind) {
            .cjs => {
                part.stmts[0] = Stmt.assign(
                    Expr.init(
                        E.Dot,
                        E.Dot{
                            .target = Expr.initIdentifier(module_ref, stmt.loc),
                            .name = "exports",
                            .name_loc = stmt.loc,
                        },
                        stmt.loc,
                    ),
                    expr,
                    this.allocator,
                );
                try this.graph.generateSymbolImportAndUse(source_index, 0, module_ref, 1, Index.init(source_index));
            },
            else => {
                // Otherwise, generate ES6 export statements. These are added as additional
                // parts so they can be tree shaken individually.
                part.stmts.len = 0;

                if (expr.data == .e_object) {
                    for (expr.data.e_object.properties.slice()) |property_| {
                        const property: G.Property = property_;
                        if (property.key == null or property.key.?.data != .e_string or property.value == null or
                            property.key.?.data.e_string.eqlComptime("default") or property.key.?.data.e_string.eqlComptime("__esModule"))
                        {
                            continue;
                        }

                        const name = property.key.?.data.e_string.slice(this.allocator);

                        // TODO: support non-identifier names
                        if (!bun.js_lexer.isIdentifier(name))
                            continue;

                        // This initializes the generated variable with a copy of the property
                        // value, which is INCORRECT for values that are objects/arrays because
                        // they will have separate object identity. This is fixed up later in
                        // "generateCodeForFileInChunkJS" by changing the object literal to
                        // reference this generated variable instead.
                        //
                        // Changing the object literal is deferred until that point instead of
                        // doing it now because we only want to do this for top-level variables
                        // that actually end up being used, and we don't know which ones will
                        // end up actually being used at this point (since import binding hasn't
                        // happened yet). So we need to wait until after tree shaking happens.
                        const generated = try this.generateNamedExportInFile(source_index, module_ref, name, name);
                        parts.ptr[generated[1]].stmts = this.allocator.alloc(Stmt, 1) catch unreachable;
                        parts.ptr[generated[1]].stmts[0] = Stmt.alloc(
                            S.Local,
                            S.Local{
                                .is_export = true,
                                .decls = bun.fromSlice(
                                    []js_ast.G.Decl,
                                    this.allocator,
                                    []const js_ast.G.Decl,
                                    &.{
                                        .{
                                            .binding = Binding.alloc(
                                                this.allocator,
                                                B.Identifier{
                                                    .ref = generated[0],
                                                },
                                                expr.loc,
                                            ),
                                            .value = property.value.?,
                                        },
                                    },
                                ) catch unreachable,
                            },
                            property.key.?.loc,
                        );
                    }
                }

                {
                    const generated = try this.generateNamedExportInFile(
                        source_index,
                        module_ref,
                        std.fmt.allocPrint(
                            this.allocator,
                            "{}_default",
                            .{this.parse_graph.input_files.items(.source)[source_index].fmtIdentifier()},
                        ) catch unreachable,
                        "default",
                    );
                    parts.ptr[generated[1]].stmts = this.allocator.alloc(Stmt, 1) catch unreachable;
                    parts.ptr[generated[1]].stmts[0] = Stmt.alloc(
                        S.ExportDefault,
                        S.ExportDefault{
                            .default_name = .{
                                .ref = generated[0],
                                .loc = stmt.loc,
                            },
                            .value = .{
                                .expr = expr,
                            },
                        },
                        stmt.loc,
                    );
                }
            },
        }
    }

    pub fn scanImportsAndExports(this: *LinkerContext) !void {
        const reachable = this.graph.reachable_files;
        const output_format = this.options.output_format;
        {
            var import_records_list: []ImportRecord.List = this.graph.ast.items(.import_records);

            // var parts_list: [][]js_ast.Part = this.graph.ast.items(.parts);
            var exports_kind: []js_ast.ExportsKind = this.graph.ast.items(.exports_kind);
            var entry_point_kinds: []EntryPoint.Kind = this.graph.files.items(.entry_point_kind);
            var named_imports: []js_ast.Ast.NamedImports = this.graph.ast.items(.named_imports);
            var flags: []JSMeta.Flags = this.graph.meta.items(.flags);

            var export_star_import_records: [][]u32 = this.graph.ast.items(.export_star_import_records);
            var exports_refs: []Ref = this.graph.ast.items(.exports_ref);
            var module_refs: []Ref = this.graph.ast.items(.module_ref);
            var lazy_exports: []bool = this.graph.ast.items(.has_lazy_export);
            var symbols = &this.graph.symbols;
            defer this.graph.symbols = symbols.*;

            // Step 1: Figure out what modules must be CommonJS
            for (reachable) |source_index_| {
                const id = source_index_.get();

                // does it have a JS AST?
                if (!(id < import_records_list.len)) continue;

                var import_records: []ImportRecord = import_records_list[id].slice();
                for (import_records) |record| {
                    if (!record.source_index.isValid()) {
                        continue;
                    }

                    const other_file = record.source_index.get();
                    // other file is empty
                    if (other_file >= exports_kind.len) continue;
                    const other_kind = exports_kind[other_file];

                    switch (record.kind) {
                        ImportKind.stmt => {
                            // Importing using ES6 syntax from a file without any ES6 syntax
                            // causes that module to be considered CommonJS-style, even if it
                            // doesn't have any CommonJS exports.
                            //
                            // That means the ES6 imports will become undefined instead of
                            // causing errors. This is for compatibility with older CommonJS-
                            // style bundlers.
                            //
                            // We emit a warning in this case but try to avoid turning the module
                            // into a CommonJS module if possible. This is possible with named
                            // imports (the module stays an ECMAScript module but the imports are
                            // rewritten with undefined) but is not possible with star or default
                            // imports:
                            //
                            //   import * as ns from './empty-file'
                            //   import defVal from './empty-file'
                            //   console.log(ns, defVal)
                            //
                            // In that case the module *is* considered a CommonJS module because
                            // the namespace object must be created.
                            if ((record.contains_import_star or record.contains_default_alias) and
                                !lazy_exports[other_file] and
                                exports_kind[other_file] == .none)
                            {
                                exports_kind[other_file] = .cjs;
                                flags[other_file].wrap = .cjs;
                            }
                        },
                        ImportKind.require =>
                        // Files that are imported with require() must be CommonJS modules
                        {
                            if (other_kind == .esm) {
                                flags[other_file].wrap = .esm;
                            } else {
                                flags[other_file].wrap = .cjs;
                                exports_kind[other_file] = .cjs;
                            }
                        },
                        ImportKind.dynamic => {
                            if (!this.graph.code_splitting) {
                                // If we're not splitting, then import() is just a require() that
                                // returns a promise, so the imported file must be a CommonJS module
                                if (exports_kind[other_file] == .esm) {
                                    flags[other_file].wrap = .esm;
                                } else {
                                    flags[other_file].wrap = .cjs;
                                    exports_kind[other_file] = .cjs;
                                }
                            }
                        },
                        else => {},
                    }
                }

                const kind = exports_kind[id];

                // If the output format doesn't have an implicit CommonJS wrapper, any file
                // that uses CommonJS features will need to be wrapped, even though the
                // resulting wrapper won't be invoked by other files. An exception is made
                // for entry point files in CommonJS format (or when in pass-through mode).
                if (kind == .cjs and (!entry_point_kinds[id].isEntryPoint() or output_format == .iife or output_format == .esm)) {
                    flags[id].wrap = .cjs;
                    std.debug.assert(kind == .cjs);
                }
            }

            if (comptime Environment.allow_assert) {
                var cjs_count: usize = 0;
                var esm_count: usize = 0;
                var wrap_cjs_count: usize = 0;
                var wrap_esm_count: usize = 0;
                for (exports_kind) |kind| {
                    cjs_count += @boolToInt(kind == .cjs);
                    esm_count += @boolToInt(kind == .esm);
                }

                for (flags) |flag| {
                    wrap_cjs_count += @boolToInt(flag.wrap == .cjs);
                    wrap_esm_count += @boolToInt(flag.wrap == .esm);
                }

                debug("Step 1: {d} CommonJS modules (+ {d} wrapped), {d} ES modules (+ {d} wrapped)", .{
                    cjs_count,
                    wrap_cjs_count,
                    esm_count,
                    wrap_esm_count,
                });
            }

            // Step 2: Propagate dynamic export status for export star statements that
            // are re-exports from a module whose exports are not statically analyzable.
            // In this case the export star must be evaluated at run time instead of at
            // bundle time.

            {
                var dependency_wrapper = DependencyWrapper{
                    .linker = this,
                    .flags = flags,
                    .import_records = import_records_list,
                    .exports_kind = exports_kind,
                    .entry_point_kinds = entry_point_kinds,
                    .export_star_map = std.AutoHashMap(u32, void).init(this.allocator),
                    .export_star_records = export_star_import_records,
                    .output_format = output_format,
                };
                defer dependency_wrapper.export_star_map.deinit();

                for (reachable) |source_index_| {
                    const source_index = source_index_.get();
                    const id = source_index;

                    // does it have a JS AST?
                    if (!(id < import_records_list.len)) continue;

                    if (flags[id].wrap != .none) {
                        dependency_wrapper.wrap(id);
                    }

                    if (export_star_import_records[id].len > 0) {
                        dependency_wrapper.export_star_map.clearRetainingCapacity();
                        _ = dependency_wrapper.hasDynamicExportsDueToExportStar(id);
                    }

                    // Even if the output file is CommonJS-like, we may still need to wrap
                    // CommonJS-style files. Any file that imports a CommonJS-style file will
                    // cause that file to need to be wrapped. This is because the import
                    // method, whatever it is, will need to invoke the wrapper. Note that
                    // this can include entry points (e.g. an entry point that imports a file
                    // that imports that entry point).
                    for (import_records_list[id].slice()) |record| {
                        if (record.source_index.isValid()) {
                            if (exports_kind[record.source_index.get()] == .cjs) {
                                dependency_wrapper.wrap(record.source_index.get());
                            }
                        }
                    }
                }
            }

            // Step 3: Resolve "export * from" statements. This must be done after we
            // discover all modules that can have dynamic exports because export stars
            // are ignored for those modules.
            {
                var export_star_ctx: ?ExportStarContext = null;
                var resolved_exports: []ResolvedExports = this.graph.meta.items(.resolved_exports);
                var resolved_export_stars: []ExportData = this.graph.meta.items(.resolved_export_star);
                var has_lazy_export: []bool = this.graph.ast.items(.has_lazy_export);

                for (reachable) |source_index_| {
                    const source_index = source_index_.get();
                    const id = source_index;

                    // --
                    if (has_lazy_export[id]) {
                        try this.generateCodeForLazyExport(id);
                    }
                    // --

                    // Propagate exports for export star statements
                    var export_star_ids = export_star_import_records[id];
                    if (export_star_ids.len > 0) {
                        if (export_star_ctx == null) {
                            export_star_ctx = ExportStarContext{
                                .allocator = this.allocator,
                                .resolved_exports = resolved_exports,
                                .import_records_list = import_records_list,
                                .export_star_records = export_star_import_records,

                                .imports_to_bind = this.graph.meta.items(.imports_to_bind),

                                .source_index_stack = std.ArrayList(u32).initCapacity(this.allocator, 32) catch unreachable,
                                .exports_kind = exports_kind,
                                .named_exports = this.graph.ast.items(.named_exports),
                            };
                        } else {
                            export_star_ctx.?.source_index_stack.clearRetainingCapacity();
                        }
                        export_star_ctx.?.addExports(&resolved_exports[id], source_index);
                    }

                    // Also add a special export so import stars can bind to it. This must be
                    // done in this step because it must come after CommonJS module discovery
                    // but before matching imports with exports.
                    resolved_export_stars[id] = ExportData{
                        .data = .{
                            .source_index = Index.source(source_index),
                            .import_ref = exports_refs[id],
                        },
                    };
                }
            }

            // Step 4: Match imports with exports. This must be done after we process all
            // export stars because imports can bind to export star re-exports.
            {
                this.cycle_detector.clearRetainingCapacity();
                var wrapper_part_indices = this.graph.meta.items(.wrapper_part_index);
                var imports_to_bind = this.graph.meta.items(.imports_to_bind);
                var to_mark_as_esm_with_dynamic_fallback = std.AutoArrayHashMap(u32, void).init(this.allocator);
                defer to_mark_as_esm_with_dynamic_fallback.deinit();
                for (reachable) |source_index_| {
                    const source_index = source_index_.get();
                    const id = source_index;

                    // not a JS ast or empty
                    if (id >= named_imports.len) {
                        continue;
                    }

                    var named_imports_ = &named_imports[id];
                    if (named_imports_.count() > 0) {
                        this.matchImportsWithExportsForFile(
                            named_imports_,
                            &imports_to_bind[id],
                            source_index,
                            &to_mark_as_esm_with_dynamic_fallback,
                        );

                        if (this.log.errors > 0) {
                            return error.ImportResolutionFailed;
                        }
                    }
                    const export_kind = exports_kind[id];
                    var flag = flags[id];
                    // If we're exporting as CommonJS and this file was originally CommonJS,
                    // then we'll be using the actual CommonJS "exports" and/or "module"
                    // symbols. In that case make sure to mark them as such so they don't
                    // get minified.
                    if ((output_format == .cjs or output_format == .preserve) and
                        entry_point_kinds[source_index].isEntryPoint() and
                        export_kind == .cjs and flag.wrap == .none)
                    {
                        const exports_ref = symbols.follow(exports_refs[id]);
                        const module_ref = symbols.follow(module_refs[id]);
                        symbols.get(exports_ref).?.kind = .unbound;
                        symbols.get(module_ref).?.kind = .unbound;
                    } else if (flag.force_include_exports_for_entry_point or export_kind != .cjs) {
                        flag.needs_exports_variable = true;
                        flags[id] = flag;
                    }

                    const wrapped_ref = this.graph.ast.items(.wrapper_ref)[id];
                    if (wrapped_ref.isNull() or wrapped_ref.isEmpty()) continue;

                    // Create the wrapper part for wrapped files. This is needed by a later step.
                    this.createWrapperForFile(
                        flag.wrap,
                        // if this one is null, the AST does not need to be wrapped.
                        wrapped_ref,
                        &wrapper_part_indices[id],
                        source_index,
                    );
                }

                // When we hit an unknown import on a file that started as CommonJS
                // We make it an ESM file with dynamic fallback.
                for (to_mark_as_esm_with_dynamic_fallback.keys()) |id| {
                    this.graph.ast.items(.exports_kind)[id] = .esm_with_dynamic_fallback;
                }
            }

            // Step 5: Create namespace exports for every file. This is always necessary
            // for CommonJS files, and is also necessary for other files if they are
            // imported using an import star statement.
            // Note: `do` will wait for all to finish before moving forward
            try this.parse_graph.pool.pool.do(this.allocator, &this.wait_group, this, doStep5, this.graph.reachable_files);
        }
        // Step 6: Bind imports to exports. This adds non-local dependencies on the
        // parts that declare the export to all parts that use the import. Also
        // generate wrapper parts for wrapped files.
        {
            const bufPrint = std.fmt.bufPrint;
            var parts_list: []js_ast.Part.List = this.graph.ast.items(.parts);
            var wrapper_refs = this.graph.ast.items(.wrapper_ref);
            // const needs_export_symbol_from_runtime: []const bool = this.graph.meta.items(.needs_export_symbol_from_runtime);
            var imports_to_bind_list: []RefImportData = this.graph.meta.items(.imports_to_bind);
            var runtime_export_symbol_ref: Ref = Ref.None;
            var entry_point_kinds: []EntryPoint.Kind = this.graph.files.items(.entry_point_kind);
            const flags: []const JSMeta.Flags = this.graph.meta.items(.flags);
            const exports_kind = this.graph.ast.items(.exports_kind);
            const exports_refs = this.graph.ast.items(.exports_ref);
            const module_refs = this.graph.ast.items(.module_ref);
            const named_imports = this.graph.ast.items(.named_imports);
            const import_records_list = this.graph.ast.items(.import_records);
            const export_star_import_records = this.graph.ast.items(.export_star_import_records);
            for (reachable) |source_index_| {
                const source_index = source_index_.get();
                const id = source_index;

                const is_entry_point = entry_point_kinds[source_index].isEntryPoint();
                const aliases = this.graph.meta.items(.sorted_and_filtered_export_aliases)[id];
                const flag = flags[id];
                const wrap = flag.wrap;
                const export_kind = exports_kind[id];
                const source: *const Logger.Source = &this.parse_graph.input_files.items(.source)[source_index];

                const exports_ref = exports_refs[id];
                var exports_symbol: ?*js_ast.Symbol = if (exports_ref.isValid())
                    this.graph.symbols.get(exports_ref)
                else
                    null;
                const module_ref = module_refs[id];
                var module_symbol: ?*js_ast.Symbol = if (module_ref.isValid())
                    this.graph.symbols.get(module_ref)
                else
                    null;

                // TODO: see if counting and batching into a single large allocation instead of per-file improves perf
                const string_buffer_len: usize = brk: {
                    var count: usize = 0;
                    if (is_entry_point and this.options.output_format == .esm) {
                        for (aliases) |alias| {
                            count += std.fmt.count("export_{}", .{strings.fmtIdentifier(alias)});
                        }
                    }

                    const ident_fmt_len: usize = if (source.identifier_name.len > 0)
                        source.identifier_name.len
                    else
                        std.fmt.count("{}", .{source.fmtIdentifier()});

                    if (wrap == .esm) {
                        count += "init_".len + ident_fmt_len;
                    }

                    if (wrap != .cjs and export_kind != .cjs) {
                        count += "exports_".len + ident_fmt_len;
                        count += "module_".len + ident_fmt_len;
                    }

                    break :brk count;
                };

                var string_buffer = this.allocator.alloc(u8, string_buffer_len) catch unreachable;
                var buf = string_buffer;

                defer std.debug.assert(buf.len == 0); // ensure we used all of it

                // Pre-generate symbols for re-exports CommonJS symbols in case they
                // are necessary later. This is done now because the symbols map cannot be
                // mutated later due to parallelism.
                if (is_entry_point and this.options.output_format == .esm) {
                    var copies = this.allocator.alloc(Ref, aliases.len) catch unreachable;

                    for (aliases, copies) |alias, *copy| {
                        const original_name = bufPrint(buf, "export_{}", .{strings.fmtIdentifier(alias)}) catch unreachable;
                        buf = buf[original_name.len..];
                        copy.* = this.graph.generateNewSymbol(source_index, .other, original_name);
                    }
                    this.graph.meta.items(.cjs_export_copies)[id] = copies;
                }

                // Use "init_*" for ESM wrappers instead of "require_*"
                if (wrap == .esm) {
                    const original_name = bufPrint(
                        buf,
                        "init_{}",
                        .{
                            source.fmtIdentifier(),
                        },
                    ) catch unreachable;

                    buf = buf[original_name.len..];
                    this.graph.symbols.get(wrapper_refs[id]).?.original_name = original_name;
                }

                // If this isn't CommonJS, then rename the unused "exports" and "module"
                // variables to avoid them causing the identically-named variables in
                // actual CommonJS files from being renamed. This is purely about
                // aesthetics and is not about correctness. This is done here because by
                // this point, we know the CommonJS status will not change further.
                if (wrap != .cjs and export_kind != .cjs) {
                    const exports_name = bufPrint(buf, "exports_{any}", .{source.fmtIdentifier()}) catch unreachable;
                    buf = buf[exports_name.len..];
                    const module_name = bufPrint(buf, "module_{any}", .{source.fmtIdentifier()}) catch unreachable;
                    buf = buf[module_name.len..];
                    if (exports_symbol != null)
                        exports_symbol.?.original_name = exports_name;
                    if (module_symbol != null)
                        module_symbol.?.original_name = module_name;
                }

                // Include the "__export" symbol from the runtime if it was used in the
                // previous step. The previous step can't do this because it's running in
                // parallel and can't safely mutate the "importsToBind" map of another file.
                if (flag.needs_export_symbol_from_runtime) {
                    if (!runtime_export_symbol_ref.isValid()) {
                        runtime_export_symbol_ref = this.runtimeFunction("__export");
                    }

                    std.debug.assert(runtime_export_symbol_ref.isValid());

                    this.graph.generateSymbolImportAndUse(
                        id,
                        js_ast.namespace_export_part_index,
                        runtime_export_symbol_ref,
                        1,
                        Index.runtime,
                    ) catch unreachable;
                }

                var imports_to_bind = &imports_to_bind_list[id];

                var parts: []js_ast.Part = parts_list[id].slice();
                var needs_reindex = false;
                for (imports_to_bind.keys(), imports_to_bind.values()) |*import_ref, import| {
                    const import_source_index = import.data.source_index.get();
                    const import_id = import_source_index;
                    const ref = import_ref.*;

                    if (named_imports[id].get(ref)) |named_import| {
                        for (named_import.local_parts_with_uses.slice()) |part_index| {
                            var part: *js_ast.Part = &parts[part_index];
                            const parts_declaring_symbol: []u32 = this.graph.topLevelSymbolToParts(import_id, import.data.import_ref);

                            part.dependencies.ensureUnusedCapacity(
                                this.allocator,
                                parts_declaring_symbol.len + @as(usize, import.re_exports.len),
                            ) catch unreachable;

                            // Depend on the file containing the imported symbol
                            for (parts_declaring_symbol) |resolved_part_index| {
                                part.dependencies.appendAssumeCapacity(
                                    .{
                                        .source_index = Index.source(import_source_index),
                                        .part_index = resolved_part_index,
                                    },
                                );
                            }

                            // Also depend on any files that re-exported this symbol in between the
                            // file containing the import and the file containing the imported symbol
                            part.dependencies.appendSliceAssumeCapacity(import.re_exports.slice());
                        }

                        // Merge these symbols so they will share the same name
                        const merged = this.graph.symbols.merge(ref, import.data.import_ref);
                        import_ref.* = merged;
                        needs_reindex = needs_reindex or !merged.eql(ref);
                    }
                }

                if (needs_reindex)
                    imports_to_bind.reIndex(this.allocator) catch unreachable;

                // If this is an entry point, depend on all exports so they are included
                if (is_entry_point) {
                    const force_include_exports = flag.force_include_exports_for_entry_point;
                    const add_wrapper = wrap != .none;
                    var dependencies = std.ArrayList(js_ast.Dependency).initCapacity(
                        this.allocator,
                        @as(usize, @boolToInt(force_include_exports)) + @as(usize, @boolToInt(add_wrapper)),
                    ) catch unreachable;
                    var resolved_exports_list: *ResolvedExports = &this.graph.meta.items(.resolved_exports)[id];
                    for (aliases) |alias| {
                        var export_ = resolved_exports_list.get(alias).?;
                        var target_source_index = export_.data.source_index.get();
                        var target_id = target_source_index;
                        var target_ref = export_.data.import_ref;

                        // If this is an import, then target what the import points to

                        if (imports_to_bind.get(target_ref)) |import_data| {
                            target_source_index = import_data.data.source_index.get();
                            target_id = target_source_index;
                            target_ref = import_data.data.import_ref;
                            dependencies.appendSlice(import_data.re_exports.slice()) catch unreachable;
                        }

                        const top_to_parts = this.topLevelSymbolsToParts(target_id, target_ref);
                        dependencies.ensureUnusedCapacity(top_to_parts.len) catch unreachable;
                        // Pull in all declarations of this symbol
                        for (top_to_parts) |part_index| {
                            dependencies.appendAssumeCapacity(
                                .{
                                    .source_index = Index.source(target_source_index),
                                    .part_index = part_index,
                                },
                            );
                        }
                    }

                    dependencies.ensureUnusedCapacity(@as(usize, @boolToInt(force_include_exports)) + @as(usize, @boolToInt(add_wrapper))) catch unreachable;

                    // Ensure "exports" is included if the current output format needs it
                    if (force_include_exports) {
                        dependencies.appendAssumeCapacity(
                            .{ .source_index = Index.source(source_index), .part_index = js_ast.namespace_export_part_index },
                        );
                    }

                    if (add_wrapper) {
                        dependencies.appendAssumeCapacity(
                            .{
                                .source_index = Index.source(source_index),
                                .part_index = this.graph.meta.items(.wrapper_part_index)[id].get(),
                            },
                        );
                    }

                    // Represent these constraints with a dummy part
                    const entry_point_part_index = this.graph.addPartToFile(
                        id,
                        .{
                            .dependencies = js_ast.Dependency.List.fromList(dependencies),
                            .can_be_removed_if_unused = false,
                        },
                    ) catch unreachable;
                    parts = parts_list[id].slice();
                    this.graph.meta.items(.entry_point_part_index)[id] = Index.part(entry_point_part_index);

                    // Pull in the "__toCommonJS" symbol if we need it due to being an entry point
                    if (force_include_exports) {
                        this.graph.generateRuntimeSymbolImportAndUse(
                            source_index,
                            Index.part(entry_point_part_index),
                            "__toCommonJS",
                            1,
                        ) catch unreachable;
                    }
                }

                // Encode import-specific constraints in the dependency graph
                var import_records: []ImportRecord = import_records_list[id].slice();
                debug("Binding {d} imports for file {s} (#{d})", .{ import_records.len, source.path.text, id });

                for (parts, 0..) |*part, part_index| {
                    var to_esm_uses: u32 = 0;
                    var to_common_js_uses: u32 = 0;
                    var runtime_require_uses: u32 = 0;

                    for (part.import_record_indices.slice()) |import_record_index| {
                        var record = &import_records[import_record_index];
                        const kind = record.kind;

                        // Don't follow external imports (this includes import() expressions)
                        if (!record.source_index.isValid() or this.isExternalDynamicImport(record, source_index)) {
                            // This is an external import. Check if it will be a "require()" call.
                            if (kind == .require or !output_format.keepES6ImportExportSyntax() or
                                (kind == .dynamic))
                            {
                                // We should use "__require" instead of "require" if we're not
                                // generating a CommonJS output file, since it won't exist otherwise
                                if (shouldCallRuntimeRequire(output_format)) {
                                    record.calls_runtime_require = true;
                                    runtime_require_uses += 1;
                                }

                                // If this wasn't originally a "require()" call, then we may need
                                // to wrap this in a call to the "__toESM" wrapper to convert from
                                // CommonJS semantics to ESM semantics.
                                //
                                // Unfortunately this adds some additional code since the conversion
                                // is somewhat complex. As an optimization, we can avoid this if the
                                // following things are true:
                                //
                                // - The import is an ES module statement (e.g. not an "import()" expression)
                                // - The ES module namespace object must not be captured
                                // - The "default" and "__esModule" exports must not be accessed
                                //
                                if (kind != .require and
                                    (kind != .stmt or
                                    record.contains_import_star or
                                    record.contains_default_alias or
                                    record.contains_es_module_alias))
                                {
                                    record.wrap_with_to_esm = true;
                                    to_esm_uses += 1;
                                }
                            }
                            continue;
                        }

                        const other_source_index = record.source_index.get();
                        const other_id = other_source_index;
                        std.debug.assert(@intCast(usize, other_id) < this.graph.meta.len);
                        const other_flags = flags[other_id];
                        const other_export_kind = exports_kind[other_id];

                        if (other_flags.wrap != .none) {
                            // Depend on the automatically-generated require wrapper symbol
                            const wrapper_ref = wrapper_refs[other_id];
                            this.graph.generateSymbolImportAndUse(
                                source_index,
                                @intCast(u32, part_index),
                                wrapper_ref,
                                1,
                                Index.source(other_source_index),
                            ) catch unreachable;

                            // This is an ES6 import of a CommonJS module, so it needs the
                            // "__toESM" wrapper as long as it's not a bare "require()"
                            if (kind != .require and other_export_kind == .cjs) {
                                record.wrap_with_to_esm = true;
                                to_esm_uses += 1;
                            }

                            // If this is an ESM wrapper, also depend on the exports object
                            // since the final code will contain an inline reference to it.
                            // This must be done for "require()" and "import()" expressions
                            // but does not need to be done for "import" statements since
                            // those just cause us to reference the exports directly.
                            if (other_flags.wrap == .esm and record.kind != .stmt) {
                                this.graph.generateSymbolImportAndUse(
                                    source_index,
                                    @intCast(u32, part_index),
                                    this.graph.ast.items(.exports_ref)[other_id],
                                    1,
                                    Index.source(other_source_index),
                                ) catch unreachable;

                                // If this is a "require()" call, then we should add the
                                // "__esModule" marker to behave as if the module was converted
                                // from ESM to CommonJS. This is done via a wrapper instead of
                                // by modifying the exports object itself because the same ES
                                // module may be simultaneously imported and required, and the
                                // importing code should not see "__esModule" while the requiring
                                // code should see "__esModule". This is an extremely complex
                                // and subtle set of bundler interop issues. See for example
                                // https://github.com/evanw/esbuild/issues/1591.
                                if (record.kind == .require) {
                                    record.wrap_with_to_commonjs = true;
                                    to_common_js_uses += 1;
                                }
                            }
                        } else if (kind == .stmt and other_export_kind == .esm_with_dynamic_fallback) {
                            // This is an import of a module that has a dynamic export fallback
                            // object. In that case we need to depend on that object in case
                            // something ends up needing to use it later. This could potentially
                            // be omitted in some cases with more advanced analysis if this
                            // dynamic export fallback object doesn't end up being needed.
                            this.graph.generateSymbolImportAndUse(
                                source_index,
                                @intCast(u32, part_index),
                                this.graph.ast.items(.exports_ref)[other_id],
                                1,
                                Index.source(other_source_index),
                            ) catch unreachable;
                        }
                    }

                    // If there's an ES6 import of a non-ES6 module, then we're going to need the
                    // "__toESM" symbol from the runtime to wrap the result of "require()"
                    this.graph.generateRuntimeSymbolImportAndUse(
                        source_index,
                        Index.part(part_index),

                        "__toESM",
                        to_esm_uses,
                    ) catch unreachable;

                    // If there's a CommonJS require of an ES6 module, then we're going to need the
                    // "__toCommonJS" symbol from the runtime to wrap the exports object
                    this.graph.generateRuntimeSymbolImportAndUse(
                        source_index,
                        Index.part(part_index),
                        "__toCommonJS",
                        to_common_js_uses,
                    ) catch unreachable;

                    // If there are unbundled calls to "require()" and we're not generating
                    // code for node, then substitute a "__require" wrapper for "require".
                    this.graph.generateRuntimeSymbolImportAndUse(
                        source_index,
                        Index.part(part_index),

                        // TODO: refactor this runtime symbol
                        "__require",
                        runtime_require_uses,
                    ) catch unreachable;

                    // If there's an ES6 export star statement of a non-ES6 module, then we're
                    // going to need the "__reExport" symbol from the runtime
                    var re_export_uses: u32 = 0;

                    for (export_star_import_records[id]) |import_record_index| {
                        var record = &import_records[import_record_index];

                        var happens_at_runtime = record.source_index.isInvalid() and (!is_entry_point or !output_format.keepES6ImportExportSyntax());
                        if (record.source_index.isValid()) {
                            var other_source_index = record.source_index.get();
                            const other_id = other_source_index;
                            std.debug.assert(@intCast(usize, other_id) < this.graph.meta.len);
                            const other_export_kind = exports_kind[other_id];
                            if (other_source_index != source_index and other_export_kind.isDynamic()) {
                                happens_at_runtime = true;
                            }

                            if (other_export_kind == .esm_with_dynamic_fallback) {
                                // This looks like "__reExport(exports_a, exports_b)". Make sure to
                                // pull in the "exports_b" symbol into this export star. This matters
                                // in code splitting situations where the "export_b" symbol might live
                                // in a different chunk than this export star.
                                this.graph.generateSymbolImportAndUse(
                                    source_index,
                                    @intCast(u32, part_index),
                                    this.graph.ast.items(.exports_ref)[other_id],
                                    1,
                                    Index.source(other_source_index),
                                ) catch unreachable;
                            }
                        }

                        if (happens_at_runtime) {
                            // Depend on this file's "exports" object for the first argument to "__reExport"
                            this.graph.generateSymbolImportAndUse(
                                source_index,
                                @intCast(u32, part_index),
                                this.graph.ast.items(.exports_ref)[id],
                                1,
                                Index.source(source_index),
                            ) catch unreachable;
                            this.graph.ast.items(.uses_exports_ref)[id] = true;
                            record.calls_runtime_re_export_fn = true;
                            re_export_uses += 1;
                        }
                    }

                    this.graph.generateRuntimeSymbolImportAndUse(
                        source_index,
                        Index.part(part_index),

                        "__reExport",
                        re_export_uses,
                    ) catch unreachable;
                }
            }
        }
    }

    pub fn createExportsForFile(
        c: *LinkerContext,
        allocator_: std.mem.Allocator,
        id: u32,
        resolved_exports: *ResolvedExports,
        imports_to_bind: []RefImportData,
        export_aliases: []const string,
        re_exports_count: usize,
    ) void {
        ////////////////////////////////////////////////////////////////////////////////
        // WARNING: This method is run in parallel over all files. Do not mutate data
        // for other files within this method or you will create a data race.
        ////////////////////////////////////////////////////////////////////////////////

        Stmt.Disabler.disable();
        defer Stmt.Disabler.enable();
        Expr.Disabler.disable();
        defer Expr.Disabler.enable();

        // 1 property per export
        var properties = std.ArrayList(js_ast.G.Property)
            .initCapacity(allocator_, export_aliases.len) catch unreachable;

        var ns_export_symbol_uses = js_ast.Part.SymbolUseMap{};
        ns_export_symbol_uses.ensureTotalCapacity(allocator_, export_aliases.len) catch unreachable;

        const needs_exports_variable = c.graph.meta.items(.flags)[id].needs_exports_variable;

        const stmts_count =
            // 2 statements for every export
            export_aliases.len * 2 +
            // + 1 if there are non-zero exports
            @as(usize, @boolToInt(export_aliases.len > 0)) +
            // + 1 if we need to inject the exports variable
            @as(usize, @boolToInt(needs_exports_variable));

        var stmts = js_ast.Stmt.Batcher.init(allocator_, stmts_count) catch unreachable;
        defer stmts.done();
        const loc = Logger.Loc.Empty;
        // todo: investigate if preallocating this array is faster
        var ns_export_dependencies = std.ArrayList(js_ast.Dependency).initCapacity(allocator_, re_exports_count) catch unreachable;
        for (export_aliases) |alias| {
            var export_ = resolved_exports.getPtr(alias).?;

            const other_id = export_.data.source_index.get();

            // If this is an export of an import, reference the symbol that the import
            // was eventually resolved to. We need to do this because imports have
            // already been resolved by this point, so we can't generate a new import
            // and have that be resolved later.
            if (imports_to_bind[other_id].get(export_.data.import_ref)) |import_data| {
                export_.data = import_data.data;
                ns_export_dependencies.appendSlice(import_data.re_exports.slice()) catch unreachable;
            }

            // Exports of imports need EImportIdentifier in case they need to be re-
            // written to a property access later on
            // note: this is stack allocated
            const value: js_ast.Expr = brk: {
                if (c.graph.symbols.getConst(export_.data.import_ref)) |symbol| {
                    if (symbol.namespace_alias != null) {
                        break :brk js_ast.Expr.init(
                            js_ast.E.ImportIdentifier,
                            js_ast.E.ImportIdentifier{
                                .ref = export_.data.import_ref,
                            },
                            loc,
                        );
                    }
                }

                break :brk js_ast.Expr.init(
                    js_ast.E.Identifier,
                    js_ast.E.Identifier{
                        .ref = export_.data.import_ref,
                    },
                    loc,
                );
            };

            const block = stmts.eat1(
                js_ast.Stmt.allocate(allocator_, js_ast.S.Block, .{
                    .stmts = stmts.eat1(
                        js_ast.Stmt.allocate(
                            allocator_,
                            js_ast.S.Return,
                            .{ .value = value },
                            loc,
                        ),
                    ),
                }, loc),
            );
            const fn_body = js_ast.G.FnBody{
                .stmts = block,
                .loc = loc,
            };
            properties.appendAssumeCapacity(
                .{
                    .key = js_ast.Expr.allocate(
                        allocator_,
                        js_ast.E.String,
                        .{
                            // TODO: test emoji work as expected
                            // relevant for WASM exports
                            .data = alias,
                        },
                        loc,
                    ),
                    .value = js_ast.Expr.allocate(
                        allocator_,
                        js_ast.E.Arrow,
                        .{ .prefer_expr = true, .body = fn_body },
                        loc,
                    ),
                },
            );
            ns_export_symbol_uses.putAssumeCapacity(export_.data.import_ref, .{ .count_estimate = 1 });

            // Make sure the part that declares the export is included
            const parts = c.topLevelSymbolsToParts(other_id, export_.data.import_ref);
            ns_export_dependencies.ensureUnusedCapacity(parts.len) catch unreachable;
            var ptr = ns_export_dependencies.items.ptr + ns_export_dependencies.items.len;
            ns_export_dependencies.items.len += parts.len;

            for (parts, ptr[0..parts.len]) |part_id, *dependency| {
                // Use a non-local dependency since this is likely from a different
                // file if it came in through an export star
                dependency.* = .{
                    .source_index = export_.data.source_index,
                    .part_index = part_id,
                };
            }
        }

        var declared_symbols = js_ast.DeclaredSymbol.List{};
        var exports_ref = c.graph.ast.items(.exports_ref)[id];
        var all_export_stmts: []js_ast.Stmt = stmts.head[0 .. @as(usize, @boolToInt(needs_exports_variable)) + @as(usize, @boolToInt(properties.items.len > 0))];
        stmts.head = stmts.head[all_export_stmts.len..];
        var remaining_stmts = all_export_stmts;
        defer std.debug.assert(remaining_stmts.len == 0); // all must be used

        // Prefix this part with "var exports = {}" if this isn't a CommonJS entry point
        if (needs_exports_variable) {
            var decls = allocator_.alloc(js_ast.G.Decl, 1) catch unreachable;
            decls[0] = .{
                .binding = js_ast.Binding.alloc(
                    allocator_,
                    js_ast.B.Identifier{
                        .ref = exports_ref,
                    },
                    loc,
                ),
                .value = js_ast.Expr.allocate(allocator_, js_ast.E.Object, .{}, loc),
            };
            remaining_stmts[0] = js_ast.Stmt.allocate(
                allocator_,
                js_ast.S.Local,
                .{
                    .decls = decls,
                },
                loc,
            );
            remaining_stmts = remaining_stmts[1..];
            declared_symbols.append(allocator_, .{ .ref = exports_ref, .is_top_level = true }) catch unreachable;
        }

        // "__export(exports, { foo: () => foo })"
        var export_ref = Ref.None;
        if (properties.items.len > 0) {
            export_ref = c.graph.ast.items(.module_scope)[Index.runtime.get()].members.get("__export").?.ref;
            var args = allocator_.alloc(js_ast.Expr, 2) catch unreachable;
            args[0..2].* = [_]js_ast.Expr{
                js_ast.Expr.initIdentifier(exports_ref, loc),
                js_ast.Expr.allocate(allocator_, js_ast.E.Object, .{ .properties = js_ast.G.Property.List.fromList(properties) }, loc),
            };
            remaining_stmts[0] = js_ast.Stmt.allocate(
                allocator_,
                js_ast.S.SExpr,
                .{
                    .value = js_ast.Expr.allocate(
                        allocator_,
                        js_ast.E.Call,
                        .{
                            .target = js_ast.Expr.initIdentifier(export_ref, loc),
                            .args = js_ast.ExprNodeList.init(args),
                        },
                        loc,
                    ),
                },
                loc,
            );
            remaining_stmts = remaining_stmts[1..];
            // Make sure this file depends on the "__export" symbol
            const parts = c.topLevelSymbolsToPartsForRuntime(export_ref);
            ns_export_dependencies.ensureUnusedCapacity(parts.len) catch unreachable;
            for (parts) |part_index| {
                ns_export_dependencies.appendAssumeCapacity(
                    .{ .source_index = Index.runtime, .part_index = part_index },
                );
            }

            // Make sure the CommonJS closure, if there is one, includes "exports"
            c.graph.ast.items(.uses_exports_ref)[id] = true;
        }

        // No need to generate a part if it'll be empty
        if (all_export_stmts.len > 0) {
            // - we must already have preallocated the parts array
            // - if the parts list is completely empty, we shouldn't have gotten here in the first place

            // Initialize the part that was allocated for us earlier. The information
            // here will be used after this during tree shaking.
            c.graph.ast.items(.parts)[id].slice()[js_ast.namespace_export_part_index] = .{
                .stmts = all_export_stmts,
                .symbol_uses = ns_export_symbol_uses,
                .dependencies = js_ast.Dependency.List.fromList(ns_export_dependencies),
                .declared_symbols = declared_symbols,

                // This can be removed if nothing uses it
                .can_be_removed_if_unused = true,

                // Make sure this is trimmed if unused even if tree shaking is disabled
                .force_tree_shaking = true,
            };

            // Pull in the "__export" symbol if it was used
            if (export_ref.isValid()) {
                c.graph.meta.items(.flags)[id].needs_export_symbol_from_runtime = true;
            }
        }
    }

    /// Step 5: Create namespace exports for every file. This is always necessary
    /// for CommonJS files, and is also necessary for other files if they are
    /// imported using an import star statement.
    pub fn doStep5(c: *LinkerContext, source_index_: Index, _: usize) void {
        const source_index = source_index_.get();

        const id = source_index;
        if (id > c.graph.meta.len) return;

        var worker: *ThreadPool.Worker = @ptrCast(
            *ThreadPool.Worker,
            @alignCast(
                @alignOf(*ThreadPool.Worker),
                ThreadPoolLib.Thread.current.?.ctx.?,
            ),
        );
        // we must use this allocator here
        const allocator_ = worker.allocator;
        if (comptime FeatureFlags.help_catch_memory_issues) {
            worker.heap.gc(false);
        }
        defer {
            if (comptime FeatureFlags.help_catch_memory_issues) {
                worker.heap.gc(false);
            }
        }

        var resolved_exports: *ResolvedExports = &c.graph.meta.items(.resolved_exports)[id];

        // Now that all exports have been resolved, sort and filter them to create
        // something we can iterate over later.
        var aliases = std.ArrayList(string).initCapacity(allocator_, resolved_exports.count()) catch unreachable;
        var alias_iter = resolved_exports.iterator();
        var imports_to_bind = c.graph.meta.items(.imports_to_bind);
        var probably_typescript_type = c.graph.meta.items(.probably_typescript_type);

        // counting in here saves us an extra pass through the array
        var re_exports_count: usize = 0;

        next_alias: while (alias_iter.next()) |entry| {
            var export_ = entry.value_ptr.*;
            var alias = entry.key_ptr.*;
            const this_id = export_.data.source_index.get();
            var inner_count: usize = 0;
            // Re-exporting multiple symbols with the same name causes an ambiguous
            // export. These names cannot be used and should not end up in generated code.
            if (export_.potentially_ambiguous_export_star_refs.len > 0) {
                const main = imports_to_bind[this_id].get(export_.data.import_ref) orelse ImportData{ .data = export_.data };
                for (export_.potentially_ambiguous_export_star_refs.slice()) |ambig| {
                    const _id = ambig.data.source_index.get();
                    const ambig_ref = if (imports_to_bind[_id].get(ambig.data.import_ref)) |bound|
                        bound.data.import_ref
                    else
                        ambig.data.import_ref;
                    if (!main.data.import_ref.eql(ambig_ref)) {
                        continue :next_alias;
                    }
                    inner_count += @as(usize, ambig.re_exports.len);
                }
            }

            // Ignore re-exported imports in TypeScript files that failed to be
            // resolved. These are probably just type-only imports so the best thing to
            // do is to silently omit them from the export list.
            if (probably_typescript_type[this_id].contains(export_.data.import_ref)) {
                continue;
            }
            re_exports_count += inner_count;

            aliases.appendAssumeCapacity(alias);
        }
        // TODO: can this be u32 instead of a string?
        // if yes, we could just move all the hidden exports to the end of the array
        // and only store a count instead of an array
        strings.sortDesc(aliases.items);
        const export_aliases = aliases.toOwnedSlice() catch unreachable;
        c.graph.meta.items(.sorted_and_filtered_export_aliases)[id] = export_aliases;

        // Export creation uses "sortedAndFilteredExportAliases" so this must
        // come second after we fill in that array
        c.createExportsForFile(
            allocator_,
            id,
            resolved_exports,
            imports_to_bind,
            export_aliases,
            re_exports_count,
        );

        // Each part tracks the other parts it depends on within this file
        var local_dependencies = std.AutoHashMap(u32, u32).init(allocator_);
        defer local_dependencies.deinit();
        var parts = &c.graph.ast.items(.parts)[id];
        var parts_slice: []js_ast.Part = parts.slice();
        var named_imports: js_ast.Ast.NamedImports = c.graph.ast.items(.named_imports)[id];
        defer c.graph.ast.items(.named_imports)[id] = named_imports;
        outer: for (parts_slice, 0..) |*part, part_index| {

            // TODO: inline const TypeScript enum here

            // TODO: inline function calls here

            // Inline cross-module constants
            if (c.graph.const_values.count() > 0) {
                // First, find any symbol usage that points to a constant value.
                // This will be pretty rare.
                const first_constant_i: ?usize = brk: {
                    for (part.symbol_uses.keys(), 0..) |ref, j| {
                        if (c.graph.const_values.contains(ref)) {
                            break :brk j;
                        }
                    }

                    break :brk null;
                };
                if (first_constant_i) |j| {
                    var end_i: usize = 0;
                    // symbol_uses is an array
                    var keys = part.symbol_uses.keys()[j..];
                    var values = part.symbol_uses.values()[j..];
                    for (keys, values) |ref, val| {
                        if (c.graph.const_values.contains(ref)) {
                            continue;
                        }

                        keys[end_i] = ref;
                        values[end_i] = val;
                        end_i += 1;
                    }
                    part.symbol_uses.entries.len = end_i + j;

                    if (part.symbol_uses.entries.len == 0 and part.can_be_removed_if_unused) {
                        part.tag = .dead_due_to_inlining;
                        part.dependencies.len = 0;
                        continue :outer;
                    }

                    part.symbol_uses.reIndex(allocator_) catch unreachable;
                }
            }

            var symbol_uses = part.symbol_uses.keys();

            // Now that we know this, we can determine cross-part dependencies
            for (symbol_uses, 0..) |ref, j| {
                if (comptime Environment.allow_assert) {
                    std.debug.assert(part.symbol_uses.values()[j].count_estimate > 0);
                }

                const other_parts = c.topLevelSymbolsToParts(id, ref);

                for (other_parts) |other_part_index| {
                    var local = local_dependencies.getOrPut(@intCast(u32, other_part_index)) catch unreachable;
                    if (!local.found_existing or local.value_ptr.* != part_index) {
                        local.value_ptr.* = @intCast(u32, part_index);
                        // note: if we crash on append, it is due to threadlocal heaps in mimalloc
                        part.dependencies.push(
                            allocator_,
                            .{
                                .source_index = Index.source(source_index),
                                .part_index = other_part_index,
                            },
                        ) catch unreachable;
                    }
                }

                // Also map from imports to parts that use them
                if (named_imports.getPtr(ref)) |existing| {
                    existing.local_parts_with_uses.push(allocator_, @intCast(u32, part_index)) catch unreachable;
                }
            }
        }
    }

    const MatchImport = struct {
        alias: string = "",
        kind: MatchImport.Kind = MatchImport.Kind.ignore,
        namespace_ref: Ref = Ref.None,
        source_index: u32 = 0,
        name_loc: Logger.Loc = Logger.Loc.Empty, // Optional, goes with sourceIndex, ignore if zero,
        other_source_index: u32 = 0,
        other_name_loc: Logger.Loc = Logger.Loc.Empty, // Optional, goes with otherSourceIndex, ignore if zero,
        ref: Ref = Ref.None,

        pub const Kind = enum {
            /// The import is either external or undefined
            ignore,

            /// "sourceIndex" and "ref" are in use
            normal,

            /// "namespaceRef" and "alias" are in use
            namespace,

            /// Both "normal" and "namespace"
            normal_and_namespace,

            /// The import could not be evaluated due to a cycle
            cycle,

            /// The import is missing but came from a TypeScript file
            probably_typescript_type,

            /// The import resolved to multiple symbols via "export * from"
            ambiguous,
        };
    };
    pub fn source_(c: *LinkerContext, index: anytype) *const Logger.Source {
        return &c.parse_graph.input_files.items(.source)[index];
    }

    pub fn treeShakingAndCodeSplitting(c: *LinkerContext) !void {
        var parts = c.graph.ast.items(.parts);
        var import_records = c.graph.ast.items(.import_records);
        var side_effects = c.parse_graph.input_files.items(.side_effects);
        var entry_point_kinds = c.graph.files.items(.entry_point_kind);
        const entry_points = c.graph.entry_points.items(.source_index);
        var distances = c.graph.files.items(.distance_from_entry_point);

        // Tree shaking: Each entry point marks all files reachable from itself
        for (entry_points) |entry_point| {
            c.markFileLiveForTreeShaking(
                entry_point,
                side_effects,
                parts,
                import_records,
                entry_point_kinds,
            );
        }

        var file_entry_bits: []AutoBitSet = c.graph.files.items(.entry_bits);
        // AutoBitSet needs to be initialized if it is dynamic
        if (AutoBitSet.needsDynamic(entry_points.len)) {
            for (file_entry_bits) |*bits| {
                bits.* = try AutoBitSet.initEmpty(c.allocator, entry_points.len);
            }
        } else if (file_entry_bits.len > 0) {
            // assert that the tag is correct
            std.debug.assert(file_entry_bits[0] == .static);
        }

        // Code splitting: Determine which entry points can reach which files. This
        // has to happen after tree shaking because there is an implicit dependency
        // between live parts within the same file. All liveness has to be computed
        // first before determining which entry points can reach which files.
        for (entry_points, 0..) |entry_point, i| {
            c.markFileReachableForCodeSplitting(
                entry_point,
                i,
                distances,
                0,
                parts,
                import_records,
                file_entry_bits,
            );
        }
    }

    const ChunkMeta = struct {
        imports: Map,
        exports: Map,
        dynamic_imports: std.AutoArrayHashMap(Index.Int, void),

        pub const Map = std.AutoArrayHashMap(Ref, void);
    };

    const CrossChunkDependencies = struct {
        chunk_meta: []ChunkMeta,
        chunks: []Chunk,
        parts: []BabyList(js_ast.Part),
        import_records: []BabyList(bun.ImportRecord),
        flags: []const JSMeta.Flags,
        entry_point_chunk_indices: []Index.Int,
        imports_to_bind: []RefImportData,
        wrapper_refs: []const Ref,
        sorted_and_filtered_export_aliases: []const []const string,
        resolved_exports: []const ResolvedExports,
        ctx: *LinkerContext,
        symbols: *Symbol.Map,

        pub fn walk(deps: *@This(), chunk: *Chunk, chunk_index: usize) void {
            var chunk_meta = &deps.chunk_meta[chunk_index];
            var imports = &deps.chunk_meta[chunk_index].imports;

            const entry_point_chunk_indices = deps.entry_point_chunk_indices;

            // Go over each file in this chunk
            for (chunk.files_with_parts_in_chunk.keys()) |source_index| {
                if (chunk.content != .javascript) continue;

                // Go over each part in this file that's marked for inclusion in this chunk
                const parts = deps.parts[source_index].slice();
                var import_records = deps.import_records[source_index].slice();
                const imports_to_bind = deps.imports_to_bind[source_index];
                const wrap = deps.flags[source_index].wrap;
                const wrapper_ref = deps.wrapper_refs[source_index];
                const _chunks = deps.chunks;

                for (parts) |part| {
                    if (!part.is_live)
                        continue;

                    // Rewrite external dynamic imports to point to the chunk for that entry point
                    for (part.import_record_indices.slice()) |import_record_id| {
                        var import_record = &import_records[import_record_id];
                        if (import_record.source_index.isValid() and deps.ctx.isExternalDynamicImport(import_record, source_index)) {
                            const other_chunk_index = entry_point_chunk_indices[import_record.source_index.get()];
                            import_record.path.text = _chunks[other_chunk_index].unique_key;
                            import_record.source_index = Index.invalid;

                            // Track this cross-chunk dynamic import so we make sure to
                            // include its hash when we're calculating the hashes of all
                            // dependencies of this chunk.
                            if (other_chunk_index != chunk_index)
                                chunk_meta.dynamic_imports.put(other_chunk_index, {}) catch unreachable;
                        }
                    }

                    // Remember what chunk each top-level symbol is declared in. Symbols
                    // with multiple declarations such as repeated "var" statements with
                    // the same name should already be marked as all being in a single
                    // chunk. In that case this will overwrite the same value below which
                    // is fine.
                    deps.symbols.assignChunkIndex(part.declared_symbols, @truncate(u32, chunk_index));

                    const used_refs = part.symbol_uses.keys();

                    for (used_refs) |ref_| {
                        const ref_to_use = brk: {
                            var ref = ref_;
                            var symbol = deps.symbols.getConst(ref).?;

                            // Ignore unbound symbols
                            if (symbol.kind == .unbound)
                                continue;

                            // Ignore symbols that are going to be replaced by undefined
                            if (symbol.import_item_status == .missing) {
                                continue;
                            }

                            // If this is imported from another file, follow the import
                            // reference and reference the symbol in that file instead
                            if (imports_to_bind.get(ref)) |import_data| {
                                ref = import_data.data.import_ref;
                                symbol = deps.symbols.getConst(ref).?;
                            } else if (wrap == .cjs and ref.eql(wrapper_ref)) {
                                // The only internal symbol that wrapped CommonJS files export
                                // is the wrapper itself.
                                continue;
                            } else if (symbol.kind == .other) {
                                // TODO: figure out why we need to do this
                                // Without this, we are unable to map the import to runtime symbols across chunks
                                // which means we miss any runtime-imported symbol
                                if (imports_to_bind.get(deps.symbols.follow(ref))) |import_data| {
                                    ref = import_data.data.import_ref;
                                    symbol = deps.symbols.getConst(ref).?;
                                }
                            }

                            // If this is an ES6 import from a CommonJS file, it will become a
                            // property access off the namespace symbol instead of a bare
                            // identifier. In that case we want to pull in the namespace symbol
                            // instead. The namespace symbol stores the result of "require()".
                            if (symbol.namespace_alias) |*namespace_alias| {
                                ref = namespace_alias.namespace_ref;
                            }
                            break :brk ref;
                        };

                        if (comptime Environment.allow_assert)
                            debug("Cross-chunk import: {s} {}", .{ deps.symbols.get(ref_to_use).?.original_name, ref_to_use });

                        // We must record this relationship even for symbols that are not
                        // imports. Due to code splitting, the definition of a symbol may
                        // be moved to a separate chunk than the use of a symbol even if
                        // the definition and use of that symbol are originally from the
                        // same source file.
                        imports.put(ref_to_use, {}) catch unreachable;
                    }
                }
            }

            // Include the exports if this is an entry point chunk
            if (chunk.content == .javascript) {
                if (chunk.entry_point.is_entry_point) {
                    const flags = deps.flags[chunk.entry_point.source_index];
                    if (flags.wrap != .cjs) {
                        const resolved_exports = deps.resolved_exports[chunk.entry_point.source_index];
                        const sorted_and_filtered_export_aliases = deps.sorted_and_filtered_export_aliases[chunk.entry_point.source_index];
                        for (sorted_and_filtered_export_aliases) |alias| {
                            const export_ = resolved_exports.get(alias).?;
                            var target_ref = export_.data.import_ref;

                            // If this is an import, then target what the import points to
                            if (deps.imports_to_bind[export_.data.source_index.get()].get(target_ref)) |import_data| {
                                target_ref = import_data.data.import_ref;
                            }

                            // If this is an ES6 import from a CommonJS file, it will become a
                            // property access off the namespace symbol instead of a bare
                            // identifier. In that case we want to pull in the namespace symbol
                            // instead. The namespace symbol stores the result of "require()".
                            if (deps.symbols.getConst(target_ref).?.namespace_alias) |namespace_alias| {
                                target_ref = namespace_alias.namespace_ref;
                            }
                            if (comptime Environment.allow_assert)
                                debug("Cross-chunk export: {s}", .{deps.symbols.get(target_ref).?.original_name});

                            imports.put(target_ref, {}) catch unreachable;
                        }
                    }

                    // Ensure "exports" is included if the current output format needs it
                    if (flags.force_include_exports_for_entry_point) {
                        imports.put(deps.wrapper_refs[chunk.entry_point.source_index], {}) catch unreachable;
                    }

                    // Include the wrapper if present
                    if (flags.wrap != .none) {
                        imports.put(deps.wrapper_refs[chunk.entry_point.source_index], {}) catch unreachable;
                    }
                }
            }
        }
    };

    pub fn computeCrossChunkDependencies(c: *LinkerContext, chunks: []Chunk) !void {
        if (!c.graph.code_splitting) {
            // No need to compute cross-chunk dependencies if there can't be any
            return;
        }

        var chunk_metas = try c.allocator.alloc(ChunkMeta, chunks.len);
        for (chunk_metas) |*meta| {
            // these must be global allocator
            meta.* = .{
                .imports = ChunkMeta.Map.init(bun.default_allocator),
                .exports = ChunkMeta.Map.init(bun.default_allocator),
                .dynamic_imports = std.AutoArrayHashMap(Index.Int, void).init(bun.default_allocator),
            };
        }
        defer {
            for (chunk_metas) |*meta| {
                meta.imports.deinit();
                meta.exports.deinit();
                meta.dynamic_imports.deinit();
            }
            c.allocator.free(chunk_metas);
        }

        {
            var cross_chunk_dependencies = c.allocator.create(CrossChunkDependencies) catch unreachable;
            defer c.allocator.destroy(cross_chunk_dependencies);

            cross_chunk_dependencies.* = .{
                .chunks = chunks,
                .chunk_meta = chunk_metas,
                .parts = c.graph.ast.items(.parts),
                .import_records = c.graph.ast.items(.import_records),
                .flags = c.graph.meta.items(.flags),
                .entry_point_chunk_indices = c.graph.files.items(.entry_point_chunk_index),
                .imports_to_bind = c.graph.meta.items(.imports_to_bind),
                .wrapper_refs = c.graph.ast.items(.wrapper_ref),
                .sorted_and_filtered_export_aliases = c.graph.meta.items(.sorted_and_filtered_export_aliases),
                .resolved_exports = c.graph.meta.items(.resolved_exports),
                .ctx = c,
                .symbols = &c.graph.symbols,
            };

            c.parse_graph.pool.pool.doPtr(
                c.allocator,
                &c.wait_group,
                cross_chunk_dependencies,
                CrossChunkDependencies.walk,
                chunks,
            ) catch unreachable;
        }

        // Mark imported symbols as exported in the chunk from which they are declared
        for (chunks, chunk_metas, 0..) |*chunk, *chunk_meta, chunk_index| {
            if (chunk.content != .javascript) {
                continue;
            }
            var js = &chunk.content.javascript;

            // Find all uses in this chunk of symbols from other chunks
            for (chunk_meta.imports.keys()) |import_ref| {
                const symbol = c.graph.symbols.getConst(import_ref).?;

                // Ignore uses that aren't top-level symbols
                if (symbol.chunkIndex()) |other_chunk_index| {
                    if (@as(usize, other_chunk_index) != chunk_index) {
                        if (comptime Environment.allow_assert)
                            debug("Import name: {s} (in {s})", .{
                                symbol.original_name,
                                c.parse_graph.input_files.get(import_ref.sourceIndex()).source.path.text,
                            });

                        {
                            var entry = try js
                                .imports_from_other_chunks
                                .getOrPutValue(c.allocator, other_chunk_index, .{});
                            try entry.value_ptr.push(c.allocator, .{
                                .ref = import_ref,
                            });
                        }
                        _ = chunk_metas[other_chunk_index].exports.getOrPut(import_ref) catch unreachable;
                    }
                }
            }

            // If this is an entry point, make sure we import all chunks belonging to
            // this entry point, even if there are no imports. We need to make sure
            // these chunks are evaluated for their side effects too.
            if (chunk.entry_point.is_entry_point) {
                for (chunks, 0..) |*other_chunk, other_chunk_index| {
                    if (other_chunk_index == chunk_index or other_chunk.content != .javascript) continue;

                    if (other_chunk.entry_bits.isSet(chunk.entry_point.entry_point_id)) {
                        if (other_chunk.entry_point.is_entry_point) {
                            if (c.graph.react_client_component_boundary.bit_length > 0 or c.graph.react_server_component_boundary.bit_length > 0) {
                                const other_kind = c.graph.files.items(.entry_point_kind)[other_chunk.entry_point.source_index];
                                const this_kind = c.graph.files.items(.entry_point_kind)[chunk.entry_point.source_index];

                                if (this_kind != .react_client_component and
                                    other_kind.isReactReference())
                                {
                                    continue;
                                }
                            }
                        }
                        _ = js.imports_from_other_chunks.getOrPutValue(
                            c.allocator,
                            @truncate(u32, other_chunk_index),
                            CrossChunkImport.Item.List{},
                        ) catch unreachable;
                    }
                }
            }

            // Make sure we also track dynamic cross-chunk imports. These need to be
            // tracked so we count them as dependencies of this chunk for the purpose
            // of hash calculation.
            if (chunk_meta.dynamic_imports.count() > 0) {
                var dynamic_chunk_indices = chunk_meta.dynamic_imports.keys();
                std.sort.sort(Index.Int, dynamic_chunk_indices, {}, std.sort.asc(Index.Int));

                var imports = chunk.cross_chunk_imports.listManaged(c.allocator);
                defer chunk.cross_chunk_imports.update(imports);
                imports.ensureUnusedCapacity(dynamic_chunk_indices.len) catch unreachable;
                const prev_len = imports.items.len;
                imports.items.len += dynamic_chunk_indices.len;
                for (dynamic_chunk_indices, imports.items[prev_len..]) |dynamic_chunk_index, *item| {
                    item.* = .{
                        .import_kind = .dynamic,
                        .chunk_index = dynamic_chunk_index,
                    };
                }
            }
        }

        // Generate cross-chunk exports. These must be computed before cross-chunk
        // imports because of export alias renaming, which must consider all export
        // aliases simultaneously to avoid collisions.
        {
            std.debug.assert(chunk_metas.len == chunks.len);
            var r = renamer.ExportRenamer.init(c.allocator);
            defer r.deinit();
            debug("Generating cross-chunk exports", .{});

            var stable_ref_list = std.ArrayList(StableRef).init(c.allocator);
            defer stable_ref_list.deinit();

            for (chunks, chunk_metas) |*chunk, *chunk_meta| {
                if (chunk.content != .javascript) continue;

                var repr = &chunk.content.javascript;

                switch (c.options.output_format) {
                    .esm => {
                        c.sortedCrossChunkExportItems(
                            chunk_meta.exports,
                            &stable_ref_list,
                        );
                        var clause_items = BabyList(js_ast.ClauseItem).initCapacity(c.allocator, stable_ref_list.items.len) catch unreachable;
                        clause_items.len = @truncate(u32, stable_ref_list.items.len);
                        repr.exports_to_other_chunks.ensureUnusedCapacity(c.allocator, stable_ref_list.items.len) catch unreachable;
                        r.clearRetainingCapacity();

                        for (stable_ref_list.items, clause_items.slice()) |stable_ref, *clause_item| {
                            const ref = stable_ref.ref;
                            const alias = r.nextRenamedName(c.graph.symbols.get(ref).?.original_name);

                            clause_item.* = .{
                                .name = .{
                                    .ref = ref,
                                    .loc = Logger.Loc.Empty,
                                },
                                .alias = alias,
                                .alias_loc = Logger.Loc.Empty,
                                .original_name = "",
                            };

                            repr.exports_to_other_chunks.putAssumeCapacity(
                                ref,
                                alias,
                            );
                        }

                        if (clause_items.len > 0) {
                            var stmts = BabyList(js_ast.Stmt).initCapacity(c.allocator, 1) catch unreachable;
                            var export_clause = c.allocator.create(js_ast.S.ExportClause) catch unreachable;
                            export_clause.* = .{
                                .items = clause_items.slice(),
                                .is_single_line = true,
                            };
                            stmts.appendAssumeCapacity(.{
                                .data = .{
                                    .s_export_clause = export_clause,
                                },
                                .loc = Logger.Loc.Empty,
                            });
                            repr.cross_chunk_suffix_stmts = stmts;
                        }
                    },
                    else => {},
                    // else => bun.unreachablePanic("Unexpected output format", .{}),
                }
            }
        }

        // Generate cross-chunk imports. These must be computed after cross-chunk
        // exports because the export aliases must already be finalized so they can
        // be embedded in the generated import statements.
        {
            debug("Generating cross-chunk imports", .{});
            var list = CrossChunkImport.List.init(c.allocator);
            defer list.deinit();

            for (chunks) |*chunk| {
                if (chunk.content != .javascript) continue;
                var repr = &chunk.content.javascript;
                var cross_chunk_prefix_stmts = BabyList(js_ast.Stmt){};

                list.clearRetainingCapacity();
                CrossChunkImport.sortedCrossChunkImports(&list, chunks, &repr.imports_from_other_chunks) catch unreachable;
                var cross_chunk_imports_input: []CrossChunkImport = list.items;
                var cross_chunk_imports = chunk.cross_chunk_imports;
                for (cross_chunk_imports_input) |cross_chunk_import| {
                    switch (c.options.output_format) {
                        .esm => {
                            const import_record_index = @intCast(u32, cross_chunk_imports.len);

                            var clauses = std.ArrayList(js_ast.ClauseItem).initCapacity(c.allocator, cross_chunk_import.sorted_import_items.len) catch unreachable;
                            for (cross_chunk_import.sorted_import_items.slice()) |item| {
                                clauses.appendAssumeCapacity(.{
                                    .name = .{
                                        .ref = item.ref,
                                        .loc = Logger.Loc.Empty,
                                    },
                                    .alias = item.export_alias,
                                    .alias_loc = Logger.Loc.Empty,
                                });
                            }

                            cross_chunk_imports.push(c.allocator, .{
                                .import_kind = .stmt,
                                .chunk_index = cross_chunk_import.chunk_index,
                            }) catch unreachable;
                            var import = c.allocator.create(js_ast.S.Import) catch unreachable;
                            import.* = .{
                                .items = clauses.items,
                                .import_record_index = import_record_index,
                                .namespace_ref = Ref.None,
                            };
                            cross_chunk_prefix_stmts.push(
                                c.allocator,
                                .{
                                    .data = .{
                                        .s_import = import,
                                    },
                                    .loc = Logger.Loc.Empty,
                                },
                            ) catch unreachable;
                        },
                        else => {},
                    }
                }

                repr.cross_chunk_prefix_stmts = cross_chunk_prefix_stmts;
                chunk.cross_chunk_imports = cross_chunk_imports;
            }
        }
    }

    const GenerateChunkCtx = struct {
        wg: *sync.WaitGroup,
        c: *LinkerContext,
        chunks: []Chunk,
    };
    fn generateChunkJS(ctx: GenerateChunkCtx, chunk: *Chunk, chunk_index: usize) void {
        generateChunkJS_(ctx, chunk, chunk_index) catch |err| Output.panic("TODO: handle error: {s}", .{@errorName(err)});
    }

    // TODO: investigate if we need to parallelize this function
    // esbuild does parallelize it.
    fn renameSymbolsInChunk(
        c: *LinkerContext,
        allocator: std.mem.Allocator,
        chunk: *Chunk,
        files_in_order: []const u32,
    ) !renamer.Renamer {

        // TODO: minify identifiers
        const all_module_scopes = c.graph.ast.items(.module_scope);
        const all_flags: []const JSMeta.Flags = c.graph.meta.items(.flags);
        const all_parts: []const js_ast.Part.List = c.graph.ast.items(.parts);
        const all_wrapper_refs: []const Ref = c.graph.ast.items(.wrapper_ref);
        const all_import_records: []const ImportRecord.List = c.graph.ast.items(.import_records);

        var r = try renamer.NumberRenamer.init(
            allocator,
            allocator,
            c.graph.symbols,
            brk: {
                var reserved_names = try renamer.computeInitialReservedNames(allocator);

                for (files_in_order) |source_index| {
                    renamer.computeReservedNamesForScope(&all_module_scopes[source_index], &c.graph.symbols, &reserved_names, allocator);
                }

                break :brk reserved_names;
            },
        );
        {
            var sorted_imports_from_other_chunks: std.ArrayList(StableRef) = brk: {
                var list = std.ArrayList(StableRef).init(allocator);
                var count: u32 = 0;
                var imports_from_other_chunks = chunk.content.javascript.imports_from_other_chunks.values();
                for (imports_from_other_chunks) |item| {
                    count += item.len;
                }

                list.ensureTotalCapacityPrecise(count) catch unreachable;
                list.items.len = count;
                var remain = list.items;
                const stable_source_indices = c.graph.stable_source_indices;
                for (imports_from_other_chunks) |item| {
                    for (item.slice()) |ref| {
                        remain[0] = StableRef{
                            .stable_source_index = stable_source_indices[ref.ref.sourceIndex()],
                            .ref = ref.ref,
                        };
                        remain = remain[1..];
                    }
                }

                std.sort.sort(StableRef, list.items, {}, StableRef.isLessThan);
                break :brk list;
            };
            defer sorted_imports_from_other_chunks.deinit();

            for (sorted_imports_from_other_chunks.items) |stable_ref| {
                r.addTopLevelSymbol(stable_ref.ref);
            }
        }

        var sorted_ = std.ArrayList(u32).init(r.temp_allocator);
        var sorted = &sorted_;
        defer sorted.deinit();

        for (files_in_order) |source_index| {
            const wrap = all_flags[source_index].wrap;
            const parts: []const js_ast.Part = all_parts[source_index].slice();

            switch (wrap) {
                // Modules wrapped in a CommonJS closure look like this:
                //
                //   // foo.js
                //   var require_foo = __commonJS((exports, module) => {
                //     exports.foo = 123;
                //   });
                //
                // The symbol "require_foo" is stored in "file.ast.WrapperRef". We want
                // to be able to minify everything inside the closure without worrying
                // about collisions with other CommonJS modules. Set up the scopes such
                // that it appears as if the file was structured this way all along. It's
                // not completely accurate (e.g. we don't set the parent of the module
                // scope to this new top-level scope) but it's good enough for the
                // renaming code.
                .cjs => {
                    r.addTopLevelSymbol(all_wrapper_refs[source_index]);

                    // External import statements will be hoisted outside of the CommonJS
                    // wrapper if the output format supports import statements. We need to
                    // add those symbols to the top-level scope to avoid causing name
                    // collisions. This code special-cases only those symbols.
                    if (c.options.output_format.keepES6ImportExportSyntax()) {
                        const import_records = all_import_records[source_index].slice();
                        for (parts) |*part| {
                            for (part.stmts) |stmt| {
                                switch (stmt.data) {
                                    .s_import => |import| {
                                        if (!import_records[import.import_record_index].source_index.isValid()) {
                                            r.addTopLevelSymbol(import.namespace_ref);
                                            if (import.default_name) |default_name| {
                                                if (default_name.ref) |ref| {
                                                    r.addTopLevelSymbol(ref);
                                                }
                                            }

                                            for (import.items) |*item| {
                                                if (item.name.ref) |ref| {
                                                    r.addTopLevelSymbol(ref);
                                                }
                                            }
                                        }
                                    },
                                    .s_export_star => |export_| {
                                        if (!import_records[export_.import_record_index].source_index.isValid()) {
                                            r.addTopLevelSymbol(export_.namespace_ref);
                                        }
                                    },
                                    .s_export_from => |export_| {
                                        if (!import_records[export_.import_record_index].source_index.isValid()) {
                                            r.addTopLevelSymbol(export_.namespace_ref);

                                            for (export_.items) |*item| {
                                                if (item.name.ref) |ref| {
                                                    r.addTopLevelSymbol(ref);
                                                }
                                            }
                                        }
                                    },
                                    else => {},
                                }
                            }
                        }
                    }
                    r.assignNamesRecursiveWithNumberScope(&r.root, &all_module_scopes[source_index], source_index, sorted);
                    continue;
                },

                // Modules wrapped in an ESM closure look like this:
                //
                //   // foo.js
                //   var foo, foo_exports = {};
                //   __export(foo_exports, {
                //     foo: () => foo
                //   });
                //   let init_foo = __esm(() => {
                //     foo = 123;
                //   });
                //
                // The symbol "init_foo" is stored in "file.ast.WrapperRef". We need to
                // minify everything inside the closure without introducing a new scope
                // since all top-level variables will be hoisted outside of the closure.
                .esm => {
                    r.addTopLevelSymbol(all_wrapper_refs[source_index]);
                },

                else => {},
            }

            for (parts) |*part| {
                if (!part.is_live) continue;

                r.addTopLevelDeclaredSymbols(part.declared_symbols);
                for (part.scopes) |scope| {
                    r.assignNamesRecursiveWithNumberScope(&r.root, scope, source_index, sorted);
                }
                r.number_scope_pool.hive.available = @TypeOf(r.number_scope_pool.hive.available).initFull();
            }
        }

        return r.toRenamer();
    }

    fn generateChunkJS_(ctx: GenerateChunkCtx, chunk: *Chunk, chunk_index: usize) !void {
        _ = chunk_index;
        defer ctx.wg.finish();
        var worker = ThreadPool.Worker.get();

        if (comptime FeatureFlags.help_catch_memory_issues) {
            worker.heap.gc(false);
        }

        const allocator = worker.allocator;
        const c = ctx.c;
        std.debug.assert(chunk.content == .javascript);

        var repr = &chunk.content.javascript;

        var runtime_scope: *Scope = &c.graph.ast.items(.module_scope)[c.graph.files.items(.input_file)[Index.runtime.value].get()];
        var runtime_members = &runtime_scope.members;
        const toCommonJSRef = c.graph.symbols.follow(runtime_members.get("__toCommonJS").?.ref);
        const toESMRef = c.graph.symbols.follow(runtime_members.get("__toESM").?.ref);
        const runtimeRequireRef = c.graph.symbols.follow(runtime_members.get("__require").?.ref);

        js_ast.Expr.Data.Store.create(bun.default_allocator);
        js_ast.Stmt.Data.Store.create(bun.default_allocator);

        var r = try c.renameSymbolsInChunk(allocator, chunk, repr.files_in_chunk_order);
        defer r.deinit();
        const part_ranges = repr.parts_in_chunk_in_order;
        var stmts = StmtList.init(allocator);
        defer stmts.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var compile_results = std.ArrayList(CompileResult).initCapacity(allocator, part_ranges.len) catch unreachable;
        {
            defer _ = arena.reset(.retain_capacity);

            var buffer_writer = js_printer.BufferWriter.init(allocator) catch unreachable;

            for (part_ranges, 0..) |part_range, i| {
                if (i > 0) _ = arena.reset(.retain_capacity);
                const result = c.generateCodeForFileInChunkJS(
                    &buffer_writer,
                    r,
                    chunk,
                    part_range,
                    toCommonJSRef,
                    toESMRef,
                    runtimeRequireRef,
                    &stmts,
                    allocator,
                    arena.allocator(),
                );

                if (i < part_ranges.len - 1) {
                    compile_results.appendAssumeCapacity(
                        // we reuse the memory buffer up until the final chunk to minimize reallocations
                        .{
                            .javascript = .{
                                .result = result.clone(allocator) catch unreachable,
                                .source_index = part_range.source_index.get(),
                            },
                        },
                    );
                } else {
                    if (comptime Environment.allow_assert) {
                        if (result == .result) {
                            if (buffer_writer.buffer.list.capacity > result.result.code.len) {
                                // add a 0 to make it easier to view the code in a debugger
                                // but only if room
                                buffer_writer.buffer.list.items.ptr[result.result.code.len] = 0;
                            }
                        }
                    }

                    // the final chunk owns the memory buffer
                    compile_results.appendAssumeCapacity(.{
                        .javascript = .{
                            .result = result,
                            .source_index = part_range.source_index.get(),
                        },
                    });
                }
            }
        }

        // Also generate the cross-chunk binding code
        var cross_chunk_prefix: []u8 = &.{};
        var cross_chunk_suffix: []u8 = &.{};

        {
            const indent: usize = 0;
            // TODO: IIFE indent

            const print_options = js_printer.Options{
                // TODO: IIFE
                .indent = indent,

                .allocator = allocator,
                .require_ref = runtimeRequireRef,
                .minify_whitespace = c.options.minify_whitespace,
                .const_values = c.graph.const_values,
            };

            var cross_chunk_import_records = ImportRecord.List.initCapacity(allocator, chunk.cross_chunk_imports.len) catch unreachable;
            defer cross_chunk_import_records.deinitWithAllocator(allocator);
            for (chunk.cross_chunk_imports.slice()) |import_record| {
                cross_chunk_import_records.appendAssumeCapacity(
                    .{
                        .kind = import_record.import_kind,
                        .path = Fs.Path.init(ctx.chunks[import_record.chunk_index].unique_key),
                        .range = Logger.Range.None,
                    },
                );
            }

            cross_chunk_prefix = js_printer.print(
                allocator,
                c.resolver.opts.platform,
                print_options,
                cross_chunk_import_records.slice(),
                &[_]js_ast.Part{
                    .{ .stmts = chunk.content.javascript.cross_chunk_prefix_stmts.slice() },
                },
                r,
            ).result.code;
            cross_chunk_suffix = js_printer.print(
                allocator,
                c.resolver.opts.platform,
                print_options,
                &.{},
                &[_]js_ast.Part{
                    .{ .stmts = chunk.content.javascript.cross_chunk_suffix_stmts.slice() },
                },
                r,
            ).result.code;
        }

        // Generate the exports for the entry point, if there are any
        const entry_point_tail = brk: {
            if (chunk.isEntryPoint()) {
                break :brk c.generateEntryPointTailJS(
                    toCommonJSRef,
                    toESMRef,
                    chunk.entry_point.source_index,
                    allocator,
                    arena.allocator(),
                    r,
                );
            }

            break :brk CompileResult.empty;
        };

        var j = bun.Joiner{
            .use_pool = false,
            .node_allocator = allocator,
            .watcher = .{
                .input = chunk.unique_key,
            },
        };
        var line_offset: bun.sourcemap.LineColumnOffset.Optional = .{ .null = {} };

        // Concatenate the generated JavaScript chunks together

        var newline_before_comment = false;
        var is_executable = false;

        // Start with the hashbang if there is one. This must be done before the
        // banner because it only works if it's literally the first character.
        if (chunk.isEntryPoint()) {
            if (c.graph.ast.items(.hashbang)[chunk.entry_point.source_index]) |hashbang| {
                std.debug.assert(hashbang.len > 0);
                j.push(hashbang);
                j.push("\n");
                line_offset.advance(hashbang);
                newline_before_comment = true;
                is_executable = true;
            }
        }

        if (chunk.entry_point.is_entry_point and ctx.c.graph.ast.items(.platform)[chunk.entry_point.source_index].isBun()) {
            j.push("// @bun\n");
        }

        // TODO: banner

        // TODO: directive

        // TODO: IIFE wrap

        if (cross_chunk_prefix.len > 0) {
            newline_before_comment = true;
            line_offset.advance(cross_chunk_prefix);
            j.push(cross_chunk_prefix);
        }

        // Concatenate the generated JavaScript chunks together

        var prev_filename_comment: Index.Int = 0;

        const sources: []const Logger.Source = c.parse_graph.input_files.items(.source);
        for (@as([]CompileResult, compile_results.items)) |compile_result| {
            const source_index = compile_result.sourceIndex();
            const is_runtime = source_index == Index.runtime.value;

            // TODO: extracated legal comments

            // Add a comment with the file path before the file contents
            if (c.options.mode == .bundle and !c.options.minify_whitespace and source_index != prev_filename_comment and compile_result.code().len > 0) {
                prev_filename_comment = source_index;
                if (newline_before_comment) {
                    j.push("\n");
                    line_offset.advance("\n");
                }

                // Make sure newlines in the path can't cause a syntax error. This does
                // not minimize allocations because it's expected that this case never
                // comes up in practice.
                const CommentType = enum {
                    multiline,
                    single,
                };

                const pretty = sources[source_index].path.pretty;

                // TODO: quote this. This is really janky.
                const comment_type = if (strings.indexOfNewlineOrNonASCII(pretty, 0) != null)
                    CommentType.multiline
                else
                    CommentType.single;

                switch (comment_type) {
                    .multiline => {
                        j.push("/* ");
                        line_offset.advance("/* ");
                    },
                    .single => {
                        j.push("// ");
                        line_offset.advance("// ");
                    },
                }

                j.push(pretty);
                line_offset.advance(pretty);

                switch (comment_type) {
                    .multiline => {
                        j.push(" */\n");
                        line_offset.advance(" */\n");
                    },
                    .single => {
                        j.push("\n");
                        line_offset.advance("\n");
                    },
                }
                prev_filename_comment = source_index;
            }

            if (is_runtime) {
                line_offset.advance(compile_result.code());
                j.append(compile_result.code(), 0, allocator);
            } else {
                line_offset.advance(compile_result.code());
                j.append(compile_result.code(), 0, allocator);

                // TODO: sourcemap
            }

            // TODO: metafile
            newline_before_comment = compile_result.code().len > 0;
        }

        const tail_code = entry_point_tail.code();
        if (tail_code.len > 0) {
            // Stick the entry point tail at the end of the file. Deliberately don't
            // include any source mapping information for this because it's automatically
            // generated and doesn't correspond to a location in the input file.
            j.push(tail_code);
        }

        // Put the cross-chunk suffix inside the IIFE
        if (cross_chunk_suffix.len > 0) {
            if (newline_before_comment) {
                j.push("\n");
                line_offset.advance("\n");
            }

            j.push(cross_chunk_suffix);
        }

        if (c.options.output_format == .iife) {
            const without_newline = "})();";

            const with_newline = if (newline_before_comment)
                without_newline ++ "\n"
            else
                without_newline;

            j.push(with_newline);
        }

        j.ensureNewlineAtEnd();
        // TODO: maybeAppendLegalComments

        // TODO: footer

        chunk.intermediate_output = c.breakOutputIntoPieces(
            allocator,
            &j,
            cross_chunk_prefix.len > 0 or
                cross_chunk_suffix.len > 0,
            @truncate(u32, ctx.chunks.len),
        ) catch @panic("Unhandled out of memory error in breakOutputIntoPieces()");

        // TODO: meta contents

        chunk.isolated_hash = c.generateIsolatedHash(chunk);
        chunk.is_executable = is_executable;
    }

    pub fn generateIsolatedHash(c: *LinkerContext, chunk: *const Chunk) u64 {
        var hasher = ContentHasher{};

        // Mix the file names and part ranges of all of the files in this chunk into
        // the hash. Objects that appear identical but that live in separate files or
        // that live in separate parts in the same file must not be merged. This only
        // needs to be done for JavaScript files, not CSS files.
        if (chunk.content == .javascript) {
            const sources = c.parse_graph.input_files.items(.source);
            for (chunk.content.javascript.parts_in_chunk_in_order) |part_range| {
                const source: Logger.Source = sources[part_range.source_index.get()];

                const file_path = brk: {
                    if (strings.eqlComptime(source.path.namespace, "file")) {
                        // Use the pretty path as the file name since it should be platform-
                        // independent (relative paths and the "/" path separator)
                        break :brk source.path.pretty;
                    } else {
                        // If this isn't in the "file" namespace, just use the full path text
                        // verbatim. This could be a source of cross-platform differences if
                        // plugins are storing platform-specific information in here, but then
                        // that problem isn't caused by esbuild itself.
                        break :brk source.path.text;
                    }
                };

                // Include the path namespace in the hash so that files with the same
                hasher.write(source.key_path.namespace);

                // Then include the file path
                hasher.write(file_path);

                // Then include the part range
                hasher.writeInts(&[_]u32{
                    part_range.part_index_begin,
                    part_range.part_index_end,
                });
            }
        }

        // Hash the output path template as part of the content hash because we want
        // any import to be considered different if the import's output path has changed.
        hasher.write(chunk.template.data);

        // Also hash the public path. If provided, this is used whenever files
        // reference each other such as cross-chunk imports, asset file references,
        // and source map comments. We always include the hash in all chunks instead
        // of trying to figure out which chunks will include the public path for
        // simplicity and for robustness to code changes in the future.
        if (c.options.public_path.len > 0) {
            hasher.write(c.options.public_path);
        }

        // Include the generated output content in the hash. This excludes the
        // randomly-generated import paths (the unique keys) and only includes the
        // data in the spans between them.
        if (chunk.intermediate_output == .pieces) {
            for (chunk.intermediate_output.pieces.slice()) |piece| {
                hasher.write(piece.data());
            }
        } else {
            var el = chunk.intermediate_output.joiner.head;
            while (el) |e| : (el = e.next) {
                hasher.write(e.data.slice);
            }
        }

        return hasher.digest();
    }

    pub fn generateEntryPointTailJS(
        c: *LinkerContext,
        toCommonJSRef: Ref,
        toESMRef: Ref,
        source_index: Index.Int,
        allocator: std.mem.Allocator,
        temp_allocator: std.mem.Allocator,
        r: renamer.Renamer,
    ) CompileResult {
        const flags: JSMeta.Flags = c.graph.meta.items(.flags)[source_index];
        var stmts = std.ArrayList(Stmt).init(temp_allocator);
        defer stmts.deinit();
        const ast: js_ast.Ast = c.graph.ast.get(source_index);

        switch (c.options.output_format) {
            // TODO:
            .preserve => {},

            .esm => {
                switch (flags.wrap) {
                    .cjs => {
                        stmts.append(
                            Stmt.alloc(
                                // "export default require_foo();"
                                S.ExportDefault,
                                .{
                                    .default_name = .{
                                        .loc = Logger.Loc.Empty,
                                        .ref = ast.wrapper_ref,
                                    },
                                    .value = .{
                                        .expr = Expr.init(
                                            E.Call,
                                            E.Call{
                                                .target = Expr.initIdentifier(
                                                    ast.wrapper_ref,
                                                    Logger.Loc.Empty,
                                                ),
                                            },
                                            Logger.Loc.Empty,
                                        ),
                                    },
                                },
                                Logger.Loc.Empty,
                            ),
                        ) catch unreachable;
                    },
                    else => {
                        if (flags.wrap == .esm) {
                            if (flags.is_async_or_has_async_dependency) {
                                // "await init_foo();"
                                stmts.append(
                                    Stmt.alloc(
                                        S.SExpr,
                                        .{
                                            .value = Expr.init(
                                                E.Await,
                                                E.Await{
                                                    .value = Expr.init(
                                                        E.Call,
                                                        E.Call{
                                                            .target = Expr.initIdentifier(
                                                                ast.wrapper_ref,
                                                                Logger.Loc.Empty,
                                                            ),
                                                        },
                                                        Logger.Loc.Empty,
                                                    ),
                                                },
                                                Logger.Loc.Empty,
                                            ),
                                        },
                                        Logger.Loc.Empty,
                                    ),
                                ) catch unreachable;
                            } else {
                                // "init_foo();"
                                stmts.append(
                                    Stmt.alloc(
                                        S.SExpr,
                                        .{
                                            .value = Expr.init(
                                                E.Call,
                                                E.Call{
                                                    .target = Expr.initIdentifier(
                                                        ast.wrapper_ref,
                                                        Logger.Loc.Empty,
                                                    ),
                                                },
                                                Logger.Loc.Empty,
                                            ),
                                        },
                                        Logger.Loc.Empty,
                                    ),
                                ) catch unreachable;
                            }
                        }

                        const sorted_and_filtered_export_aliases = c.graph.meta.items(.sorted_and_filtered_export_aliases)[source_index];

                        if (sorted_and_filtered_export_aliases.len > 0) {
                            const resolved_exports: ResolvedExports = c.graph.meta.items(.resolved_exports)[source_index];
                            const imports_to_bind: RefImportData = c.graph.meta.items(.imports_to_bind)[source_index];

                            // If the output format is ES6 modules and we're an entry point, generate an
                            // ES6 export statement containing all exports. Except don't do that if this
                            // entry point is a CommonJS-style module, since that would generate an ES6
                            // export statement that's not top-level. Instead, we will export the CommonJS
                            // exports as a default export later on.
                            var items = std.ArrayList(js_ast.ClauseItem).init(temp_allocator);
                            const cjs_export_copies = c.graph.meta.items(.cjs_export_copies)[source_index];

                            for (sorted_and_filtered_export_aliases, 0..) |alias, i| {
                                var resolved_export = resolved_exports.get(alias).?;

                                // If this is an export of an import, reference the symbol that the import
                                // was eventually resolved to. We need to do this because imports have
                                // already been resolved by this point, so we can't generate a new import
                                // and have that be resolved later.
                                if (imports_to_bind.get(resolved_export.data.import_ref)) |import_data| {
                                    resolved_export.data.import_ref = import_data.data.import_ref;
                                    resolved_export.data.source_index = import_data.data.source_index;
                                }

                                // Exports of imports need EImportIdentifier in case they need to be re-
                                // written to a property access later on
                                if (c.graph.symbols.get(resolved_export.data.import_ref).?.namespace_alias != null) {
                                    const temp_ref = cjs_export_copies[i];

                                    // Create both a local variable and an export clause for that variable.
                                    // The local variable is initialized with the initial value of the
                                    // export. This isn't fully correct because it's a "dead" binding and
                                    // doesn't update with the "live" value as it changes. But ES6 modules
                                    // don't have any syntax for bare named getter functions so this is the
                                    // best we can do.
                                    //
                                    // These input files:
                                    //
                                    //   // entry_point.js
                                    //   export {foo} from './cjs-format.js'
                                    //
                                    //   // cjs-format.js
                                    //   Object.defineProperty(exports, 'foo', {
                                    //     enumerable: true,
                                    //     get: () => Math.random(),
                                    //   })
                                    //
                                    // Become this output file:
                                    //
                                    //   // cjs-format.js
                                    //   var require_cjs_format = __commonJS((exports) => {
                                    //     Object.defineProperty(exports, "foo", {
                                    //       enumerable: true,
                                    //       get: () => Math.random()
                                    //     });
                                    //   });
                                    //
                                    //   // entry_point.js
                                    //   var cjs_format = __toESM(require_cjs_format());
                                    //   var export_foo = cjs_format.foo;
                                    //   export {
                                    //     export_foo as foo
                                    //   };
                                    //
                                    stmts.append(
                                        Stmt.alloc(
                                            S.Local,
                                            .{
                                                .decls = bun.fromSlice(
                                                    []js_ast.G.Decl,
                                                    temp_allocator,
                                                    []const js_ast.G.Decl,
                                                    &.{
                                                        .{
                                                            .binding = Binding.alloc(
                                                                temp_allocator,
                                                                B.Identifier{
                                                                    .ref = temp_ref,
                                                                },
                                                                Logger.Loc.Empty,
                                                            ),
                                                            .value = Expr.init(
                                                                E.ImportIdentifier,
                                                                E.ImportIdentifier{
                                                                    .ref = resolved_export.data.import_ref,
                                                                },
                                                                Logger.Loc.Empty,
                                                            ),
                                                        },
                                                    },
                                                ) catch unreachable,
                                            },
                                            Logger.Loc.Empty,
                                        ),
                                    ) catch unreachable;

                                    items.append(
                                        .{
                                            .name = js_ast.LocRef{
                                                .ref = temp_ref,
                                                .loc = Logger.Loc.Empty,
                                            },
                                            .alias = alias,
                                            .alias_loc = Logger.Loc.Empty,
                                        },
                                    ) catch unreachable;
                                } else {
                                    // Local identifiers can be exported using an export clause. This is done
                                    // this way instead of leaving the "export" keyword on the local declaration
                                    // itself both because it lets the local identifier be minified and because
                                    // it works transparently for re-exports across files.
                                    //
                                    // These input files:
                                    //
                                    //   // entry_point.js
                                    //   export * from './esm-format.js'
                                    //
                                    //   // esm-format.js
                                    //   export let foo = 123
                                    //
                                    // Become this output file:
                                    //
                                    //   // esm-format.js
                                    //   let foo = 123;
                                    //
                                    //   // entry_point.js
                                    //   export {
                                    //     foo
                                    //   };
                                    //
                                    items.append(.{
                                        .name = js_ast.LocRef{
                                            .ref = resolved_export.data.import_ref,
                                            .loc = resolved_export.data.name_loc,
                                        },
                                        .alias = alias,
                                        .alias_loc = resolved_export.data.name_loc,
                                    }) catch unreachable;
                                }
                            }

                            stmts.append(
                                Stmt.alloc(
                                    S.ExportClause,
                                    .{
                                        .items = items.items,
                                    },
                                    Logger.Loc.Empty,
                                ),
                            ) catch unreachable;
                        }
                    },
                }
            },

            // TODO: iife
            .iife => {},

            .cjs => {
                switch (flags.wrap) {
                    .cjs => {
                        // "module.exports = require_foo();"
                        stmts.append(
                            Stmt.assign(
                                Expr.init(
                                    E.Dot,
                                    .{
                                        .target = Expr.initIdentifier(c.unbound_module_ref, Logger.Loc.Empty),
                                        .name = "exports",
                                        .name_loc = Logger.Loc.Empty,
                                    },
                                    Logger.Loc.Empty,
                                ),
                                Expr.init(
                                    E.Call,
                                    .{
                                        .target = Expr.initIdentifier(ast.wrapper_ref, Logger.Loc.Empty),
                                    },
                                    Logger.Loc.Empty,
                                ),
                                temp_allocator,
                            ),
                        ) catch unreachable;
                    },
                    .esm => {
                        // "init_foo();"
                        stmts.append(
                            Stmt.alloc(
                                S.SExpr,
                                .{
                                    .value = Expr.init(
                                        E.Call,
                                        .{
                                            .target = Expr.initIdentifier(ast.wrapper_ref, Logger.Loc.Empty),
                                        },
                                        Logger.Loc.Empty,
                                    ),
                                },
                                Logger.Loc.Empty,
                            ),
                        ) catch unreachable;
                    },
                    else => {},
                }

                // TODO:
                // If we are generating CommonJS for node, encode the known export names in
                // a form that node can understand them. This relies on the specific behavior
                // of this parser, which the node project uses to detect named exports in
                // CommonJS files: https://github.com/guybedford/cjs-module-lexer. Think of
                // this code as an annotation for that parser.
            },
        }

        if (stmts.items.len == 0) {
            return .{
                .javascript = .{
                    .source_index = source_index,
                    .result = .{ .result = .{
                        .code = "",
                    } },
                },
            };
        }

        const print_options = js_printer.Options{
            // TODO: IIFE
            .indent = 0,

            .allocator = allocator,
            .to_esm_ref = toESMRef,
            .to_commonjs_ref = toCommonJSRef,
            .require_or_import_meta_for_source_callback = js_printer.RequireOrImportMeta.Callback.init(LinkerContext, requireOrImportMetaForSource, c),

            .minify_whitespace = c.options.minify_whitespace,
            .const_values = c.graph.const_values,
        };

        return .{
            .javascript = .{
                .result = js_printer.print(
                    allocator,
                    c.resolver.opts.platform,
                    print_options,
                    ast.import_records.slice(),
                    &[_]js_ast.Part{
                        .{
                            .stmts = stmts.items,
                        },
                    },
                    r,
                ),
                .source_index = source_index,
            },
        };
    }

    const StmtList = struct {
        inside_wrapper_prefix: std.ArrayList(Stmt),
        outside_wrapper_prefix: std.ArrayList(Stmt),
        inside_wrapper_suffix: std.ArrayList(Stmt),

        all_stmts: std.ArrayList(Stmt),

        pub fn reset(this: *StmtList) void {
            this.inside_wrapper_prefix.clearRetainingCapacity();
            this.outside_wrapper_prefix.clearRetainingCapacity();
            this.inside_wrapper_suffix.clearRetainingCapacity();
            this.all_stmts.clearRetainingCapacity();
        }

        pub fn deinit(this: *StmtList) void {
            this.inside_wrapper_prefix.deinit();
            this.outside_wrapper_prefix.deinit();
            this.inside_wrapper_suffix.deinit();
            this.all_stmts.deinit();
        }

        pub fn init(allocator: std.mem.Allocator) StmtList {
            return .{
                .inside_wrapper_prefix = std.ArrayList(Stmt).init(allocator),
                .outside_wrapper_prefix = std.ArrayList(Stmt).init(allocator),
                .inside_wrapper_suffix = std.ArrayList(Stmt).init(allocator),
                .all_stmts = std.ArrayList(Stmt).init(allocator),
            };
        }
    };

    fn shouldRemoveImportExportStmt(
        c: *LinkerContext,
        stmts: *StmtList,
        loc: Logger.Loc,
        namespace_ref: Ref,
        import_record_index: u32,
        allocator: std.mem.Allocator,
        ast: *const js_ast.Ast,
    ) !bool {
        const record = ast.import_records.at(import_record_index);
        if (record.tag.isReactReference())
            return false;

        // Is this an external import?
        if (!record.source_index.isValid()) {
            // Keep the "import" statement if import statements are supported
            if (c.options.output_format.keepES6ImportExportSyntax()) {
                return false;
            }

            // Otherwise, replace this statement with a call to "require()"
            stmts.inside_wrapper_prefix.append(
                Stmt.alloc(
                    S.Local,
                    S.Local{
                        .decls = try bun.fromSlice(
                            []G.Decl,
                            allocator,
                            []const G.Decl,
                            &.{
                                .{
                                    .binding = Binding.alloc(
                                        allocator,
                                        B.Identifier{
                                            .ref = namespace_ref,
                                        },
                                        loc,
                                    ),
                                    .value = Expr.init(
                                        E.RequireString,
                                        E.RequireString{
                                            .import_record_index = import_record_index,
                                        },
                                        loc,
                                    ),
                                },
                            },
                        ),
                    },
                    record.range.loc,
                ),
            ) catch unreachable;
            return true;
        }

        // We don't need a call to "require()" if this is a self-import inside a
        // CommonJS-style module, since we can just reference the exports directly.
        if (ast.exports_kind == .cjs and c.graph.symbols.follow(namespace_ref).eql(ast.exports_ref)) {
            return true;
        }

        const other_flags = c.graph.meta.items(.flags)[record.source_index.get()];
        switch (other_flags.wrap) {
            .none => {},
            .cjs => {
                // Replace the statement with a call to "require()" if this module is not wrapped
                try stmts.inside_wrapper_prefix.append(
                    Stmt.alloc(
                        S.Local,
                        S.Local{
                            .decls = try bun.fromSlice(
                                []G.Decl,
                                allocator,
                                []const G.Decl,
                                &.{
                                    .{
                                        .binding = Binding.alloc(
                                            allocator,
                                            B.Identifier{
                                                .ref = namespace_ref,
                                            },
                                            loc,
                                        ),
                                        .value = Expr.init(
                                            E.RequireString,
                                            E.RequireString{
                                                .import_record_index = import_record_index,
                                            },
                                            loc,
                                        ),
                                    },
                                },
                            ),
                        },
                        loc,
                    ),
                );
            },
            .esm => {
                // Ignore this file if it's not included in the bundle. This can happen for
                // wrapped ESM files but not for wrapped CommonJS files because we allow
                // tree shaking inside wrapped ESM files.
                if (!c.graph.files_live.isSet(record.source_index.get())) {
                    return true;
                }

                // Replace the statement with a call to "init()"
                const value: Expr = brk: {
                    const default = Expr.init(
                        E.Call,
                        E.Call{
                            .target = Expr.initIdentifier(
                                c.graph.ast.items(.wrapper_ref)[record.source_index.get()],
                                loc,
                            ),
                        },
                        loc,
                    );

                    if (other_flags.is_async_or_has_async_dependency) {
                        // This currently evaluates sibling dependencies in serial instead of in
                        // parallel, which is incorrect. This should be changed to store a promise
                        // and await all stored promises after all imports but before any code.
                        break :brk Expr.init(
                            E.Await,
                            E.Await{
                                .value = default,
                            },
                            loc,
                        );
                    }

                    break :brk default;
                };

                try stmts.inside_wrapper_prefix.append(
                    Stmt.alloc(
                        S.SExpr,
                        S.SExpr{
                            .value = value,
                        },
                        loc,
                    ),
                );
            },
        }

        return true;
    }

    /// Code we ultimately include in the bundle is potentially wrapped
    ///
    /// In that case, we do a final pass over the statements list to figure out
    /// where it needs to go in the wrapper, following the syntax of the output
    /// format ESM import and export statements to always be top-level, so they
    /// can never be inside the wrapper.
    ///
    ///      prefix - outer
    ///      ...
    ///      init_esm = () => {
    ///          prefix - inner
    ///          ...
    ///          suffix - inenr
    ///       };
    ///       ...
    ///      suffix - outer
    ///
    /// Keep in mind that we may need to wrap ES modules in some cases too
    /// Consider:
    ///   import * as foo from 'bar';
    ///   foo[computedProperty]
    ///
    /// In that case, when bundling, we still need to preserve that module
    /// namespace object (foo) because we cannot know what they are going to
    /// attempt to access statically
    ///
    fn convertStmtsForChunk(
        c: *LinkerContext,
        source_index: u32,
        stmts: *StmtList,
        part_stmts: []const js_ast.Stmt,
        chunk: *Chunk,
        allocator: std.mem.Allocator,
        wrap: WrapKind,
        ast: *const js_ast.Ast,
    ) !void {
        const shouldExtractESMStmtsForWrap = wrap != .none;
        const shouldStripExports = c.options.mode != .passthrough or c.graph.files.items(.entry_point_kind)[source_index] != .none;

        const flags = c.graph.meta.items(.flags);

        // If this file is a CommonJS entry point, double-write re-exports to the
        // external CommonJS "module.exports" object in addition to our internal ESM
        // export namespace object. The difference between these two objects is that
        // our internal one must not have the "__esModule" marker while the external
        // one must have the "__esModule" marker. This is done because an ES module
        // importing itself should not see the "__esModule" marker but a CommonJS module
        // importing us should see the "__esModule" marker.
        var module_exports_for_export: ?Expr = null;
        if (c.options.output_format == .cjs and chunk.isEntryPoint()) {
            module_exports_for_export = Expr.init(
                E.Dot,
                E.Dot{
                    .target = Expr.init(
                        E.Identifier,
                        E.Identifier{
                            .ref = c.unbound_module_ref,
                        },
                        Logger.Loc.Empty,
                    ),
                    .name = "exports",
                    .name_loc = Logger.Loc.Empty,
                },
                Logger.Loc.Empty,
            );
        }

        for (part_stmts) |stmt_| {
            var stmt = stmt_;
            proccess_stmt: {
                switch (stmt.data) {
                    .s_import => |s| {
                        // "import * as ns from 'path'"
                        // "import {foo} from 'path'"
                        if (try c.shouldRemoveImportExportStmt(
                            stmts,
                            stmt.loc,
                            s.namespace_ref,
                            s.import_record_index,
                            allocator,
                            ast,
                        )) {
                            continue;
                        }

                        // Make sure these don't end up in the wrapper closure
                        if (shouldExtractESMStmtsForWrap) {
                            try stmts.outside_wrapper_prefix.append(stmt);
                            continue;
                        }
                    },
                    .s_export_star => |s| {
                        // "export * as ns from 'path'"
                        if (s.alias) |alias| {
                            if (try c.shouldRemoveImportExportStmt(
                                stmts,
                                stmt.loc,
                                s.namespace_ref,
                                s.import_record_index,
                                allocator,
                                ast,
                            )) {
                                continue;
                            }

                            if (shouldStripExports) {
                                // Turn this statement into "import * as ns from 'path'"
                                stmt = Stmt.alloc(
                                    S.Import,
                                    S.Import{
                                        .namespace_ref = s.namespace_ref,
                                        .import_record_index = s.import_record_index,
                                        .star_name_loc = alias.loc,
                                    },
                                    stmt.loc,
                                );
                            }

                            // Make sure these don't end up in the wrapper closure
                            if (shouldExtractESMStmtsForWrap) {
                                try stmts.outside_wrapper_prefix.append(stmt);
                                continue;
                            }

                            break :proccess_stmt;
                        }

                        // "export * from 'path'"
                        if (!shouldStripExports) {
                            break :proccess_stmt;
                        }

                        const record = ast.import_records.at(s.import_record_index);

                        // Is this export star evaluated at run time?
                        if (!record.source_index.isValid() and c.options.output_format.keepES6ImportExportSyntax()) {
                            if (record.calls_runtime_re_export_fn) {
                                // Turn this statement into "import * as ns from 'path'"
                                stmt = Stmt.alloc(
                                    S.Import,
                                    S.Import{
                                        .namespace_ref = s.namespace_ref,
                                        .import_record_index = s.import_record_index,
                                        .star_name_loc = stmt.loc,
                                    },
                                    stmt.loc,
                                );

                                // Prefix this module with "__reExport(exports, ns, module.exports)"
                                const export_star_ref = c.runtimeFunction("__reExport");
                                var args = try allocator.alloc(Expr, 2 + @as(usize, @boolToInt(module_exports_for_export != null)));
                                args[0..2].* = .{
                                    Expr.init(
                                        E.Identifier,
                                        E.Identifier{
                                            .ref = ast.exports_ref,
                                        },
                                        stmt.loc,
                                    ),
                                    Expr.init(
                                        E.Identifier,
                                        E.Identifier{
                                            .ref = s.namespace_ref,
                                        },
                                        stmt.loc,
                                    ),
                                };

                                if (module_exports_for_export) |mod| {
                                    args[3] = mod;
                                }

                                try stmts.inside_wrapper_prefix.append(
                                    Stmt.alloc(
                                        S.SExpr,
                                        S.SExpr{
                                            .value = Expr.init(
                                                E.Call,
                                                E.Call{
                                                    .target = Expr.init(
                                                        E.Identifier,
                                                        E.Identifier{
                                                            .ref = export_star_ref,
                                                        },
                                                        stmt.loc,
                                                    ),
                                                    .args = bun.BabyList(Expr).init(args),
                                                },
                                                stmt.loc,
                                            ),
                                        },
                                        stmt.loc,
                                    ),
                                );

                                // Make sure these don't end up in the wrapper closure
                                if (shouldExtractESMStmtsForWrap) {
                                    try stmts.outside_wrapper_prefix.append(stmt);
                                    continue;
                                }
                            }
                        } else {
                            if (record.source_index.isValid()) {
                                const flag = flags[record.source_index.get()];
                                if (flag.wrap == .esm) {
                                    try stmts.inside_wrapper_prefix.append(
                                        Stmt.alloc(
                                            S.SExpr,
                                            .{
                                                .value = Expr.init(
                                                    E.Call,
                                                    E.Call{
                                                        .target = Expr.init(
                                                            E.Identifier,
                                                            E.Identifier{
                                                                .ref = c.graph.ast.items(.wrapper_ref)[record.source_index.get()],
                                                            },
                                                            stmt.loc,
                                                        ),
                                                    },
                                                    stmt.loc,
                                                ),
                                            },
                                            stmt.loc,
                                        ),
                                    );
                                }
                            }

                            if (record.calls_runtime_re_export_fn) {
                                const target: Expr = brk: {
                                    if (c.graph.ast.items(.exports_kind)[source_index] == .esm_with_dynamic_fallback) {
                                        // Prefix this module with "__reExport(exports, otherExports, module.exports)"
                                        break :brk Expr.initIdentifier(c.graph.ast.items(.exports_ref)[source_index], stmt.loc);
                                    }

                                    break :brk Expr.init(
                                        E.RequireString,
                                        E.RequireString{
                                            .import_record_index = s.import_record_index,
                                        },
                                        stmt.loc,
                                    );
                                };

                                // Prefix this module with "__reExport(exports, require(path), module.exports)"
                                const export_star_ref = c.runtimeFunction("__reExport");
                                var args = try allocator.alloc(Expr, 2 + @as(usize, @boolToInt(module_exports_for_export != null)));
                                args[0..2].* = .{
                                    Expr.init(
                                        E.Identifier,
                                        E.Identifier{
                                            .ref = ast.exports_ref,
                                        },
                                        stmt.loc,
                                    ),
                                    target,
                                };

                                if (module_exports_for_export) |mod| {
                                    args[3] = mod;
                                }

                                try stmts.inside_wrapper_prefix.append(
                                    Stmt.alloc(
                                        S.SExpr,
                                        S.SExpr{
                                            .value = Expr.init(
                                                E.Call,
                                                E.Call{
                                                    .target = Expr.init(
                                                        E.Identifier,
                                                        E.Identifier{
                                                            .ref = export_star_ref,
                                                        },
                                                        stmt.loc,
                                                    ),
                                                    .args = js_ast.ExprNodeList.init(args),
                                                },
                                                stmt.loc,
                                            ),
                                        },
                                        stmt.loc,
                                    ),
                                );
                            }

                            // Remove the export star statement
                            continue;
                        }
                    },

                    .s_export_from => |s| {
                        // "export {foo} from 'path'"

                        if (try c.shouldRemoveImportExportStmt(
                            stmts,
                            stmt.loc,
                            s.namespace_ref,
                            s.import_record_index,
                            allocator,
                            ast,
                        )) {
                            continue;
                        }

                        if (shouldStripExports) {
                            // Turn this statement into "import {foo} from 'path'"
                            // TODO: is this allocation necessary?
                            var items = allocator.alloc(js_ast.ClauseItem, s.items.len) catch unreachable;
                            for (s.items, items) |src, *dest| {
                                dest.* = .{
                                    .alias = src.original_name,
                                    .alias_loc = src.alias_loc,
                                    .name = src.name,
                                };
                            }

                            stmt = Stmt.alloc(
                                S.Import,
                                S.Import{
                                    .items = items,
                                    .import_record_index = s.import_record_index,
                                    .namespace_ref = s.namespace_ref,
                                    .is_single_line = s.is_single_line,
                                },
                                stmt.loc,
                            );
                        }

                        // Make sure these don't end up in the wrapper closure
                        if (shouldExtractESMStmtsForWrap) {
                            try stmts.outside_wrapper_prefix.append(stmt);
                            continue;
                        }
                    },

                    .s_export_clause => {
                        // "export {foo}"

                        if (shouldStripExports) {
                            // Remove export statements entirely

                            continue;
                        }

                        // Make sure these don't end up in the wrapper closure
                        if (shouldExtractESMStmtsForWrap) {
                            try stmts.outside_wrapper_prefix.append(stmt);
                            continue;
                        }
                    },

                    .s_function => |s| {

                        // Strip the "export" keyword while bundling
                        if (shouldStripExports and s.func.flags.contains(.is_export)) {
                            // Be c areful to not modify the original statement
                            stmt = Stmt.alloc(
                                S.Function,
                                S.Function{
                                    .func = s.func,
                                },
                                stmt.loc,
                            );
                            stmt.data.s_function.func.flags.remove(.is_export);
                        }
                    },

                    .s_class => |s| {

                        // Strip the "export" keyword while bundling
                        if (shouldStripExports and s.is_export) {
                            // Be c areful to not modify the original statement
                            stmt = Stmt.alloc(
                                S.Class,
                                S.Class{
                                    .class = s.class,
                                    .is_export = false,
                                },
                                stmt.loc,
                            );
                        }
                    },

                    .s_local => |s| {
                        // Strip the "export" keyword while bundling
                        if (shouldStripExports and s.is_export) {
                            // Be c areful to not modify the original statement
                            stmt = Stmt.alloc(
                                S.Local,
                                s.*,
                                stmt.loc,
                            );
                            stmt.data.s_local.is_export = false;
                        } else if (FeatureFlags.unwrap_commonjs_to_esm and s.was_commonjs_export and wrap == .cjs) {
                            std.debug.assert(stmt.data.s_local.decls.len == 1);
                            const decl = stmt.data.s_local.decls[0];
                            stmt = Stmt.alloc(
                                S.SExpr,
                                S.SExpr{
                                    .value = Expr.init(
                                        E.Binary,
                                        E.Binary{
                                            .op = .bin_assign,
                                            .left = Expr.init(
                                                E.CommonJSExportIdentifier,
                                                E.CommonJSExportIdentifier{
                                                    .ref = decl.binding.data.b_identifier.ref,
                                                },
                                                decl.binding.loc,
                                            ),
                                            .right = decl.value orelse Expr.init(E.Undefined, E.Undefined{}, Logger.Loc.Empty),
                                        },
                                        stmt.loc,
                                    ),
                                },
                                stmt.loc,
                            );
                        }
                    },

                    .s_export_default => |s| {
                        // "export default foo"

                        if (shouldStripExports) {
                            switch (s.value) {
                                .stmt => |stmt2| {
                                    switch (stmt2.data) {
                                        .s_expr => |s2| {
                                            // "export default foo;" => "var default = foo;"
                                            stmt = Stmt.alloc(
                                                S.Local,
                                                S.Local{
                                                    .decls = try bun.fromSlice(
                                                        []js_ast.G.Decl,
                                                        allocator,
                                                        []const js_ast.G.Decl,
                                                        &.{
                                                            .{
                                                                .binding = Binding.alloc(
                                                                    allocator,
                                                                    B.Identifier{
                                                                        .ref = s.default_name.ref.?,
                                                                    },
                                                                    s2.value.loc,
                                                                ),
                                                                .value = s2.value,
                                                            },
                                                        },
                                                    ),
                                                },
                                                stmt.loc,
                                            );
                                        },
                                        .s_function => |s2| {
                                            // "export default function() {}" => "function default() {}"
                                            // "export default function foo() {}" => "function foo() {}"

                                            // Be careful to not modify the original statement
                                            stmt = Stmt.alloc(
                                                S.Function,
                                                S.Function{
                                                    .func = s2.func,
                                                },
                                                stmt.loc,
                                            );
                                            stmt.data.s_function.func.name = s.default_name;
                                        },

                                        .s_class => |s2| {
                                            // "export default class {}" => "class default {}"
                                            // "export default class foo {}" => "class foo {}"

                                            // Be careful to not modify the original statement
                                            stmt = Stmt.alloc(
                                                S.Class,
                                                S.Class{
                                                    .class = s2.class,
                                                    .is_export = false,
                                                },
                                                stmt.loc,
                                            );
                                            stmt.data.s_class.class.class_name = s.default_name;
                                        },

                                        else => bun.unreachablePanic(
                                            "Unexpected type {any} in source file {s}",
                                            .{
                                                stmt2.data,
                                                c.parse_graph.input_files.get(c.graph.files.get(source_index).input_file.get()).source.path.text,
                                            },
                                        ),
                                    }
                                },
                                .expr => |e| {
                                    stmt = Stmt.alloc(
                                        S.Local,
                                        S.Local{
                                            .decls = try bun.fromSlice(
                                                []js_ast.G.Decl,
                                                allocator,
                                                []const js_ast.G.Decl,
                                                &.{
                                                    .{
                                                        .binding = Binding.alloc(
                                                            allocator,
                                                            B.Identifier{
                                                                .ref = s.default_name.ref.?,
                                                            },
                                                            e.loc,
                                                        ),
                                                        .value = e,
                                                    },
                                                },
                                            ),
                                        },
                                        stmt.loc,
                                    );
                                },
                            }
                        }
                    },

                    else => {},
                }
            }

            try stmts.inside_wrapper_suffix.append(stmt);
        }
    }

    fn runtimeFunction(c: *LinkerContext, name: []const u8) Ref {
        return c.graph.runtimeFunction(name);
    }

    fn generateCodeForFileInChunkJS(
        c: *LinkerContext,
        writer: *js_printer.BufferWriter,
        r: renamer.Renamer,
        chunk: *Chunk,
        part_range: PartRange,
        toCommonJSRef: Ref,
        toESMRef: Ref,
        runtimeRequireRef: Ref,
        stmts: *StmtList,
        allocator: std.mem.Allocator,
        temp_allocator: std.mem.Allocator,
    ) js_printer.PrintResult {
        // var file = &c.graph.files.items(.input_file)[part.source_index.get()];
        var parts: []js_ast.Part = c.graph.ast.items(.parts)[part_range.source_index.get()].slice()[part_range.part_index_begin..part_range.part_index_end];
        // const resolved_exports: []ResolvedExports = c.graph.meta.items(.resolved_exports);
        const all_flags: []const JSMeta.Flags = c.graph.meta.items(.flags);
        const flags = all_flags[part_range.source_index.get()];
        const wrapper_part_index = if (flags.wrap != .none)
            c.graph.meta.items(.wrapper_part_index)[part_range.source_index.get()]
        else
            Index.invalid;

        // referencing everything by array makes the code a lot more annoying :(
        const ast: js_ast.Ast = c.graph.ast.get(part_range.source_index.get());

        js_ast.Expr.Data.Store.reset();
        js_ast.Stmt.Data.Store.reset();

        var needs_wrapper = false;

        const namespace_export_part_index = js_ast.namespace_export_part_index;

        stmts.reset();

        const part_index_for_lazy_default_export: u32 = if (ast.has_lazy_export) brk: {
            if (c.graph.meta.items(.resolved_exports)[part_range.source_index.get()].get("default")) |default| {
                break :brk c.graph.topLevelSymbolToParts(part_range.source_index.get(), default.data.import_ref)[0];
            }

            break :brk std.math.maxInt(u32);
        } else std.math.maxInt(u32);

        // TODO: handle directive
        if (namespace_export_part_index >= part_range.part_index_begin and
            namespace_export_part_index < part_range.part_index_end and
            parts[namespace_export_part_index].is_live)
        {
            c.convertStmtsForChunk(
                part_range.source_index.get(),
                stmts,
                parts[namespace_export_part_index].stmts,
                chunk,
                temp_allocator,
                flags.wrap,
                &ast,
            ) catch |err| return .{
                .err = err,
            };

            switch (flags.wrap) {
                .esm => {
                    stmts.outside_wrapper_prefix.appendSlice(stmts.inside_wrapper_suffix.items) catch unreachable;
                },
                else => {
                    stmts.inside_wrapper_prefix.appendSlice(stmts.inside_wrapper_suffix.items) catch unreachable;
                },
            }
            stmts.inside_wrapper_suffix.clearRetainingCapacity();
        }

        // Add all other parts in this chunk
        for (parts, 0..) |part, index_| {
            const index = part_range.part_index_begin + @truncate(u32, index_);
            if (!part.is_live) {
                // Skip the part if it's not in this chunk
                continue;
            }

            if (index == namespace_export_part_index) {
                // Skip the namespace export part because we already handled it above
                continue;
            }

            if (index == wrapper_part_index.get()) {
                // Skip the wrapper part because we already handled it above
                needs_wrapper = true;
                continue;
            }

            var single_stmts_list = [1]Stmt{undefined};
            var part_stmts = part.stmts;

            // If this could be a JSON or TOML file that exports a top-level object literal, go
            // over the non-default top-level properties that ended up being imported
            // and substitute references to them into the main top-level object literal.
            // So this JSON file:
            //
            //   {
            //     "foo": [1, 2, 3],
            //     "bar": [4, 5, 6],
            //   }
            //
            // is initially compiled into this:
            //
            //   export var foo = [1, 2, 3];
            //   export var bar = [4, 5, 6];
            //   export default {
            //     foo: [1, 2, 3],
            //     bar: [4, 5, 6],
            //   };
            //
            // But we turn it into this if both "foo" and "default" are imported:
            //
            //   export var foo = [1, 2, 3];
            //   export default {
            //     foo,
            //     bar: [4, 5, 6],
            //   };
            //
            if (index == part_index_for_lazy_default_export) {
                std.debug.assert(index != std.math.maxInt(u32));

                const stmt = part_stmts[0];

                if (stmt.data != .s_export_default)
                    @panic("expected Lazy default export to be an export default statement");

                var default_export = stmt.data.s_export_default;
                var default_expr = default_export.value.expr;

                // Be careful: the top-level value in a JSON file is not necessarily an object
                if (default_expr.data == .e_object) {
                    var new_properties = std.ArrayList(js_ast.G.Property).initCapacity(temp_allocator, default_expr.data.e_object.properties.len) catch unreachable;
                    var resolved_exports = c.graph.meta.items(.resolved_exports)[part_range.source_index.get()];

                    // If any top-level properties ended up being imported directly, change
                    // the property to just reference the corresponding variable instead
                    for (default_expr.data.e_object.properties.slice()) |prop| {
                        if (prop.key == null or prop.key.?.data != .e_string or prop.value == null) continue;
                        const name = prop.key.?.data.e_string.slice(temp_allocator);
                        if (strings.eqlComptime(name, "default") or
                            strings.eqlComptime(name, "__esModule") or
                            !bun.js_lexer.isIdentifier(name)) continue;

                        if (resolved_exports.get(name)) |export_data| {
                            const export_ref = export_data.data.import_ref;
                            const export_part = ast.parts.slice()[c.graph.topLevelSymbolToParts(part_range.source_index.get(), export_ref)[0]];
                            if (export_part.is_live) {
                                new_properties.appendAssumeCapacity(
                                    .{
                                        .key = prop.key,
                                        .value = Expr.initIdentifier(export_ref, prop.value.?.loc),
                                    },
                                );
                            }
                        }
                    }

                    default_expr = Expr.allocate(
                        temp_allocator,
                        E.Object,
                        E.Object{
                            .properties = BabyList(G.Property).init(new_properties.items),
                        },
                        default_expr.loc,
                    );
                }

                single_stmts_list[0] = Stmt.allocate(
                    temp_allocator,
                    S.ExportDefault,
                    .{
                        .default_name = default_export.default_name,
                        .value = .{ .expr = default_expr },
                    },
                    stmt.loc,
                );
                part_stmts = single_stmts_list[0..];
            }

            c.convertStmtsForChunk(
                part_range.source_index.get(),
                stmts,
                part_stmts,
                chunk,
                temp_allocator,
                flags.wrap,
                &ast,
            ) catch |err| return .{
                .err = err,
            };
        }

        // Hoist all import statements before any normal statements. ES6 imports
        // are different than CommonJS imports. All modules imported via ES6 import
        // statements are evaluated before the module doing the importing is
        // evaluated (well, except for cyclic import scenarios). We need to preserve
        // these semantics even when modules imported via ES6 import statements end
        // up being CommonJS modules.
        stmts.all_stmts.ensureUnusedCapacity(stmts.inside_wrapper_prefix.items.len + stmts.inside_wrapper_suffix.items.len) catch unreachable;
        stmts.all_stmts.appendSliceAssumeCapacity(stmts.inside_wrapper_prefix.items);
        stmts.all_stmts.appendSliceAssumeCapacity(stmts.inside_wrapper_suffix.items);
        stmts.inside_wrapper_prefix.items.len = 0;
        stmts.inside_wrapper_suffix.items.len = 0;

        // TODO: mergeAdjacentLocalStmts

        var out_stmts: []js_ast.Stmt = stmts.all_stmts.items;

        // Optionally wrap all statements in a closure
        if (needs_wrapper) {
            switch (flags.wrap) {
                .cjs => {
                    var uses_exports_ref = ast.uses_exports_ref;

                    // Only include the arguments that are actually used
                    var args = std.ArrayList(js_ast.G.Arg).initCapacity(
                        temp_allocator,
                        if (ast.uses_module_ref or uses_exports_ref) 2 else 0,
                    ) catch unreachable;

                    if (ast.uses_module_ref or uses_exports_ref) {
                        args.appendAssumeCapacity(
                            js_ast.G.Arg{
                                .binding = js_ast.Binding.alloc(
                                    temp_allocator,
                                    js_ast.B.Identifier{
                                        .ref = ast.exports_ref,
                                    },
                                    Logger.Loc.Empty,
                                ),
                            },
                        );

                        if (ast.uses_module_ref) {
                            args.appendAssumeCapacity(
                                js_ast.G.Arg{
                                    .binding = js_ast.Binding.alloc(
                                        temp_allocator,
                                        js_ast.B.Identifier{
                                            .ref = ast.module_ref,
                                        },
                                        Logger.Loc.Empty,
                                    ),
                                },
                            );
                        }
                    }

                    // TODO: variants of the runtime functions
                    var cjs_args = temp_allocator.alloc(Expr, 1) catch unreachable;
                    cjs_args[0] = Expr.init(
                        E.Arrow,
                        E.Arrow{
                            .args = args.items,
                            .body = .{
                                .stmts = stmts.all_stmts.items,
                                .loc = Logger.Loc.Empty,
                            },
                        },
                        Logger.Loc.Empty,
                    );

                    const commonjs_wrapper_definition = Expr.init(
                        E.Call,
                        E.Call{
                            .target = Expr.init(
                                E.Identifier,
                                E.Identifier{
                                    .ref = c.cjs_runtime_ref,
                                },
                                Logger.Loc.Empty,
                            ),
                            .args = bun.BabyList(Expr).init(cjs_args),
                        },
                        Logger.Loc.Empty,
                    );

                    // "var require_foo = __commonJS(...);"
                    {
                        var decls = temp_allocator.alloc(G.Decl, 1) catch unreachable;
                        decls[0] = G.Decl{
                            .binding = Binding.alloc(
                                temp_allocator,
                                B.Identifier{
                                    .ref = ast.wrapper_ref,
                                },
                                Logger.Loc.Empty,
                            ),
                            .value = commonjs_wrapper_definition,
                        };

                        stmts.outside_wrapper_prefix.append(
                            Stmt.alloc(
                                S.Local,
                                S.Local{
                                    .decls = decls,
                                },
                                Logger.Loc.Empty,
                            ),
                        ) catch unreachable;
                    }
                },
                .esm => {
                    // The wrapper only needs to be "async" if there is a transitive async
                    // dependency. For correctness, we must not use "async" if the module
                    // isn't async because then calling "require()" on that module would
                    // swallow any exceptions thrown during module initialization.
                    const is_async = flags.is_async_or_has_async_dependency;
                    const Hoisty = struct {
                        decls: std.ArrayList(G.Decl),
                        allocator: std.mem.Allocator,

                        pub fn wrapIdentifier(w: *@This(), loc: Logger.Loc, ref: Ref) Expr {
                            w.decls.append(
                                G.Decl{
                                    .binding = Binding.alloc(
                                        w.allocator,
                                        B.Identifier{
                                            .ref = ref,
                                        },
                                        loc,
                                    ),
                                },
                            ) catch unreachable;
                            return Expr.init(
                                E.Identifier,
                                E.Identifier{
                                    .ref = ref,
                                },
                                loc,
                            );
                        }
                    };
                    var hoisty = Hoisty{
                        .decls = std.ArrayList(G.Decl).init(temp_allocator),
                        .allocator = temp_allocator,
                    };
                    var inner_stmts = stmts.all_stmts.items;
                    // Hoist all top-level "var" and "function" declarations out of the closure
                    {
                        var end: usize = 0;
                        for (stmts.all_stmts.items) |stmt_| {
                            var stmt: Stmt = stmt_;
                            switch (stmt.data) {
                                .s_local => |local| {
                                    if (local.was_commonjs_export or ast.commonjs_named_exports.count() == 0) {
                                        var value: Expr = Expr.init(E.Missing, E.Missing{}, Logger.Loc.Empty);
                                        for (local.decls) |*decl| {
                                            const binding = decl.binding.toExpr(&hoisty);
                                            if (decl.value) |other| {
                                                value = value.joinWithComma(
                                                    binding.assign(
                                                        other,
                                                        temp_allocator,
                                                    ),
                                                    temp_allocator,
                                                );
                                            }
                                        }

                                        if (value.isEmpty()) {
                                            continue;
                                        }
                                        stmt = Stmt.alloc(
                                            S.SExpr,
                                            S.SExpr{
                                                .value = value,
                                            },
                                            stmt.loc,
                                        );
                                    }
                                },
                                .s_class, .s_function => {
                                    stmts.outside_wrapper_prefix.append(stmt) catch unreachable;
                                    continue;
                                },
                                else => {},
                            }
                            inner_stmts[end] = stmt;
                            end += 1;
                        }
                        inner_stmts.len = end;
                    }

                    if (hoisty.decls.items.len > 0) {
                        stmts.outside_wrapper_prefix.append(
                            Stmt.alloc(
                                S.Local,
                                S.Local{
                                    .decls = hoisty.decls.items,
                                },
                                Logger.Loc.Empty,
                            ),
                        ) catch unreachable;
                        hoisty.decls.items.len = 0;
                    }

                    // "__esm(() => { ... })"
                    var esm_args = temp_allocator.alloc(Expr, 1) catch unreachable;
                    esm_args[0] = Expr.init(
                        E.Arrow,
                        E.Arrow{
                            .args = &.{},
                            .is_async = is_async,
                            .body = .{
                                .stmts = inner_stmts,
                                .loc = Logger.Loc.Empty,
                            },
                        },
                        Logger.Loc.Empty,
                    );

                    // "var init_foo = __esm(...);"
                    {
                        const value = Expr.init(
                            E.Call,
                            E.Call{
                                .target = Expr.init(
                                    E.Identifier,
                                    E.Identifier{
                                        .ref = c.esm_runtime_ref,
                                    },
                                    Logger.Loc.Empty,
                                ),
                                .args = bun.BabyList(Expr).init(esm_args),
                            },
                            Logger.Loc.Empty,
                        );

                        var decls = temp_allocator.alloc(G.Decl, 1) catch unreachable;
                        decls[0] = G.Decl{
                            .binding = Binding.alloc(
                                temp_allocator,
                                B.Identifier{
                                    .ref = ast.wrapper_ref,
                                },
                                Logger.Loc.Empty,
                            ),
                            .value = value,
                        };

                        stmts.outside_wrapper_prefix.append(
                            Stmt.alloc(
                                S.Local,
                                S.Local{
                                    .decls = decls,
                                },
                                Logger.Loc.Empty,
                            ),
                        ) catch unreachable;
                    }
                },
                else => {},
            }

            out_stmts = stmts.outside_wrapper_prefix.items;
        }

        if (out_stmts.len == 0) {
            return .{
                .result = .{
                    .code = &[_]u8{},
                    .source_map = null,
                },
            };
        }

        const parts_to_print = &[_]js_ast.Part{
            js_ast.Part{
                // .tag = .stmts,
                .stmts = out_stmts,
            },
        };

        const print_options = js_printer.Options{
            // TODO: IIFE
            .indent = 0,

            .commonjs_named_exports = ast.commonjs_named_exports,
            .commonjs_named_exports_ref = ast.exports_ref,
            .commonjs_named_exports_deoptimized = flags.wrap == .cjs,
            .const_values = c.graph.const_values,

            .allocator = allocator,
            .to_esm_ref = toESMRef,
            .to_commonjs_ref = toCommonJSRef,
            .require_ref = runtimeRequireRef,
            .require_or_import_meta_for_source_callback = js_printer.RequireOrImportMeta.Callback.init(
                LinkerContext,
                requireOrImportMetaForSource,
                c,
            ),
        };

        writer.buffer.reset();
        var printer = js_printer.BufferPrinter.init(
            writer.*,
        );
        defer writer.* = printer.ctx;

        return js_printer.printWithWriter(
            *js_printer.BufferPrinter,
            &printer,
            ast.platform,
            print_options,
            ast.import_records.slice(),
            parts_to_print,
            r,
        );
    }

    fn requireOrImportMetaForSource(
        c: *LinkerContext,
        source_index: Index.Int,
    ) js_printer.RequireOrImportMeta {
        const flags = c.graph.meta.items(.flags)[source_index];
        return .{
            .exports_ref = if (flags.wrap == .esm)
                c.graph.ast.items(.exports_ref)[source_index]
            else
                Ref.None,
            .is_wrapper_async = flags.is_async_or_has_async_dependency,
            .wrapper_ref = c.graph.ast.items(.wrapper_ref)[source_index],
        };
    }

    pub fn generateChunksInParallel(c: *LinkerContext, chunks: []Chunk) !std.ArrayList(options.OutputFile) {
        {
            debug("START Generating {d} chunks in parallel", .{chunks.len});
            defer debug(" DONE Generating {d} chunks in parallel", .{chunks.len});
            var wait_group = try c.allocator.create(sync.WaitGroup);
            wait_group.init();
            defer {
                wait_group.deinit();
                c.allocator.destroy(wait_group);
            }
            wait_group.counter = @truncate(u32, chunks.len);
            var ctx = GenerateChunkCtx{ .wg = wait_group, .c = c, .chunks = chunks };
            try c.parse_graph.pool.pool.doPtr(c.allocator, wait_group, ctx, generateChunkJS, chunks);
        }

        // TODO: enforceNoCyclicChunkImports()
        {

            // Compute the final hashes of each chunk. This can technically be done in
            // parallel but it probably doesn't matter so much because we're not hashing
            // that much data.
            for (chunks) |*chunk| {
                // TODO: non-isolated-hash
                chunk.template.placeholder.hash = chunk.isolated_hash;

                chunk.final_rel_path = std.fmt.allocPrint(c.allocator, "{any}", .{chunk.template}) catch unreachable;
            }
        }

        var react_client_components_manifest: []u8 = if (c.resolver.opts.react_server_components) brk: {
            var bytes = std.ArrayList(u8).init(c.allocator);
            defer bytes.deinit();
            var all_sources = c.parse_graph.input_files.items(.source);
            var all_named_exports = c.graph.ast.items(.named_exports);
            var export_names = std.ArrayList(Api.StringPointer).init(c.allocator);
            defer export_names.deinit();

            var client_modules = std.ArrayList(Api.ClientServerModule).initCapacity(c.allocator, c.graph.react_client_component_boundary.count()) catch unreachable;
            defer client_modules.deinit();
            var server_modules = std.ArrayList(Api.ClientServerModule).initCapacity(c.allocator, c.graph.react_server_component_boundary.count()) catch unreachable;
            defer server_modules.deinit();

            var react_client_components_iterator = c.graph.react_client_component_boundary.iterator(.{});
            var react_server_components_iterator = c.graph.react_server_component_boundary.iterator(.{});

            var sorted_client_component_ids = std.ArrayList(u32).initCapacity(c.allocator, client_modules.capacity) catch unreachable;
            defer sorted_client_component_ids.deinit();
            while (react_client_components_iterator.next()) |source_index| {
                if (!c.graph.files_live.isSet(source_index)) continue;
                sorted_client_component_ids.appendAssumeCapacity(@intCast(u32, source_index));
            }

            var sorted_server_component_ids = std.ArrayList(u32).initCapacity(c.allocator, server_modules.capacity) catch unreachable;
            defer sorted_server_component_ids.deinit();
            while (react_server_components_iterator.next()) |source_index| {
                if (!c.graph.files_live.isSet(source_index)) continue;
                sorted_server_component_ids.appendAssumeCapacity(@intCast(u32, source_index));
            }

            const Sorter = struct {
                sources: []const Logger.Source,
                pub fn isLessThan(ctx: @This(), a_index: u32, b_index: u32) bool {
                    const a = ctx.sources[a_index].path.text;
                    const b = ctx.sources[b_index].path.text;
                    return strings.order(a, b) == .lt;
                }
            };
            std.sort.sort(u32, sorted_client_component_ids.items, Sorter{ .sources = all_sources }, Sorter.isLessThan);
            std.sort.sort(u32, sorted_server_component_ids.items, Sorter{ .sources = all_sources }, Sorter.isLessThan);

            inline for (.{
                sorted_client_component_ids.items,
                sorted_server_component_ids.items,
            }, .{
                &client_modules,
                &server_modules,
            }) |sorted_component_ids, modules| {
                for (sorted_component_ids) |source_index| {
                    const named_exports = all_named_exports[source_index].keys();
                    const exports_len = @intCast(u32, named_exports.len);
                    const exports_start = @intCast(u32, export_names.items.len);

                    var grow_length: usize = 0;
                    try export_names.ensureUnusedCapacity(named_exports.len);

                    var chunk: *Chunk = brk2: {
                        for (chunks) |*chunk_| {
                            if (chunk_.entry_point.source_index == @intCast(u32, source_index)) {
                                break :brk2 chunk_;
                            }
                        }

                        @panic("Assertion failure: missing chunk for react client component");
                    };

                    grow_length += chunk.final_rel_path.len;

                    grow_length += all_sources[source_index].path.pretty.len;

                    for (named_exports) |export_name| {
                        try export_names.append(Api.StringPointer{
                            .offset = @intCast(u32, bytes.items.len + grow_length),
                            .length = @intCast(u32, export_name.len),
                        });
                        grow_length += export_name.len;
                    }

                    try bytes.ensureUnusedCapacity(grow_length);

                    const input_name = Api.StringPointer{
                        .offset = @intCast(u32, bytes.items.len),
                        .length = @intCast(u32, all_sources[source_index].path.pretty.len),
                    };

                    bytes.appendSliceAssumeCapacity(all_sources[source_index].path.pretty);

                    const asset_name = Api.StringPointer{
                        .offset = @intCast(u32, bytes.items.len),
                        .length = @intCast(u32, chunk.final_rel_path.len),
                    };

                    bytes.appendSliceAssumeCapacity(chunk.final_rel_path);

                    for (named_exports) |export_name| {
                        bytes.appendSliceAssumeCapacity(export_name);
                    }

                    modules.appendAssumeCapacity(.{
                        .module_id = bun.hash32(all_sources[source_index].path.pretty),
                        .asset_name = asset_name,
                        .input_name = input_name,
                        .export_names = .{
                            .length = exports_len,
                            .offset = exports_start,
                        },
                    });
                }
            }

            if (client_modules.items.len == 0 and server_modules.items.len == 0) break :brk &.{};

            var manifest = Api.ClientServerModuleManifest{
                .version = 2,
                .client_modules = client_modules.items,

                // TODO:
                .ssr_modules = client_modules.items,

                .server_modules = server_modules.items,
                .export_names = export_names.items,
                .contents = bytes.items,
            };
            var byte_buffer = std.ArrayList(u8).initCapacity(c.allocator, bytes.items.len) catch unreachable;
            var byte_buffer_writer = byte_buffer.writer();
            const SchemaWriter = schema.Writer(@TypeOf(&byte_buffer_writer));
            var writer = SchemaWriter.init(&byte_buffer_writer);
            manifest.encode(&writer) catch unreachable;
            break :brk byte_buffer.items;
        } else &.{};

        // Generate the final output files by joining file pieces together
        var output_files = std.ArrayList(options.OutputFile).initCapacity(c.allocator, chunks.len + @as(
            usize,
            @boolToInt(react_client_components_manifest.len > 0),
        )) catch unreachable;
        output_files.items.len = chunks.len;
        for (chunks, output_files.items) |*chunk, *output_file| {
            output_file.* = options.OutputFile.initBuf(
                chunk.intermediate_output.code(c.allocator, chunk, chunks) catch @panic("Failed to allocate memory for output file"),
                chunk.final_rel_path,
                // TODO: remove this field
                .js,
            );
        }

        if (react_client_components_manifest.len > 0) {
            output_files.appendAssumeCapacity(options.OutputFile.initBuf(
                react_client_components_manifest,
                "./components-manifest.blob",
                .file,
            ));
        }

        return output_files;
    }

    // Sort cross-chunk exports by chunk name for determinism
    fn sortedCrossChunkExportItems(
        c: *LinkerContext,
        export_refs: ChunkMeta.Map,
        list: *std.ArrayList(StableRef),
    ) void {
        var result = list.*;
        defer list.* = result;
        result.clearRetainingCapacity();
        result.ensureTotalCapacity(export_refs.count()) catch unreachable;
        result.items.len = export_refs.count();
        for (export_refs.keys(), result.items) |export_ref, *item| {
            if (comptime Environment.allow_assert)
                debugTreeShake("Export name: {s} (in {s})", .{
                    c.graph.symbols.get(export_ref).?.original_name,
                    c.parse_graph.input_files.get(export_ref.sourceIndex()).source.path.text,
                });
            item.* = .{
                .stable_source_index = c.graph.stable_source_indices[export_ref.sourceIndex()],
                .ref = export_ref,
            };
        }
        std.sort.sort(StableRef, result.items, {}, StableRef.isLessThan);
    }

    pub fn markFileReachableForCodeSplitting(
        c: *LinkerContext,
        source_index: Index.Int,
        entry_points_count: usize,
        distances: []u32,
        distance: u32,
        parts: []bun.BabyList(js_ast.Part),
        import_records: []bun.BabyList(bun.ImportRecord),
        file_entry_bits: []AutoBitSet,
    ) void {
        if (!c.graph.files_live.isSet(source_index))
            return;

        const cur_dist = distances[source_index];
        const traverse_again = distance < cur_dist;
        if (traverse_again) {
            distances[source_index] = distance;
        }
        const out_dist = distance + 1;

        var bits = &file_entry_bits[source_index];

        // Don't mark this file more than once
        if (bits.isSet(entry_points_count) and !traverse_again)
            return;

        bits.set(entry_points_count);

        if (comptime bun.Environment.allow_assert)
            debugTreeShake(
                "markFileReachableForCodeSplitting(entry: {d}): {s} ({d})",
                .{
                    entry_points_count,
                    c.parse_graph.input_files.get(source_index).source.path.text,
                    out_dist,
                },
            );

        // TODO: CSS AST
        var imports_a_boundary = false;
        const use_directive = c.graph.useDirectiveBoundary(source_index);

        for (import_records[source_index].slice()) |*record| {
            const is_boundary = use_directive.isBoundary(record.tag.useDirective());
            imports_a_boundary = use_directive != .none and (imports_a_boundary or is_boundary);
            if (record.source_index.isValid() and !is_boundary and !c.isExternalDynamicImport(record, source_index)) {
                c.markFileReachableForCodeSplitting(
                    record.source_index.get(),
                    entry_points_count,
                    distances,
                    out_dist,
                    parts,
                    import_records,
                    file_entry_bits,
                );
            }
        }

        const parts_in_file = parts[source_index].slice();
        for (parts_in_file) |part| {
            for (part.dependencies.slice()) |dependency| {
                if (dependency.source_index.get() != source_index) {
                    if (imports_a_boundary and
                        // "use client" -> "use server" imports don't
                        use_directive.isBoundary(c.graph.files.items(.entry_point_kind)[dependency.source_index.get()]
                        .useDirective()))
                        continue;

                    c.markFileReachableForCodeSplitting(
                        dependency.source_index.get(),
                        entry_points_count,
                        distances,
                        out_dist,
                        parts,
                        import_records,
                        file_entry_bits,
                    );
                }
            }
        }
    }

    pub fn markFileLiveForTreeShaking(
        c: *LinkerContext,
        source_index: Index.Int,
        side_effects: []_resolver.SideEffects,
        parts: []bun.BabyList(js_ast.Part),
        import_records: []bun.BabyList(bun.ImportRecord),
        entry_point_kinds: []EntryPoint.Kind,
    ) void {
        if (comptime bun.Environment.allow_assert)
            debugTreeShake(
                "markFileLiveForTreeShaking({d}, {s}) = {s}",
                .{
                    source_index,
                    c.parse_graph.input_files.get(source_index).source.path.text,
                    if (c.graph.files_live.isSet(source_index)) "seen" else "not seen",
                },
            );

        if (c.graph.files_live.isSet(source_index))
            return;

        c.graph.files_live.set(source_index);

        // TODO: CSS source index

        const id = source_index;
        if (@as(usize, id) >= c.graph.ast.len)
            return;
        var _parts = parts[id].slice();
        for (_parts, 0..) |part, part_index| {
            var can_be_removed_if_unused = part.can_be_removed_if_unused;

            if (can_be_removed_if_unused and part.tag == .commonjs_named_export) {
                if (c.graph.meta.items(.flags)[id].wrap == .cjs) {
                    can_be_removed_if_unused = false;
                }
            }

            // Also include any statement-level imports
            for (part.import_record_indices.slice()) |import_record_Index| {
                var record: *ImportRecord = &import_records[source_index].slice()[import_record_Index];

                if (record.kind != .stmt)
                    continue;

                if (record.source_index.isValid()) {
                    const other_source_index = record.source_index.get();

                    // Don't include this module for its side effects if it can be
                    // considered to have no side effects
                    if (side_effects[other_source_index] != .has_side_effects and !c.options.ignore_dce_annotations) {
                        continue;
                    }

                    // Otherwise, include this module for its side effects
                    c.markFileLiveForTreeShaking(
                        other_source_index,
                        side_effects,
                        parts,
                        import_records,
                        entry_point_kinds,
                    );
                } else if (record.is_external_without_side_effects) {
                    // This can be removed if it's unused
                    continue;
                }

                // If we get here then the import was included for its side effects, so
                // we must also keep this part
                can_be_removed_if_unused = false;
            }

            // Include all parts in this file with side effects, or just include
            // everything if tree-shaking is disabled. Note that we still want to
            // perform tree-shaking on the runtime even if tree-shaking is disabled.
            if (!can_be_removed_if_unused or
                (!part.force_tree_shaking and
                !c.options.tree_shaking and
                entry_point_kinds[id].isEntryPoint()))
            {
                _ = c.markPartLiveForTreeShaking(
                    @intCast(u32, part_index),
                    id,
                    side_effects,
                    parts,
                    import_records,
                    entry_point_kinds,
                );
            }
        }
    }

    pub fn markPartLiveForTreeShaking(
        c: *LinkerContext,
        part_index: Index.Int,
        id: Index.Int,
        side_effects: []_resolver.SideEffects,
        parts: []bun.BabyList(js_ast.Part),
        import_records: []bun.BabyList(bun.ImportRecord),
        entry_point_kinds: []EntryPoint.Kind,
    ) bool {
        var part: *js_ast.Part = &parts[id].slice()[part_index];
        // only once
        if (part.is_live) {
            return false;
        }

        part.is_live = true;
        if (comptime bun.Environment.allow_assert)
            debugTreeShake("markPartLiveForTreeShaking({d}): {s}:{d} = {d}, {s}", .{
                id,
                c.parse_graph.input_files.get(id).source.path.text,
                part_index,
                if (part.stmts.len > 0) part.stmts[0].loc.start else Logger.Loc.Empty.start,
                if (part.stmts.len > 0) @tagName(part.stmts[0].data) else @tagName(Stmt.empty().data),
            });

        // Include the file containing this part
        c.markFileLiveForTreeShaking(
            id,
            side_effects,
            parts,
            import_records,
            entry_point_kinds,
        );

        for (part.dependencies.slice()) |dependency| {
            _ = c.markPartLiveForTreeShaking(
                dependency.part_index,
                dependency.source_index.get(),
                side_effects,
                parts,
                import_records,
                entry_point_kinds,
            );
        }

        return true;
    }

    pub fn matchImportWithExport(
        c: *LinkerContext,
        init_tracker: *ImportTracker,
        re_exports: *std.ArrayList(js_ast.Dependency),
        to_mark_as_esm_with_dynamic_fallback: *std.AutoArrayHashMap(u32, void),
    ) MatchImport {
        var tracker = init_tracker;
        var ambiguous_results = std.ArrayList(MatchImport).init(c.allocator);
        defer ambiguous_results.clearAndFree();
        var result: MatchImport = MatchImport{};
        const named_imports = c.graph.ast.items(.named_imports);

        loop: while (true) {
            // Make sure we avoid infinite loops trying to resolve cycles:
            //
            //   // foo.js
            //   export {a as b} from './foo.js'
            //   export {b as c} from './foo.js'
            //   export {c as a} from './foo.js'
            //
            // This uses a O(n^2) array scan instead of a O(n) map because the vast
            // majority of cases have one or two elements
            for (c.cycle_detector.items) |prev_tracker| {
                if (std.meta.eql(tracker.*, prev_tracker)) {
                    result = .{ .kind = .cycle };
                    break :loop;
                }
            }

            const prev_import_ref = tracker.import_ref;

            if (tracker.source_index.isInvalid()) {
                // External
                break;
            }

            const prev_source_index = tracker.source_index.get();
            c.cycle_detector.append(tracker.*) catch unreachable;

            // Resolve the import by one step
            var advanced = c.advanceImportTracker(tracker);
            advanced.tracker.* = advanced.value;
            const next_tracker = advanced.tracker.*;
            const status = advanced.status;
            const potentially_ambiguous_export_star_refs = advanced.import_data;
            const other_id = advanced.value.source_index.get();

            switch (status) {
                .cjs, .cjs_without_exports, .disabled, .external => {
                    if (status == .external and c.options.output_format.keepES6ImportExportSyntax()) {
                        // Imports from external modules should not be converted to CommonJS
                        // if the output format preserves the original ES6 import statements
                        break;
                    }

                    // If it's a CommonJS or external file, rewrite the import to a
                    // property access. Don't do this if the namespace reference is invalid
                    // though. This is the case for star imports, where the import is the
                    // namespace.
                    const named_import: js_ast.NamedImport = named_imports[prev_source_index].get(prev_import_ref).?;

                    if (named_import.namespace_ref != null and named_import.namespace_ref.?.isValid()) {
                        if (result.kind == .normal) {
                            result.kind = .normal_and_namespace;
                            result.namespace_ref = named_import.namespace_ref.?;
                            result.alias = named_import.alias.?;
                        } else {
                            result = .{
                                .kind = .namespace,
                                .namespace_ref = named_import.namespace_ref.?,
                                .alias = named_import.alias.?,
                            };
                        }
                    }

                    // Warn about importing from a file that is known to not have any exports
                    if (status == .cjs_without_exports) {
                        const source = c.source_(tracker.source_index.get());
                        c.log.addRangeWarningFmt(
                            source,
                            source.rangeOfIdentifier(named_import.alias_loc.?),
                            c.allocator,
                            "Import \"{s}\" will always be undefined because the file \"{s}\" has no exports",
                            .{
                                named_import.alias.?,
                                source.path.pretty,
                            },
                        ) catch unreachable;
                    }
                },

                .dynamic_fallback_interop_default => {
                    const named_import: js_ast.NamedImport = named_imports[prev_source_index].get(prev_import_ref).?;
                    to_mark_as_esm_with_dynamic_fallback.put(other_id, {}) catch unreachable;
                    if (named_import.namespace_ref != null and named_import.namespace_ref.?.isValid()) {

                        // If the file was rewritten to ESM from CJS, the "default" export should alias to the namespace export.
                        if (strings.eqlComptime(named_import.alias orelse "", "default")) {
                            result.kind = .normal;
                            result.ref = c.graph.ast.items(.exports_ref)[other_id];
                            result.name_loc = named_import.alias_loc orelse Logger.Loc.Empty;
                        } else {
                            result.kind = .normal_and_namespace;
                            result.namespace_ref = c.graph.ast.items(.exports_ref)[other_id];
                            result.alias = named_import.alias.?;
                            result.name_loc = named_import.alias_loc orelse Logger.Loc.Empty;
                        }
                    }
                },

                .dynamic_fallback => {
                    // If it's a file with dynamic export fallback, rewrite the import to a property access
                    const named_import: js_ast.NamedImport = named_imports[prev_source_index].get(prev_import_ref).?;
                    if (named_import.namespace_ref != null and named_import.namespace_ref.?.isValid()) {
                        if (result.kind == .normal) {
                            result.kind = .normal_and_namespace;
                            result.namespace_ref = named_import.namespace_ref.?;
                            result.alias = named_import.alias.?;
                        } else {
                            result = .{
                                .kind = .namespace,
                                .namespace_ref = named_import.namespace_ref.?,
                                .alias = named_import.alias.?,
                            };
                        }
                    }
                },
                .no_match => {
                    // Report mismatched imports and exports
                    const symbol = c.graph.symbols.get(prev_import_ref).?;
                    const named_import: js_ast.NamedImport = named_imports[prev_source_index].get(prev_import_ref).?;
                    const source = c.source_(prev_source_index);

                    const next_source = c.source_(next_tracker.source_index.get());
                    const r = source.rangeOfIdentifier(named_import.alias_loc.?);

                    // Report mismatched imports and exports
                    if (symbol.import_item_status == .generated) {
                        // This is a debug message instead of an error because although it
                        // appears to be a named import, it's actually an automatically-
                        // generated named import that was originally a property access on an
                        // import star namespace object. Normally this property access would
                        // just resolve to undefined at run-time instead of failing at binding-
                        // time, so we emit a debug message and rewrite the value to the literal
                        // "undefined" instead of emitting an error.
                        symbol.import_item_status = .missing;
                        c.log.addRangeWarningFmt(
                            source,
                            r,
                            c.allocator,
                            "Import \"{s}\" will always be undefined because there is no matching export in \"{s}\"",
                            .{
                                named_import.alias.?,
                                next_source.path.pretty,
                            },
                        ) catch unreachable;
                    } else {
                        if (!strings.eql(symbol.original_name, named_import.alias.?)) {
                            c.log.addRangeErrorFmt(
                                source,
                                r,
                                c.allocator,
                                "No matching export \"{s}\" in \"{s}\" for import \"{s}\"",
                                .{
                                    symbol.original_name,
                                    next_source.path.pretty,
                                    named_import.alias.?,
                                },
                            ) catch unreachable;
                        } else {
                            c.log.addRangeErrorFmt(
                                source,
                                r,
                                c.allocator,
                                "No matching export in \"{s}\" for import \"{s}\"",
                                .{
                                    next_source.path.pretty,
                                    named_import.alias.?,
                                },
                            ) catch unreachable;
                        }
                    }
                },
                .probably_typescript_type => {
                    // Omit this import from any namespace export code we generate for
                    // import star statements (i.e. "import * as ns from 'path'")
                    result = .{ .kind = .probably_typescript_type };
                },
                .found => {

                    // If there are multiple ambiguous results due to use of "export * from"
                    // statements, trace them all to see if they point to different things.
                    for (potentially_ambiguous_export_star_refs) |*ambiguous_tracker| {
                        // If this is a re-export of another import, follow the import
                        if (named_imports[ambiguous_tracker.data.source_index.get()].contains(ambiguous_tracker.data.import_ref)) {
                            c.cycle_detector.clearRetainingCapacity();
                            c.swap_cycle_detector.clearRetainingCapacity();

                            var old_cycle_detector = c.cycle_detector;
                            c.cycle_detector = c.swap_cycle_detector;
                            var ambig = c.matchImportWithExport(&ambiguous_tracker.data, re_exports, to_mark_as_esm_with_dynamic_fallback);
                            c.cycle_detector.clearRetainingCapacity();
                            c.swap_cycle_detector = c.cycle_detector;
                            c.cycle_detector = old_cycle_detector;
                            ambiguous_results.append(ambig) catch unreachable;
                        } else {
                            ambiguous_results.append(.{
                                .kind = .normal,
                                .source_index = ambiguous_tracker.data.source_index.get(),
                                .ref = ambiguous_tracker.data.import_ref,
                                .name_loc = ambiguous_tracker.data.name_loc,
                            }) catch unreachable;
                        }
                    }

                    // Defer the actual binding of this import until after we generate
                    // namespace export code for all files. This has to be done for all
                    // import-to-export matches, not just the initial import to the final
                    // export, since all imports and re-exports must be merged together
                    // for correctness.
                    result = .{
                        .kind = .normal,
                        .source_index = next_tracker.source_index.get(),
                        .ref = next_tracker.import_ref,
                        .name_loc = next_tracker.name_loc,
                    };

                    // Depend on the statement(s) that declared this import symbol in the
                    // original file
                    {
                        var deps = c.topLevelSymbolsToParts(other_id, tracker.import_ref);
                        re_exports.ensureUnusedCapacity(deps.len) catch unreachable;
                        for (deps) |dep| {
                            re_exports.appendAssumeCapacity(
                                .{
                                    .part_index = dep,
                                    .source_index = tracker.source_index,
                                },
                            );
                        }
                    }

                    // If this is a re-export of another import, continue for another
                    // iteration of the loop to resolve that import as well
                    const next_id = next_tracker.source_index.get();
                    if (named_imports[next_id].contains(next_tracker.import_ref)) {
                        tracker.* = next_tracker;
                        continue :loop;
                    }
                },
            }

            break :loop;
        }

        // If there is a potential ambiguity, all results must be the same
        for (ambiguous_results.items) |ambig| {
            if (!std.meta.eql(ambig, result)) {
                if (result.kind == ambig.kind and
                    ambig.kind == .normal and
                    ambig.name_loc.start != 0 and
                    result.name_loc.start != 0)
                {
                    return .{
                        .kind = .ambiguous,
                        .source_index = result.source_index,
                        .name_loc = result.name_loc,
                        .other_source_index = ambig.source_index,
                        .other_name_loc = ambig.name_loc,
                    };
                }

                return .{ .kind = .ambiguous };
            }
        }

        return result;
    }

    pub fn topLevelSymbolsToParts(c: *LinkerContext, id: u32, ref: Ref) []u32 {
        return c.graph.topLevelSymbolToParts(id, ref);
    }

    pub fn topLevelSymbolsToPartsForRuntime(c: *LinkerContext, ref: Ref) []u32 {
        return topLevelSymbolsToParts(c, Index.runtime.get(), ref);
    }

    pub fn createWrapperForFile(
        c: *LinkerContext,
        wrap: WrapKind,
        wrapper_ref: Ref,
        wrapper_part_index: *Index,
        source_index: Index.Int,
    ) void {
        switch (wrap) {
            // If this is a CommonJS file, we're going to need to generate a wrapper
            // for the CommonJS closure. That will end up looking something like this:
            //
            //   var require_foo = __commonJS((exports, module) => {
            //     ...
            //   });
            //
            // However, that generation is special-cased for various reasons and is
            // done later on. Still, we're going to need to ensure that this file
            // both depends on the "__commonJS" symbol and declares the "require_foo"
            // symbol. Instead of special-casing this during the reachablity analysis
            // below, we just append a dummy part to the end of the file with these
            // dependencies and let the general-purpose reachablity analysis take care
            // of it.
            .cjs => {
                const common_js_parts = c.topLevelSymbolsToPartsForRuntime(c.cjs_runtime_ref);

                var total_dependencies_count = common_js_parts.len;
                var runtime_parts = c.graph.ast.items(.parts)[Index.runtime.get()].slice();

                for (common_js_parts) |part_id| {
                    var part: *js_ast.Part = &runtime_parts[part_id];
                    var symbol_refs = part.symbol_uses.keys();
                    for (symbol_refs) |ref| {
                        if (ref.eql(c.cjs_runtime_ref)) continue;
                        total_dependencies_count += c.topLevelSymbolsToPartsForRuntime(ref).len;
                    }
                }

                // generate a dummy part that depends on the "__commonJS" symbol
                var dependencies = c.allocator.alloc(js_ast.Dependency, common_js_parts.len) catch unreachable;
                for (common_js_parts, dependencies) |part, *cjs| {
                    cjs.* = .{
                        .part_index = part,
                        .source_index = Index.runtime,
                    };
                }
                const part_index = c.graph.addPartToFile(
                    source_index,
                    .{
                        .stmts = &.{},
                        .symbol_uses = bun.from(
                            js_ast.Part.SymbolUseMap,
                            c.allocator,
                            .{
                                .{ wrapper_ref, .{ .count_estimate = 1 } },
                            },
                        ) catch unreachable,
                        .declared_symbols = js_ast.DeclaredSymbol.List.fromSlice(
                            c.allocator,
                            &[_]js_ast.DeclaredSymbol{
                                .{ .ref = c.graph.ast.items(.exports_ref)[source_index], .is_top_level = true },
                                .{ .ref = c.graph.ast.items(.module_ref)[source_index], .is_top_level = true },
                                .{ .ref = c.graph.ast.items(.wrapper_ref)[source_index], .is_top_level = true },
                            },
                        ) catch unreachable,
                        .dependencies = Dependency.List.init(dependencies),
                    },
                ) catch unreachable;
                std.debug.assert(part_index != js_ast.namespace_export_part_index);
                wrapper_part_index.* = Index.part(part_index);
                c.graph.generateSymbolImportAndUse(
                    source_index,
                    part_index,
                    c.cjs_runtime_ref,
                    1,
                    Index.runtime,
                ) catch unreachable;
            },

            .esm => {
                // If this is a lazily-initialized ESM file, we're going to need to
                // generate a wrapper for the ESM closure. That will end up looking
                // something like this:
                //
                //   var init_foo = __esm(() => {
                //     ...
                //   });
                //
                // This depends on the "__esm" symbol and declares the "init_foo" symbol
                // for similar reasons to the CommonJS closure above.
                const esm_parts = c.topLevelSymbolsToPartsForRuntime(c.esm_runtime_ref);

                // generate a dummy part that depends on the "__esm" symbol
                var dependencies = c.allocator.alloc(js_ast.Dependency, esm_parts.len) catch unreachable;
                for (esm_parts, dependencies) |part, *esm| {
                    esm.* = .{
                        .part_index = part,
                        .source_index = Index.runtime,
                    };
                }

                const part_index = c.graph.addPartToFile(
                    source_index,
                    .{
                        .symbol_uses = bun.from(
                            js_ast.Part.SymbolUseMap,
                            c.allocator,
                            .{
                                .{ wrapper_ref, .{ .count_estimate = 1 } },
                            },
                        ) catch unreachable,
                        .declared_symbols = js_ast.DeclaredSymbol.List.fromSlice(c.allocator, &[_]js_ast.DeclaredSymbol{
                            .{ .ref = wrapper_ref, .is_top_level = true },
                        }) catch unreachable,
                        .dependencies = Dependency.List.init(dependencies),
                    },
                ) catch unreachable;
                std.debug.assert(part_index != js_ast.namespace_export_part_index);
                wrapper_part_index.* = Index.part(part_index);
                c.graph.generateSymbolImportAndUse(
                    source_index,
                    part_index,
                    c.esm_runtime_ref,
                    1,
                    Index.runtime,
                ) catch unreachable;
            },
            else => {},
        }
    }

    pub fn advanceImportTracker(c: *LinkerContext, tracker: *ImportTracker) ImportTracker.Iterator {
        const id = tracker.source_index.get();
        var named_imports: *JSAst.NamedImports = &c.graph.ast.items(.named_imports)[id];
        var import_records = c.graph.ast.items(.import_records)[id];
        const exports_kind: []js_ast.ExportsKind = c.graph.ast.items(.exports_kind);

        const named_import: js_ast.NamedImport = named_imports.get(tracker.import_ref) orelse
            // TODO: investigate if this is a bug
            // It implies there are imports being added without being resolved
            return .{
            .value = .{},
            .status = .external,
            .tracker = tracker,
        };

        // Is this an external file?
        const record: *const ImportRecord = import_records.at(named_import.import_record_index);
        if (!record.source_index.isValid()) {
            return .{
                .value = .{},
                .status = .external,
                .tracker = tracker,
            };
        }

        // Is this a disabled file?
        const other_source_index = record.source_index.get();
        const other_id = other_source_index;

        if (other_id > c.graph.ast.len or c.parse_graph.input_files.items(.source)[other_source_index].key_path.is_disabled) {
            return .{
                .value = .{
                    .source_index = record.source_index,
                },
                .status = .disabled,
                .tracker = tracker,
            };
        }

        // Is this a named import of a file without any exports?
        if (!named_import.alias_is_star and
            !c.parse_graph.ast.items(.has_lazy_export)[other_id] and

            // CommonJS exports
            c.graph.ast.items(.export_keyword)[other_id].len == 0 and !strings.eqlComptime(named_import.alias orelse "", "default") and
            // ESM exports
            !c.graph.ast.items(.uses_exports_ref)[other_id] and !c.graph.ast.items(.uses_module_ref)[other_id])
        {
            // Just warn about it and replace the import with "undefined"
            return .{
                .value = .{
                    .source_index = Index.source(other_source_index),
                    .import_ref = Ref.None,
                },
                .status = .cjs_without_exports,
                .tracker = tracker,
            };
        }
        const other_kind = exports_kind[other_id];
        // Is this a CommonJS file?
        if (other_kind == .cjs) {
            return .{
                .value = .{
                    .source_index = Index.source(other_source_index),
                    .import_ref = Ref.None,
                },
                .status = .cjs,
                .tracker = tracker,
            };
        }

        // Match this import star with an export star from the imported file
        if (named_import.alias_is_star) {
            const matching_export = c.graph.meta.items(.resolved_export_star)[other_id];
            if (matching_export.data.import_ref.isValid()) {
                // Check to see if this is a re-export of another import
                return .{
                    .value = matching_export.data,
                    .status = .found,
                    .import_data = matching_export.potentially_ambiguous_export_star_refs.slice(),
                    .tracker = tracker,
                };
            }
        }

        // Match this import up with an export from the imported file
        if (c.graph.meta.items(.resolved_exports)[other_id].get(named_import.alias.?)) |matching_export| {
            // Check to see if this is a re-export of another import
            return .{
                .value = .{
                    .source_index = matching_export.data.source_index,
                    .import_ref = matching_export.data.import_ref,
                    .name_loc = matching_export.data.name_loc,
                },
                .status = .found,
                .import_data = matching_export.potentially_ambiguous_export_star_refs.slice(),
                .tracker = tracker,
            };
        }

        // Is this a file with dynamic exports?
        const is_commonjs_to_esm = other_kind == .esm_with_dynamic_fallback_from_cjs;
        if (other_kind == .esm_with_dynamic_fallback or is_commonjs_to_esm) {
            return .{
                .value = .{
                    .source_index = Index.source(other_source_index),
                    .import_ref = c.graph.ast.items(.exports_ref)[other_id],
                },
                .status = if (is_commonjs_to_esm)
                    .dynamic_fallback_interop_default
                else
                    .dynamic_fallback,
                .tracker = tracker,
            };
        }

        // Missing re-exports in TypeScript files are indistinguishable from types
        if (named_import.is_exported and c.parse_graph.input_files.items(.loader)[other_source_index].isTypeScript()) {
            return .{
                .value = .{},
                .status = .probably_typescript_type,
                .tracker = tracker,
            };
        }

        return .{
            .value = .{
                .source_index = Index.source(other_source_index),
            },
            .status = .no_match,
            .tracker = tracker,
        };
    }

    pub fn matchImportsWithExportsForFile(
        c: *LinkerContext,
        named_imports_ptr: *JSAst.NamedImports,
        imports_to_bind: *RefImportData,
        source_index: Index.Int,
        to_mark_as_esm_with_dynamic_fallback: *std.AutoArrayHashMap(u32, void),
    ) void {
        var named_imports = named_imports_ptr.cloneWithAllocator(c.allocator) catch unreachable;
        defer named_imports_ptr.* = named_imports;

        const Sorter = struct {
            imports: *JSAst.NamedImports,

            pub fn lessThan(self: @This(), a_index: usize, b_index: usize) bool {
                const a_ref = self.imports.keys()[a_index];
                const b_ref = self.imports.keys()[b_index];

                return std.math.order(a_ref.innerIndex(), b_ref.innerIndex()) == .lt;
            }
        };
        var sorter = Sorter{
            .imports = &named_imports,
        };
        named_imports.sort(sorter);

        for (named_imports.keys(), named_imports.values()) |ref, named_import| {
            // Re-use memory for the cycle detector
            c.cycle_detector.clearRetainingCapacity();

            const import_ref = ref;

            var import_tracker = ImportData{
                .data = .{
                    .source_index = Index.source(source_index),
                    .import_ref = import_ref,
                },
            };
            var re_exports = std.ArrayList(js_ast.Dependency).init(c.allocator);
            var result = c.matchImportWithExport(
                &import_tracker.data,
                &re_exports,
                to_mark_as_esm_with_dynamic_fallback,
            );

            switch (result.kind) {
                .normal => {
                    imports_to_bind.put(
                        c.allocator,
                        import_ref,
                        .{
                            .re_exports = bun.BabyList(js_ast.Dependency).init(re_exports.items),
                            .data = .{
                                .source_index = Index.source(result.source_index),
                                .import_ref = result.ref,
                            },
                        },
                    ) catch unreachable;
                },
                .namespace => {
                    c.graph.symbols.get(import_ref).?.namespace_alias = js_ast.G.NamespaceAlias{
                        .namespace_ref = result.namespace_ref,
                        .alias = result.alias,
                    };
                },
                .normal_and_namespace => {
                    imports_to_bind.put(
                        c.allocator,
                        import_ref,
                        .{
                            .re_exports = bun.BabyList(js_ast.Dependency).init(re_exports.items),
                            .data = .{
                                .source_index = Index.source(result.source_index),
                                .import_ref = result.ref,
                            },
                        },
                    ) catch unreachable;

                    c.graph.symbols.get(import_ref).?.namespace_alias = js_ast.G.NamespaceAlias{
                        .namespace_ref = result.namespace_ref,
                        .alias = result.alias,
                    };
                },
                .cycle => {
                    const source = &c.parse_graph.input_files.items(.source)[source_index];
                    const r = lex.rangeOfIdentifier(source, named_import.alias_loc orelse Logger.Loc{});
                    c.log.addRangeErrorFmt(
                        source,
                        r,
                        c.allocator,
                        "Detected cycle while resolving import \"{s}\"",
                        .{
                            named_import.alias.?,
                        },
                    ) catch unreachable;
                },
                .probably_typescript_type => {
                    c.graph.meta.items(.probably_typescript_type)[source_index].put(
                        c.allocator,
                        import_ref,
                        {},
                    ) catch unreachable;
                },
                .ambiguous => {
                    const source = &c.parse_graph.input_files.items(.source)[source_index];

                    const r = lex.rangeOfIdentifier(source, named_import.alias_loc orelse Logger.Loc{});

                    // TODO: log locations of the ambiguous exports

                    const symbol: *Symbol = c.graph.symbols.get(import_ref).?;
                    if (symbol.import_item_status == .generated) {
                        symbol.import_item_status = .missing;
                        c.log.addRangeWarningFmt(
                            source,
                            r,
                            c.allocator,
                            "Import \"{s}\" will always be undefined because there are multiple matching exports",
                            .{
                                named_import.alias.?,
                            },
                        ) catch unreachable;
                    } else {
                        c.log.addRangeErrorFmt(
                            source,
                            r,
                            c.allocator,
                            "Ambiguous import \"{s}\" has multiple matching exports",
                            .{
                                named_import.alias.?,
                            },
                        ) catch unreachable;
                    }
                },
                .ignore => {},
            }
        }
    }

    const ExportStarContext = struct {
        import_records_list: []const ImportRecord.List,
        source_index_stack: std.ArrayList(Index.Int),
        exports_kind: []js_ast.ExportsKind,
        named_exports: []js_ast.Ast.NamedExports,
        resolved_exports: []ResolvedExports,
        imports_to_bind: []RefImportData,
        export_star_records: []const []const Index.Int,
        allocator: std.mem.Allocator,

        pub fn addExports(
            this: *ExportStarContext,
            resolved_exports: *ResolvedExports,
            source_index: Index.Int,
        ) void {
            // Avoid infinite loops due to cycles in the export star graph
            for (this.source_index_stack.items) |i| {
                if (i == source_index)
                    return;
            }

            this.source_index_stack.append(source_index) catch unreachable;
            const stack_end_pos = this.source_index_stack.items.len;
            const id = source_index;

            const import_records = this.import_records_list[id].slice();

            for (this.export_star_records[id]) |import_id| {
                const other_source_index = import_records[import_id].source_index.get();

                const other_id = other_source_index;
                if (other_id >= this.named_exports.len)
                    // this AST was empty or it wasn't a JS AST
                    continue;

                // Export stars from a CommonJS module don't work because they can't be
                // statically discovered. Just silently ignore them in this case.
                //
                // We could attempt to check whether the imported file still has ES6
                // exports even though it still uses CommonJS features. However, when
                // doing this we'd also have to rewrite any imports of these export star
                // re-exports as property accesses off of a generated require() call.
                if (this.exports_kind[other_id] == .cjs)
                    continue;
                var iter = this.named_exports[other_id].iterator();
                next_export: while (iter.next()) |entry| {
                    const alias = entry.key_ptr.*;

                    // ES6 export star statements ignore exports named "default"
                    if (strings.eqlComptime(alias, "default"))
                        continue;

                    // This export star is shadowed if any file in the stack has a matching real named export
                    for (this.source_index_stack.items[0..stack_end_pos]) |prev| {
                        if (this.named_exports[prev].contains(alias)) {
                            continue :next_export;
                        }
                    }
                    const ref = entry.value_ptr.ref;
                    var resolved = resolved_exports.getOrPut(this.allocator, entry.key_ptr.*) catch unreachable;
                    if (!resolved.found_existing) {
                        resolved.value_ptr.* = .{
                            .data = .{
                                .import_ref = ref,
                                .source_index = Index.source(other_source_index),
                                .name_loc = entry.value_ptr.alias_loc,
                            },
                        };

                        // Make sure the symbol is marked as imported so that code splitting
                        // imports it correctly if it ends up being shared with another chunk
                        this.imports_to_bind[id].put(this.allocator, entry.value_ptr.ref, .{
                            .data = .{
                                .import_ref = ref,
                                .source_index = Index.source(other_source_index),
                            },
                        }) catch unreachable;
                    } else if (resolved.value_ptr.data.source_index.get() != other_source_index) {
                        // Two different re-exports colliding makes it potentially ambiguous
                        resolved.value_ptr.potentially_ambiguous_export_star_refs.push(this.allocator, .{
                            .data = .{
                                .source_index = Index.source(other_source_index),
                                .import_ref = ref,
                                .name_loc = entry.value_ptr.alias_loc,
                            },
                        }) catch unreachable;
                    }
                }

                // Search further through this file's export stars
                this.addExports(resolved_exports, other_source_index);
            }
        }
    };

    pub fn breakOutputIntoPieces(
        c: *LinkerContext,
        allocator: std.mem.Allocator,
        j: *bun.Joiner,
        has_any_cross_chunk_code: bool,
        count: u32,
    ) !Chunk.IntermediateOutput {
        // Optimization: If there can be no substitutions, just reuse the initial
        // joiner that was used when generating the intermediate chunk output
        // instead of creating another one and copying the whole file into it.
        if (!has_any_cross_chunk_code) {
            return Chunk.IntermediateOutput{
                .joiner = j.*,
            };
        }

        var pieces = try std.ArrayList(Chunk.OutputPiece).initCapacity(allocator, count);
        const complete_output = try j.done(allocator);
        var output = complete_output;

        const prefix = c.unique_key_prefix;

        while (true) {
            const invalid_boundary = std.math.maxInt(usize);
            // Scan for the next piece boundary
            var boundary = strings.indexOf(output, prefix) orelse invalid_boundary;

            var output_piece_index = Chunk.OutputPieceIndex{};
            var index: usize = 0;

            // Try to parse the piece boundary
            if (boundary != invalid_boundary) {
                const start = boundary + prefix.len;
                if (start + 9 > output.len) {
                    // Not enough bytes to parse the piece index
                    boundary = invalid_boundary;
                } else {
                    switch (output[start]) {
                        'A' => {
                            output_piece_index.kind = .asset;
                        },
                        'C' => {
                            output_piece_index.kind = .chunk;
                        },
                        else => {},
                    }

                    for (output[start..][1..9].*) |char| {
                        if (char < '0' or char > '9') {
                            boundary = invalid_boundary;
                            break;
                        }

                        index = (index * 10) + (@as(usize, char) - '0');
                    }
                }
            }

            // Validate the boundary
            switch (output_piece_index.kind) {
                .asset => {
                    if (index >= c.graph.files.len) {
                        boundary = invalid_boundary;
                    }
                },
                .chunk => {
                    if (index >= count) {
                        boundary = invalid_boundary;
                    }
                },
                else => {
                    boundary = invalid_boundary;
                },
            }

            output_piece_index.index = @intCast(u30, index);

            // If we're at the end, generate one final piece
            if (boundary == invalid_boundary) {
                try pieces.append(Chunk.OutputPiece{
                    .index = output_piece_index,
                    .data_ptr = output.ptr,
                    .data_len = @truncate(u32, output.len),
                });
                break;
            }

            // Otherwise, generate an interior piece and continue
            try pieces.append(Chunk.OutputPiece{
                .index = output_piece_index,
                .data_ptr = output.ptr,

                // sliced this way to panic if out of bounds
                .data_len = @truncate(u32, output[0..boundary].len),
            });
            output = output[boundary + prefix.len + 9 ..];
        }

        return Chunk.IntermediateOutput{
            .pieces = bun.BabyList(Chunk.OutputPiece).init(pieces.items),
        };
    }

    const DependencyWrapper = struct {
        linker: *LinkerContext,
        flags: []JSMeta.Flags,
        exports_kind: []js_ast.ExportsKind,
        import_records: []ImportRecord.List,
        export_star_map: std.AutoHashMap(Index.Int, void),
        entry_point_kinds: []EntryPoint.Kind,
        export_star_records: [][]u32,
        output_format: options.OutputFormat,

        pub fn hasDynamicExportsDueToExportStar(this: *DependencyWrapper, source_index: Index.Int) bool {
            // Terminate the traversal now if this file already has dynamic exports
            const export_kind = this.exports_kind[source_index];
            switch (export_kind) {
                .cjs, .esm_with_dynamic_fallback => return true,
                else => {},
            }

            // Avoid infinite loops due to cycles in the export star graph
            const has_visited = this.export_star_map.getOrPut(source_index) catch unreachable;
            if (has_visited.found_existing) {
                return false;
            }

            for (this.export_star_records[source_index]) |id| {
                const records: []const ImportRecord = this.import_records[id].slice();
                for (records) |record| {
                    // This file has dynamic exports if the exported imports are from a file
                    // that either has dynamic exports directly or transitively by itself
                    // having an export star from a file with dynamic exports.
                    const kind = this.entry_point_kinds[record.source_index.get()];
                    if ((record.source_index.get() >= this.import_records.len and (!kind.isEntryPoint() or !this.output_format.keepES6ImportExportSyntax())) or
                        (record.source_index.get() < this.import_records.len and record.source_index.get() != source_index and this.hasDynamicExportsDueToExportStar(record.source_index.get())))
                    {
                        this.exports_kind[source_index] = .esm_with_dynamic_fallback;
                        return true;
                    }
                }
            }

            return false;
        }

        pub fn wrap(this: *DependencyWrapper, source_index: Index.Int) void {

            // Never wrap the runtime file since it always comes first
            if (source_index == Index.runtime.get()) {
                return;
            }

            this.flags[source_index] = brk: {
                var flags = this.flags[source_index];

                if (flags.did_wrap_dependencies) return;
                flags.did_wrap_dependencies = true;

                // This module must be wrapped
                if (flags.wrap == .none) {
                    flags.wrap = switch (this.exports_kind[source_index]) {
                        .cjs => .cjs,
                        else => .esm,
                    };
                }
                break :brk flags;
            };

            const records = this.import_records[source_index].slice();
            for (records) |record| {
                if (!record.source_index.isValid()) {
                    continue;
                }
                this.wrap(record.source_index.get());
            }
        }
    };
};

pub const PartRange = struct {
    source_index: Index = Index.invalid,
    part_index_begin: u32 = 0,
    part_index_end: u32 = 0,
};

const StableRef = packed struct {
    stable_source_index: Index.Int,
    ref: Ref,

    pub fn isLessThan(_: void, a: StableRef, b: StableRef) bool {
        return a.stable_source_index < b.stable_source_index or
            (a.stable_source_index == b.stable_source_index and a.ref.innerIndex() < b.ref.innerIndex());
    }
};

pub const ImportTracker = struct {
    source_index: Index = Index.invalid,
    name_loc: Logger.Loc = Logger.Loc.Empty,
    import_ref: Ref = Ref.None,

    pub const Status = enum {
        /// The imported file has no matching export
        no_match,

        /// The imported file has a matching export
        found,

        /// The imported file is CommonJS and has unknown exports
        cjs,

        /// The import is missing but there is a dynamic fallback object
        dynamic_fallback,

        /// The import is missing but there is a dynamic fallback object
        /// and the file was originally CommonJS.
        dynamic_fallback_interop_default,

        /// The import was treated as a CommonJS import but the file is known to have no exports
        cjs_without_exports,

        /// The imported file was disabled by mapping it to false in the "browser"
        /// field of package.json
        disabled,

        /// The imported file is external and has unknown exports
        external,

        /// This is a missing re-export in a TypeScript file, so it's probably a type
        probably_typescript_type,
    };

    pub const Iterator = struct {
        status: Status = Status.no_match,
        value: ImportTracker = .{},
        import_data: []ImportData = &.{},
        tracker: *ImportTracker,
    };
};

const PathTemplate = options.PathTemplate;

pub const Chunk = struct {
    /// This is a random string and is used to represent the output path of this
    /// chunk before the final output path has been computed.
    unique_key: string = "",

    files_with_parts_in_chunk: std.AutoArrayHashMapUnmanaged(Index.Int, void) = .{},

    /// We must not keep pointers to this type until all chunks have been allocated.
    entry_bits: AutoBitSet = undefined,

    final_rel_path: string = "",
    template: PathTemplate = .{},

    /// For code splitting
    cross_chunk_imports: BabyList(ChunkImport) = .{},

    content: Content,

    entry_point: Chunk.EntryPoint = .{},

    is_executable: bool = false,

    intermediate_output: IntermediateOutput = .{ .empty = {} },
    isolated_hash: u64 = std.math.maxInt(u64),

    pub inline fn isEntryPoint(this: *const Chunk) bool {
        return this.entry_point.is_entry_point;
    }

    pub inline fn entryBits(this: *const Chunk) *const AutoBitSet {
        return &this.entry_bits;
    }

    pub const Order = struct {
        source_index: Index.Int = 0,
        distance: u32 = 0,
        tie_breaker: u32 = 0,

        pub fn lessThan(_: @This(), a: Order, b: Order) bool {
            return (a.distance < b.distance) or
                (a.distance == b.distance and a.tie_breaker < b.tie_breaker);
        }

        /// Sort so files closest to an entry point come first. If two files are
        /// equidistant to an entry point, then break the tie by sorting on the
        /// stable source index derived from the DFS over all entry points.
        pub fn sort(a: []Order) void {
            std.sort.sort(Order, a, Order{}, lessThan);
        }
    };

    /// TODO: rewrite this
    /// This implementation is just slow.
    /// Can we make the JSPrinter itself track this without increasing
    /// complexity a lot?
    pub const IntermediateOutput = union(enum) {
        /// If the chunk has references to other chunks, then "pieces" contains the
        /// contents of the chunk. Another joiner
        /// will have to be constructed later when merging the pieces together.
        pieces: bun.BabyList(OutputPiece),

        /// If the chunk doesn't have any references to other chunks, then
        /// `joiner` contains the contents of the chunk. This is more efficient
        /// because it avoids doing a join operation twice.
        joiner: bun.Joiner,

        empty: void,

        pub fn code(this: IntermediateOutput, allocator: std.mem.Allocator, chunk: *Chunk, chunks: []Chunk) ![]const u8 {
            switch (this) {
                .pieces => |*pieces| {
                    var count: usize = 0;
                    var file_path_buf: [4096]u8 = undefined;
                    _ = file_path_buf;
                    var from_chunk_dir = std.fs.path.dirname(chunk.final_rel_path) orelse "";
                    if (strings.eqlComptime(from_chunk_dir, "."))
                        from_chunk_dir = "";

                    for (pieces.slice()) |piece| {
                        count += piece.data_len;
                        if (piece.index.kind != .none) {
                            const file_path = chunks[piece.index.index].final_rel_path;
                            count += if (from_chunk_dir.len == 0) file_path.len else bun.path.relative(from_chunk_dir, file_path).len;
                        }
                    }

                    var total_buf = try allocator.alloc(u8, count);
                    var remain = total_buf;

                    for (pieces.slice()) |piece| {
                        const data = piece.data();

                        if (data.len > 0)
                            @memcpy(remain.ptr, data.ptr, data.len);

                        remain = remain[data.len..];
                        const index = piece.index.index;

                        if (piece.index.kind != .none) {
                            const file_path = chunks[index].final_rel_path;
                            const relative_path = if (from_chunk_dir.len > 0)
                                bun.path.relative(from_chunk_dir, file_path)
                            else
                                file_path;

                            if (relative_path.len > 0)
                                @memcpy(remain.ptr, relative_path.ptr, relative_path.len);

                            remain = remain[relative_path.len..];
                        }
                    }

                    std.debug.assert(remain.len == 0);
                    std.debug.assert(total_buf.len == count);

                    return total_buf;
                },
                .joiner => |joiner_| {
                    // TODO: make this safe
                    var joiny = joiner_;
                    return joiny.done(allocator);
                },
                .empty => return "",
            }
        }
    };

    pub const OutputPiece = struct {
        // layed out like this so it takes up the same amount of space as a []const u8
        data_ptr: [*]const u8 = undefined,
        data_len: u32 = 0,

        index: OutputPieceIndex = .{},

        pub inline fn data(this: OutputPiece) []const u8 {
            return this.data_ptr[0..this.data_len];
        }
    };

    pub const OutputPieceIndex = packed struct {
        index: u30 = 0,

        kind: Kind = Kind.none,

        pub const Kind = enum(u2) {
            /// The "kind" may be "none" in which case there is one piece
            /// with data and no chunk index. For example, the chunk may not contain any
            /// imports.
            none,

            asset,
            chunk,
        };
    };

    pub const EntryPoint = packed struct(u64) {
        source_index: Index.Int = 0,
        entry_point_id: ID = 0,
        is_entry_point: bool = false,

        // so it fits in a 64-bit integer
        pub const ID = u31;
    };

    pub const JavaScriptChunk = struct {
        files_in_chunk_order: []const Index.Int = &.{},
        parts_in_chunk_in_order: []const PartRange = &.{},

        // for code splitting
        exports_to_other_chunks: std.ArrayHashMapUnmanaged(Ref, string, Ref.ArrayHashCtx, false) = .{},
        imports_from_other_chunks: ImportsFromOtherChunks = .{},
        cross_chunk_prefix_stmts: BabyList(Stmt) = .{},
        cross_chunk_suffix_stmts: BabyList(Stmt) = .{},
    };

    pub const ImportsFromOtherChunks = std.AutoArrayHashMapUnmanaged(Index.Int, CrossChunkImport.Item.List);

    pub const Content = union(enum) {
        javascript: JavaScriptChunk,
    };
};

pub const ChunkImport = struct {
    chunk_index: u32,
    import_kind: ImportKind,
};

pub const CrossChunkImport = struct {
    chunk_index: Index.Int = 0,
    sorted_import_items: CrossChunkImport.Item.List = undefined,

    pub const Item = struct {
        export_alias: string = "",
        ref: Ref = Ref.None,

        pub const List = bun.BabyList(Item);

        pub fn lessThan(_: void, a: CrossChunkImport.Item, b: CrossChunkImport.Item) bool {
            return strings.order(a.export_alias, b.export_alias) == .lt;
        }
    };

    pub fn lessThan(_: void, a: CrossChunkImport, b: CrossChunkImport) bool {
        return std.math.order(a.chunk_index, b.chunk_index) == .lt;
    }

    pub const List = std.ArrayList(CrossChunkImport);

    pub fn sortedCrossChunkImports(
        list: *List,
        chunks: []Chunk,
        imports_from_other_chunks: *Chunk.ImportsFromOtherChunks,
    ) !void {
        var result = list.*;
        defer {
            list.* = result;
        }

        try result.ensureTotalCapacity(imports_from_other_chunks.count());

        var import_items_list = imports_from_other_chunks.values();
        var chunk_indices = imports_from_other_chunks.keys();
        for (chunk_indices, import_items_list) |chunk_index, import_items| {
            var chunk = &chunks[chunk_index];

            // Sort imports from a single chunk by alias for determinism
            const exports_to_other_chunks = &chunk.content.javascript.exports_to_other_chunks;
            // TODO: do we need to clone this array?
            for (import_items.slice()) |*item| {
                item.export_alias = exports_to_other_chunks.get(item.ref).?;
                std.debug.assert(item.export_alias.len > 0);
            }
            std.sort.sort(CrossChunkImport.Item, import_items.slice(), {}, CrossChunkImport.Item.lessThan);

            result.append(CrossChunkImport{
                .chunk_index = chunk_index,
                .sorted_import_items = import_items,
            }) catch unreachable;
        }

        std.sort.sort(CrossChunkImport, result.items, {}, CrossChunkImport.lessThan);
    }
};

const CompileResult = union(enum) {
    javascript: struct {
        source_index: Index.Int,
        result: js_printer.PrintResult,
    },

    pub const empty = CompileResult{
        .javascript = .{
            .source_index = 0,
            .result = js_printer.PrintResult{
                .result = .{
                    .code = "",
                },
            },
        },
    };

    pub fn code(this: *const CompileResult) []const u8 {
        return switch (this.*) {
            .javascript => |r| switch (r.result) {
                .result => |r2| r2.code,
                else => "",
            },
            // else => "",
        };
    }

    pub fn sourceIndex(this: *const CompileResult) Index.Int {
        return switch (this.*) {
            .javascript => |r| r.source_index,
            // else => 0,
        };
    }
};

const ContentHasher = struct {
    hasher: std.hash.XxHash64 = std.hash.XxHash64.init(0),

    pub fn write(self: *ContentHasher, bytes: []const u8) void {
        self.hasher.update(std.mem.asBytes(&bytes.len));
        self.hasher.update(bytes);
    }

    pub fn writeInts(self: *ContentHasher, i: []const u32) void {
        // TODO: BigEndian
        self.hasher.update(std.mem.sliceAsBytes(i));
    }

    pub fn digest(self: *ContentHasher) u64 {
        return self.hasher.final();
    }
};
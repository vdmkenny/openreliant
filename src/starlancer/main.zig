//! `starlancer`: the game, on SDL3 in place of Win32 and DirectX. It runs in the game's directory,
//! or in the one given, and reads `resource.hog` and the texture cache as the game does.
//!
//! So far it shows a fighter in space from the chase view, drawn through Surrender's pipeline and
//! its Direct3D driver onto the software device.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const starlancer = @import("starlancer");
const platform = @import("platform");
const shp = starlancer.shp;
const tcache = starlancer.tcache;
const tga = starlancer.tga;
const lancer = starlancer.lancer;
const math = lancer.surrender.math;
const srapi = lancer.surrender.surrenderlib.srapi;
const srcore = lancer.surrender.surrenderlib.srcore;
const srtexture = lancer.surrender.surrenderlib.srtexture;
const srd3d = lancer.surrender.srd3d;
const game = lancer.game;
const camera = game.camera;

const usage =
    \\usage: starlancer [<game-directory>] [--ship <type>] [--screenshot <file.png>]
    \\  <game-directory>          where the game is installed, with resource.hog and tcachehw.dat
    \\  --ship <type>             the ship type to show, by its number in shipstats.bin; 0 is the
    \\                            Predator
    \\  --screenshot <file.png>   draw one frame, with the camera settled, to a PNG, and quit
    \\
;

const Options = struct {
    directory: []const u8 = ".",
    ship: usize = 0,
    screenshot: ?[]const u8 = null,

    fn parse(args: []const [:0]const u8) error{Usage}!Options {
        var options: Options = .{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--ship")) {
                i += 1;
                if (i == args.len) return error.Usage;
                options.ship = std.fmt.parseInt(usize, args[i], 0) catch return error.Usage;
                if (options.ship >= game.create.models.ship_types.len) return error.Usage;
                if (game.create.models.ship_types[options.ship].model == null) return error.Usage;
            } else if (std.mem.eql(u8, args[i], "--screenshot")) {
                i += 1;
                if (i == args.len) return error.Usage;
                options.screenshot = args[i];
            } else if (std.mem.startsWith(u8, args[i], "-")) {
                return error.Usage;
            } else {
                options.directory = args[i];
            }
        }
        return options;
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const options = Options.parse(args[1..]) catch {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    try run(init.io, arena, options);
    return 0;
}

fn run(io: Io, arena: Allocator, options: Options) !void {
    const directory = try Io.Dir.cwd().openDir(io, options.directory, .{});
    defer directory.close(io);

    // What `WinMain` opens at start-up, and the texture cache `renderer_start` opens.
    var resources: game.bigfile.Hog = try .open(arena, io, directory, game.bigfile.resource_name);
    defer resources.close(arena);
    const cache_bytes = try directory.readFileAlloc(io, "tcachehw.dat", arena, .limited(256 << 20));
    const cache: tcache.Cache = try .parse(arena, cache_bytes);
    const palette = try tga.palette(try resources.readFile(arena, "palette.tga"));
    var textures: srtexture.Table = .init(arena, cache, palette);

    var window: platform.window.Window = try .open("StarLancer", 1280, 720);
    defer window.close();

    var context: srapi.Context = .{ .projection = (camera.Camera{}).projection(1280, 720) };
    var rand: lancer.libcmt.Rand = .{};
    const space = try game.backdrop.Backdrop.create(arena, &textures, try tga.decode(arena, try resources.readFile(arena, game.backdrop.star_map_name)), &rand, context.projection.near);
    const sky = try game.nebula.Sky.create(arena, &textures, try tga.decode(arena, try resources.readFile(arena, game.nebula.dome_image_name)));
    try sky.select(&textures, game.nebula.default_nebula, &space.lights);

    // The ship, as `create_object` makes one of its type.
    const model = try arena.create(shp.Model);
    model.* = try .parse(arena, try resources.readFile(arena, game.create.models.ship_types[options.ship].model.?));
    const loaded = try game.srofiles.modelLoad(arena, &textures, model, .{}, false);
    var models = [1]game.objects.Model{try .create(arena, model, &loaded)};
    models[0].place(@splat(0), math.identity);
    const player: camera.Subject = .{
        .position = @splat(0),
        .orientation = math.identity,
        .eye = .{ model.header.eye.x, model.header.eye.y, model.header.eye.z },
        .radius = radius(models[0], loaded),
        .motion = .{ .ship_type = @intCast(options.ship) },
    };

    var view: camera.Camera = .{};
    var last_view = view.view;
    var last_tick = platform.window.ticks();
    _ = view.setView(.chase, 0, false, false, @truncate(last_tick));
    // A screenshot waits for the chase view to settle, a tick a frame, and for the second frame,
    // which draws the sun by how much of it the first found showing.
    var frames_left: ?usize = null;
    if (options.screenshot != null) {
        for (0..settling_frames) |_| _ = view.frame(.{ .object = player, .player = player, .ticks = 1 });
        frames_left = 2;
    }

    // The device the driver draws with, and the driver, made again when the window's size changes.
    const Drawing = struct { device: srd3d.software.Software, driver: srd3d.srd3d.Driver };
    var drawing: ?*Drawing = null;
    defer if (drawing) |d| {
        d.driver.deinit();
        d.device.deinit(arena);
    };
    var scene: srcore.Scene = .{};
    defer scene.deinit(arena);
    // What a frame needs until it is drawn, kept from frame to frame.
    var frame_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer frame_arena.deinit();

    while (true) {
        while (window.poll()) |event| switch (event) {
            .quit => return,
            .key => |key| if (key.down and key.scancode == escape) return,
        };

        const now = platform.window.ticks();
        const ticks: u32 = if (frames_left != null) 1 else @truncate(now - last_tick);
        last_tick = now;
        if (view.frame(.{ .object = player, .player = player, .ticks = ticks })) |next| {
            _ = view.setView(next, 0, false, true, @truncate(now));
        }

        const size = window.size();
        if (drawing == null or drawing.?.device.width != size[0] or drawing.?.device.height != size[1]) {
            if (drawing) |d| {
                d.driver.deinit();
                d.device.deinit(arena);
            } else {
                drawing = try arena.create(Drawing);
            }
            const d = drawing.?;
            d.device = try .init(arena, size[0], size[1]);
            d.driver = try .init(arena, d.device.interface());
        }
        const device = &drawing.?.device;
        const driver = &drawing.?.driver;

        context.camera = .{ .position = view.place.position, .orientation = view.place.orientation };
        context.projection = view.projection(size[0], size[1]);
        _ = frame_arena.reset(.retain_capacity);
        try game.main.drawFrame(arena, frame_arena.allocator(), &scene, &context, .{
            .models = &models,
            .space = space,
            .sky = sky,
            .view = view.view,
            .cockpit_mode = view.cockpit_mode,
            .last_view = last_view,
        }, driver.interface());
        last_view = view.view;
        const rgba = try device.rgba(frame_arena.allocator());
        try window.present(rgba, size[0], size[1]);
        if (frames_left) |*left| {
            left.* -= 1;
            if (left.* == 0) return save(io, frame_arena.allocator(), options.screenshot.?, rgba, size);
        }
    }
}

/// Frames the chase view takes to settle, at a tick a frame.
const settling_frames = 200;

fn save(io: Io, gpa: Allocator, path: []const u8, rgba: []const u8, size: [2]u32) !void {
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try starlancer.png.writeRgba(gpa, &writer.interface, size[0], size[1], rgba);
    try writer.interface.flush();
}

/// SDL's scan code for Escape.
const escape = 41;

/// The farthest a vertex of the model's finest levels lies from its origin: the object's radius.
fn radius(model: game.objects.Model, loaded: game.srofiles.Loaded) f32 {
    var farthest: f32 = 0;
    for (model.parts, loaded.parts) |part, levels| {
        if (levels.meshes.len == 0) continue;
        for (levels.meshes[0].positions) |position| farthest = @max(farthest, math.length(part.origin + position));
    }
    return farthest;
}

test Options {
    try std.testing.expectEqualStrings(".", (try Options.parse(&.{})).directory);
    const given = try Options.parse(&.{ "game/install", "--ship", "3" });
    try std.testing.expectEqualStrings("game/install", given.directory);
    try std.testing.expectEqual(3, given.ship);
    try std.testing.expectError(error.Usage, Options.parse(&.{"--ship"}));
    try std.testing.expectError(error.Usage, Options.parse(&.{ "--ship", "0x0E" }));
    try std.testing.expectError(error.Usage, Options.parse(&.{"--bogus"}));
    try std.testing.expectEqualStrings("shot.png", (try Options.parse(&.{ "--screenshot", "shot.png" })).screenshot.?);
}

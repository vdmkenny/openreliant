//! `sltool render ...`: draw a model against the backdrop with the reference renderer, by the
//! engine's rules as the library states them.

const std = @import("std");
const Io = std.Io;

const starlancer = @import("starlancer");
const png = starlancer.png;
const shp = starlancer.shp;
const tcache = starlancer.tcache;
const tga = starlancer.tga;
const render = starlancer.render;
const math = starlancer.lancer.surrender.math;
const backdrop = starlancer.lancer.game.backdrop;
const nebula = starlancer.lancer.game.nebula;

const Context = @import("main.zig").Context;
const Library = @import("library.zig").Library;

pub const Command = struct {
    /// The extracted `resource.hog`: the palette, `starref12.tga`, `space.tga` and the models.
    resources: []const u8,
    /// `tcachehw.dat`.
    cache: []const u8,
    out: []const u8,
    model: ?[]const u8 = null,
    nebula: usize = nebula.default_nebula,
    width: u32 = 1280,
    height: u32 = 720,
    /// Where the camera looks, from the middle of the backdrop.
    toward: [3]f32 = .{ -1, 0, 0 },
    /// Where the model's nose points.
    heading: [3]f32 = .{ 1, -0.25, 0.75 },
    /// How far ahead of the camera the model is; by default, far enough to fill most of the view.
    distance: ?f32 = null,
    level: usize = 0,
    flares: bool = false,

    pub const usage =
        \\  render <resource-dir> <tcachehw.dat> <out.png> [--model <file>] [--nebula <0-6>]
        \\         [--size <w>x<h>] [--toward <x,y,z>] [--heading <x,y,z>] [--distance <d>]
        \\         [--lod <n>] [--flares]
        \\                                  draw a model against the backdrop by the engine's
        \\                                  rules, looking along a direction with Y down
        \\
    ;

    pub fn parse(args: []const [:0]const u8) error{Usage}!Command {
        if (args.len < 3) return error.Usage;
        var command: Command = .{ .resources = args[0], .cache = args[1], .out = args[2] };
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--flares")) {
                command.flares = true;
                continue;
            }
            const option = std.meta.stringToEnum(Option, args[i]) orelse return error.Usage;
            i += 1;
            if (i == args.len) return error.Usage;
            const value = args[i];
            switch (option) {
                .@"--model" => command.model = value,
                .@"--nebula" => {
                    command.nebula = std.fmt.parseInt(usize, value, 10) catch return error.Usage;
                    if (command.nebula >= nebula.nebulae.len) return error.Usage;
                },
                .@"--size" => {
                    const x = std.mem.indexOfScalar(u8, value, 'x') orelse return error.Usage;
                    command.width = std.fmt.parseInt(u32, value[0..x], 10) catch return error.Usage;
                    command.height = std.fmt.parseInt(u32, value[x + 1 ..], 10) catch return error.Usage;
                    if (command.width == 0 or command.height == 0 or command.width > 16384 or command.height > 16384) return error.Usage;
                },
                .@"--toward" => command.toward = try direction(value),
                .@"--heading" => command.heading = try direction(value),
                .@"--distance" => command.distance = std.fmt.parseFloat(f32, value) catch return error.Usage,
                .@"--lod" => command.level = std.fmt.parseInt(usize, value, 10) catch return error.Usage,
            }
        }
        return command;
    }

    /// The options that take a value.
    const Option = enum { @"--model", @"--nebula", @"--size", @"--toward", @"--heading", @"--distance", @"--lod" };

    pub fn run(command: Command, ctx: Context) !void {
        try draw(ctx, command);
    }
};

/// `x,y,z`, not zero.
fn direction(text: []const u8) error{Usage}![3]f32 {
    var out: [3]f32 = undefined;
    var parts = std.mem.splitScalar(u8, text, ',');
    for (&out) |*c| c.* = std.fmt.parseFloat(f32, parts.next() orelse return error.Usage) catch return error.Usage;
    if (parts.next() != null or math.length(out) == 0 or !std.math.isFinite(math.length(out))) return error.Usage;
    return out;
}

fn draw(ctx: Context, command: Command) !void {
    const gpa = ctx.arena;
    var resources: Library = try .open(ctx, command.resources);
    defer resources.deinit();

    const cache: tcache.Cache = try .parse(gpa, try Io.Dir.cwd().readFileAlloc(ctx.io, command.cache, gpa, .limited(256 << 20)));
    const palette = try tga.palette(try need(&resources, "palette.tga"));
    var textures: render.texture.Library = try .init(gpa, cache, palette);
    defer textures.deinit();

    // A quarter turn across the width: the game's own field of view is not yet known.
    const scale = @as(f32, @floatFromInt(command.width)) / 2;
    var target: render.scene.Scene = .{ .camera = .looking(@splat(0), command.toward, command.width, command.height, scale) };
    defer target.deinit(gpa);

    const dome = try render.backdrop.dome(try tga.decode(gpa, try need(&resources, nebula.dome_image_name)));
    try render.backdrop.addDome(gpa, &target, &dome);
    const choice = nebula.nebulae[command.nebula];
    const image = try textures.find(choice.texture) orelse return missingTexture(choice.texture);
    try render.backdrop.addNebula(gpa, &target, image, command.nebula, nebula.patch_orientation);
    const fields = try backdrop.fields(gpa, try tga.decode(gpa, try need(&resources, backdrop.star_map_name)));
    try render.backdrop.addStars(gpa, &target, &fields);
    render.backdrop.addSun(gpa, &target, &textures, backdrop.sun_direction, command.flares) catch |err| switch (err) {
        error.TextureNotFound => return missingTexture("the sun's"),
        else => return err,
    };

    if (command.model) |name| {
        const model = try resources.load(name) orelse {
            std.debug.print("no model {s} in {s}\n", .{ name, command.resources });
            return error.FileNotFound;
        };
        const distance = command.distance orelse radius(model, command.level) * scale / (0.35 * @as(f32, @floatFromInt(command.height)));
        var diagnostics: render.model.Diagnostics = .{};
        const lights = backdrop.lightsWith(choice.fill);
        render.model.add(gpa, &target, &textures, .{
            .model = model,
            .position = math.normalize(command.toward) * @as(math.Vector, @splat(distance)),
            .orientation = math.lookAt(math.normalize(command.heading)),
            .level = command.level,
        }, &lights, .{}, &diagnostics) catch |err| switch (err) {
            error.TextureNotFound => return missingTexture(diagnostics.material),
            else => return err,
        };
    }

    const frame: render.raster.Frame = try .init(gpa, command.width, command.height);
    try render.raster.draw(gpa, frame, &target);

    if (std.fs.path.dirname(command.out)) |dir| try Io.Dir.cwd().createDirPath(ctx.io, dir);
    const file = try Io.Dir.cwd().createFile(ctx.io, command.out, .{});
    defer file.close(ctx.io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(ctx.io, &buffer);
    try png.writeRgba(gpa, &writer.interface, command.width, command.height, try frame.rgba(gpa));
    try writer.interface.flush();

    var triangles: usize = 0;
    for (target.layers.values) |layer| triangles += layer.triangles.items.len;
    try ctx.stdout.print("wrote {s}: {d} triangles, {d} stars, {d} sprites\n", .{
        command.out,
        triangles,
        target.layers.get(.background).points.items.len,
        target.layers.get(.background).sprites.items.len + target.layers.get(.overlay).sprites.items.len,
    });
}

fn need(resources: *Library, name: []const u8) ![]u8 {
    return try resources.read(name) orelse {
        std.debug.print("no {s} in the resource directory\n", .{name});
        return error.FileNotFound;
    };
}

fn missingTexture(name: []const u8) error{TextureNotFound} {
    std.debug.print("the texture cache has no texture for {s}\n", .{name});
    return error.TextureNotFound;
}

/// The farthest a vertex of the model's level `level` lies from its origin.
fn radius(model: shp.Model, level: usize) f32 {
    var farthest: f32 = 1;
    for (model.parts, 0..) |part, index| {
        if (part.meshes.len == 0) continue;
        const origin = render.model.partOrigin(model, index);
        for (part.meshes[@min(level, part.meshes.len - 1)].vertices) |vertex| {
            const p = vertex.position;
            farthest = @max(farthest, math.length(origin + math.Vector{ p.x, p.y, p.z }));
        }
    }
    return farthest;
}

test Command {
    const plain = try Command.parse(&.{ "resource", "tcachehw.dat", "out.png" });
    try std.testing.expectEqual(null, plain.model);
    try std.testing.expectEqual(1280, plain.width);
    try std.testing.expect(!plain.flares);

    const full = try Command.parse(&.{
        "resource", "tcachehw.dat", "out.png",  "--model",  "USLF_Prd.SHP", "--nebula",   "5",
        "--size",   "640x480",      "--flares", "--toward", "1,-0.5,0.2",   "--distance", "900",
    });
    try std.testing.expectEqualStrings("USLF_Prd.SHP", full.model.?);
    try std.testing.expectEqual(5, full.nebula);
    try std.testing.expectEqual(480, full.height);
    try std.testing.expect(full.flares);
    try std.testing.expectEqual([3]f32{ 1, -0.5, 0.2 }, full.toward);
    try std.testing.expectEqual(900, full.distance.?);

    try std.testing.expectError(error.Usage, Command.parse(&.{ "resource", "tcachehw.dat" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "resource", "tcachehw.dat", "out.png", "--nebula", "7" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "resource", "tcachehw.dat", "out.png", "--size", "640" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "resource", "tcachehw.dat", "out.png", "--toward", "0,0,0" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "resource", "tcachehw.dat", "out.png", "--toward", "1,2" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "resource", "tcachehw.dat", "out.png", "--model" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "resource", "tcachehw.dat", "out.png", "--bogus" }));
}

//! `openreliant`: the engine, on SDL3 in place of Win32 and DirectX. It has no data of its own: it
//! runs in the directory of an installed copy of StarLancer, or in the one given, and reads
//! `resource.hog` and the texture cache from it as the game does. `openreliant install` installs
//! the game's files from its discs; see `install.zig`.
//!
//! So far it runs a sandbox of its own: the player's ship in space, the Reliant standing still
//! ahead of it, and a wing of Coalition fighters flying at it, drawn through Surrender's pipeline
//! and its Direct3D driver with the GPU, or onto the software device, from the camera's views,
//! which the game's camera keys pick and steer. Added for the port: F2 and F3 start the sandbox
//! again in the previous or next ship type, F4 brings another wing, Alt and Enter switch to the
//! full screen and back, and Escape quits.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const shp = openreliant.shp;
const stats = openreliant.stats;
const tcache = openreliant.tcache;
const tga = openreliant.tga;
const spr = openreliant.spr;
const engine = openreliant.engine;
const math = engine.surrender.math;
const srapi = engine.surrender.surrenderlib.srapi;
const srcore = engine.surrender.surrenderlib.srcore;
const srtexture = engine.surrender.surrenderlib.srtexture;
const srd3d = engine.surrender.srd3d;
const game = engine.game;
const camera = game.camera;
const help = @import("help.zig");
const install = @import("install.zig");
const joysticks = @import("joysticks.zig");

/// Everything `openreliant` takes on its command line, in the order the help page lists them.
const Arg = enum {
    @"--original",
    @"--ship",
    @"--view",
    @"--difficulty",
    @"--music",
    @"--fullscreen",
    @"--size",
    @"--fps",
    @"--no-vsync",
    @"--software",
    @"--16-bit",
    @"--msaa",
    @"--filter",
    @"--no-bloom",
    @"--no-dither",
    @"--no-pixel-lighting",
    @"--no-smooth-motion",
    @"--few-shot-lights",
    @"--hrtf",
    @"--no-hrtf",
    @"--no-reverb",
    @"--no-compressor",
    @"--no-sound",
    @"--screenshot",
    @"--help",

    /// The value it takes, as the help page shows it, or null for none.
    fn value(arg: Arg) ?[]const u8 {
        return docs.get(arg).value;
    }
};

/// The help page's sections, in order.
const Section = enum {
    original,
    sandbox,
    display,
    graphics,
    sound,
    other,

    fn title(section: Section) []const u8 {
        return switch (section) {
            .original => "The original",
            .sandbox => "The sandbox",
            .display => "Display",
            .graphics => "Graphics",
            .sound => "Sound",
            .other => "Other",
        };
    }
};

/// What the help page says of an option: its section, the value it takes, and what it does.
const Doc = struct {
    section: Section,
    value: ?[]const u8 = null,
    /// Another name for it, shown before it.
    alias: ?[]const u8 = null,
    text: []const u8,
};

/// Every option's help, which the compiler holds to having one for each.
const docs: std.enums.EnumArray(Arg, Doc) = .init(.{
    .@"--original" = .{ .section = .original, .text = "the original's look and sound: 16-bit colour, one sample a pixel, bilinear filtering, lighting each vertex, motion that moves on with the game's ticks, lights from the latest shots only, an explosion's debris lit by every light, its fireballs, rings and particles as few and plain as the original's, the shields' bubbles as coarse as the original's, the marker for a target out of sight placed as the original misplaces it, and the sound mixed plainly in stereo" },
    .@"--ship" = .{ .section = .sandbox, .value = "<type>", .text = "the ship type to fly, by its number in shipstats.bin; 0, the Predator, by default" },
    .@"--view" = .{ .section = .sandbox, .value = "<0|1|2>", .text = "the view it starts in, as the game's settings keep it: 0 the cockpit, the default; 1 the chase view; 2 no cockpit" },
    .@"--difficulty" = .{ .section = .sandbox, .value = "<easy|medium|hard>", .text = "the game's difficulty: how hard hits land on your ship, and shots on the enemy; medium by default, as in the game" },
    .@"--music" = .{ .section = .sandbox, .value = "<file>", .text = "the piece from the game's music folder it plays, or none; New_Mission01.wav by default" },
    .@"--fullscreen" = .{ .section = .display, .text = "fill the display; Alt and Enter switch while playing" },
    .@"--size" = .{ .section = .display, .value = "<width>x<height>", .text = "draw frames of this size in pixels whatever the window's, which shows them scaled; for a screenshot larger than the display" },
    .@"--fps" = .{ .section = .display, .value = "<rate>", .text = "frames a second at most; without vsync, the display's rate by default; 0 for no limit" },
    .@"--no-vsync" = .{ .section = .display, .text = "draw without waiting for the display" },
    .@"--software" = .{ .section = .graphics, .text = "draw on the software device, the port's reference, rather than the GPU" },
    .@"--16-bit" = .{ .section = .graphics, .text = "16-bit colour, dithered" },
    .@"--msaa" = .{ .section = .graphics, .value = "<1|2|4|8>", .text = "samples a pixel, for smooth edges; 4 by default" },
    .@"--filter" = .{ .section = .graphics, .value = "<original|trilinear|crisp>", .text = "how textures are filtered; crisp by default" },
    .@"--no-bloom" = .{ .section = .graphics, .text = "draw without the bloom around bright things" },
    .@"--no-dither" = .{ .section = .graphics, .text = "draw 32-bit colour without dithering" },
    .@"--no-pixel-lighting" = .{ .section = .graphics, .text = "light each vertex rather than each pixel, as the original does" },
    .@"--no-smooth-motion" = .{ .section = .graphics, .text = "move what moves on with the game's ticks, a hundred a second, as the original does, rather than on every frame" },
    .@"--few-shot-lights" = .{ .section = .graphics, .text = "light only the latest two of the player's shots and the latest two of everyone else's, as the original does" },
    .@"--hrtf" = .{ .section = .sound, .text = "place the sounds for headphones whatever the output; by default they are while the output is headphones" },
    .@"--no-hrtf" = .{ .section = .sound, .text = "place the sounds for speakers whatever the output" },
    .@"--no-reverb" = .{ .section = .sound, .text = "play the sounds around you and the cockpit's voice without reverb" },
    .@"--no-compressor" = .{ .section = .sound, .text = "leave the mix's loudness as it is, only keeping its peaks in check" },
    .@"--no-sound" = .{ .section = .sound, .text = "play without sound" },
    .@"--screenshot" = .{ .section = .other, .value = "<file.png>", .text = "draw one frame, with the camera settled, to a PNG, and quit" },
    .@"--help" = .{ .section = .other, .alias = "-h", .text = "show this page" },
});

/// `openreliant --help`.
const help_page = page: {
    var out: []const u8 = help.paragraph("OpenReliant plays StarLancer from an installed copy of the game.", 0) ++
        \\
        \\usage: openreliant [<game-directory>] [<option>...]
        \\       openreliant install [--from <disc>] [--force] <directory>
        \\       openreliant joysticks [<game-directory>] [--watch]
        \\
        \\
    ++ help.table(&.{.{ .typed = "<game-directory>", .text = "where StarLancer is installed, with resource.hog and tcachehw.dat; the current directory by default" }});
    for (std.enums.values(Section)) |section| {
        out = out ++ "\n" ++ section.title() ++ ":\n";
        if (section == .original) out = out ++ help.paragraph("OpenReliant improves on the original's look and sound. --original turns the improvements off, and an option after it turns one back on.", 2);
        var rows: []const help.Row = &.{};
        for (std.enums.values(Arg)) |arg| {
            const doc = docs.get(arg);
            if (doc.section != section) continue;
            const named = (if (doc.alias) |alias| alias ++ ", " else "") ++ @tagName(arg);
            rows = rows ++ .{help.Row{ .typed = if (doc.value) |shown| named ++ " " ++ shown else named, .text = doc.text }};
        }
        out = out ++ help.table(rows);
    }
    break :page out ++ "\nWhile playing:\n" ++
        help.paragraph("The flight keys are the game's own, as starlancer.ini binds them. OpenReliant adds:", 2) ++
        help.table(&.{
            .{ .typed = "F2, F3", .text = "start again in the previous or next ship type" },
            .{ .typed = "F4", .text = "bring in another wing" },
            .{ .typed = "Alt+Enter", .text = "switch between the window and the full screen" },
            .{ .typed = "Escape", .text = "quit" },
        }) ++ "\nCommands:\n" ++
        help.table(&.{
            .{ .typed = "install", .text = "copy the game's files from StarLancer disc 1 into a directory" },
            .{ .typed = "joysticks", .text = "list the joysticks and gamepads, and which one the game uses" },
        }) ++ help.paragraph("Each command's --help shows its options.", 2);
};

/// What the command line asks for.
const Command = union(enum) {
    play: Options,
    help,
    wrong: Problem,
};

/// What is wrong with the command line.
const Problem = union(enum) {
    /// An option there is no such thing as.
    unknown: []const u8,
    /// An option with no value after it.
    missing: Arg,
    /// An option with a value it doesn't take.
    bad: struct { arg: Arg, value: []const u8 },

    pub fn format(problem: Problem, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (problem) {
            .unknown => |arg| try writer.print("unknown option '{s}'", .{arg}),
            .missing => |arg| try writer.print("{s} takes a value, {s}", .{ @tagName(arg), arg.value().? }),
            .bad => |wrong| try writer.print("{s} takes {s}, not '{s}'", .{ @tagName(wrong.arg), wrong.arg.value().?, wrong.value }),
        }
    }
};

const Options = struct {
    directory: []const u8 = ".",
    ship: usize = 0,
    /// The options' cockpit setting, the ini's `[Device] View`.
    cockpit: camera.CockpitSetting = .cockpit,
    difficulty: game.collision.Difficulty = .medium,
    screenshot: ?[]const u8 = null,
    fullscreen: bool = false,
    software: bool = false,
    settings: platform.gpu.Settings = .{},
    /// Frames a second at most, 0 for no limit; null for the display's rate without vsync.
    fps: ?f32 = null,
    /// Draw what moves between the game's ticks as well as between its steps
    /// (`Clock.stepFraction`).
    smooth_motion: bool = true,
    /// Which shots cast a light: every one, or the latest two of each side as the original does.
    shot_lights: game.guns.ShotLights = .every_shot,
    /// Which lights reach an explosion's debris: a ship's, or every one as the original lets them.
    debris_lights: game.explode.DebrisLights = .like_ships,
    /// How full the explosions look: their fireballs, their shockwaves' rings, and the particles
    /// sent far from the camera.
    fireballs: game.explode.Fireballs = .fuller,
    rings: game.shockwave.Roundness = .round,
    distant: game.particles.Pool.Distant = .whole,
    /// How the shields' bubbles are drawn.
    shields: game.shield.Style = .smooth,
    /// Where the line starts that places the marker for a target out of sight.
    edge_line: game.hud.EdgeLine = .from_tip,
    /// How the sound plays, or null for none.
    sound: ?platform.audio.Options = .{},
    /// The piece of music the sandbox plays, from `music\`, or none.
    music: ?[]const u8 = default_music,

    const default_music = "New_Mission01.wav";

    /// OpenAL Soft's settings, which a setting for it after `--original` plays with again.
    fn openAl(options: *Options) ?*platform.audio.openal.Settings {
        const sound = &(options.sound orelse return null);
        if (sound.player == .software) sound.player = .{ .openal = .{} };
        return &sound.player.openal;
    }

    /// What `args` ask for: to play with these options, the help page, or what is wrong with them.
    fn parse(args: []const [:0]const u8) Command {
        var options: Options = .{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const text = args[i];
            if (std.mem.eql(u8, text, "-h")) return .help;
            const arg = std.meta.stringToEnum(Arg, text) orelse {
                if (std.mem.startsWith(u8, text, "-")) return .{ .wrong = .{ .unknown = text } };
                options.directory = text;
                continue;
            };
            const value: [:0]const u8 = if (arg.value() == null) "" else value: {
                i += 1;
                if (i == args.len) return .{ .wrong = .{ .missing = arg } };
                break :value args[i];
            };
            options.apply(arg, value) catch return .{ .wrong = .{ .bad = .{ .arg = arg, .value = value } } };
            if (arg == .@"--help") return .help;
        }
        return .{ .play = options };
    }

    /// Takes in `arg`, with its value where it has one.
    fn apply(options: *Options, arg: Arg, value: []const u8) error{BadValue}!void {
        switch (arg) {
            .@"--original" => {
                options.settings = .original;
                options.smooth_motion = false;
                options.shot_lights = .latest_two;
                options.debris_lights = .every_light;
                options.fireballs = .original;
                options.rings = .octagon;
                options.distant = .thinned;
                options.shields = .original;
                options.edge_line = .original;
                if (options.sound) |*sound| sound.* = .{ .player = .software, .master = null };
            },
            .@"--ship" => {
                const ship = std.fmt.parseInt(usize, value, 0) catch return error.BadValue;
                if (ship >= game.create.models.ship_types.len) return error.BadValue;
                if (game.create.models.ship_types[ship].model == null) return error.BadValue;
                options.ship = ship;
            },
            .@"--view" => {
                const setting = std.fmt.parseInt(u32, value, 10) catch return error.BadValue;
                if (setting > 2) return error.BadValue;
                options.cockpit = @enumFromInt(setting);
            },
            .@"--difficulty" => options.difficulty = std.meta.stringToEnum(game.collision.Difficulty, value) orelse return error.BadValue,
            .@"--music" => options.music = if (std.mem.eql(u8, value, "none")) null else value,
            .@"--fullscreen" => options.fullscreen = true,
            .@"--size" => options.settings.size = parseSize(value) orelse return error.BadValue,
            .@"--fps" => {
                const fps = std.fmt.parseFloat(f32, value) catch return error.BadValue;
                if (!(fps >= 0 and fps <= 10_000)) return error.BadValue;
                options.fps = fps;
            },
            .@"--no-vsync" => options.settings.vsync = false,
            .@"--software" => options.software = true,
            .@"--16-bit" => options.settings.sixteen_bit = true,
            .@"--msaa" => {
                const samples = std.fmt.parseInt(u8, value, 10) catch return error.BadValue;
                if (std.mem.indexOfScalar(u8, &.{ 1, 2, 4, 8 }, samples) == null) return error.BadValue;
                options.settings.samples = samples;
            },
            .@"--filter" => options.settings.filter = std.meta.stringToEnum(platform.gpu.Settings.Filter, value) orelse return error.BadValue,
            .@"--no-bloom" => options.settings.bloom = false,
            .@"--no-dither" => options.settings.dither = false,
            .@"--no-pixel-lighting" => options.settings.pixel_lighting = false,
            .@"--no-smooth-motion" => options.smooth_motion = false,
            .@"--few-shot-lights" => options.shot_lights = .latest_two,
            .@"--hrtf" => if (options.openAl()) |settings| {
                settings.hrtf = .on;
            },
            .@"--no-hrtf" => if (options.openAl()) |settings| {
                settings.hrtf = .off;
            },
            .@"--no-reverb" => if (options.openAl()) |settings| {
                settings.reverb = false;
            },
            .@"--no-compressor" => if (options.sound) |*sound| {
                // The limiter stays.
                const master = if (sound.master) |*master| master else master: {
                    sound.master = .{};
                    break :master &sound.master.?;
                };
                master.ratio = 1;
                master.makeup = 0;
            },
            .@"--no-sound" => options.sound = null,
            .@"--screenshot" => options.screenshot = value,
            .@"--help" => {},
        }
    }

    /// A size given as `<width>x<height>`, each from 1 to `max_size`.
    fn parseSize(text: []const u8) ?[2]u32 {
        var halves = std.mem.splitScalar(u8, text, 'x');
        var size: [2]u32 = undefined;
        for (&size) |*side| {
            const digits = halves.next() orelse return null;
            side.* = std.fmt.parseInt(u32, digits, 10) catch return null;
            if (side.* == 0 or side.* > max_size) return null;
        }
        return if (halves.next() == null) size else null;
    }

    /// The largest side `--size` takes, which GPUs draw to.
    const max_size = 16384;

    /// The frames a second to hold to, where the display does not already.
    fn frameRate(options: Options, window: platform.window.Window) ?f32 {
        if (options.fps) |fps| return if (fps > 0) fps else null;
        if (options.software or options.settings.vsync) return null;
        return window.refreshRate();
    }
};

/// What the driver draws with: the GPU, or the software device, the port's reference, whose frames
/// the window shows.
const Screen = union(enum) {
    gpu: platform.gpu.Gpu,
    software: srd3d.software.Software,

    fn interface(screen: *Screen) srd3d.device.Device {
        return switch (screen.*) {
            inline else => |*device| device.interface(),
        };
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 1 and std.mem.eql(u8, args[1], "install")) return install.main(init.io, arena, args[2..]);
    if (args.len > 1 and std.mem.eql(u8, args[1], "joysticks")) return joysticks.main(init.io, arena, args[2..]);
    const options = switch (Options.parse(args[1..])) {
        .play => |options| options,
        .help => {
            var buffer: [4096]u8 = undefined;
            var stdout: Io.File.Writer = .initStreaming(.stdout(), init.io, &buffer);
            try stdout.interface.writeAll(help_page);
            try stdout.interface.flush();
            return 0;
        },
        .wrong => |problem| {
            std.debug.print("openreliant: {f}\nRun 'openreliant --help' to see the options.\n", .{problem});
            return 2;
        },
    };
    run(init.io, init.gpa, arena, options) catch |err| switch (err) {
        error.MissingGameFiles => return 1,
        else => return err,
    };
    return 0;
}

/// The game's settings file, in its directory, which it names in lower case.
const settings_name = "starlancer.ini";

/// Added by the port: an optional file in the game folder with extra gamepad mappings in SDL's
/// format, for gamepads missing from SDL's database.
pub const mappings_name = "gamecontrollerdb.txt";

/// Opens the controller the game should use, unless it is already open, and loads the input
/// settings and bindings, which depend on the controller. The original does this once at startup
/// in `input_init` and `load_key_config`; the port also does it whenever a controller is connected
/// or disconnected. `platform.joystick.choose` selects the controller; `ThrottleAxis`, `TwistAxis`
/// and `ThrottleInvert` in `JoyConfig` configure a joystick's throttle and twist axes.
fn connectController(arena: Allocator, devices: *engine.input.Devices, controller: *?platform.joystick.Controller, settings_file: engine.profile.Profile) void {
    const joystick = platform.joystick;
    const found = joystick.attached(arena) catch &.{};
    const chosen = joystick.choose(found, settings_file.value("JoyConfig", "Joystick"));
    if (controller.*) |*open| {
        if (chosen != null and chosen.?.id == open.id() and devices.joystick.device != null) return;
        devices.joystick.close();
        open.close();
        controller.* = null;
    }
    if (chosen) |which| {
        const throttle: joystick.Choice = .parse(settings_file.value("JoyConfig", "ThrottleAxis"));
        const twist: joystick.Choice = .parse(settings_file.value("JoyConfig", "TwistAxis"));
        const inverted = settings_file.int("JoyConfig", "ThrottleInvert", 0) != 0;
        controller.* = joystick.Controller.openInverted(which, throttle, twist, inverted) catch null;
        if (controller.*) |*open| devices.joystick.open(open.device(), game.interface.deadZone(settings_file));
    }
    game.interface.loadKeyConfig(devices, settings_file);
}

/// Says that `directory` holds no installed copy of the game, and what the engine needs.
fn missingGameFiles(directory: []const u8, file: ?[]const u8) error{MissingGameFiles} {
    if (file) |name| {
        std.debug.print("openreliant: {s} is missing from {s}.\n", .{ name, directory });
    } else {
        std.debug.print("openreliant: there is no directory {s}.\n", .{directory});
    }
    std.debug.print(
        \\OpenReliant is an engine only: it plays the files of a legally obtained copy of
        \\StarLancer. Run it in the directory the game is installed in, or name that directory:
        \\
        \\    openreliant <game-directory>
        \\
        \\To install the game's files from your StarLancer discs:
        \\
        \\    openreliant install <game-directory>
        \\
    , .{});
    return error.MissingGameFiles;
}

fn run(io: Io, gpa: Allocator, arena: Allocator, options: Options) !void {
    const directory = Io.Dir.cwd().openDir(io, options.directory, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return missingGameFiles(options.directory, null),
        else => return err,
    };
    defer directory.close(io);
    if (install.missingGameFile(io, directory)) |name| return missingGameFiles(options.directory, name);

    // What `WinMain` opens at start-up, and the texture cache `renderer_start` opens.
    var resources: game.bigfile.Hog = try .open(arena, io, directory, game.bigfile.resource_name);
    defer resources.close(arena);
    const cache_bytes = try directory.readFileAlloc(io, "tcachehw.dat", arena, .limited(256 << 20));
    const cache: tcache.Cache = try .parse(arena, cache_bytes);
    const palette = try tga.palette(try resources.readFile(arena, "palette.tga"));
    var textures: srtexture.Table = .init(arena, cache, palette);
    // The flight and combat stats `stats_load_ships` reads.
    const ship_stats = (try stats.File.parse(.ships, try directory.readFileAlloc(io, "shipstats.bin", arena, .limited(4 << 20)))).ships;
    // Every gun type's figures, which `stats_load_guns` reads.
    const gun_stats = (try stats.File.parse(.guns, try directory.readFileAlloc(io, "gunstats.bin", arena, .limited(4 << 20)))).guns;
    const pilot_stats = (try stats.File.parse(.pilots, try directory.readFileAlloc(io, "pilotstats.bin", arena, .limited(4 << 20)))).pilots;
    // The strings `language_init` reads out of `language.dll` at start-up.
    const strings: game.language.Language = try .load(arena, try .parse(try directory.readFileAlloc(io, game.language.file_name, arena, .limited(16 << 20))));

    var window: platform.window.Window = try .open("OpenReliant", 1280, 720, options.fullscreen);
    defer window.close();
    // The device the driver draws with, and the driver.
    const screen = try arena.create(Screen);
    screen.* = if (options.software)
        .{ .software = try .init(arena, 1280, 720) }
    else
        .{ .gpu = try .init(gpa, window.gpu, window.handle, options.settings) };
    defer switch (screen.*) {
        .gpu => |*device| device.deinit(),
        .software => |*device| device.deinit(arena),
    };
    var driver: srd3d.srd3d.Driver = try .init(arena, screen.interface());
    defer driver.deinit();
    var pacer: platform.window.Pacer = .{};

    var context: srapi.Context = .{ .projection = (camera.Camera{}).projection(1280, 720) };
    var rand: engine.libcmt.Rand = .{};
    const space = try game.backdrop.Backdrop.create(arena, &textures, try tga.decode(arena, try resources.readFile(arena, game.backdrop.star_map_name)), &rand, context.projection.near);
    const sky = try game.nebula.Sky.create(arena, &textures, try tga.decode(arena, try resources.readFile(arena, game.nebula.dome_image_name)));
    try sky.select(&textures, game.nebula.default_nebula, &space.lights);

    // The engine glows every ship's thrusters burn, built once and shared by them all.
    const glows: game.environfx.Glows = try .create(arena, &textures);
    // The radar's backing, which the cockpit's view draws under the radar.
    const backing = try game.main.RadarBacking.create(arena, &textures);
    // The display's shapes, whose global palette the ships' schematics are drawn with too.
    const shapes = try spr.Sprite.parse(try resources.readFile(arena, game.hud.hardware_shapes));
    const global_palette = game.hud.globalPalette(shapes);
    // The ship types' stats as `stats_load_ships` leaves them, and the objects as a mission's start
    // does, every slot standing in; then the sandbox's own ships.
    const tables = try arena.create(game.create.Stats);
    tables.* = .initial;
    tables.load(ship_stats);
    var sandbox: Sandbox = try .init(gpa, tables, gun_stats, pilot_stats, &rand, .{
        .gpa = gpa,
        .resources = &resources,
        .textures = &textures,
        .glows = &glows,
        .light_sprites = try .load(&textures),
        .global_palette = global_palette,
    });
    defer sandbox.deinit();
    // What the shots are drawn with, built once (`guns_init`); the Turret Flak's shell is a ship
    // type's model, so it comes after the types' loader.
    sandbox.objects.bullets.looks = try game.guns.Looks.create(arena, &textures, sandbox.types.interface());
    sandbox.objects.bullets.shot_lights = options.shot_lights;
    var player: engine.input.Player = .{};
    var devices: engine.input.Devices = .{};
    // The game's settings file, which `load_key_config` reads the input settings from. If it's
    // missing, every setting keeps its default.
    const settings_file: engine.profile.Profile = .{
        .text = directory.readFileAlloc(io, settings_name, arena, .limited(1 << 20)) catch "",
    };
    // The joystick or gamepad the game uses, opened as `input_init` opens a joystick, and again
    // whenever a controller is connected or disconnected.
    try platform.joystick.init(.game);
    defer platform.joystick.deinit();
    _ = platform.joystick.addMappings(try std.fs.path.joinZ(arena, &.{ options.directory, mappings_name }));
    var controller: ?platform.joystick.Controller = null;
    defer if (controller) |*open| open.close();
    connectController(arena, &devices, &controller, settings_file);

    // Sound: Miles's calls, played by OpenAL Soft or the port's own mixer through SDL3's audio,
    // with the ten voices `WinMain` asks `sound_init` for, the volumes of `[Sound]`, and the 3D
    // provider it opens; silent where there is no device, or with `--no-sound`.
    const output: ?*platform.audio.Output = if (options.sound) |chosen| platform.audio.Output.create(gpa, chosen) catch |err| none: {
        std.log.warn("playing without sound: {s}", .{@errorName(err)});
        break :none null;
    } else null;
    defer if (output) |open| open.destroy();
    const sound = try arena.create(game.hog_snd.Sound);
    sound.init(if (output) |open| open.driver() else null, 10, .{ .gpa = gpa, .io = io, .dir = directory });
    defer sound.shutdown();
    sound.volumes = soundVolumes(settings_file);
    sound.objects = sandbox.objects;
    // `bank_stdsmp`, which the positional sounds of a frame play from, and `smp3d.fat`, which the
    // 3D sounds do.
    const stdsmp = try openreliant.fat.Bank.parse(try resources.readFile(arena, "stdsmp.fat"));
    sound.betty = try openreliant.fat.Bank.parse(try resources.readFile(arena, "betty.fat"));
    sound.open3D(try openreliant.fat.Bank.parse(try resources.readFile(arena, "smp3d.fat")));

    // The camera as a mission's launch leaves it: in the cockpit mode the options pick.
    var view: camera.Camera = .{ .cockpit_mode = options.cockpit.mode() };
    var last_view = view.view;
    // The mission's clocks, which `mission_run` zeroes before it loops.
    var clock: game.main.Clock = .{};
    clock.start(platform.window.ticks());
    const hearing: game.hog_snd.Hearing = .{ .sound = sound, .camera = &view.place, .clock = &clock };
    // What the explosions leave for the frames after them, and the particles they send out.
    var explosions: game.explode.Explosions = try .init(gpa, try .load(&textures));
    defer explosions.deinit();
    explosions.settings.debris_lights = options.debris_lights;
    explosions.settings.fireballs = options.fireballs;
    var particles: game.particles.Pool = try .load(gpa, &textures, options.distant);
    defer particles.deinit();
    var shockwaves: game.shockwave.Shockwaves = try .create(gpa, &textures, options.rings);
    defer shockwaves.deinit(gpa);
    var sparks: game.sparks.Sparks = try .create(gpa, &textures);
    defer sparks.deinit();
    var shields: game.shield.Shields = try .create(gpa, &textures, explosions.settings.detail, context.hardware, options.shields);
    defer shields.deinit(gpa);
    // What the objects run in, the camera's view brought up to date each frame.
    var world: game.gameobj.World = .{ .objects = sandbox.objects, .player = &player, .clock = &clock, .view = view.view, .shake = &view.hit_shake, .random = sandbox.random, .difficulty = options.difficulty, .hearing = hearing, .camera = &view, .explosions = &explosions, .particles = &particles, .shockwaves = &shockwaves, .sparks = &sparks, .shields = &shields };
    try sandbox.start(.{ .world = world, .clock = &clock, .devices = &devices }, @intCast(options.ship));
    // The music, as a mission's script starts it (`cmd_PlayMusic`): from `music\`, for ever, at 80.
    if (options.music) |name| {
        const path = try std.fmt.allocPrint(arena, "music\\{s}", .{name});
        sound.playMusic(path, 0, 80, true);
    }
    _ = view.setView(startingView(sandbox.player(), view.cockpit_mode), sandbox.objects.player, false, false, 0);
    // A screenshot waits for the chase view to settle, a tick a frame, and for the second frame,
    // which draws the sun by how much of it the first found showing.
    var frames_left: ?usize = null;
    if (options.screenshot != null) {
        const subject = playerSubject(sandbox.player());
        for (0..settling_frames) |_| _ = view.frame(.{ .object = subject, .player = subject, .ticks = 1 });
        frames_left = 2;
    }

    // The head-up display: what it draws with, and what draws it over the finished scene.
    var display: Display = .{
        .resources = try .load(arena, resources, shapes),
        .edge_line = options.edge_line,
        .gpa = arena,
        .target = undefined,
        .screen = .{ 0, 0 },
        .sandbox = &sandbox,
        .clock = &clock,
        .player = &player,
        .view = &view,
        .random = &rand,
        .strings = &strings,
    };
    // What the mission's start fits the player's ship with, once `hud_init` has set the display up.
    game.main.fitDevices(&display.state, sandbox.player_type, sandbox.canCloak());
    world.display = &display.state;

    var scene: srcore.Scene = .{};
    defer scene.deinit(arena);
    // What a frame needs until it is drawn, kept from frame to frame.
    var frame_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer frame_arena.deinit();

    // The window's activation, which a screenshot doesn't wait on.
    var app: game.winmain.App = .{};
    // When the sandbox starts again after the player's ship is destroyed.
    var restart_at: ?u32 = null;
    while (true) {
        while (window.poll()) |event| switch (event) {
            .quit => return,
            .key => |key| devices.keyboard.down[key.scan] = key.down,
            .controllers => connectController(arena, &devices, &controller, settings_file),
            .active => |active| app.active = active or frames_left != null,
        };
        // While the window is inactive, the game and its sound are paused, as the message pump
        // pauses them.
        game.winmain.followActivation(&app, sound, &clock);
        if (output) |open| open.update();
        // The timer's ticks since the last pass, then a game tick for each, as `mission_run` paces
        // them: the simulation steps on every fourth, reading the keyboard as it goes, and runs the
        // objects' updates. A screenshot takes one tick a frame so that the camera settles the same
        // way on every run.
        const now = platform.window.nanoseconds();
        if (frames_left != null) clock.advanceBy(now / platform.window.tick_nanoseconds, 1) else clock.advanceToFine(now, platform.window.tick_nanoseconds);
        // While the communications window is open the keys 1 to 8 are its menu's.
        devices.keyboard.numbers_taken = display.state.windows.status.get(.comms).phase == .open;
        world.view = view.view;
        const orders: game.aigeneric.Context = .{ .world = world, .clock = &clock, .devices = &devices };
        while (clock.nextTick(&devices, world)) |_| {}
        clock.frameBegin();
        // Each frame `mission_frame` runs every object's orders, which fly the ships and read the
        // player's controls, and then, before anything is drawn, has every object's frames drawn
        // between its last two places, as far into the step as the clock is; the camera follows the
        // player's.
        game.main.missionFrame(orders, game.objects.stepFraction(&clock, options.smooth_motion));

        const ticks: u32 = @intCast(@max(clock.frame_duration, 0));
        const at: u32 = @intCast(@max(clock.mission_ticks, 0));
        if (devices.keyboard.pressed(engine.input.scan.escape, .none, true)) return;
        // The player's ship gone, the sandbox starts again once the camera has watched for a
        // while, where a mission would end and go to its debriefing.
        if (sandbox.player().object.type == .stand_in) {
            const again = restart_at orelse at + restart_after;
            restart_at = again;
            if (at >= again) {
                restart_at = null;
                try sandbox.start(orders, sandbox.player_type);
                settleStart(&display, &sandbox, &view, at);
            }
        }
        for ([_]struct { u8, isize }{ .{ f2, -1 }, .{ f3, 1 } }) |step| {
            if (!devices.keyboard.pressed(step[0], .none, true)) continue;
            const was = sandbox.player_type;
            var candidate: usize = was;
            while (true) {
                candidate = nextShipType(candidate, step[1]);
                // Types whose files the game lacks are passed over; with none to go to, the
                // sandbox starts again as it was.
                const next: u8 = @intCast(candidate);
                sandbox.start(orders, next) catch |err| {
                    if (next == was) return err;
                    std.log.warn("ship type {d} left out: {s}", .{ candidate, @errorName(err) });
                    continue;
                };
                break;
            }
            settleStart(&display, &sandbox, &view, at);
        }
        if (devices.keyboard.pressed(f4, .none, true)) sandbox.bringWing(orders);

        // `frame_controls` and the camera run once a frame, over the ticks the frame spans.
        view.frameControls(&devices, sandbox.objects.player, ticks, at);
        const slot = sandbox.player();
        // After the camera's keys, `frame_controls` reads the targeting keys, then its own.
        game.hud.targetKeys(&display.state, .{
            .devices = &devices,
            .player = &player,
            .all = sandbox.objects,
            .sight = display.sight,
            .last_view = last_view,
            .scale = game.hud.scaleFor(display.screen),
            .multiplayer = false,
        });
        engine.input.frameKeys(&display.state, &player, &devices, &slot.object, view.view, display.clock.game_ticks, false);
        // What moves the cockpit's model: the ship's rates of turn over its full ones, and its
        // speed over its cruise speed.
        const cockpit_input: ?camera.Cockpit.Input = if (sandbox.cockpit) |*cockpit| input: {
            const live = &slot.object;
            const flight = slot.flight.?;
            const rates: [3]f32 = .{
                live.pitch_rate / flight.pitch_rate,
                live.yaw_rate / flight.yaw_rate,
                live.roll_rate / flight.roll_rate,
            };
            const speed = live.speed / game.ai.cruiseSpeed(live, flight, view.view);
            break :input game.main.cockpitInput(&cockpit.model, cockpit.source, rates, speed);
        } else null;
        const subject = playerSubject(slot);
        const marker = if (explosions.marker) |left| left.position else null;
        if (view.frame(.{ .object = subject, .player = subject, .ticks = ticks, .now = at, .marker = marker, .cockpit = cockpit_input, .random = &rand })) |next| {
            _ = view.setView(next, sandbox.objects.player, false, true, at);
        }
        // From its cockpit, the ship is not drawn, as `camera_set_view` sees to.
        slot.object.flags.hidden = view.inside(sandbox.objects.player);
        // The frame's sound, heard from where the camera now is: the fades `tick_timer` steps, the
        // music waiting its turn, the positional sounds gathered, and the 3D sounds placed again
        // (`mission_frame`).
        if (!app.paused) {
            sound.timerTick(clock.game_ticks);
            sound.updateMusic();
            sound.playBuffered(stdsmp);
            sound.update3D(hearing.scene(world));
        }

        // The GPU draws at the display's own resolution; the software device at the window's size
        // in points, made again when it changes.
        const size = switch (screen.*) {
            .gpu => |*device| device.frameSize(),
            .software => |*device| resized: {
                const size = options.settings.size orelse window.size();
                if (device.width != size[0] or device.height != size[1]) {
                    device.deinit(arena);
                    device.* = try .init(arena, size[0], size[1]);
                }
                break :resized size;
            },
        };

        context.camera = .{ .position = view.place.position, .orientation = view.place.orientation };
        context.projection = view.projection(size[0], size[1]);
        // The cockpit's model hangs from the camera, and the radar's backing stands on the radar.
        if (sandbox.cockpit) |*cockpit| if (view.cockpit_place) |placed| game.main.placeCockpit(&cockpit.model, view.place, placed);
        backing.place(context.projection, view.place, game.hud.scaleFor(size));
        _ = frame_arena.reset(.retain_capacity);
        display.target = screen.interface();
        display.screen = size;
        display.sight = .{ .place = view.place, .projection = context.projection };
        display.last_view = last_view;
        display.cockpit_mode = view.cockpit_mode;
        try game.main.drawFrame(arena, frame_arena.allocator(), &scene, &context, .{
            .objects = sandbox.objects,
            .space = space,
            .sky = sky,
            .view = view.view,
            .cockpit_mode = view.cockpit_mode,
            .last_view = last_view,
            .overlay = display.overlay(),
            .cockpit = if (sandbox.cockpit) |*cockpit| &cockpit.model else null,
            .backing = backing,
            .kills_shown = devices.active(.display_kills, false),
            .particles = &particles,
            .sparks = &sparks,
            .ahead = game.objects.pastTick(&clock, options.smooth_motion),
            .explosions = &explosions,
            .shockwaves = &shockwaves,
            .shields = &shields,
            .paused = app.paused,
            .attachments = .{
                .camera = view.place.position,
                .frame_start = clock.frame_start,
                .random = &rand,
            },
        }, driver.interface());
        last_view = view.view;
        if (screen.* == .software) try window.present(try screen.software.rgba(frame_arena.allocator()), size[0], size[1]);
        if (frames_left) |*left| {
            left.* -= 1;
            if (left.* == 0) {
                const rgba = switch (screen.*) {
                    .gpu => |*device| try device.capture(frame_arena.allocator()),
                    .software => |*device| try device.rgba(frame_arena.allocator()),
                };
                return save(io, frame_arena.allocator(), options.screenshot.?, rgba, size);
            }
        }
        if (options.frameRate(window)) |rate| pacer.wait(rate);
    }
}

/// The volumes `[Sound]` of the settings file holds, each from 0 to 127, and the defaults for any
/// it lacks.
fn soundVolumes(settings: engine.profile.Profile) game.hog_snd.Volumes {
    const defaults: game.hog_snd.Volumes = .{};
    const section = game.hog_snd.Volumes.section;
    return .{
        .master = volume(settings.int(section, "Mastervolume", @intCast(defaults.master))),
        .effects = volume(settings.int(section, "Fxvolume", @intCast(defaults.effects))),
        .music = volume(settings.int(section, "Musicvolume", @intCast(defaults.music))),
        .speech = volume(settings.int(section, "Speechvolume", @intCast(defaults.speech))),
    };
}

fn volume(setting: u32) i32 {
    return @intCast(@min(setting, 127));
}

/// What the camera follows of the player's ship: where its root's frame has it drawn, its model's
/// eye point and its size, and for the chase view its type, its throttle and its rates of turn.
fn playerSubject(slot: *const game.create.Slot) camera.Subject {
    const live = &slot.object;
    const eye = if (slot.type) |loaded| loaded.model.header.eye else std.mem.zeroes(shp.Vec3);
    return .{
        .position = slot.drawn.position,
        .orientation = slot.drawn.orientation,
        .eye = .{ eye.x, eye.y, eye.z },
        .radius = live.radius,
        // The chase view sits farther back the more throttle the ship carries and swings against
        // its rates of turn, so it lags a turn rather than riding rigidly behind the ship.
        .motion = .{
            .ship_type = live.type,
            .throttle = live.throttle,
            .afterburner = live.afterburner,
            .pitch_rate = live.pitch_rate,
            .yaw_rate = live.yaw_rate,
            .roll_rate = live.roll_rate,
        },
    };
}

/// The view a ship is shown in at first: view 0, as a mission's launch ends in, in `mode`. The
/// chase mode sits a fixed distance behind, which the camera keeps per ship type, so a ship whose
/// own radius is larger than that distance would not fit in it: the sandbox flies ships the game
/// never gives the player. Those are shown in the external view, which orbits at a distance
/// worked out from the ship's own size.
fn startingView(slot: *const game.create.Slot, mode: camera.CockpitMode) camera.View {
    if (mode != .chase) return .cockpit;
    const behind = camera.Chase.offset(slot.object.type).distance;
    return if (slot.object.radius > behind) .external else .cockpit;
}

/// Frames the chase view takes to settle, at a tick a frame.
const settling_frames = 200;

fn save(io: Io, gpa: Allocator, path: []const u8, rgba: []const u8, size: [2]u32) !void {
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try openreliant.png.writeRgba(gpa, &writer.interface, size[0], size[1], rgba);
    try writer.interface.flush();
}

/// The DirectInput scan codes of F2, F3 and F4, which the original leaves unbound.
const f2 = 0x3C;
const f3 = 0x3D;
const f4 = 0x3E;

/// The models an attachment point holds, read from the game's files as they are asked for and kept
/// for the ship that mounts them: a ship of three of the same turret reads that turret once. It
/// lives in the ship's own arena, so unloading the ship lets the lot go.
const Library = struct {
    gpa: Allocator,
    resources: *game.bigfile.Hog,
    textures: *srtexture.Table,
    read: std.StringHashMapUnmanaged(?game.objects.Mounts.Mounted) = .empty,

    fn mounts(library: *Library) game.objects.Mounts {
        return .{ .context = library, .load = load };
    }

    fn load(context: *anyopaque, file: []const u8) ?game.objects.Mounts.Mounted {
        const library: *Library = @ptrCast(@alignCast(context));
        // A model the game lacks is remembered as missing, so it is looked for only once.
        if (library.read.get(file)) |found| return found;
        const mounted = library.build(file) catch |err| missing: {
            std.log.warn("the model {s} is not mounted: {s}", .{ file, @errorName(err) });
            break :missing null;
        };
        library.read.put(library.gpa, file, mounted) catch return mounted;
        return mounted;
    }

    fn build(library: *Library, file: []const u8) !game.objects.Mounts.Mounted {
        const gpa = library.gpa;
        const model = try gpa.create(shp.Model);
        model.* = try .parse(gpa, try library.resources.readFile(gpa, file));
        const loaded = try gpa.create(game.srofiles.Loaded);
        loaded.* = try game.srofiles.modelLoad(gpa, library.textures, model, .{}, false);
        return .{ .model = model, .loaded = loaded };
    }
};

/// The sandbox's mission: the objects, the ship types' tables and the models they loaded, and the
/// cockpit the mission's start loads for the player's ship. Its ships are the player's, at the
/// origin facing along Z, the Reliant standing still ahead of it, and a wing of Coalition fighters
/// flying at it.
const Sandbox = struct {
    gpa: Allocator,
    objects: *game.create.Objects,
    tables: *game.create.Stats,
    types: *TypeCache,
    random: *engine.libcmt.Rand,
    player_type: u8 = 0,
    /// The cockpit's frame model, for a ship the player can fly, which the view ahead from the
    /// cockpit draws over the world; null for the rest. It lives in an arena of its own, so that
    /// another ship's can take its place.
    cockpit: ?Cockpit = null,
    cockpit_arena: std.heap.ArenaAllocator,

    const Cockpit = struct {
        source: *shp.Model,
        model: game.objects.Model,
    };

    /// The Reliant, which the sandbox starts ahead of the player and turned across its way. It flies its heading at `reliant_speed`, a tenth of the 100 its type cruises at,
    /// which carries it slowly across the player's way.
    const reliant_at: math.Vector = .{ 6000, -9000, 48000 };
    const reliant_turn: f32 = 1.1;
    const reliant_speed: i32 = 10;
    /// A wing: four Sabres, `wing_ahead` in front of the player, beyond the Reliant, and
    /// `wing_spacing` apart. Their models are drawn once they are within 25000, a fighter's last
    /// level of detail.
    const wing_size = 4;
    const wing_ahead: f32 = 150000;
    const wing_spacing: f32 = 3000;

    fn init(gpa: Allocator, tables: *game.create.Stats, gun_stats: []align(1) const stats.Gun, pilot_stats: []align(1) const stats.Pilot, random: *engine.libcmt.Rand, types: TypeCache) !Sandbox {
        const cache = try gpa.create(TypeCache);
        errdefer gpa.destroy(cache);
        cache.* = types;
        const objects = try game.create.Objects.create(gpa, random);
        objects.gun_stats.load(gun_stats);
        objects.pilots.load(pilot_stats);
        return .{
            .gpa = gpa,
            .objects = objects,
            .tables = tables,
            .types = cache,
            .random = random,
            .cockpit_arena = .init(std.heap.page_allocator),
        };
    }

    fn deinit(sandbox: *Sandbox) void {
        sandbox.objects.destroy();
        sandbox.types.deinit();
        sandbox.gpa.destroy(sandbox.types);
        sandbox.cockpit_arena.deinit();
    }

    fn player(sandbox: *Sandbox) *game.create.Slot {
        return &sandbox.objects.slots[sandbox.objects.player];
    }

    /// Whether the player's ship can cloak: its model's flag.
    fn canCloak(sandbox: *Sandbox) bool {
        const loaded = sandbox.player().type orelse return false;
        return loaded.model.header.flags.cloak;
    }

    /// Starts the mission again, as the game's does: every slot a stand-in, then the player in a
    /// ship of `ship_type` on its own controls, the Reliant flying its slow way across, and a wing.
    /// The types no object uses any more are let go. Fails where the game has no model for the
    /// player's type.
    fn start(sandbox: *Sandbox, orders: game.aigeneric.Context, ship_type: u8) !void {
        if (orders.world.hearing) |hearing| game.sound3d.endAll(hearing.sound);
        orders.world.player.ending = .playing;
        if (orders.world.explosions) |explosions| explosions.reset();
        if (orders.world.shockwaves) |waves| waves.reset();
        if (orders.world.sparks) |thrown| thrown.reset();
        if (orders.world.particles) |pool| pool.reset();
        sandbox.objects.reset(sandbox.random);
        // The debris models, counted as used so the sweep below keeps them (`explosions_init`).
        if (orders.world.explosions) |explosions| explosions.debris = .load(sandbox.objects, sandbox.types.interface());
        const index = try sandbox.create(@enumFromInt(ship_type), @splat(0));
        if (sandbox.objects.slots[index].model == null) return error.NoModel;
        // The engine's sound, which a mission starts as the player's ship launches (`launch_run`).
        if (orders.world.hearing) |hearing| {
            const engine_sound = game.sound3d.engineSound(@enumFromInt(ship_type));
            _ = game.sound3d.play(hearing.sound, hearing.scene(orders.world), null, null, index, engine_sound, 0, .player_engines);
        }
        // The order a mission's start gives the player's ship, which its controls fly it by.
        _ = game.aigeneric.push(orders, index, .player_control, .none) catch |err| {
            std.log.warn("the player's controls are left out: {s}", .{@errorName(err)});
        };
        if (sandbox.create(.reliant, reliant_at)) |reliant| {
            const slot = &sandbox.objects.slots[reliant];
            game.objects.setOrientation(&slot.object, &slot.drawn, math.rotation(.y, reliant_turn));
            // Fly with nothing to fly to holds the heading it starts on, at the speed in its data.
            if (game.aigeneric.push(orders, reliant, .fly, .none) catch false) {
                if (game.aigeneric.current(sandbox.objects, reliant)) |entry| entry.data.fly = reliant_speed;
            }
        } else |err| std.log.warn("the Reliant is left out: {s}", .{@errorName(err)});
        sandbox.bringWing(orders);
        sandbox.types.sweep(&sandbox.objects.types);
        if (sandbox.player_type != ship_type or sandbox.cockpit == null) try sandbox.loadCockpit(ship_type);
        sandbox.player_type = ship_type;
    }

    fn create(sandbox: *Sandbox, ship_type: game.gameobj.Type, at: math.Vector) game.create.Error!u16 {
        return game.create.createObject(sandbox.objects, sandbox.tables, sandbox.types.interface(), null, ship_type, at, sandbox.random);
    }

    /// A wing of fighters `wing_ahead` in front of the player, side by side and facing it, each
    /// under a Fight order against the player. A wing past the last slot is left out.
    fn bringWing(sandbox: *Sandbox, orders: game.aigeneric.Context) void {
        const ship = &sandbox.player().object;
        const from = ship.nextPosition();
        const facing = math.product(ship.root.next_orientation, math.rotation(.y, std.math.pi));
        for (0..wing_size) |place| {
            const across = (@as(f32, @floatFromInt(place)) - @as(f32, wing_size - 1) / 2) * wing_spacing;
            const at = from + math.transform(ship.root.next_orientation, .{ across, 0, wing_ahead });
            const index = sandbox.create(.sabre, at) catch |err| {
                std.log.warn("the wing is left out: {s}", .{@errorName(err)});
                return;
            };
            const slot = &sandbox.objects.slots[index];
            game.objects.setOrientation(&slot.object, &slot.drawn, facing);
            _ = game.aigeneric.pushShip(orders, index, .fight, sandbox.objects.player, -1) catch |err| {
                std.log.warn("a Sabre won't fight: {s}", .{@errorName(err)});
            };
        }
    }

    /// The cockpit the mission's start loads for a ship the player can fly.
    fn loadCockpit(sandbox: *Sandbox, ship_type: u8) !void {
        sandbox.cockpit = null;
        _ = sandbox.cockpit_arena.reset(.free_all);
        const player_ship = game.main.playerShip(ship_type) orelse return;
        const gpa = sandbox.cockpit_arena.allocator();
        const source = try gpa.create(shp.Model);
        const bytes = sandbox.types.resources.readFile(gpa, player_ship.cockpit) catch |err| {
            std.log.warn("the cockpit {s} is left out: {s}", .{ player_ship.cockpit, @errorName(err) });
            return;
        };
        source.* = shp.Model.parse(gpa, bytes) catch |err| {
            std.log.warn("the cockpit {s} is left out: {s}", .{ player_ship.cockpit, @errorName(err) });
            return;
        };
        const built = try gpa.create(game.srofiles.Loaded);
        built.* = try game.srofiles.modelLoad(gpa, sandbox.types.textures, source, .{}, false);
        sandbox.cockpit = .{ .source = source, .model = try game.main.createCockpit(gpa, source, built) };
    }
};

/// The ship types' models, read from the game's files as `create_object` asks for them, each with
/// what it mounts and its schematic, in an arena of its own that is let go once no object is of
/// the type.
const TypeCache = struct {
    gpa: Allocator,
    resources: *game.bigfile.Hog,
    textures: *srtexture.Table,
    glows: *const game.environfx.Glows,
    light_sprites: game.objects.LightSprites,
    global_palette: ?*const [spr.palette_size]u8,
    loaded: [game.create.ship_type_count]?*Cached = @splat(null),
    /// Types whose files the game lacks, looked for once.
    missing: std.StaticBitSet(game.create.ship_type_count) = .initEmpty(),

    const Cached = struct {
        arena: std.heap.ArenaAllocator,
        type: game.create.Type,
        library: Library,
        /// The schematic the display's ship status indicator draws, where the game has one.
        schematic: ?game.hud.Art,
    };

    fn interface(cache: *TypeCache) game.create.Types {
        return .{ .context = cache, .load = load };
    }

    fn load(context: *anyopaque, ship_type: u8) ?*const game.create.Type {
        const cache: *TypeCache = @ptrCast(@alignCast(context));
        if (cache.loaded[ship_type]) |cached| return &cached.type;
        if (cache.missing.isSet(ship_type)) return null;
        const cached = cache.build(ship_type) catch |err| {
            std.log.warn("ship type {d} has no model: {s}", .{ ship_type, @errorName(err) });
            cache.missing.set(ship_type);
            return null;
        };
        cache.loaded[ship_type] = cached;
        return &cached.type;
    }

    fn build(cache: *TypeCache, ship_type: u8) !*Cached {
        const name = game.create.models.ship_types[ship_type].model orelse return error.NoModel;
        const cached = try cache.gpa.create(Cached);
        errdefer cache.gpa.destroy(cached);
        cached.arena = .init(std.heap.page_allocator);
        errdefer cached.arena.deinit();
        const gpa = cached.arena.allocator();
        const model = try gpa.create(shp.Model);
        model.* = try .parse(gpa, try cache.resources.readFile(gpa, name));
        const loaded = try gpa.create(game.srofiles.Loaded);
        loaded.* = try game.srofiles.modelLoad(gpa, cache.textures, model, .{}, false);
        cached.library = .{ .gpa = gpa, .resources = cache.resources, .textures = cache.textures };
        cached.schematic = if (game.create.models.ship_types[ship_type].schematic) |file| found: {
            const bytes = cache.resources.readFile(gpa, file) catch |err| {
                std.log.warn("the schematic {s} is left out: {s}", .{ file, @errorName(err) });
                break :found null;
            };
            break :found try .init(gpa, try spr.Sprite.parse(bytes), cache.global_palette);
        } else null;
        cached.type = .{
            .model = model,
            .loaded = loaded,
            .effects = .{
                .light_sprites = cache.light_sprites,
                .glows = cache.glows,
                .mounts = cached.library.mounts(),
            },
            .schematic = if (cached.schematic) |*art| .{ .art = art, .gpa = gpa } else null,
        };
        return cached;
    }

    /// Lets go of each type no object is of any more.
    fn sweep(cache: *TypeCache, uses: *const [game.create.ship_type_count]game.create.TypeUse) void {
        for (&cache.loaded, uses) |*held, use| {
            const cached = held.* orelse continue;
            if (use.objects > 0) continue;
            cached.arena.deinit();
            cache.gpa.destroy(cached);
            held.* = null;
        }
    }

    fn deinit(cache: *TypeCache) void {
        for (cache.loaded) |held| if (held) |cached| {
            cached.arena.deinit();
            cache.gpa.destroy(cached);
        };
    }
};

/// How long the camera watches the player's ship's end before the sandbox starts again, in ticks.
const restart_after = 500;

/// What a start of the sandbox leaves the player: its devices fitted to the ship, and the camera
/// where a start puts it, since a ship of another size wants another view to be seen in.
fn settleStart(display: *Display, sandbox: *Sandbox, view: *camera.Camera, at: u32) void {
    game.main.fitDevices(&display.state, sandbox.player_type, sandbox.canCloak());
    // The start let go of the types no object is of any more, whose schematics what the target
    // display last showed may hold.
    display.state.target_pictures = .{};
    _ = view.setView(startingView(sandbox.player(), view.cockpit_mode), sandbox.objects.player, false, true, at);
}

/// What draws the head-up display over the finished scene: `hud_draw`, given the sandbox's game.
/// `srcore.render` reaches it where Surrender reaches `hud_draw`, through the overlay it is handed.
const Display = struct {
    resources: game.hud.Resources,
    gpa: Allocator,
    /// Filled in each frame, before the scene is drawn.
    target: srd3d.device.Device,
    screen: [2]u32,
    /// Last frame's view, which is what `hud_draw` reads to know whether to draw the instruments.
    last_view: camera.View = .cockpit,
    /// What the cockpit view shows, which leaves the reticle out of the chase view.
    cockpit_mode: camera.CockpitMode = .cockpit,
    /// The scene as it is drawn, which the targeting keys find the object under the reticle by
    /// and the target is drawn over; null until the first frame.
    sight: ?game.hud.Sight = null,
    /// Where the line starts that places the marker for a target out of sight.
    edge_line: game.hud.EdgeLine,
    /// The sandbox, whose player's ship the display shows.
    sandbox: *Sandbox,
    clock: *const game.main.Clock,
    player: *const engine.input.Player,
    /// The camera, whose shake shakes the power ball too.
    view: *const camera.Camera,
    /// The C runtime's `rand`, which the camera and the display both draw from.
    random: *engine.libcmt.Rand,
    /// The display's own state, `hud.cpp`'s globals.
    state: game.hud.State = .{},
    /// What the mission has ready for JUMP DRIVE. The sandbox runs no mission, so nothing is.
    ready: game.hud.Readiness = .{},
    /// The game's strings, which the views without the instruments are named by.
    strings: *const game.language.Language,

    fn overlay(display: *Display) srcore.Overlay {
        return .{ .context = display, .draw = draw };
    }

    fn draw(context: *anyopaque) Allocator.Error!void {
        const display: *Display = @ptrCast(@alignCast(context));
        const sandbox = display.sandbox;
        game.hud.draw(&display.state, &display.resources, .{
            .gpa = display.gpa,
            .target = display.target,
            .screen = display.screen,
            .sight = display.sight,
            .all = sandbox.objects,
            .player = display.player,
            .clock = display.clock,
            .last_view = display.last_view,
            .mode = display.cockpit_mode,
            .strings = display.strings,
            .hit_shake = display.view.hit_shake,
            .random = display.random,
            .ready = &display.ready,
            .edge_line = display.edge_line,
        }) catch |err| switch (err) {
            error.OutOfMemory => |out| return out,
            // A shape the file does not hold draws nothing, as it does in the game.
            else => {},
        };
    }
};

/// The ship type `step` from `from` that has a model, going round the table.
fn nextShipType(from: usize, step: isize) usize {
    const types = game.create.models.ship_types;
    var at = from;
    for (types) |_| {
        at = @intCast(@mod(@as(isize, @intCast(at)) + step, @as(isize, types.len)));
        if (types[at].model != null) return at;
    }
    return from;
}

test {
    _ = install;
    _ = joysticks;
}

test nextShipType {
    // The Predator's neighbours: the Nagi after it, and the last type with a model before it.
    try std.testing.expectEqual(1, nextShipType(0, 1));
    const last = nextShipType(0, -1);
    try std.testing.expect(game.create.models.ship_types[last].model != null);
    try std.testing.expectEqual(0, nextShipType(last, 1));
}

test "the sandbox's Reliant flies at a crawl" {
    // Its type cruises at 100 (`shipstats.bin`, type 0x0C). Fly holds the throttle at the speed in
    // its data over that, and the flight model settles the nose speed there, so the sandbox's
    // Reliant makes its 10 a step.
    const cruise = 100;
    var flight = game.gameobj.testing.flight;
    flight.max_speed = cruise;
    var object = game.gameobj.testing.object();
    object.throttle = @as(f32, @floatFromInt(Sandbox.reliant_speed)) / cruise;
    for (0..200) |_| game.motion.fly(&object, &flight, .chase, game.motion.Motion.forward.thrust());
    const crawl: f32 = @floatFromInt(Sandbox.reliant_speed);
    try std.testing.expectApproxEqAbs(crawl, math.length(game.gameobj.vector(object.velocity)), 0.01);
}

/// The options `args` play with, for the tests.
fn play(args: []const [:0]const u8) error{Usage}!Options {
    return switch (Options.parse(args)) {
        .play => |options| options,
        .help, .wrong => error.Usage,
    };
}

test Options {
    try std.testing.expectEqualStrings(".", (try play(&.{})).directory);
    const given = try play(&.{ "game/install", "--ship", "3" });
    try std.testing.expectEqualStrings("game/install", given.directory);
    try std.testing.expectEqual(3, given.ship);
    try std.testing.expectEqual(camera.CockpitSetting.cockpit, given.cockpit);
    try std.testing.expectEqual(camera.CockpitSetting.chase, (try play(&.{ "--view", "1" })).cockpit);
    try std.testing.expectError(error.Usage, play(&.{ "--view", "3" }));
    try std.testing.expectError(error.Usage, play(&.{"--ship"}));
    try std.testing.expectError(error.Usage, play(&.{ "--ship", "0x0E" }));
    try std.testing.expectError(error.Usage, play(&.{"--bogus"}));
    try std.testing.expectEqualStrings("shot.png", (try play(&.{ "--screenshot", "shot.png" })).screenshot.?);
    // Medium, the game's own default, unless told otherwise.
    try std.testing.expectEqual(.medium, (try play(&.{})).difficulty);
    try std.testing.expectEqual(.hard, (try play(&.{ "--difficulty", "hard" })).difficulty);
    try std.testing.expectEqual(.medium, (try play(&.{ "--original", "--difficulty", "medium" })).difficulty);
    try std.testing.expectError(error.Usage, play(&.{ "--difficulty", "ace" }));

    // The improvements on by default; the original's look, and single settings after it.
    const plain = try play(&.{});
    try std.testing.expectEqual(platform.gpu.Settings{}, plain.settings);
    try std.testing.expectEqual(null, plain.fps);
    const retro = try play(&.{ "--original", "--msaa", "8", "--no-vsync", "--fps", "0" });
    try std.testing.expect(retro.settings.sixteen_bit);
    try std.testing.expectEqual(.original, retro.settings.filter);
    try std.testing.expectEqual(8, retro.settings.samples);
    try std.testing.expect(!retro.settings.vsync);
    try std.testing.expectEqual(0, retro.fps.?);
    try std.testing.expect(!retro.smooth_motion);
    try std.testing.expectEqual(.latest_two, retro.shot_lights);
    try std.testing.expectEqual(.every_light, retro.debris_lights);
    try std.testing.expectEqual(.like_ships, plain.debris_lights);
    try std.testing.expectEqual(.original, retro.fireballs);
    try std.testing.expectEqual(.octagon, retro.rings);
    try std.testing.expectEqual(.thinned, retro.distant);
    try std.testing.expectEqual(.fuller, plain.fireballs);
    try std.testing.expectEqual(.smooth, plain.shields);
    try std.testing.expectEqual(.original, retro.shields);
    try std.testing.expect(!(try play(&.{"--no-smooth-motion"})).smooth_motion);
    try std.testing.expectEqual(.latest_two, (try play(&.{"--few-shot-lights"})).shot_lights);
    // Sound is on, with the first mission's music, unless told otherwise.
    try std.testing.expect((try play(&.{})).sound.?.player == .openal);
    try std.testing.expectEqual(null, (try play(&.{"--no-sound"})).sound);
    try std.testing.expectEqual(null, (try play(&.{ "--no-sound", "--hrtf" })).sound);
    // The original's sound is the plain mixer with no master bus; OpenAL's settings bring OpenAL
    // back.
    const original_sound = (try play(&.{"--original"})).sound.?;
    try std.testing.expect(original_sound.player == .software and original_sound.master == null);
    const headphones = (try play(&.{ "--original", "--hrtf", "--no-reverb" })).sound.?;
    try std.testing.expect(headphones.player.openal.hrtf == .on and !headphones.player.openal.reverb);
    try std.testing.expectEqual(.auto, (try play(&.{})).sound.?.player.openal.hrtf);
    try std.testing.expectEqual(.off, (try play(&.{"--no-hrtf"})).sound.?.player.openal.hrtf);
    const uncompressed = (try play(&.{"--no-compressor"})).sound.?.master.?;
    try std.testing.expectEqual(1, uncompressed.ratio);
    try std.testing.expectEqualStrings(Options.default_music, (try play(&.{})).music.?);
    try std.testing.expectEqualStrings("New_Sim01.wav", (try play(&.{ "--music", "New_Sim01.wav" })).music.?);
    try std.testing.expectEqual(null, (try play(&.{ "--music", "none" })).music);
    try std.testing.expect((try play(&.{})).smooth_motion);
    try std.testing.expectEqual([2]u32{ 3840, 2160 }, (try play(&.{ "--size", "3840x2160" })).settings.size.?);
    for ([_][:0]const u8{ "3840", "0x100", "100x", "1x2x3", "99999x100" }) |bad| {
        try std.testing.expectError(error.Usage, play(&.{ "--size", bad }));
    }
    const chosen = try play(&.{ "--filter", "trilinear", "--16-bit", "--software", "--fullscreen" });
    try std.testing.expectEqual(.trilinear, chosen.settings.filter);
    try std.testing.expect(chosen.settings.sixteen_bit and chosen.software and chosen.fullscreen);
    try std.testing.expectError(error.Usage, play(&.{ "--msaa", "3" }));
    try std.testing.expectError(error.Usage, play(&.{ "--filter", "sharp" }));
    try std.testing.expectError(error.Usage, play(&.{ "--fps", "-1" }));
    try std.testing.expectError(error.Usage, play(&.{ "--fps", "nan" }));
}

test "Options asks for help, and says what is wrong" {
    try std.testing.expectEqual(.help, std.meta.activeTag(Options.parse(&.{"--help"})));
    try std.testing.expectEqual(.help, std.meta.activeTag(Options.parse(&.{ "game", "-h" })));
    var buffer: [128]u8 = undefined;
    const cases = [_]struct { []const [:0]const u8, []const u8 }{
        .{ &.{"--bogus"}, "unknown option '--bogus'" },
        .{ &.{"--msaa"}, "--msaa takes a value, <1|2|4|8>" },
        .{ &.{ "--msaa", "3" }, "--msaa takes <1|2|4|8>, not '3'" },
        .{ &.{ "--no-sound", "--view", "cockpit" }, "--view takes <0|1|2>, not 'cockpit'" },
    };
    for (cases) |case| {
        const problem = Options.parse(case[0]).wrong;
        try std.testing.expectEqualStrings(case[1], try std.fmt.bufPrint(&buffer, "{f}", .{problem}));
    }
}

test help_page {
    // Every option is on it, and it fits in 80 columns.
    for (std.enums.values(Arg)) |arg| {
        try std.testing.expect(std.mem.indexOf(u8, help_page, @tagName(arg)) != null);
    }
    var lines = std.mem.splitScalar(u8, help_page, '\n');
    while (lines.next()) |line| try std.testing.expect(line.len <= help.width);
}

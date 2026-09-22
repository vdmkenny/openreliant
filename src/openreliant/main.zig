//! `openreliant`: the engine, on SDL3 in place of Win32 and DirectX. It has no data of its own: it
//! runs in the directory of an installed copy of StarLancer, or in the one given, and reads
//! `resource.hog` and the texture cache from it as the game does. `openreliant install` installs
//! the game's files from its discs; see `install.zig`.
//!
//! So far it shows a ship in space, drawn through Surrender's pipeline and its Direct3D driver with
//! the GPU, or onto the software device, from the camera's views, which the game's camera keys pick
//! and steer. Added for the port: F2 and F3 step back and forth through the ship types, Alt and
//! Enter switch to the full screen and back, and Escape quits.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const shp = openreliant.shp;
const stats = openreliant.stats;
const tcache = openreliant.tcache;
const tga = openreliant.tga;
const fnt = openreliant.fnt;
const spr = openreliant.spr;
const engine = openreliant.engine;
const math = engine.surrender.math;
const srapi = engine.surrender.surrenderlib.srapi;
const srcore = engine.surrender.surrenderlib.srcore;
const srtexture = engine.surrender.surrenderlib.srtexture;
const srd3d = engine.surrender.srd3d;
const game = engine.game;
const camera = game.camera;
const install = @import("install.zig");

const usage =
    \\usage: openreliant [<game-directory>] [<option>...]
    \\       openreliant install [--from <disc>] [--force] <game-directory>
    \\  <game-directory>          where StarLancer is installed, with resource.hog and
    \\                            tcachehw.dat; the current directory by default
    \\  --ship <type>             the ship type to show, by its number in shipstats.bin; 0 is the
    \\                            Predator
    \\  --view <0|1|2>            the view a mission starts in, as the game's ini keeps it: 0 the
    \\                            cockpit, the default; 1 the chase view; 2 no cockpit
    \\  --screenshot <file.png>   draw one frame, with the camera settled, to a PNG, and quit
    \\  --fullscreen              fill the display; Alt and Enter switch while running
    \\  --original                the original's look: 16-bit colour, one sample a pixel and
    \\                            bilinear filtering
    \\  --16-bit                  16-bit colour, dithered
    \\  --msaa <1|2|4|8>          samples a pixel; 4 by default
    \\  --filter <original|trilinear|crisp>
    \\                            how textures are filtered; crisp by default
    \\  --no-bloom                draw without the bloom around bright things
    \\  --no-dither               draw without dithering 32-bit colour
    \\  --no-vsync                draw without waiting for the display
    \\  --fps <rate>              frames a second at most; without vsync, the display's rate by
    \\                            default; 0 for no limit
    \\  --software                draw on the software device, the port's reference
    \\
;

const Options = struct {
    directory: []const u8 = ".",
    ship: usize = 0,
    /// The options' cockpit setting, the ini's `[Device] View`.
    cockpit: camera.CockpitSetting = .cockpit,
    screenshot: ?[]const u8 = null,
    fullscreen: bool = false,
    software: bool = false,
    settings: platform.gpu.Settings = .{},
    /// Frames a second at most, 0 for no limit; null for the display's rate without vsync.
    fps: ?f32 = null,

    const Flag = enum { @"--fullscreen", @"--original", @"--16-bit", @"--no-vsync", @"--no-bloom", @"--no-dither", @"--software" };
    const Option = enum { @"--ship", @"--view", @"--screenshot", @"--msaa", @"--filter", @"--fps" };

    fn parse(args: []const [:0]const u8) error{Usage}!Options {
        var options: Options = .{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.meta.stringToEnum(Flag, arg)) |flag| switch (flag) {
                .@"--fullscreen" => options.fullscreen = true,
                .@"--original" => options.settings = .original,
                .@"--16-bit" => options.settings.sixteen_bit = true,
                .@"--no-vsync" => options.settings.vsync = false,
                .@"--no-bloom" => options.settings.bloom = false,
                .@"--no-dither" => options.settings.dither = false,
                .@"--software" => options.software = true,
            } else if (std.meta.stringToEnum(Option, arg)) |option| {
                i += 1;
                if (i == args.len) return error.Usage;
                const value = args[i];
                switch (option) {
                    .@"--ship" => {
                        options.ship = std.fmt.parseInt(usize, value, 0) catch return error.Usage;
                        if (options.ship >= game.create.models.ship_types.len) return error.Usage;
                        if (game.create.models.ship_types[options.ship].model == null) return error.Usage;
                    },
                    .@"--view" => {
                        const setting = std.fmt.parseInt(u32, value, 10) catch return error.Usage;
                        if (setting > 2) return error.Usage;
                        options.cockpit = @enumFromInt(setting);
                    },
                    .@"--screenshot" => options.screenshot = value,
                    .@"--msaa" => {
                        options.settings.samples = std.fmt.parseInt(u8, value, 10) catch return error.Usage;
                        if (std.mem.indexOfScalar(u8, &.{ 1, 2, 4, 8 }, options.settings.samples) == null) return error.Usage;
                    },
                    .@"--filter" => options.settings.filter = std.meta.stringToEnum(platform.gpu.Settings.Filter, value) orelse return error.Usage,
                    .@"--fps" => {
                        const fps = std.fmt.parseFloat(f32, value) catch return error.Usage;
                        if (!(fps >= 0 and fps <= 10_000)) return error.Usage;
                        options.fps = fps;
                    },
                }
            } else if (std.mem.startsWith(u8, arg, "-")) {
                return error.Usage;
            } else {
                options.directory = arg;
            }
        }
        return options;
    }

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
    const options = Options.parse(args[1..]) catch {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    run(init.io, init.gpa, arena, options) catch |err| switch (err) {
        error.MissingGameFiles => return 1,
        else => return err,
    };
    return 0;
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
    var ship = try Ship.load(&resources, &textures, ship_stats, &glows, global_palette, options.ship);
    var player: engine.input.Player = .{};
    defer ship.unload();
    var keyboard: engine.input.Keyboard = .{};

    // The camera as a mission's launch leaves it: in the cockpit mode the options pick.
    var view: camera.Camera = .{ .cockpit_mode = options.cockpit.mode() };
    var last_view = view.view;
    // The mission's clocks, which `mission_run` zeroes before it loops.
    var clock: game.main.Clock = .{};
    clock.start(platform.window.ticks());
    _ = view.setView(startingView(ship, view.cockpit_mode), 0, false, false, 0);
    // A screenshot waits for the chase view to settle, a tick a frame, and for the second frame,
    // which draws the sun by how much of it the first found showing.
    var frames_left: ?usize = null;
    if (options.screenshot != null) {
        for (0..settling_frames) |_| _ = view.frame(.{ .object = ship.subject, .player = ship.subject, .ticks = 1 });
        frames_left = 2;
    }

    // The head-up display: its shapes, its font, and what draws it over the finished scene.
    var display: Display = .{
        .art = try .init(arena, shapes, global_palette),
        .font = .open(try fnt.Font.parse(try resources.readFile(arena, hud_font))),
        .gpa = arena,
        .target = undefined,
        .screen = .{ 0, 0 },
        .ship = &ship,
        .clock = &clock,
        .player = &player,
        .strings = &strings,
    };
    // What the mission's start fits the player's ship with, once `hud_init` has set the display up.
    game.main.fitDevices(&display.state, @intCast(ship.ship_type), ship.can_cloak);

    var scene: srcore.Scene = .{};
    defer scene.deinit(arena);
    // What a frame needs until it is drawn, kept from frame to frame.
    var frame_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer frame_arena.deinit();

    while (true) {
        while (window.poll()) |event| switch (event) {
            .quit => return,
            .key => |key| keyboard.down[key.scan] = key.down,
        };
        // The timer's ticks since the last pass, then a game tick for each, as `mission_run` paces
        // them: the simulation steps on every fourth, reading the keyboard as it goes. A screenshot
        // takes one tick a frame so that the camera settles the same way on every run.
        const now = platform.window.ticks();
        if (frames_left != null) clock.advanceBy(now, 1) else clock.advanceTo(now);
        // While the communications window is open the keys 1 to 8 are its menu's.
        keyboard.numbers_taken = display.state.windows.status.get(.comms).phase == .open;
        while (clock.nextTick(&keyboard)) |stepped| {
            if (!stepped) continue;
            // What `simulation_step` runs in order: the player's orders, then the objects move.
            engine.input.playerControls(&player, &keyboard, &ship.live, view.view);
            game.gameobj.move(&ship.live, &ship.flight, view.view, .forward);
            // The object takes up the place the move worked out, so that the next one carries on
            // from it. The game marks the root instead, with the node flag `object_move` sets and
            // `object_link_part` clears for a part; which routine takes a root's up is not yet
            // known.
            ship.live.root.position = ship.live.root.next_position;
            ship.live.root.orientation = ship.live.root.next_orientation;
        }
        clock.frameBegin();
        // An object's place is its root's next one, which is what the game steers and draws by.
        const flown = ship.live.root.next_position;
        ship.object.place(.{ flown.x, flown.y, flown.z }, ship.live.root.next_orientation);
        ship.subject.position = .{ flown.x, flown.y, flown.z };
        ship.subject.orientation = ship.live.root.next_orientation;
        // The chase view sits farther back the more throttle the ship carries and swings against
        // its rates of turn, so it lags a turn rather than riding rigidly behind the ship.
        ship.subject.motion = .{
            .ship_type = @intCast(ship.ship_type),
            .throttle = ship.live.throttle,
            .afterburner = ship.live.afterburner,
            .pitch_rate = ship.live.pitch_rate,
            .yaw_rate = ship.live.yaw_rate,
            .roll_rate = ship.live.roll_rate,
        };

        if (keyboard.pressed(engine.input.scan.escape, .none, true)) return;
        for ([_]struct { u8, isize }{ .{ f2, -1 }, .{ f3, 1 } }) |step| {
            if (!keyboard.pressed(step[0], .none, true)) continue;
            // Types whose files the game lacks are passed over.
            var candidate = ship.ship_type;
            while (true) {
                candidate = nextShipType(candidate, step[1]);
                if (candidate == ship.ship_type) break;
                const next = Ship.load(&resources, &textures, ship_stats, &glows, global_palette, candidate) catch |err| {
                    std.log.warn("ship type {d} left out: {s}", .{ candidate, @errorName(err) });
                    continue;
                };
                ship.unload();
                ship = next;
                game.main.fitDevices(&display.state, @intCast(ship.ship_type), ship.can_cloak);
                // A ship of another size wants another view to be seen in.
                _ = view.setView(startingView(ship, view.cockpit_mode), 0, false, true, @intCast(@max(clock.mission_ticks, 0)));
                break;
            }
        }

        // `frame_controls` and the camera run once a frame, over the ticks the frame spans.
        const ticks: u32 = @intCast(@max(clock.frame_duration, 0));
        const at: u32 = @intCast(@max(clock.mission_ticks, 0));
        view.frameControls(&keyboard, 0, ticks, at);
        // After the camera's keys, `frame_controls` reads the targeting keys, then its own.
        game.hud.targetKeys(&display.state, &keyboard, false);
        engine.input.frameKeys(&display.state, &keyboard, &ship.live, view.view, display.clock.game_ticks, false);
        // What moves the cockpit's model: the ship's rates of turn over its full ones, and its
        // speed over its cruise speed.
        const cockpit_input: ?camera.Cockpit.Input = if (ship.cockpit) |*cockpit| input: {
            const live = &ship.live;
            const rates: [3]f32 = .{
                live.pitch_rate / ship.flight.pitch_rate,
                live.yaw_rate / ship.flight.yaw_rate,
                live.roll_rate / ship.flight.roll_rate,
            };
            const speed = live.speed / game.gameobj.cruiseSpeed(live, &ship.flight, view.view);
            break :input game.main.cockpitInput(&cockpit.model, cockpit.source, rates, speed);
        } else null;
        if (view.frame(.{ .object = ship.subject, .player = ship.subject, .ticks = ticks, .cockpit = cockpit_input, .random = &rand })) |next| {
            _ = view.setView(next, 0, false, true, at);
        }
        // From its cockpit, the ship is not drawn, as `camera_set_view` sees to.
        ship.object.hidden = view.inside(0);

        // The GPU draws at the display's own resolution; the software device at the window's size
        // in points, made again when it changes.
        const size = switch (screen.*) {
            .gpu => |*device| device.frameSize(),
            .software => |*device| resized: {
                const size = window.size();
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
        if (ship.cockpit) |*cockpit| if (view.cockpit_place) |placed| game.main.placeCockpit(&cockpit.model, view.place, placed);
        backing.place(context.projection, view.place, game.hud.scaleFor(size));
        _ = frame_arena.reset(.retain_capacity);
        display.target = screen.interface();
        display.screen = size;
        display.last_view = last_view;
        display.cockpit_mode = view.cockpit_mode;
        try game.main.drawFrame(arena, frame_arena.allocator(), &scene, &context, .{
            .models = (&ship.object)[0..1],
            .space = space,
            .sky = sky,
            .view = view.view,
            .cockpit_mode = view.cockpit_mode,
            .last_view = last_view,
            .overlay = display.overlay(),
            .cockpit = if (ship.cockpit) |*cockpit| &cockpit.model else null,
            .backing = backing,
            .kills_shown = engine.input.controlActive(&keyboard, engine.input.controls.binding(.display_kills), false),
            .attachments = .{
                .camera = view.place.position,
                .frame_start = clock.frame_start,
                // A ship's glows burn by the throttle of its last update, dimmed by the share of
                // its engines still standing.
                .throttle = ship.live.last_throttle * ship.live.engines_intact,
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

/// The view a ship is shown in at first: view 0, as a mission's launch ends in, in `mode`. The
/// chase mode sits a fixed distance behind, which the camera keeps per ship type, so a ship whose
/// own radius is larger than that distance would not fit in it: the sandbox flies ships the game
/// never gives the player. Those are shown in the external view, which orbits at a distance
/// worked out from the ship's own size.
fn startingView(ship: Ship, mode: camera.CockpitMode) camera.View {
    if (mode != .chase) return .cockpit;
    const behind = camera.Chase.offset(@intCast(ship.ship_type)).distance;
    return if (ship.object.radius > behind) .external else .cockpit;
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

/// The DirectInput scan codes of F2 and F3, which the original leaves unbound.
const f2 = 0x3C;
const f3 = 0x3D;

/// A ship of a type, as `create_object` makes one: its model's meshes and its object's nodes, all
/// in an arena of its own so that the next can take its place.
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

const Ship = struct {
    arena: std.heap.ArenaAllocator,
    ship_type: usize,
    object: game.objects.Model,
    subject: camera.Subject,
    /// The live object the simulation flies, as `create_object` leaves one.
    live: game.gameobj.GameObject,
    /// Its type's flight stats, which `stats_load_ships` builds from `shipstats.bin`.
    flight: game.create.FlightModel,
    /// Its type's shield power, truncated as `stats_load_ships` keeps it.
    shield_power: i32,
    /// The most its guns' charge holds.
    gun_energy: f32,
    /// Whether its model can cloak.
    can_cloak: bool,
    /// Its type's schematic, which the display's ship status indicator draws, where the game has
    /// one.
    schematic: ?game.hud.Art,
    /// The cockpit's frame model, for a ship the player can fly, which the view ahead from the
    /// cockpit draws over the world; null for the rest.
    cockpit: ?Cockpit,

    const Cockpit = struct {
        source: *shp.Model,
        model: game.objects.Model,
    };

    fn load(
        resources: *game.bigfile.Hog,
        textures: *srtexture.Table,
        ship_stats: []align(1) const stats.Ship,
        glows: *const game.environfx.Glows,
        global_palette: ?*const [spr.palette_size]u8,
        ship_type: usize,
    ) !Ship {
        if (ship_type >= ship_stats.len) return error.NoShipStats;
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        errdefer arena.deinit();
        const gpa = arena.allocator();
        const model = try gpa.create(shp.Model);
        model.* = try .parse(gpa, try resources.readFile(gpa, game.create.models.ship_types[ship_type].model.?));
        const loaded = try gpa.create(game.srofiles.Loaded);
        loaded.* = try game.srofiles.modelLoad(gpa, textures, model, .{}, false);
        const library = try gpa.create(Library);
        library.* = .{ .gpa = gpa, .resources = resources, .textures = textures };
        var object: game.objects.Model = try .create(gpa, model, loaded, .{
            .light_sprite = try game.objects.lightSprite(textures),
            .glows = glows,
            .mounts = library.mounts(),
        });
        object.recentre(model);
        object.place(@splat(0), math.identity);
        // What `create_object` sets of a new object: undamaged, at rest, flying itself forward.
        var live: game.gameobj.GameObject = std.mem.zeroes(game.gameobj.GameObject);
        live.root.orientation = math.identity;
        live.root.next_orientation = math.identity;
        live.speed_factor = 1;
        live.armor_speed_factor = 1;
        live.engines_intact = 1;
        live.radius = object.radius;
        live.afterburner_fuel = @intFromFloat(100 * ship_stats[ship_type].afterburner_fuel);
        live.countermeasures = game.gameobj.countermeasures_when_created;
        // Each quadrant's shields and armour, six times the type's figure, less one. The sandbox
        // fits no guns, so the gun mode stays at nothing: `create_object` sets it by the groups of
        // guns the ship's loadout gives it.
        const shield_power: i32 = @intFromFloat(ship_stats[ship_type].shield_power);
        const armor_class: i32 = @intFromFloat(ship_stats[ship_type].armor_class);
        live.shields = @splat(@floatFromInt(6 * shield_power - 1));
        live.armor = @splat(@floatFromInt(6 * armor_class - 1));
        // Its guns full.
        live.gun_charge = ship_stats[ship_type].gun_energy;
        const schematic: ?game.hud.Art = if (game.create.models.ship_types[ship_type].schematic) |name| found: {
            const bytes = resources.readFile(gpa, name) catch |err| {
                std.log.warn("the schematic {s} is left out: {s}", .{ name, @errorName(err) });
                break :found null;
            };
            break :found try .init(gpa, try spr.Sprite.parse(bytes), global_palette);
        } else null;
        // The cockpit the mission's start loads for a ship the player can fly.
        const cockpit: ?Cockpit = if (game.main.playerShip(@intCast(ship_type))) |player| found: {
            const source = try gpa.create(shp.Model);
            source.* = shp.Model.parse(gpa, resources.readFile(gpa, player.cockpit) catch |err| {
                std.log.warn("the cockpit {s} is left out: {s}", .{ player.cockpit, @errorName(err) });
                break :found null;
            }) catch |err| {
                std.log.warn("the cockpit {s} is left out: {s}", .{ player.cockpit, @errorName(err) });
                break :found null;
            };
            const built = try gpa.create(game.srofiles.Loaded);
            built.* = try game.srofiles.modelLoad(gpa, textures, source, .{}, false);
            break :found .{ .source = source, .model = try game.main.createCockpit(gpa, source, built) };
        } else null;
        return .{
            .arena = arena,
            .ship_type = ship_type,
            .live = live,
            .cockpit = cockpit,
            .flight = game.create.flightModel(ship_stats[ship_type]),
            .shield_power = shield_power,
            .gun_energy = ship_stats[ship_type].gun_energy,
            .can_cloak = model.header.flags.cloak,
            .schematic = schematic,
            .object = object,
            .subject = .{
                .position = @splat(0),
                .orientation = math.identity,
                .eye = .{ model.header.eye.x, model.header.eye.y, model.header.eye.z },
                .radius = object.radius,
                .motion = .{ .ship_type = @intCast(ship_type) },
            },
        };
    }

    fn unload(ship: *Ship) void {
        ship.arena.deinit();
    }
};

/// The font the display's readouts are drawn with.
const hud_font = "FONT.FNT";

/// What draws the head-up display over the finished scene. `srcore.render` reaches it where
/// Surrender reaches `hud_draw`, through the overlay it is handed.
const Display = struct {
    art: game.hud.Art,
    font: game.hud.Opened,
    gpa: Allocator,
    /// Filled in each frame, before the scene is drawn.
    target: srd3d.device.Device,
    screen: [2]u32,
    /// Last frame's view, which is what `hud_draw` reads to know whether to draw the instruments.
    last_view: camera.View = .cockpit,
    /// What the cockpit view shows, which leaves the reticle out of the chase view.
    cockpit_mode: camera.CockpitMode = .cockpit,
    ship: *Ship,
    clock: *const game.main.Clock,
    player: *const engine.input.Player,
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
        display.drawShapes() catch |err| switch (err) {
            error.OutOfMemory => |out| return out,
            // A shape the file does not hold draws nothing, as it does in the game.
            else => {},
        };
    }

    /// What `hud_draw` draws, in its order.
    fn drawShapes(display: *Display) (spr.Error || Allocator.Error)!void {
        const frame_duration = display.clock.frame_duration;
        const live = &display.ship.live;
        const white: [4]f32 = .{ 1, 1, 1, 1 };
        const scale = game.hud.scaleFor(display.screen);
        const state = &display.state;
        const instrumented = game.hud.instrumented(display.last_view);
        // The devices' charges run in every view.
        state.runCharges(live, frame_duration, false);
        if (instrumented) {
            try state.drawJumpPrompt(&display.ready, &display.art, display.gpa, display.target, display.screen, frame_duration, white, scale);
            // The sandbox runs no mission, so nothing is scanned for.
            try state.drawEjectMarker(&display.art, display.gpa, display.target, display.screen, frame_duration, white, scale);
            try state.drawScanner(false, display.clock.game_ticks, &display.art, display.gpa, display.target, display.screen, white, scale);
            const lit = state.lit(live, display.player.matching_speed, false, frame_duration);
            try state.drawLights(&display.art, display.gpa, display.target, display.screen, lit, frame_duration, white, scale);
        }
        // The other views are named instead.
        try game.hud.drawViewName(&display.font, display.gpa, display.target, display.screen, display.last_view, display.strings.*, white, scale);
        if (instrumented) try display.drawInstruments(white, scale);
        // The windows move on in every view, after the instruments.
        try state.windows.frame(&display.art, display.gpa, display.target, display.screen, display.last_view, frame_duration, white, scale);
    }

    /// What `hud_draw` draws only in the view ahead from the cockpit.
    fn drawInstruments(display: *Display, white: [4]f32, scale: f32) (spr.Error || Allocator.Error)!void {
        const frame_duration = display.clock.frame_duration;
        const live = &display.ship.live;
        const state = &display.state;
        for ([_]game.hud.Readout{ .fuel, .skull, .coil }) |readout| {
            if (!state.shows(readout, frame_duration)) continue;
            const value: i32 = switch (readout) {
                .fuel => @divTrunc(live.afterburner_fuel, 100),
                // The tally a mission's start zeroes; the sandbox runs no mission, so it stays 0.
                .skull => 0,
                .coil => live.countermeasures,
            };
            try readout.draw(&display.art, &display.font, display.gpa, display.target, display.screen, value, white, scale);
        }
        if (display.ship.schematic) |*schematic| {
            try game.hud.ShipStatus.drawSchematic(schematic, display.ship.arena.allocator(), display.target, display.screen, white, scale);
        }
        try game.hud.ShipStatus.draw(&display.art, display.gpa, display.target, display.screen, live.shields, display.ship.shield_power, white, scale);
        try game.hud.drawCluster(&display.art, &display.font, display.gpa, display.target, display.screen, .{
            .throttle = live.throttle,
            .speed = live.speed,
            .max_speed = display.ship.flight.max_speed,
            .charge = live.gun_charge,
            .full_charge = display.ship.gun_energy,
        }, white, scale);
        try game.hud.drawRadar(&display.art, display.gpa, display.target, display.screen, state.radar_rings, white, scale);
        game.hud.stepRadarZoom(state, display.clock.game_ticks);
        // The sandbox has no target, so blind fire has nothing to aim at. It would aim with its
        // guns not all firing; the sandbox fits no guns, so no group of them is ever the one.
        const blind_fire: game.hud.BlindFire = if (state.blind_fire_fitted and state.blind_fire and !live.gun_mode.all) .on else .off;
        const aims = try game.hud.drawReticle(state, &display.art, display.gpa, display.target, display.screen, display.cockpit_mode, null, blind_fire, frame_duration, white, scale);
        live.blind_fire_aim = @intFromBool(aims);
        try game.hud.drawClock(
            &display.font,
            display.gpa,
            display.target,
            display.screen,
            display.clock.play.minutes,
            display.clock.play.seconds,
            white,
            scale,
        );
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
}

test nextShipType {
    // The Predator's neighbours: the Nagi after it, and the last type with a model before it.
    try std.testing.expectEqual(1, nextShipType(0, 1));
    const last = nextShipType(0, -1);
    try std.testing.expect(game.create.models.ship_types[last].model != null);
    try std.testing.expectEqual(0, nextShipType(last, 1));
}

test Options {
    try std.testing.expectEqualStrings(".", (try Options.parse(&.{})).directory);
    const given = try Options.parse(&.{ "game/install", "--ship", "3" });
    try std.testing.expectEqualStrings("game/install", given.directory);
    try std.testing.expectEqual(3, given.ship);
    try std.testing.expectEqual(camera.CockpitSetting.cockpit, given.cockpit);
    try std.testing.expectEqual(camera.CockpitSetting.chase, (try Options.parse(&.{ "--view", "1" })).cockpit);
    try std.testing.expectError(error.Usage, Options.parse(&.{ "--view", "3" }));
    try std.testing.expectError(error.Usage, Options.parse(&.{"--ship"}));
    try std.testing.expectError(error.Usage, Options.parse(&.{ "--ship", "0x0E" }));
    try std.testing.expectError(error.Usage, Options.parse(&.{"--bogus"}));
    try std.testing.expectEqualStrings("shot.png", (try Options.parse(&.{ "--screenshot", "shot.png" })).screenshot.?);

    // The improvements on by default; the original's look, and single settings after it.
    const plain = try Options.parse(&.{});
    try std.testing.expectEqual(platform.gpu.Settings{}, plain.settings);
    try std.testing.expectEqual(null, plain.fps);
    const retro = try Options.parse(&.{ "--original", "--msaa", "8", "--no-vsync", "--fps", "0" });
    try std.testing.expect(retro.settings.sixteen_bit);
    try std.testing.expectEqual(.original, retro.settings.filter);
    try std.testing.expectEqual(8, retro.settings.samples);
    try std.testing.expect(!retro.settings.vsync);
    try std.testing.expectEqual(0, retro.fps.?);
    const chosen = try Options.parse(&.{ "--filter", "trilinear", "--16-bit", "--software", "--fullscreen" });
    try std.testing.expectEqual(.trilinear, chosen.settings.filter);
    try std.testing.expect(chosen.settings.sixteen_bit and chosen.software and chosen.fullscreen);
    try std.testing.expectError(error.Usage, Options.parse(&.{ "--msaa", "3" }));
    try std.testing.expectError(error.Usage, Options.parse(&.{ "--filter", "sharp" }));
    try std.testing.expectError(error.Usage, Options.parse(&.{ "--fps", "-1" }));
    try std.testing.expectError(error.Usage, Options.parse(&.{ "--fps", "nan" }));
}

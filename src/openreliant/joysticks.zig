//! `openreliant joysticks`: lists the connected joysticks and gamepads, shows which one the game
//! will use and, for joysticks, which axis is used for what, and whether `starlancer.ini` chose it.
//! With `--watch` it shows live input from the selected controller as the game sees it, and for a
//! joystick every axis by the number `ThrottleAxis` and `TwistAxis` take, to help find axis and
//! button numbers for `starlancer.ini`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const help = @import("help.zig");
const joystick = platform.joystick;
const input = openreliant.engine.input;
const interface = openreliant.engine.game.interface;
const Profile = openreliant.engine.profile.Profile;

pub const usage =
    \\usage: openreliant joysticks [<game-directory>] [--watch]
    \\  <game-directory>  the folder StarLancer is installed in, for the settings in its
    \\                    starlancer.ini; the current directory by default
    \\  --watch           show live input from the controller the game uses, until Ctrl+C
    \\  -h, --help        show this page
    \\
;

pub const Options = struct {
    directory: []const u8 = ".",
    watch: bool = false,

    pub fn parse(args: []const [:0]const u8) error{Usage}!Options {
        var options: Options = .{};
        var directory: ?[]const u8 = null;
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--watch")) {
                options.watch = true;
            } else if (std.mem.startsWith(u8, arg, "-") or directory != null) {
                return error.Usage;
            } else {
                directory = arg;
            }
        }
        if (directory) |given| options.directory = given;
        return options;
    }
};

/// Runs `openreliant joysticks` with the given arguments. Returns the exit code.
pub fn main(io: Io, arena: Allocator, args: []const [:0]const u8) !u8 {
    var out_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .initStreaming(.stdout(), io, &out_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    if (help.asked(args)) {
        try out.writeAll(usage);
        return 0;
    }
    const options = Options.parse(args) catch {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    const settings_file: Profile = settings: {
        var directory = Io.Dir.cwd().openDir(io, options.directory, .{}) catch break :settings .empty;
        defer directory.close(io);
        break :settings .read(io, arena, directory);
    };
    const setup: joystick.Setup = .read(settings_file);

    try joystick.init(.tool);
    defer joystick.deinit();
    const mappings = joystick.addMappings(try std.fs.path.joinZ(arena, &.{ options.directory, joystick.mappings_name }));
    if (mappings > 0) try out.print("Read {d} gamepad {s} from {s}.\n", .{ mappings, if (mappings == 1) "mapping" else "mappings", joystick.mappings_name });
    joystick.update();
    const found = try joystick.attached(arena);
    if (found.len == 0) {
        try out.writeAll("No joystick or gamepad is attached.\n");
        return 1;
    }
    const chosen = joystick.choose(found, setup.preference).?;
    for (found, 1..) |each, number| {
        var controller = joystick.Controller.open(each, setup) catch {
            try out.print("{d}. {s}: can't be opened.\n", .{ number, each.name });
            continue;
        };
        defer controller.close();
        try describe(out, number, each, &controller, setup, each.id == chosen.id);
    }
    try out.flush();
    if (!options.watch) return 0;

    var controller = try joystick.Controller.open(chosen, setup);
    defer controller.close();
    var devices: input.Devices = .{};
    devices.joystick.open(controller.device(), interface.deadZone(settings_file));
    try out.print("\nShowing input from {s} as the game sees it. Press Ctrl+C to stop.\n", .{chosen.name});
    try out.flush();
    var last: [watch_size]u8 = undefined;
    var last_len: usize = 0;
    while (true) {
        joystick.update();
        devices.joystick.read();
        if (devices.joystick.device == null) {
            try out.writeAll("The controller was disconnected.\n");
            return 1;
        }
        var lines_buffer: [watch_size]u8 = undefined;
        var lines: Io.Writer = .fixed(&lines_buffer);
        var state_buffer: [256]u8 = undefined;
        lines.writeAll(state(&state_buffer, devices.joystick)) catch {};
        if (controller.handle == .joystick) {
            const plain = controller.sdlJoystick();
            var readings: [max_axes]i16 = undefined;
            const axes = @min(platform.joystick.axisCount(plain), max_axes);
            for (readings[0..axes], 0..) |*reading, index| reading.* = platform.joystick.axisValue(plain, @intCast(index));
            var axes_buffer: [watch_size]u8 = undefined;
            lines.print("\n  {s}", .{axesLine(&axes_buffer, readings[0..axes], controller.layout)}) catch {};
        }
        const text = lines.buffered();
        if (!std.mem.eql(u8, text, last[0..last_len])) {
            try out.print("{s}\n", .{text});
            try out.flush();
            @memcpy(last[0..text.len], text);
            last_len = text.len;
        }
        try io.sleep(.fromMilliseconds(100), .awake);
    }
}

/// Room for what `--watch` prints at a time, and the axes it shows at most.
const watch_size = 1024;
const max_axes = 32;

/// Prints a controller's entry in the list: its name, type, axis layout, and the setting that
/// chooses it.
fn describe(out: *Io.Writer, number: usize, found: joystick.Found, controller: *joystick.Controller, setup: joystick.Setup, chosen: bool) !void {
    const plain = controller.sdlJoystick();
    try out.print("{d}. {s}{s}\n   {s}, USB ID {x:0>4}:{x:0>4}", .{
        number,
        found.name,
        if (chosen) " (used by the game)" else "",
        @tagName(found.kind),
        found.vendor,
        found.product,
    });
    switch (controller.handle) {
        .gamepad => try out.writeAll(
            \\
            \\   Left stick: pitch and turn. Right stick: roll and speed. D-pad: look around.
            \\
        ),
        .joystick => {
            try count(out, platform.joystick.axisCount(plain), "axis", "axes");
            try count(out, platform.joystick.buttonCount(plain), "button", "buttons");
            try count(out, platform.joystick.hatCount(plain), "hat", "hats");
            try out.writeAll("\n   ");
            try writeLayout(out, controller.layout, setup);
            try out.writeAll("\n");
        },
    }
    // `Joystick=` picks the first controller whose name holds what it gives.
    try out.print("   To choose it: Joystick={s}\n", .{found.name});
}

/// A joystick's axis for each of its uses, and for the throttle and the twist, whether it is the
/// automatic choice or the one `starlancer.ini` gives.
fn writeLayout(out: *Io.Writer, layout: joystick.Layout, setup: joystick.Setup) !void {
    for (std.enums.values(joystick.Layout.Role), 0..) |which, index| {
        if (index > 0) try out.writeAll(", ");
        try out.print("{s}: ", .{label(which)});
        if (layout.axisFor(which)) |axis| try out.print("axis {d}", .{axis}) else try out.writeAll("none");
        const choice = switch (which) {
            .x, .y => continue,
            .throttle => setup.throttle,
            .twist => setup.twist,
        };
        try out.writeAll(switch (choice) {
            .guess => " (automatic)",
            else => if (which == .throttle) " (ThrottleAxis)" else " (TwistAxis)",
        });
    }
}

/// What the list calls each use of an axis.
fn label(which: joystick.Layout.Role) []const u8 {
    return switch (which) {
        .x => "X",
        .y => "Y",
        .throttle => "throttle",
        .twist => "twist",
    };
}

/// Every axis of a joystick by its number, as `ThrottleAxis` and `TwistAxis` take it: its reading
/// as a whole percentage of its travel either way, which the axis's noise rarely moves, and what the
/// game reads it as.
fn axesLine(buffer: []u8, readings: []const i16, layout: joystick.Layout) []const u8 {
    var line: Io.Writer = .fixed(buffer);
    line.writeAll("axes:") catch {};
    for (readings, 0..) |reading, index| {
        const share = @divTrunc(@as(i32, reading) * 100, std.math.maxInt(i16));
        line.print("  {d}: {d}%", .{ index, share }) catch {};
        if (layout.role(@intCast(index))) |which| line.print(" ({s})", .{label(which)}) catch {};
    }
    return line.buffered();
}

fn count(out: *Io.Writer, how_many: u32, one: []const u8, many: []const u8) !void {
    try out.print(", {d} {s}", .{ how_many, if (how_many == 1) one else many });
}

/// Formats the joystick's state, as the game sees it, on one line.
fn state(buffer: []u8, read: input.Joystick) []const u8 {
    var line: Io.Writer = .fixed(buffer);
    const values = read.state;
    line.print("X {d}  Y {d}", .{ values.x, values.y }) catch {};
    if (read.axes.z) line.print("  throttle {d}", .{values.z}) catch {};
    if (read.axes.slider) line.print("  slider {d}", .{values.sliders[0]}) catch {};
    if (read.axes.rz) line.print("  twist {d}", .{values.rz}) catch {};
    if (read.hats > 0) {
        if (values.hat(0)) |angle| {
            line.print("  hat {d}", .{angle / 100}) catch {};
        } else {
            line.writeAll("  hat -") catch {};
        }
    }
    line.writeAll("  buttons down:") catch {};
    for (values.buttons[0..read.buttons], 0..) |button, index| {
        if (button != 0) line.print(" {d}", .{index}) catch {};
    }
    return line.buffered();
}

test Options {
    try std.testing.expectEqualStrings(".", (try Options.parse(&.{})).directory);
    const given = try Options.parse(&.{ "game", "--watch" });
    try std.testing.expectEqualStrings("game", given.directory);
    try std.testing.expect(given.watch);
    try std.testing.expectError(error.Usage, Options.parse(&.{"--bogus"}));
    try std.testing.expectError(error.Usage, Options.parse(&.{ "a", "b" }));
}

test state {
    var read: input.Joystick = .{ .buttons = 12, .hats = 1 };
    read.axes.z = true;
    read.state.x = -1000;
    read.state.z = 250;
    read.state.pov = @splat(input.JoystickState.centred);
    read.state.pov[0] = 9000;
    read.state.buttons[0] = input.JoystickState.pressed;
    read.state.buttons[11] = input.JoystickState.pressed;
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("X -1000  Y 0  throttle 250  hat 90  buttons down: 0 11", state(&buffer, read));
    read.state.pov[0] = input.JoystickState.centred;
    try std.testing.expectEqualStrings("X -1000  Y 0  throttle 250  hat -  buttons down: 0 11", state(&buffer, read));
}

test writeLayout {
    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    const layout: joystick.Layout = .{ .x = 0, .y = 1, .throttle = 2, .twist = 4 };
    try writeLayout(&out, layout, .{ .twist = .{ .axis = 4 } });
    try std.testing.expectEqualStrings("X: axis 0, Y: axis 1, throttle: axis 2 (automatic), twist: axis 4 (TwistAxis)", out.buffered());
    out = .fixed(&buffer);
    try writeLayout(&out, .{ .x = 0, .y = 1 }, .{ .throttle = .none });
    try std.testing.expectEqualStrings("X: axis 0, Y: axis 1, throttle: none (ThrottleAxis), twist: none (automatic)", out.buffered());
}

test axesLine {
    var buffer: [256]u8 = undefined;
    const layout: joystick.Layout = .{ .x = 0, .y = 1, .throttle = 2, .twist = 4 };
    try std.testing.expectEqualStrings(
        "axes:  0: -100% (X)  1: 0% (Y)  2: 50% (throttle)  3: 100%  4: 15% (twist)",
        axesLine(&buffer, &.{ -32768, 0, 16384, 32767, 5000 }, layout),
    );
}

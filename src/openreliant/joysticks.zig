//! `openreliant joysticks`: lists the connected joysticks and gamepads, shows which one the game
//! will use and, for joysticks, which axis is used for what. With `--watch` it shows live input from
//! the selected controller as the game sees it, to help find axis and button numbers for
//! `starlancer.ini`.

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
        try describe(out, number, each, &controller, each.id == chosen.id);
    }
    try out.flush();
    if (!options.watch) return 0;

    var controller = try joystick.Controller.open(chosen, setup);
    defer controller.close();
    var devices: input.Devices = .{};
    devices.joystick.open(controller.device(), interface.deadZone(settings_file));
    try out.print("\nShowing input from {s} as the game sees it. Press Ctrl+C to stop.\n", .{chosen.name});
    try out.flush();
    var last: [256]u8 = undefined;
    var last_len: usize = 0;
    while (true) {
        joystick.update();
        devices.joystick.read();
        if (devices.joystick.device == null) {
            try out.writeAll("The controller was disconnected.\n");
            return 1;
        }
        var line_buffer: [256]u8 = undefined;
        const line = state(&line_buffer, devices.joystick);
        if (!std.mem.eql(u8, line, last[0..last_len])) {
            try out.print("{s}\n", .{line});
            try out.flush();
            @memcpy(last[0..line.len], line);
            last_len = line.len;
        }
        try io.sleep(.fromMilliseconds(100), .awake);
    }
}

/// Prints a controller's entry in the list: its name, type and axis layout.
fn describe(out: *Io.Writer, number: usize, found: joystick.Found, controller: *joystick.Controller, chosen: bool) !void {
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
            const layout = controller.layout;
            const roles = [_]struct { []const u8, ?u8 }{
                .{ "X", layout.x },
                .{ "Y", layout.y },
                .{ "throttle", layout.throttle },
                .{ "twist", layout.twist },
            };
            try out.writeAll("\n  ");
            for (roles, 0..) |pair, index| {
                try out.writeAll(if (index == 0) " " else ", ");
                if (pair[1]) |axis| {
                    try out.print("{s}: axis {d}", .{ pair[0], axis });
                } else {
                    try out.print("{s}: none", .{pair[0]});
                }
            }
            try out.writeAll("\n");
        },
    }
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

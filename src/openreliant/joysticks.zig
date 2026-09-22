//! `openreliant joysticks`: lists the joysticks and gamepads attached, and how the game reads each:
//! which one it plays with, and which of a joystick's axes it takes for what. With `--watch` it
//! shows the one the game plays with as the game reads it, live, so that an axis's or a button's
//! number can be found for `starlancer.ini`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const joystick = platform.joystick;
const input = openreliant.engine.input;
const interface = openreliant.engine.game.interface;
const Profile = openreliant.engine.profile.Profile;

pub const usage =
    \\usage: openreliant joysticks [<game-directory>] [--watch]
    \\  <game-directory>  where StarLancer is installed, whose starlancer.ini can pick the
    \\                    joystick and its axes; the current directory by default
    \\  --watch           show the joystick the game plays with, as the game reads it, until
    \\                    Ctrl+C
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

/// `openreliant joysticks`, given its arguments. Returns the exit code.
pub fn main(io: Io, arena: Allocator, args: []const [:0]const u8) !u8 {
    var out_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .initStreaming(.stdout(), io, &out_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    const options = Options.parse(args) catch {
        try out.writeAll(usage);
        return 2;
    };
    const settings_file: Profile = .{ .text = settings: {
        var directory = Io.Dir.cwd().openDir(io, options.directory, .{}) catch break :settings "";
        defer directory.close(io);
        break :settings directory.readFileAlloc(io, "starlancer.ini", arena, .limited(1 << 20)) catch "";
    } };

    try joystick.init(.tool);
    defer joystick.deinit();
    const mappings = joystick.addMappings(try std.fs.path.joinZ(arena, &.{ options.directory, "gamecontrollerdb.txt" }));
    if (mappings > 0) try out.print("Read {d} gamepad {s} from gamecontrollerdb.txt.\n", .{ mappings, if (mappings == 1) "mapping" else "mappings" });
    joystick.update();
    const found = try joystick.attached(arena);
    if (found.len == 0) {
        try out.writeAll("No joystick or gamepad is attached.\n");
        return 1;
    }
    const chosen = joystick.choose(found, settings_file.value("JoyConfig", "Joystick")).?;
    const throttle: joystick.Choice = .parse(settings_file.value("JoyConfig", "ThrottleAxis"));
    const twist: joystick.Choice = .parse(settings_file.value("JoyConfig", "TwistAxis"));
    for (found, 1..) |each, number| {
        var controller = joystick.Controller.open(each, throttle, twist) catch {
            try out.print("{d}. {s}: SDL can't open it.\n", .{ number, each.name });
            continue;
        };
        defer controller.close();
        try describe(out, number, each, &controller, each.id == chosen.id);
    }
    try out.flush();
    if (!options.watch) return 0;

    var controller = try joystick.Controller.open(chosen, throttle, twist);
    defer controller.close();
    var devices: input.Devices = .{};
    devices.joystick.open(controller.device(), interface.deadZone(settings_file));
    try out.print("\nWatching {s} as the game reads it; Ctrl+C stops.\n", .{chosen.name});
    try out.flush();
    var last: [256]u8 = undefined;
    var last_len: usize = 0;
    while (true) {
        joystick.update();
        devices.joystick.read();
        if (devices.joystick.device == null) {
            try out.writeAll("It was unplugged.\n");
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

/// A controller's line in the list, and how the game reads it.
fn describe(out: *Io.Writer, number: usize, found: joystick.Found, controller: *joystick.Controller, chosen: bool) !void {
    const plain = controller.sdlJoystick();
    try out.print("{d}. {s}{s}\n   {s}, USB ID {x:0>4}:{x:0>4}", .{
        number,
        found.name,
        if (chosen) " (the game plays with this one)" else "",
        @tagName(found.kind),
        found.vendor,
        found.product,
    });
    switch (controller.handle) {
        .gamepad => try out.writeAll(
            \\
            \\   The left stick steers, the right stick rolls and moves the throttle, the pad glances.
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

/// The joystick's state as the game reads it, on one line.
fn state(buffer: []u8, read: input.Joystick) []const u8 {
    var line: Io.Writer = .fixed(buffer);
    const values = read.state;
    line.print("X {d}  Y {d}", .{ values.x, values.y }) catch {};
    if (read.axes.z) line.print("  throttle {d}", .{values.z}) catch {};
    if (read.axes.slider) line.print("  slider {d}", .{values.sliders[0]}) catch {};
    if (read.axes.rz) line.print("  twist {d}", .{values.rz}) catch {};
    if (read.hats > 0) {
        if (values.pov[0] == input.JoystickState.centred) {
            line.writeAll("  hat -") catch {};
        } else {
            line.print("  hat {d}", .{values.pov[0] / 100}) catch {};
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
    read.state.buttons[0] = 0x80;
    read.state.buttons[11] = 0x80;
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("X -1000  Y 0  throttle 250  hat 90  buttons down: 0 11", state(&buffer, read));
}

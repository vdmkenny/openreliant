//! Joysticks and gamepads, with SDL3, in place of DirectInput's joystick. Each controller SDL finds
//! reaches the game as the joystick DirectInput would have handed it
//! (`engine.input.JoystickDevice`): axes in the ranges the game sets, read through its dead zone,
//! 32 buttons and up to four hats. SDL reads a wide range of controllers, old and new, on every
//! system: flight sticks, throttles, wheels and old gameport sticks on USB adapters as plain
//! joysticks, and the gamepads its mappings know, Xbox, PlayStation and Nintendo pads and many
//! others, in one layout.

const std = @import("std");
const c = @import("sdl");
const openreliant = @import("openreliant");
const input = openreliant.engine.input;
const Axis = input.Axis;
const JoystickState = input.JoystickState;
const GamepadButton = input.GamepadButton;

pub const Error = error{Sdl};

/// SDL's last error, logged, as an error.
fn fail(what: []const u8) Error {
    std.log.scoped(.sdl).err("{s}: {s}", .{ what, c.SDL_GetError() });
    return error.Sdl;
}

/// What SDL's joystick support serves.
pub const Mode = enum {
    /// The game, which handles SDL's events, Ctrl+C's quit among them, and reads the controllers
    /// while its window is in front.
    game,
    /// A tool without a window, which reads no events: the controllers are read whatever is in
    /// front, and Ctrl+C ends it as it ends any program, rather than SDL turning it into an event.
    tool,
};

/// Starts SDL's joystick and gamepad support. SDL then reports each controller already attached as
/// plugged in.
pub fn init(mode: Mode) Error!void {
    if (mode == .tool) {
        _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
        _ = c.SDL_SetHint(c.SDL_HINT_NO_SIGNAL_HANDLERS, "1");
    }
    if (!c.SDL_InitSubSystem(c.SDL_INIT_GAMEPAD)) return fail("SDL_InitSubSystem");
}

pub fn deinit() void {
    c.SDL_QuitSubSystem(c.SDL_INIT_GAMEPAD);
}

/// The gamepad mappings in the file at `path`, in SDL's format, added to those SDL knows, so that
/// a gamepad it does not know is read as one. Returns how many there were; a missing file has
/// none.
pub fn addMappings(path: [:0]const u8) u32 {
    return @intCast(@max(c.SDL_AddGamepadMappingsFromFile(path), 0));
}

/// Has SDL read the controllers now, rather than as it next handles events.
pub fn update() void {
    c.SDL_UpdateJoysticks();
}

/// How many axes, buttons and hats SDL finds on a joystick.
pub fn axisCount(plain: *c.SDL_Joystick) u32 {
    return @intCast(@max(c.SDL_GetNumJoystickAxes(plain), 0));
}

pub fn buttonCount(plain: *c.SDL_Joystick) u32 {
    return @intCast(@max(c.SDL_GetNumJoystickButtons(plain), 0));
}

pub fn hatCount(plain: *c.SDL_Joystick) u32 {
    return @intCast(@max(c.SDL_GetNumJoystickHats(plain), 0));
}

/// A controller SDL has found, before it is opened.
pub const Found = struct {
    id: c.SDL_JoystickID,
    name: []const u8,
    kind: input.JoystickDevice.Kind,
    /// What SDL takes the controller for, from its maker's description or from what SDL knows of it.
    sdl_type: c.SDL_JoystickType,
    vendor: u16,
    product: u16,
};

/// The controllers attached now, in the order SDL found them.
pub fn attached(arena: std.mem.Allocator) ![]Found {
    var count: c_int = 0;
    const ids = c.SDL_GetJoysticks(&count) orelse return fail("SDL_GetJoysticks");
    defer c.SDL_free(ids);
    const found = try arena.alloc(Found, @intCast(count));
    for (found, ids[0..found.len]) |*each, id| {
        const name = c.SDL_GetJoystickNameForID(id);
        each.* = .{
            .id = id,
            .name = try arena.dupe(u8, if (name != null) std.mem.span(name) else "Unnamed controller"),
            .kind = if (c.SDL_IsGamepad(id)) .gamepad else .joystick,
            .sdl_type = c.SDL_GetJoystickTypeForID(id),
            .vendor = c.SDL_GetJoystickVendorForID(id),
            .product = c.SDL_GetJoystickProductForID(id),
        };
    }
    return found;
}

/// The controller the game plays with. With `Joystick` in `starlancer.ini`'s `JoyConfig`,
/// `preference`, the first whose name holds it. Otherwise the first joystick that is not a gamepad,
/// as a player who plugs in a flight stick means to fly with it, leaving out a throttle on its own;
/// then the first gamepad; then whatever there is. The game itself takes the first joystick with
/// force feedback, then the first of any.
pub fn choose(found: []const Found, preference: ?[]const u8) ?Found {
    if (preference) |text| {
        if (text.len > 0) for (found) |each| {
            if (std.ascii.indexOfIgnoreCase(each.name, text) != null) return each;
        };
    }
    for (found) |each| {
        if (each.kind == .joystick and each.sdl_type != c.SDL_JOYSTICK_TYPE_THROTTLE) return each;
    }
    for (found) |each| {
        if (each.kind == .gamepad) return each;
    }
    return if (found.len > 0) found[0] else null;
}

/// What `ThrottleAxis` or `TwistAxis` in `starlancer.ini`'s `JoyConfig` asks for, added for the
/// port: an axis by SDL's number, counted from 0 as `openreliant joysticks` shows it, or none for
/// `-1`, or the port's guess without an entry.
pub const Choice = union(enum) {
    guess,
    none,
    axis: u8,

    pub fn parse(value: ?[]const u8) Choice {
        const text = std.mem.trim(u8, value orelse return .guess, " \t");
        const number = std.fmt.parseInt(i16, text, 10) catch return .guess;
        if (number < 0) return .none;
        return .{ .axis = std.math.cast(u8, number) orelse return .none };
    }
};

/// The axes a plain joystick's axes stand for, by SDL's numbering: X and Y, the throttle, which
/// the game reads as Z, and the twist, its Rz.
pub const Layout = struct {
    x: ?u8 = null,
    y: ?u8 = null,
    throttle: ?u8 = null,
    twist: ?u8 = null,

    /// The layout of a joystick with `axes` axes, as the joysticks most seen have theirs. SDL
    /// numbers a joystick's axes in the order of the kinds they are, X, Y, Z, Rx, Ry, Rz, sliders,
    /// on every system, but does not say which kinds a joystick has. So X and Y are the first two;
    /// with three axes the third is taken for a throttle, with four for a twist, with the throttle
    /// last, as on most flight sticks; with more, the third for a throttle and the fourth, or with
    /// six or more the sixth, for the twist, as on throttle and stick sets. A throttle on its own
    /// has its first axis for the throttle, and a gamepad SDL has no mapping for, which it knows
    /// by the maker's description, the third for the twist and no throttle.
    pub fn guess(axes: u8, sdl_type: c.SDL_JoystickType) Layout {
        if (sdl_type == c.SDL_JOYSTICK_TYPE_THROTTLE) return .{ .throttle = if (axes > 0) 0 else null };
        // A gamepad SDL has no mapping for: the left stick steers, the right stick's first axis
        // twists, and with no throttle axis the keys and buttons step the throttle.
        if (sdl_type == c.SDL_JOYSTICK_TYPE_GAMEPAD) {
            return .{ .x = if (axes > 0) 0 else null, .y = if (axes > 1) 1 else null, .twist = if (axes > 2) 2 else null };
        }
        var layout: Layout = .{};
        if (axes > 0) layout.x = 0;
        if (axes > 1) layout.y = 1;
        switch (axes) {
            0, 1, 2 => {},
            3 => layout.throttle = 2,
            4 => layout = .{ .x = 0, .y = 1, .twist = 2, .throttle = 3 },
            5 => layout = .{ .x = 0, .y = 1, .throttle = 2, .twist = 3 },
            else => layout = .{ .x = 0, .y = 1, .throttle = 2, .twist = 5 },
        }
        return layout;
    }

    /// The layout with `throttle` and `twist` as `starlancer.ini` asks, on a joystick with `axes`.
    pub fn with(layout: Layout, axes: u8, throttle: Choice, twist: Choice) Layout {
        var chosen = layout;
        chosen.throttle = pick(layout.throttle, axes, throttle);
        chosen.twist = pick(layout.twist, axes, twist);
        return chosen;
    }

    fn pick(guessed: ?u8, axes: u8, choice: Choice) ?u8 {
        return switch (choice) {
            .guess => guessed,
            .none => null,
            .axis => |axis| if (axis < axes) axis else null,
        };
    }

    /// Each of the game's axes the layout gives, and the joystick's axis it comes from.
    fn sources(layout: Layout) [4]struct { Axis, ?u8 } {
        return .{ .{ .x, layout.x }, .{ .y, layout.y }, .{ .z, layout.throttle }, .{ .rz, layout.twist } };
    }
};

/// A hat as SDL gives it: a bit for each way it is pushed.
const Hat = packed struct(u8) {
    up: bool = false,
    right: bool = false,
    down: bool = false,
    left: bool = false,
    _unused: u4 = 0,
};

/// DirectInput's point of view for each position of a hat, in hundredths of a degree clockwise
/// from ahead, or centred. Two opposite ways at once cancel.
const hat_angles: [16]u32 = angles: {
    var angles: [16]u32 = undefined;
    for (&angles, 0..) |*angle, bits| {
        const hat: Hat = @bitCast(@as(u8, bits));
        const across = @as(i8, @intFromBool(hat.right)) - @intFromBool(hat.left);
        const along = @as(i8, @intFromBool(hat.down)) - @intFromBool(hat.up);
        angle.* = switch (along) {
            -1 => switch (across) {
                -1 => 31500,
                0 => 0,
                else => 4500,
            },
            0 => switch (across) {
                -1 => 27000,
                0 => JoystickState.centred,
                else => 9000,
            },
            else => switch (across) {
                -1 => 22500,
                0 => 18000,
                else => 13500,
            },
        };
    }
    break :angles angles;
};

fn pov(hat: Hat) u32 {
    return hat_angles[@as(u4, @truncate(@as(u8, @bitCast(hat))))];
}

/// A raw axis value, -32768 to 32767, as DirectInput reports it with `range` and `dead_zone`, in
/// hundredths of a percent of the travel from the centre: within the dead zone the axis reads
/// as the middle of its range, and beyond it the rest of its travel spans the range.
pub fn scale(raw: i16, range: [2]i32, dead_zone: u16) i32 {
    const position = @max(@as(f32, @floatFromInt(raw)) / 32767, -1);
    const zone = @as(f32, @floatFromInt(@min(dead_zone, 10000))) / 10000;
    const beyond = @abs(position) - zone;
    const live: f32 = if (beyond <= 0) 0 else std.math.copysign(beyond / (1 - zone), position);
    const low: f32 = @floatFromInt(range[0]);
    const high: f32 = @floatFromInt(range[1]);
    return @intFromFloat(@round((low + high) / 2 + live * (high - low) / 2));
}

/// How far a trigger is pulled, and the right stick pushed one way, to count as its button down.
const trigger_press: i16 = 8192;
const stick_press: i16 = 16384;

/// Where each of a gamepad's buttons comes from: an SDL button, a trigger pulled, or the right
/// stick pushed one way.
const Source = union(enum) {
    button: c.SDL_GamepadButton,
    trigger: c.SDL_GamepadAxis,
    stick: struct { axis: c.SDL_GamepadAxis, positive: bool },
};

const sources = std.EnumArray(GamepadButton, Source).init(.{
    .south = .{ .button = c.SDL_GAMEPAD_BUTTON_SOUTH },
    .east = .{ .button = c.SDL_GAMEPAD_BUTTON_EAST },
    .west = .{ .button = c.SDL_GAMEPAD_BUTTON_WEST },
    .north = .{ .button = c.SDL_GAMEPAD_BUTTON_NORTH },
    .back = .{ .button = c.SDL_GAMEPAD_BUTTON_BACK },
    .guide = .{ .button = c.SDL_GAMEPAD_BUTTON_GUIDE },
    .start = .{ .button = c.SDL_GAMEPAD_BUTTON_START },
    .left_stick = .{ .button = c.SDL_GAMEPAD_BUTTON_LEFT_STICK },
    .right_stick = .{ .button = c.SDL_GAMEPAD_BUTTON_RIGHT_STICK },
    .left_shoulder = .{ .button = c.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER },
    .right_shoulder = .{ .button = c.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER },
    .dpad_up = .{ .button = c.SDL_GAMEPAD_BUTTON_DPAD_UP },
    .dpad_down = .{ .button = c.SDL_GAMEPAD_BUTTON_DPAD_DOWN },
    .dpad_left = .{ .button = c.SDL_GAMEPAD_BUTTON_DPAD_LEFT },
    .dpad_right = .{ .button = c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT },
    .misc1 = .{ .button = c.SDL_GAMEPAD_BUTTON_MISC1 },
    .right_paddle1 = .{ .button = c.SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1 },
    .left_paddle1 = .{ .button = c.SDL_GAMEPAD_BUTTON_LEFT_PADDLE1 },
    .right_paddle2 = .{ .button = c.SDL_GAMEPAD_BUTTON_RIGHT_PADDLE2 },
    .left_paddle2 = .{ .button = c.SDL_GAMEPAD_BUTTON_LEFT_PADDLE2 },
    .touchpad = .{ .button = c.SDL_GAMEPAD_BUTTON_TOUCHPAD },
    .misc2 = .{ .button = c.SDL_GAMEPAD_BUTTON_MISC2 },
    .misc3 = .{ .button = c.SDL_GAMEPAD_BUTTON_MISC3 },
    .misc4 = .{ .button = c.SDL_GAMEPAD_BUTTON_MISC4 },
    .misc5 = .{ .button = c.SDL_GAMEPAD_BUTTON_MISC5 },
    .misc6 = .{ .button = c.SDL_GAMEPAD_BUTTON_MISC6 },
    .left_trigger = .{ .trigger = c.SDL_GAMEPAD_AXIS_LEFT_TRIGGER },
    .right_trigger = .{ .trigger = c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER },
    .right_stick_up = .{ .stick = .{ .axis = c.SDL_GAMEPAD_AXIS_RIGHTY, .positive = false } },
    .right_stick_down = .{ .stick = .{ .axis = c.SDL_GAMEPAD_AXIS_RIGHTY, .positive = true } },
    .right_stick_left = .{ .stick = .{ .axis = c.SDL_GAMEPAD_AXIS_RIGHTX, .positive = false } },
    .right_stick_right = .{ .stick = .{ .axis = c.SDL_GAMEPAD_AXIS_RIGHTX, .positive = true } },
});

/// A gamepad's axes, as the game's: the left stick is X and Y, the right stick's left and right
/// the twist.
const gamepad_axes = [_]struct { Axis, c.SDL_GamepadAxis }{
    .{ .x, c.SDL_GAMEPAD_AXIS_LEFTX },
    .{ .y, c.SDL_GAMEPAD_AXIS_LEFTY },
    .{ .rz, c.SDL_GAMEPAD_AXIS_RIGHTX },
};

/// An open controller, which the game reads as its joystick.
pub const Controller = struct {
    handle: Handle,
    /// A plain joystick's axes; a gamepad's are `gamepad_axes`.
    layout: Layout,
    /// The ranges the game gave its axes, and the dead zone.
    ranges: std.EnumArray(Axis, ?[2]i32) = .initFill(null),
    dead_zone: u16 = input.default_dead_zone,

    pub const Handle = union(enum) {
        joystick: *c.SDL_Joystick,
        gamepad: *c.SDL_Gamepad,
    };

    /// Opens `found`, with the throttle and twist on a plain joystick as `starlancer.ini` asks.
    pub fn open(found: Found, throttle: Choice, twist: Choice) Error!Controller {
        switch (found.kind) {
            .gamepad => {
                const gamepad = c.SDL_OpenGamepad(found.id) orelse return fail("SDL_OpenGamepad");
                return .{ .handle = .{ .gamepad = gamepad }, .layout = .{} };
            },
            .joystick => {
                const plain = c.SDL_OpenJoystick(found.id) orelse return fail("SDL_OpenJoystick");
                const axes: u8 = @intCast(@min(axisCount(plain), 255));
                return .{
                    .handle = .{ .joystick = plain },
                    .layout = Layout.guess(axes, found.sdl_type).with(axes, throttle, twist),
                };
            },
        }
    }

    pub fn close(controller: *Controller) void {
        switch (controller.handle) {
            .joystick => |plain| c.SDL_CloseJoystick(plain),
            .gamepad => |gamepad| c.SDL_CloseGamepad(gamepad),
        }
    }

    /// SDL's joystick underneath, which a gamepad has too.
    pub fn sdlJoystick(controller: Controller) *c.SDL_Joystick {
        return switch (controller.handle) {
            .joystick => |plain| plain,
            .gamepad => |gamepad| c.SDL_GetGamepadJoystick(gamepad) orelse unreachable,
        };
    }

    pub fn id(controller: Controller) c.SDL_JoystickID {
        return c.SDL_GetJoystickID(controller.sdlJoystick());
    }

    /// The controller as the game's joystick device.
    pub fn device(controller: *Controller) input.JoystickDevice {
        return .{ .context = controller, .vtable = &.{
            .capabilities = capabilities,
            .setRange = setRange,
            .setDeadZone = setDeadZone,
            .poll = poll,
        } };
    }

    fn capabilities(context: *anyopaque) input.JoystickDevice.Capabilities {
        const controller: *Controller = @ptrCast(@alignCast(context));
        const plain = controller.sdlJoystick();
        const name = c.SDL_GetJoystickName(plain);
        var found: input.JoystickDevice.Capabilities = .{
            .name = if (name != null) std.mem.span(name) else "",
            .axes = .initEmpty(),
            .buttons = 32,
            .hats = 1,
            .kind = .gamepad,
        };
        switch (controller.handle) {
            .gamepad => for (gamepad_axes) |pair| found.axes.insert(pair[0]),
            .joystick => {
                for (controller.layout.sources()) |source| {
                    if (source[1] != null) found.axes.insert(source[0]);
                }
                found.buttons = @intCast(@min(buttonCount(plain), 32));
                found.hats = @intCast(@min(hatCount(plain), 4));
                found.kind = .joystick;
            },
        }
        return found;
    }

    fn setRange(context: *anyopaque, axis: Axis, min: i32, max: i32) void {
        const controller: *Controller = @ptrCast(@alignCast(context));
        controller.ranges.set(axis, .{ min, max });
    }

    fn setDeadZone(context: *anyopaque, zone: u16) void {
        const controller: *Controller = @ptrCast(@alignCast(context));
        controller.dead_zone = zone;
    }

    fn poll(context: *anyopaque, state: *JoystickState) error{Unplugged}!void {
        const controller: *Controller = @ptrCast(@alignCast(context));
        state.* = std.mem.zeroes(JoystickState);
        state.pov = @splat(JoystickState.centred);
        switch (controller.handle) {
            .joystick => |plain| {
                if (!c.SDL_JoystickConnected(plain)) return error.Unplugged;
                for (controller.layout.sources()) |source| {
                    const index = source[1] orelse continue;
                    controller.setAxis(state, source[0], c.SDL_GetJoystickAxis(plain, index));
                }
                const buttons = @min(buttonCount(plain), 32);
                for (state.buttons[0..buttons], 0..) |*button, index| {
                    button.* = if (c.SDL_GetJoystickButton(plain, @intCast(index))) 0x80 else 0;
                }
                const hats = @min(hatCount(plain), 4);
                for (state.pov[0..hats], 0..) |*angle, index| {
                    angle.* = pov(@bitCast(c.SDL_GetJoystickHat(plain, @intCast(index))));
                }
            },
            .gamepad => |gamepad| {
                if (!c.SDL_GamepadConnected(gamepad)) return error.Unplugged;
                for (gamepad_axes) |pair| controller.setAxis(state, pair[0], c.SDL_GetGamepadAxis(gamepad, pair[1]));
                for (&state.buttons, 0..) |*button, index| {
                    const down = switch (sources.get(@enumFromInt(index))) {
                        .button => |which| c.SDL_GetGamepadButton(gamepad, which),
                        .trigger => |which| c.SDL_GetGamepadAxis(gamepad, which) >= trigger_press,
                        .stick => |stick| pushed: {
                            const value = c.SDL_GetGamepadAxis(gamepad, stick.axis);
                            break :pushed if (stick.positive) value >= stick_press else value <= -stick_press;
                        },
                    };
                    button.* = if (down) 0x80 else 0;
                }
                state.pov[0] = pov(.{
                    .up = c.SDL_GetGamepadButton(gamepad, c.SDL_GAMEPAD_BUTTON_DPAD_UP),
                    .right = c.SDL_GetGamepadButton(gamepad, c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT),
                    .down = c.SDL_GetGamepadButton(gamepad, c.SDL_GAMEPAD_BUTTON_DPAD_DOWN),
                    .left = c.SDL_GetGamepadButton(gamepad, c.SDL_GAMEPAD_BUTTON_DPAD_LEFT),
                });
            },
        }
    }

    /// Puts an axis's raw value into the state, scaled to the range the game gave it. An axis the
    /// game gave no range stays zero, as the game never reads one.
    fn setAxis(controller: *Controller, state: *JoystickState, which: Axis, raw: i16) void {
        const range = controller.ranges.get(which) orelse return;
        state.axis(which).* = scale(raw, range, controller.dead_zone);
    }
};

test scale {
    // The centre, the dead zone, and each end, over the stick's range and the throttle's.
    try std.testing.expectEqual(0, scale(0, .{ -1000, 1000 }, 1000));
    try std.testing.expectEqual(0, scale(3000, .{ -1000, 1000 }, 1000));
    try std.testing.expectEqual(1000, scale(32767, .{ -1000, 1000 }, 1000));
    try std.testing.expectEqual(-1000, scale(-32768, .{ -1000, 1000 }, 1000));
    try std.testing.expectEqual(500, scale(0, .{ 0, 1000 }, 1000));
    try std.testing.expectEqual(1000, scale(32767, .{ 0, 1000 }, 1000));
    try std.testing.expectEqual(0, scale(-32768, .{ 0, 1000 }, 1000));
    // Past the dead zone the rest of the travel spans the range: halfway beyond it, half.
    try std.testing.expectEqual(500, scale(18022, .{ -1000, 1000 }, 1000));
    // Without a dead zone the travel maps straight; all dead zone and the axis never moves.
    try std.testing.expectEqual(100, scale(3277, .{ -1000, 1000 }, 0));
    try std.testing.expectEqual(0, scale(32767, .{ -1000, 1000 }, 10000));
}

test pov {
    try std.testing.expectEqual(JoystickState.centred, pov(.{}));
    try std.testing.expectEqual(0, pov(.{ .up = true }));
    try std.testing.expectEqual(4500, pov(.{ .up = true, .right = true }));
    try std.testing.expectEqual(9000, pov(.{ .right = true }));
    try std.testing.expectEqual(18000, pov(.{ .down = true }));
    try std.testing.expectEqual(22500, pov(.{ .down = true, .left = true }));
    try std.testing.expectEqual(27000, pov(.{ .left = true }));
    try std.testing.expectEqual(31500, pov(.{ .left = true, .up = true }));
    // Opposite ways cancel.
    try std.testing.expectEqual(JoystickState.centred, pov(.{ .up = true, .down = true }));
    try std.testing.expectEqual(9000, pov(.{ .up = true, .down = true, .right = true }));
    // SDL's own bits are the hat's.
    try std.testing.expectEqual(27000, pov(@bitCast(@as(u8, c.SDL_HAT_LEFT))));
    try std.testing.expectEqual(4500, pov(@bitCast(@as(u8, c.SDL_HAT_RIGHTUP))));
}

test Layout {
    const unknown = c.SDL_JOYSTICK_TYPE_UNKNOWN;
    try std.testing.expectEqual(Layout{ .x = 0, .y = 1 }, Layout.guess(2, unknown));
    try std.testing.expectEqual(Layout{ .x = 0, .y = 1, .throttle = 2 }, Layout.guess(3, unknown));
    try std.testing.expectEqual(Layout{ .x = 0, .y = 1, .twist = 2, .throttle = 3 }, Layout.guess(4, unknown));
    try std.testing.expectEqual(Layout{ .x = 0, .y = 1, .throttle = 2, .twist = 3 }, Layout.guess(5, unknown));
    try std.testing.expectEqual(Layout{ .x = 0, .y = 1, .throttle = 2, .twist = 5 }, Layout.guess(7, unknown));
    try std.testing.expectEqual(Layout{ .throttle = 0 }, Layout.guess(3, c.SDL_JOYSTICK_TYPE_THROTTLE));
    // `starlancer.ini` moves or removes the throttle and the twist, within the joystick's axes.
    const stick = Layout.guess(4, unknown);
    try std.testing.expectEqual(Layout{ .x = 0, .y = 1, .twist = 3, .throttle = 2 }, stick.with(4, .{ .axis = 2 }, .{ .axis = 3 }));
    try std.testing.expectEqual(Layout{ .x = 0, .y = 1, .twist = 2 }, stick.with(4, .none, .guess));
    try std.testing.expectEqual(Layout{ .x = 0, .y = 1, .twist = 2 }, stick.with(4, .{ .axis = 9 }, .guess));
}

test Choice {
    try std.testing.expectEqual(Choice.guess, Choice.parse(null));
    try std.testing.expectEqual(Choice.guess, Choice.parse("slider"));
    try std.testing.expectEqual(Choice.none, Choice.parse("-1"));
    try std.testing.expectEqual(Choice{ .axis = 3 }, Choice.parse(" 3 "));
}

test choose {
    const pad: Found = .{ .id = 1, .name = "Xbox Wireless Controller", .kind = .gamepad, .sdl_type = c.SDL_JOYSTICK_TYPE_GAMEPAD, .vendor = 0x045E, .product = 0x0B13 };
    const throttle: Found = .{ .id = 2, .name = "TWCS Throttle", .kind = .joystick, .sdl_type = c.SDL_JOYSTICK_TYPE_THROTTLE, .vendor = 0x044F, .product = 0xB687 };
    const stick: Found = .{ .id = 3, .name = "T.16000M", .kind = .joystick, .sdl_type = c.SDL_JOYSTICK_TYPE_FLIGHT_STICK, .vendor = 0x044F, .product = 0xB10A };
    // A stick before a gamepad, and never a throttle on its own while there is either.
    try std.testing.expectEqual(3, choose(&.{ pad, throttle, stick }, null).?.id);
    try std.testing.expectEqual(1, choose(&.{ throttle, pad }, null).?.id);
    try std.testing.expectEqual(2, choose(&.{throttle}, null).?.id);
    try std.testing.expectEqual(null, choose(&.{}, null));
    // `Joystick` in `starlancer.ini` picks by name.
    try std.testing.expectEqual(1, choose(&.{ pad, stick }, "xbox").?.id);
    try std.testing.expectEqual(3, choose(&.{ pad, stick }, "nothing like it").?.id);
}

/// SDL's joystick support, for the tests, or null where the system has none.
fn testInit() ?void {
    init(.tool) catch return null;
}

/// A controller SDL makes up, for the tests: a joystick of `sdl_type` with `axes`, `buttons` and
/// `hats`, or with the masks, a gamepad of those controls.
fn attachVirtual(sdl_type: c.SDL_JoystickType, axes: u16, buttons: u16, hats: u16, masks: ?[2]u32) !c.SDL_JoystickID {
    var desc = std.mem.zeroes(c.SDL_VirtualJoystickDesc);
    desc.version = @sizeOf(c.SDL_VirtualJoystickDesc);
    desc.type = @intCast(sdl_type);
    desc.naxes = axes;
    desc.nbuttons = buttons;
    desc.nhats = hats;
    desc.name = "OpenReliant Test Controller";
    if (masks) |both| {
        desc.button_mask = both[0];
        desc.axis_mask = both[1];
    }
    const id = c.SDL_AttachVirtualJoystick(&desc);
    if (id == 0) return fail("SDL_AttachVirtualJoystick");
    return id;
}

test "a flight stick, as the game reads it" {
    testInit() orelse return error.SkipZigTest;
    defer deinit();
    const id = try attachVirtual(c.SDL_JOYSTICK_TYPE_FLIGHT_STICK, 4, 12, 1, null);
    defer _ = c.SDL_DetachVirtualJoystick(id);

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const found = choose(try attached(arena_state.allocator()), "OpenReliant Test").?;
    try std.testing.expectEqual(input.JoystickDevice.Kind.joystick, found.kind);
    var controller: Controller = try .open(found, .guess, .guess);
    defer controller.close();
    var joystick: input.Joystick = .{};
    joystick.open(controller.device(), input.default_dead_zone);
    // Four axes: X and Y, the twist, and the throttle last.
    try std.testing.expect(joystick.axes.x and joystick.axes.y and joystick.axes.z and joystick.axes.rz);
    try std.testing.expectEqual(12, joystick.buttons);
    try std.testing.expectEqual(1, joystick.hats);

    const virtual = controller.sdlJoystick();
    _ = c.SDL_SetJoystickVirtualAxis(virtual, 0, 32767);
    _ = c.SDL_SetJoystickVirtualAxis(virtual, 1, -32768);
    _ = c.SDL_SetJoystickVirtualAxis(virtual, 2, 1000);
    _ = c.SDL_SetJoystickVirtualAxis(virtual, 3, -32768);
    _ = c.SDL_SetJoystickVirtualButton(virtual, 0, true);
    _ = c.SDL_SetJoystickVirtualButton(virtual, 11, true);
    _ = c.SDL_SetJoystickVirtualHat(virtual, 0, c.SDL_HAT_LEFT);
    update();
    joystick.read();
    const state = joystick.state;
    try std.testing.expectEqual(1000, state.x);
    try std.testing.expectEqual(-1000, state.y);
    // The twist is within the dead zone; the throttle is pulled all the way back.
    try std.testing.expectEqual(0, state.rz);
    try std.testing.expectEqual(0, state.z);
    try std.testing.expectEqual(0x80, state.buttons[0]);
    try std.testing.expectEqual(0x80, state.buttons[11]);
    try std.testing.expectEqual(0, state.buttons[1]);
    try std.testing.expectEqual(27000, state.pov[0]);
    try std.testing.expectEqual(JoystickState.centred, state.pov[1]);

    // Unplugged, the game reads it as idle.
    _ = c.SDL_DetachVirtualJoystick(id);
    update();
    joystick.read();
    try std.testing.expectEqual(null, joystick.device);
}

test "a gamepad, as the game reads it" {
    testInit() orelse return error.SkipZigTest;
    defer deinit();
    const all_buttons: u32 = (1 << c.SDL_GAMEPAD_BUTTON_COUNT) - 1;
    const all_axes: u32 = (1 << c.SDL_GAMEPAD_AXIS_COUNT) - 1;
    const id = try attachVirtual(c.SDL_JOYSTICK_TYPE_GAMEPAD, c.SDL_GAMEPAD_AXIS_COUNT, c.SDL_GAMEPAD_BUTTON_COUNT, 0, .{ all_buttons, all_axes });
    defer _ = c.SDL_DetachVirtualJoystick(id);

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const found = choose(try attached(arena_state.allocator()), "OpenReliant Test").?;
    try std.testing.expectEqual(input.JoystickDevice.Kind.gamepad, found.kind);
    var controller: Controller = try .open(found, .guess, .guess);
    defer controller.close();
    var joystick: input.Joystick = .{};
    joystick.open(controller.device(), input.default_dead_zone);
    try std.testing.expectEqual(input.JoystickDevice.Kind.gamepad, joystick.kind);
    try std.testing.expect(joystick.axes.x and joystick.axes.y and joystick.axes.rz and !joystick.axes.z);

    const virtual = controller.sdlJoystick();
    _ = c.SDL_SetJoystickVirtualAxis(virtual, c.SDL_GAMEPAD_AXIS_LEFTX, -32768);
    _ = c.SDL_SetJoystickVirtualAxis(virtual, c.SDL_GAMEPAD_AXIS_RIGHTX, 32767);
    _ = c.SDL_SetJoystickVirtualAxis(virtual, c.SDL_GAMEPAD_AXIS_RIGHTY, -32768);
    _ = c.SDL_SetJoystickVirtualAxis(virtual, c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER, 32767);
    _ = c.SDL_SetJoystickVirtualAxis(virtual, c.SDL_GAMEPAD_AXIS_LEFT_TRIGGER, -32768);
    _ = c.SDL_SetJoystickVirtualButton(virtual, c.SDL_GAMEPAD_BUTTON_SOUTH, true);
    _ = c.SDL_SetJoystickVirtualButton(virtual, c.SDL_GAMEPAD_BUTTON_DPAD_DOWN, true);
    update();
    joystick.read();
    const state = joystick.state;
    try std.testing.expectEqual(-1000, state.x);
    try std.testing.expectEqual(1000, state.rz);
    const button = struct {
        fn down(read: JoystickState, which: GamepadButton) bool {
            return read.buttons[@intFromEnum(which)] != 0;
        }
    }.down;
    try std.testing.expect(button(state, .south));
    try std.testing.expect(button(state, .right_trigger) and !button(state, .left_trigger));
    try std.testing.expect(button(state, .right_stick_up) and !button(state, .right_stick_down));
    try std.testing.expect(button(state, .right_stick_right));
    try std.testing.expectEqual(18000, state.pov[0]);
}

test "controllers of many kinds" {
    testInit() orelse return error.SkipZigTest;
    defer deinit();
    const all_buttons: u32 = (1 << c.SDL_GAMEPAD_BUTTON_COUNT) - 1;
    const all_axes: u32 = (1 << c.SDL_GAMEPAD_AXIS_COUNT) - 1;
    const Model = struct {
        name: [:0]const u8,
        sdl_type: c.SDL_JoystickType,
        vendor: u16,
        product: u16,
        axes: u16,
        buttons: u16,
        hats: u16,
        gamepad: bool = false,
        /// What the game should find: its kind, its axes, and how many buttons and hats.
        kind: input.JoystickDevice.Kind,
        game_axes: []const Axis,
        game_buttons: u8,
        game_hats: u8,
    };
    const models = [_]Model{
        .{ .name = "Xbox 360 Controller", .sdl_type = c.SDL_JOYSTICK_TYPE_GAMEPAD, .vendor = 0x045E, .product = 0x028E, .axes = c.SDL_GAMEPAD_AXIS_COUNT, .buttons = c.SDL_GAMEPAD_BUTTON_COUNT, .hats = 0, .gamepad = true, .kind = .gamepad, .game_axes = &.{ .x, .y, .rz }, .game_buttons = 32, .game_hats = 1 },
        .{ .name = "DualSense Wireless Controller", .sdl_type = c.SDL_JOYSTICK_TYPE_GAMEPAD, .vendor = 0x054C, .product = 0x0CE6, .axes = c.SDL_GAMEPAD_AXIS_COUNT, .buttons = c.SDL_GAMEPAD_BUTTON_COUNT, .hats = 0, .gamepad = true, .kind = .gamepad, .game_axes = &.{ .x, .y, .rz }, .game_buttons = 32, .game_hats = 1 },
        .{ .name = "Logitech Extreme 3D Pro", .sdl_type = c.SDL_JOYSTICK_TYPE_FLIGHT_STICK, .vendor = 0x046D, .product = 0xC215, .axes = 4, .buttons = 12, .hats = 1, .kind = .joystick, .game_axes = &.{ .x, .y, .z, .rz }, .game_buttons = 12, .game_hats = 1 },
        .{ .name = "Saitek X52 Flight Control System", .sdl_type = c.SDL_JOYSTICK_TYPE_FLIGHT_STICK, .vendor = 0x06A3, .product = 0x0255, .axes = 7, .buttons = 39, .hats = 3, .kind = .joystick, .game_axes = &.{ .x, .y, .z, .rz }, .game_buttons = 32, .game_hats = 3 },
        .{ .name = "CH Products Fighterstick", .sdl_type = c.SDL_JOYSTICK_TYPE_UNKNOWN, .vendor = 0x068E, .product = 0x00F3, .axes = 3, .buttons = 8, .hats = 4, .kind = .joystick, .game_axes = &.{ .x, .y, .z }, .game_buttons = 8, .game_hats = 4 },
        .{ .name = "Gameport Adapter Stick", .sdl_type = c.SDL_JOYSTICK_TYPE_UNKNOWN, .vendor = 0x1209, .product = 0x0001, .axes = 2, .buttons = 4, .hats = 0, .kind = .joystick, .game_axes = &.{ .x, .y }, .game_buttons = 4, .game_hats = 0 },
        .{ .name = "TWCS Throttle", .sdl_type = c.SDL_JOYSTICK_TYPE_THROTTLE, .vendor = 0x044F, .product = 0xB687, .axes = 5, .buttons = 14, .hats = 1, .kind = .joystick, .game_axes = &.{.z}, .game_buttons = 14, .game_hats = 1 },
    };
    var ids: [models.len]c.SDL_JoystickID = undefined;
    for (models, &ids) |model, *id| {
        var desc = std.mem.zeroes(c.SDL_VirtualJoystickDesc);
        desc.version = @sizeOf(c.SDL_VirtualJoystickDesc);
        desc.type = @intCast(model.sdl_type);
        desc.vendor_id = model.vendor;
        desc.product_id = model.product;
        desc.naxes = model.axes;
        desc.nbuttons = model.buttons;
        desc.nhats = model.hats;
        desc.name = model.name;
        if (model.gamepad) {
            desc.button_mask = all_buttons;
            desc.axis_mask = all_axes;
        }
        id.* = c.SDL_AttachVirtualJoystick(&desc);
        try std.testing.expect(id.* != 0);
    }
    defer for (ids) |id| {
        _ = c.SDL_DetachVirtualJoystick(id);
    };

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const found = try attached(arena_state.allocator());
    for (models, ids) |model, id| {
        const each = for (found) |candidate| {
            if (candidate.id == id) break candidate;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(model.kind, each.kind);
        var controller: Controller = try .open(each, .guess, .guess);
        defer controller.close();
        var joystick: input.Joystick = .{};
        joystick.open(controller.device(), input.default_dead_zone);
        var axes: std.EnumSet(Axis) = .initEmpty();
        inline for (@typeInfo(input.JoystickAxes).@"struct".fields) |field| {
            if (@field(joystick.axes, field.name)) axes.insert(@field(Axis, field.name));
        }
        const expected: std.EnumSet(Axis) = .initMany(model.game_axes);
        if (!axes.eql(expected)) {
            std.debug.print("{s}: the game reads the wrong axes\n", .{model.name});
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqual(model.game_buttons, joystick.buttons);
        try std.testing.expectEqual(model.game_hats, joystick.hats);
    }
    // With all of them attached, the flight stick is the one the game plays with.
    var ours: std.ArrayList(Found) = .empty;
    for (found) |each| {
        for (ids) |id| {
            if (each.id == id) try ours.append(arena_state.allocator(), each);
        }
    }
    try std.testing.expectEqualStrings("Logitech Extreme 3D Pro", choose(ours.items, null).?.name);
}

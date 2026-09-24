//! Player input as the game reads it: DirectInput's device states, the control bindings, and the
//! setting that picks the device the player steers with. [`input/controls.zig`](input/controls.zig)
//! transcribes the actions and their default bindings. **Unknown:** the source files. The device
//! code lies between `DPSession.cpp`'s and `srAPI.cpp`'s, the player's controls between
//! `airipper.cpp`'s and `jump.cpp`'s.

const std = @import("std");
const assert = std.debug.assert;

pub const controls = @import("input/controls.zig");
pub const power = @import("input/power.zig");

/// DirectInput's `DIJOYSTATE`, which the game polls the joystick into at `joystick` each simulation
/// step. The game sets the axes to run from -1000 to 1000.
pub const JoystickState = extern struct {
    x: i32,
    y: i32,
    z: i32,
    rx: i32,
    ry: i32,
    rz: i32,
    sliders: [2]i32,
    pov: [4]u32,
    /// Nonzero while the button is down.
    buttons: [32]u8,

    /// The value DirectInput reports for a centered hat.
    pub const centred: u32 = 0xFFFF_FFFF;

    comptime {
        assert(@offsetOf(JoystickState, "rz") == 0x14);
        assert(@offsetOf(JoystickState, "buttons") == 0x30);
        assert(@sizeOf(JoystickState) == 0x50);
    }

    /// Where `axis`'s value lies.
    pub fn axis(state: *JoystickState, which: Axis) *i32 {
        return switch (which) {
            .x => &state.x,
            .y => &state.y,
            .z => &state.z,
            .rx => &state.rx,
            .ry => &state.ry,
            .rz => &state.rz,
            .slider => &state.sliders[0],
            .second_slider => &state.sliders[1],
        };
    }
};

/// A joystick's axes, in `DIJOYSTATE` order. DirectInput identifies an axis by its offset in
/// `DIJOYSTATE`.
pub const Axis = enum(u3) {
    x,
    y,
    /// The throttle, on most joysticks that have one.
    z,
    rx,
    ry,
    /// The twist.
    rz,
    /// The first slider, where some joysticks put the throttle.
    slider,
    second_slider,

    /// The range `joystick_object_found` (`0x004BD050`) sets for the axis, or null for axes the
    /// game doesn't set up or read.
    pub fn range(which: Axis) ?[2]i32 {
        return switch (which) {
            .x, .y, .rz => .{ -1000, 1000 },
            .z, .slider => .{ 0, 1000 },
            .rx, .ry, .second_slider => null,
        };
    }
};

/// The dead zone `joystick_object_found` sets for the whole device, in hundredths of a percent of
/// each axis's travel from the center: 10%. The port reads `DeadZone` from `starlancer.ini` to
/// change it.
pub const default_dead_zone: u16 = 1000;

/// A joystick device: the port's replacement for `joystick_device` (`0x005DDD24`), the game's
/// `IDirectInputDevice7`, with the calls the game makes on it. The platform implements it for each
/// connected controller, including gamepads.
pub const JoystickDevice = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        capabilities: *const fn (context: *anyopaque) Capabilities,
        setRange: *const fn (context: *anyopaque, axis: Axis, min: i32, max: i32) void,
        setDeadZone: *const fn (context: *anyopaque, zone: u16) void,
        poll: *const fn (context: *anyopaque, state: *JoystickState) error{Unplugged}!void,
    };

    /// What `joystick_found` needs from the device: the counts from `GetCapabilities`, the axes
    /// `EnumObjects` reports, and the product name from DirectInput's enumeration.
    pub const Capabilities = struct {
        name: []const u8,
        axes: std.EnumSet(Axis),
        /// `DIDEVCAPS.dwButtons`, at most the 32 `JoystickState` holds.
        buttons: u8,
        /// `DIDEVCAPS.dwPOVs`, at most 4.
        hats: u8,
        /// Added by the port: whether the controller is a gamepad. A gamepad's buttons are
        /// numbered as in `GamepadButton`, and it has its own default bindings.
        kind: Kind = .joystick,
    };

    pub const Kind = enum { joystick, gamepad };

    pub fn capabilities(device: JoystickDevice) Capabilities {
        return device.vtable.capabilities(device.context);
    }

    /// `SetProperty(DIPROP_RANGE)` for one axis: the values it reports at either end of its travel.
    pub fn setRange(device: JoystickDevice, axis: Axis, min: i32, max: i32) void {
        device.vtable.setRange(device.context, axis, min, max);
    }

    /// `SetProperty(DIPROP_DEADZONE)` for the whole device: how far an axis can move from its
    /// center, in hundredths of a percent of its travel, and still read as centered.
    pub fn setDeadZone(device: JoystickDevice, zone: u16) void {
        device.vtable.setDeadZone(device.context, zone);
    }

    /// `Poll` and `GetDeviceState`. Fails if the device has been disconnected.
    pub fn poll(device: JoystickDevice, state: *JoystickState) error{Unplugged}!void {
        return device.vtable.poll(device.context, state);
    }
};

/// The game's joystick globals: the device (`joystick_device`), its state (`joystick`,
/// `0x00588340`), the axes that were set up (`joystick_axes`), the button and hat counts
/// (`joystick_buttons`, `joystick_hats`), the name (`joystick_name`), and the latches
/// `control_active` uses to count each press only once (`button_latched`, `0x005DDC98`).
pub const Joystick = struct {
    device: ?JoystickDevice = null,
    state: JoystickState = idle,
    axes: JoystickAxes = std.mem.zeroes(JoystickAxes),
    buttons: u8 = 0,
    hats: u8 = 0,
    name: []const u8 = "",
    kind: JoystickDevice.Kind = .joystick,
    latched: [32]bool = @splat(false),

    /// The state when there is no device: all zero, as `read_joystick` leaves it.
    const idle = std.mem.zeroes(JoystickState);

    /// `joystick_found` (`0x004BD190`): stores the device's button and hat counts and its name,
    /// then, as `joystick_object_found` does, sets the range of each axis the game uses, marks it
    /// in `axes`, and sets the dead zone to `zone`. Not yet ported: turning off the centering
    /// spring of a force feedback joystick.
    pub fn open(joystick: *Joystick, device: JoystickDevice, zone: u16) void {
        const found = device.capabilities();
        joystick.* = .{
            .device = device,
            .buttons = @min(found.buttons, 32),
            .hats = @min(found.hats, 4),
            .name = found.name,
            .kind = found.kind,
        };
        var axes = found.axes.iterator();
        while (axes.next()) |axis| {
            const range = axis.range() orelse continue;
            device.setRange(axis, range[0], range[1]);
            device.setDeadZone(zone);
            switch (axis) {
                inline else => |known| @field(joystick.axes, @tagName(known)) = true,
            }
        }
    }

    /// Removes the device, for example when it has been disconnected; the joystick then reads as
    /// idle.
    pub fn close(joystick: *Joystick) void {
        joystick.* = .{};
    }

    /// `read_joystick` (`0x004BD300`): reads the device's state (all zero without a device), then
    /// clears the latch of each released button. A disconnected device is closed.
    pub fn read(joystick: *Joystick) void {
        joystick.state = idle;
        const device = joystick.device orelse return;
        device.poll(&joystick.state) catch {
            joystick.close();
            return;
        };
        for (joystick.latched[0..joystick.buttons], joystick.state.buttons[0..joystick.buttons]) |*latched, state| {
            if (state == 0) latched.* = false;
        }
    }

    /// Whether `button` is pressed. Numbers beyond the 32 buttons in `JoystickState` never are.
    pub fn down(joystick: Joystick, button: u8) bool {
        return button < joystick.state.buttons.len and joystick.state.buttons[button] != 0;
    }
};

/// Which of the joystick's axes the game set up: a byte for each axis, in the order of
/// `JoystickState`, which `joystick_object_found` sets when it gives the axis a range.
pub const JoystickAxes = extern struct {
    x: bool,
    y: bool,
    /// The throttle, when the joystick has one.
    z: bool,
    /// Never set: the game gives the axis no range and never reads it.
    rx: bool,
    /// Never set, like `rx`.
    ry: bool,
    /// The twist.
    rz: bool,
    /// The first slider, which the game reads as the throttle without a Z axis.
    slider: bool,
    /// Never set, like `rx`.
    second_slider: bool,

    comptime {
        // Each flag sits at its axis's offset in `JoystickState` over four.
        assert(@offsetOf(JoystickAxes, "rz") == @offsetOf(JoystickState, "rz") / 4);
        assert(@offsetOf(JoystickAxes, "slider") == @offsetOf(JoystickState, "sliders") / 4);
        assert(@sizeOf(JoystickAxes) == @offsetOf(JoystickState, "pov") / 4);
    }
};

/// DirectInput's `DIMOUSESTATE2`, which the game reads the mouse into at `mouse` each simulation
/// step: the movement since the previous read, and eight buttons.
pub const MouseState = extern struct {
    x: i32,
    y: i32,
    z: i32,
    /// Bit 7 is set while the button is down.
    buttons: [8]u8,

    comptime {
        assert(@offsetOf(MouseState, "buttons") == 0xC);
        assert(@sizeOf(MouseState) == 0x14);
    }
};

/// One action's bindings, an entry of `control_bindings`; [`input/controls.zig`](input/controls.zig) lists the
/// actions and the bindings the game starts with.
pub const ControlBinding = extern struct {
    /// A DirectInput scan code (`DIK_*`), an index into `keyboard`.
    key: u16,
    modifier: Modifier,
    /// The action's name.
    name: [0x48]u8,
    /// A joystick button, or -1 for none.
    button: i16,

    /// The modifier held with the key: either of its two keys, left or right, counts.
    pub const Modifier = enum(u16) {
        none = 0,
        shift = 1,
        control = 2,
        alt = 3,
        _,
    };

    comptime {
        assert(@offsetOf(ControlBinding, "name") == 0x4);
        assert(@offsetOf(ControlBinding, "button") == 0x4C);
        assert(@sizeOf(ControlBinding) == 0x4E);
    }
};

/// How `player_controls` steers the player's ship: the `Controller` setting.
pub const ControlMode = enum(u32) {
    /// The joystick's axes. The game picks the keyboard instead when it finds no joystick.
    joystick = 0,
    /// Steering keys held step the inputs.
    keyboard = 1,
    /// The mouse's movement, gathered into a stick position.
    mouse = 2,
    _,
};

/// DirectInput scan codes (`DIK_*`) the input code names: those of the modifiers, and the keys
/// `frame_controls` steers the orbiting views with.
pub const scan = struct {
    pub const escape = 0x01;
    pub const left_control = 0x1D;
    pub const left_shift = 0x2A;
    pub const right_shift = 0x36;
    pub const left_alt = 0x38;
    pub const right_control = 0x9D;
    pub const right_alt = 0xB8;
    pub const up = 0xC8;
    pub const left = 0xCB;
    pub const right = 0xCD;
    pub const down = 0xD0;
};

/// The keyboard as the game reads it (`keyboard`, `0x00595C68`): each key down or up, by scan
/// code; and the latches `key_pressed` keeps so that a press counts once (`key_latched`,
/// `0x005D54EC`, and one for each modifier).
pub const Keyboard = struct {
    down: [256]bool = @splat(false),
    latched: [256]bool = @splat(false),
    shift_latched: bool = false,
    control_latched: bool = false,
    alt_latched: bool = false,
    /// Whether the keys 1 to 8 are the radio menu's, so that no action bound to them counts: while
    /// the display's communications window is open, which `control_active` tests at `0x00501EE8`,
    /// that window's phase. The port sets it as each frame starts.
    numbers_taken: bool = false,

    /// What `read_keyboard` (`0x004BD490`) does once it has the keys: frees the latch of each key
    /// that is up, and of each modifier with both its keys up.
    pub fn read(keyboard: *Keyboard) void {
        for (&keyboard.latched, keyboard.down) |*latched, down| {
            if (latched.* and !down) latched.* = false;
        }
        if (keyboard.shift_latched and !keyboard.shift()) keyboard.shift_latched = false;
        if (keyboard.control_latched and !keyboard.control()) keyboard.control_latched = false;
        if (keyboard.alt_latched and !keyboard.alt()) keyboard.alt_latched = false;
    }

    fn shift(keyboard: Keyboard) bool {
        return keyboard.down[scan.left_shift] or keyboard.down[scan.right_shift];
    }

    fn control(keyboard: Keyboard) bool {
        return keyboard.down[scan.left_control] or keyboard.down[scan.right_control];
    }

    fn alt(keyboard: Keyboard) bool {
        return keyboard.down[scan.left_alt] or keyboard.down[scan.right_alt];
    }

    /// Whether `key` is down with `modifier` (`key_pressed`, `0x004BD570`). With `once`, only once
    /// for each press, and with no modifier, only while no modifier key is down; it latches the
    /// key and the modifier. Without it, with no modifier, only while no modifier is latched; it
    /// frees the key's latch and the modifier's.
    pub fn pressed(keyboard: *Keyboard, key: u8, modifier: ControlBinding.Modifier, once: bool) bool {
        if (!keyboard.down[key]) return false;
        if (!once) {
            switch (modifier) {
                .none => if (keyboard.shift_latched or keyboard.control_latched or keyboard.alt_latched) return false,
                .shift => if (keyboard.shift()) {
                    keyboard.shift_latched = false;
                } else return false,
                .control => if (keyboard.control()) {
                    keyboard.control_latched = false;
                } else return false,
                .alt => if (keyboard.alt()) {
                    keyboard.alt_latched = false;
                } else return false,
                _ => return false,
            }
            keyboard.latched[key] = false;
            return true;
        }
        if (keyboard.latched[key]) return false;
        switch (modifier) {
            .none => if (keyboard.shift() or keyboard.control() or keyboard.alt()) return false,
            .shift => if (keyboard.shift()) {
                keyboard.shift_latched = true;
            } else return false,
            .control => if (keyboard.control()) {
                keyboard.control_latched = true;
            } else return false,
            .alt => if (keyboard.alt()) {
                keyboard.alt_latched = true;
            } else return false,
            _ => return false,
        }
        keyboard.latched[key] = true;
        return true;
    }
};

/// The input settings `load_key_config` reads from the `KeyConfig` section of `starlancer.ini`,
/// with the game's defaults.
pub const Settings = struct {
    /// `ForceFeedback` (`0x0051DA4C`). **Unknown:** its use.
    force_feedback: bool = true,
    /// `JoystickInvert` (`joystick_invert`, `0x0051D610`): while false, pitch is reversed, from
    /// the stick, the keys and the mouse.
    joystick_invert: bool = true,
    /// `HatEnable` (`hat_enabled`, `0x0052029C`): whether the hat switches to the left, right and
    /// rear views.
    hat_enabled: bool = true,
    /// `TwistEnable` (`twist_enabled`, `0x00595D88`): whether the joystick's twist rolls the ship.
    twist_enabled: bool = false,
    /// `Controller` (`control_mode`, `0x0057E064`).
    control_mode: ControlMode = .joystick,
    /// Added by the port: `DeadZone` in the `JoyConfig` section, the joystick's dead zone in
    /// hundredths of a percent.
    dead_zone: u16 = default_dead_zone,
};

/// `control_bindings` (`0x004E2380`): each action's key, modifier and joystick button, starting
/// from the game's defaults, which `load_key_config` changes from `starlancer.ini`.
pub const Bindings = std.EnumArray(controls.Action, controls.Binding);

/// The default bindings for a controller of `kind`: the game's own for a joystick, and for a
/// gamepad (added by the port) the same keys with `gamepad_buttons` as the buttons.
pub fn defaultBindings(kind: JoystickDevice.Kind) Bindings {
    var bindings: Bindings = undefined;
    for (std.enums.values(controls.Action)) |action| bindings.set(action, controls.binding(action));
    if (kind == .gamepad) {
        for (&bindings.values) |*binding| binding.button = null;
        for (gamepad_buttons) |pair| bindings.getPtr(pair[0]).button = @intFromEnum(pair[1]);
    }
    return bindings;
}

/// How the port numbers a gamepad's buttons when it presents the gamepad to the game as a joystick.
/// These are the numbers `JOY BUTTON` uses in `JoyConfig`. Face buttons are named by position, not
/// by label. The triggers and the four directions of the right stick are buttons too. The left
/// stick is the X and Y axes, the right stick's horizontal axis is the twist, and the D-pad is the
/// hat.
pub const GamepadButton = enum(u5) {
    south,
    east,
    west,
    north,
    back,
    guide,
    start,
    left_stick,
    right_stick,
    left_shoulder,
    right_shoulder,
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
    misc1,
    right_paddle1,
    left_paddle1,
    right_paddle2,
    left_paddle2,
    touchpad,
    misc2,
    misc3,
    misc4,
    misc5,
    misc6,
    left_trigger,
    right_trigger,
    right_stick_up,
    right_stick_down,
    right_stick_left,
    right_stick_right,
};

/// The default gamepad bindings, added by the port. Gamepads have no throttle axis, so the right
/// stick's up and down directions change the throttle, like the throttle keys.
pub const gamepad_buttons = [_]struct { controls.Action, GamepadButton }{
    .{ .fire_lasers, .right_trigger },
    .{ .launch_missile, .left_trigger },
    .{ .afterburners, .south },
    .{ .match_speed, .east },
    .{ .countermeasures, .west },
    .{ .target_nearest_enemy, .north },
    .{ .next_enemy_target, .right_shoulder },
    .{ .previous_enemy_target, .left_shoulder },
    .{ .accelerate, .right_stick_up },
    .{ .decelerate, .right_stick_down },
    .{ .afterburner_toggle, .left_stick },
    .{ .target_under_reticule, .right_stick },
    .{ .radar_ranges, .back },
};

/// The mouse as the platform last reported it, in place of DirectInput's mouse: where the pointer
/// is over the window, as fractions of its size, and which buttons are down. The pause menu reads
/// it (`menu_mouse_update`); steering by the mouse is not yet ported (#115).
pub const Mouse = struct {
    /// Null until the pointer has been over the window.
    at: ?[2]f32 = null,
    buttons: Buttons = .{},

    pub const Buttons = packed struct(u2) {
        left: bool = false,
        right: bool = false,

        pub fn any(buttons: Buttons) bool {
            return buttons.left or buttons.right;
        }
    };
};

/// The input state the game keeps in globals: the keyboard, joystick and mouse states, the
/// bindings and the input settings.
pub const Devices = struct {
    keyboard: Keyboard = .{},
    joystick: Joystick = .{},
    mouse: Mouse = .{},
    bindings: Bindings = defaultBindings(.joystick),
    settings: Settings = .{},

    /// Reads the keyboard, then the joystick, as `simulation_step` does at the start of each step.
    pub fn read(devices: *Devices) void {
        devices.keyboard.read();
        devices.joystick.read();
    }

    /// `control_active` (`0x00412630`): whether `action` is active because its joystick button is
    /// pressed, or its key is pressed with its modifier (or, without a modifier, with neither Shift
    /// nor Ctrl held). With `once`, each press counts only once: a button counts while it isn't
    /// latched and is then latched, and a key is checked with `key_pressed`. While the keyboard's
    /// `numbers_taken` is set, the keys 1 to 8 are ignored.
    pub fn active(devices: *Devices, action: controls.Action, once: bool) bool {
        const binding = devices.bindings.get(action);
        const keyboard = &devices.keyboard;
        if (binding.button) |button| {
            if (devices.joystick.down(button)) {
                if (!once) return true;
                if (!devices.joystick.latched[button]) {
                    devices.joystick.latched[button] = true;
                    return true;
                }
            }
        }
        if (keyboard.numbers_taken and binding.key > 1 and binding.key < 10) return false;
        const key = std.math.lossyCast(u8, binding.key);
        if (once) return keyboard.pressed(key, binding.modifier, true);
        return switch (binding.modifier) {
            .none => !keyboard.shift() and !keyboard.control() and keyboard.down[key],
            .shift => keyboard.down[key] and keyboard.shift(),
            .control => keyboard.down[key] and keyboard.control(),
            .alt => keyboard.down[key] and keyboard.alt(),
            _ => false,
        };
    }
};

test Keyboard {
    var keyboard: Keyboard = .{};
    keyboard.down[scan.up] = true;
    // Once for each press: the latch holds until the key is up and the keyboard read again.
    try std.testing.expect(keyboard.pressed(scan.up, .none, true));
    try std.testing.expect(!keyboard.pressed(scan.up, .none, true));
    keyboard.read();
    try std.testing.expect(!keyboard.pressed(scan.up, .none, true));
    keyboard.down[scan.up] = false;
    keyboard.read();
    keyboard.down[scan.up] = true;
    try std.testing.expect(keyboard.pressed(scan.up, .none, true));

    // Held, it counts every time; with Shift down it counts only with the modifier.
    try std.testing.expect(keyboard.pressed(scan.up, .none, false));
    keyboard.down[scan.right_shift] = true;
    try std.testing.expect(keyboard.pressed(scan.up, .shift, false));
    try std.testing.expect(!keyboard.pressed(scan.up, .none, true));
}

test "Devices.active with the keyboard" {
    var devices: Devices = .{};
    const keyboard = &devices.keyboard;
    keyboard.down[controls.binding(.cockpit_camera).key] = true;
    try std.testing.expect(devices.active(.cockpit_camera, false));
    keyboard.numbers_taken = true;
    try std.testing.expect(!devices.active(.cockpit_camera, false));
    keyboard.numbers_taken = false;
    try std.testing.expect(devices.active(.cockpit_camera, true));
    try std.testing.expect(!devices.active(.cockpit_camera, true));
    // A binding with Ctrl counts only with it held.
    keyboard.down[controls.binding(.smart_target).key] = true;
    try std.testing.expect(!devices.active(.smart_target, false));
    keyboard.down[scan.left_control] = true;
    try std.testing.expect(devices.active(.smart_target, false));
}

/// A joystick device for the tests: it reports `state` and records the settings the game makes.
const TestDevice = struct {
    state: JoystickState = Joystick.idle,
    capabilities: JoystickDevice.Capabilities,
    ranges: std.EnumArray(Axis, ?[2]i32) = .initFill(null),
    dead_zone: ?u16 = null,
    unplugged: bool = false,

    fn device(test_device: *TestDevice) JoystickDevice {
        return .{ .context = test_device, .vtable = &.{
            .capabilities = capabilities_,
            .setRange = setRange,
            .setDeadZone = setDeadZone,
            .poll = poll,
        } };
    }

    fn capabilities_(context: *anyopaque) JoystickDevice.Capabilities {
        const test_device: *TestDevice = @ptrCast(@alignCast(context));
        return test_device.capabilities;
    }

    fn setRange(context: *anyopaque, axis: Axis, min: i32, max: i32) void {
        const test_device: *TestDevice = @ptrCast(@alignCast(context));
        test_device.ranges.set(axis, .{ min, max });
    }

    fn setDeadZone(context: *anyopaque, zone: u16) void {
        const test_device: *TestDevice = @ptrCast(@alignCast(context));
        test_device.dead_zone = zone;
    }

    fn poll(context: *anyopaque, state: *JoystickState) error{Unplugged}!void {
        const test_device: *TestDevice = @ptrCast(@alignCast(context));
        if (test_device.unplugged) return error.Unplugged;
        state.* = test_device.state;
    }
};

/// A four-axis flight stick with twelve buttons and a hat, for the tests.
fn testStick() TestDevice {
    return .{ .capabilities = .{
        .name = "Test Stick",
        .axes = .initMany(&.{ .x, .y, .rz, .slider }),
        .buttons = 12,
        .hats = 1,
    } };
}

test Joystick {
    var stick = testStick();
    var joystick: Joystick = .{};
    joystick.open(stick.device(), default_dead_zone);
    // The axes the game uses get their ranges and are marked; the dead zone is 10%.
    try std.testing.expectEqual([2]i32{ -1000, 1000 }, stick.ranges.get(.x).?);
    try std.testing.expectEqual([2]i32{ 0, 1000 }, stick.ranges.get(.slider).?);
    try std.testing.expectEqual(null, stick.ranges.get(.z));
    try std.testing.expect(joystick.axes.x and joystick.axes.rz and joystick.axes.slider and !joystick.axes.z);
    try std.testing.expectEqual(1000, stick.dead_zone.?);
    try std.testing.expectEqual(12, joystick.buttons);
    try std.testing.expectEqualStrings("Test Stick", joystick.name);

    // Reading copies the device's state and clears the latches of released buttons.
    stick.state.x = 250;
    stick.state.buttons[3] = 0x80;
    joystick.latched[3] = true;
    joystick.latched[4] = true;
    joystick.read();
    try std.testing.expectEqual(250, joystick.state.x);
    try std.testing.expect(joystick.latched[3] and !joystick.latched[4]);
    try std.testing.expect(joystick.down(3) and !joystick.down(4) and !joystick.down(200));

    // Once disconnected, it reads as idle and is closed.
    stick.unplugged = true;
    joystick.read();
    try std.testing.expectEqual(null, joystick.device);
    try std.testing.expectEqual(0, joystick.state.x);
    joystick.read();
    try std.testing.expectEqual(0, joystick.state.x);
}

test "Devices.active with the joystick's buttons" {
    var stick = testStick();
    var devices: Devices = .{};
    devices.joystick.open(stick.device(), default_dead_zone);
    const fire = controls.binding(.fire_lasers).button.?;

    // A held button counts every time; with `once`, only once per press.
    stick.state.buttons[fire] = 0x80;
    devices.read();
    try std.testing.expect(devices.active(.fire_lasers, false));
    try std.testing.expect(devices.active(.fire_lasers, true));
    try std.testing.expect(!devices.active(.fire_lasers, true));
    try std.testing.expect(devices.active(.fire_lasers, false));
    devices.read();
    try std.testing.expect(!devices.active(.fire_lasers, true));
    stick.state.buttons[fire] = 0;
    devices.read();
    stick.state.buttons[fire] = 0x80;
    devices.read();
    try std.testing.expect(devices.active(.fire_lasers, true));

    // The key still works too.
    stick.state.buttons[fire] = 0;
    devices.read();
    devices.keyboard.down[controls.binding(.fire_lasers).key] = true;
    try std.testing.expect(devices.active(.fire_lasers, false));
}

test defaultBindings {
    const stick = defaultBindings(.joystick);
    try std.testing.expectEqual(0, stick.get(.fire_lasers).button.?);
    try std.testing.expectEqual(null, stick.get(.accelerate).button);
    const pad = defaultBindings(.gamepad);
    try std.testing.expectEqual(@intFromEnum(GamepadButton.right_trigger), pad.get(.fire_lasers).button.?);
    try std.testing.expectEqual(@intFromEnum(GamepadButton.right_stick_up), pad.get(.accelerate).button.?);
    // Gamepad bindings drop the joystick buttons but keep every key.
    try std.testing.expectEqual(null, pad.get(.strafe_left).button);
    for (std.enums.values(controls.Action)) |action| {
        try std.testing.expectEqual(stick.get(action).key, pad.get(action).key);
    }
    // No two actions share a gamepad button.
    var used: std.EnumSet(GamepadButton) = .initEmpty();
    for (gamepad_buttons) |pair| {
        try std.testing.expect(!used.contains(pair[1]));
        used.insert(pair[1]);
    }
}

test {
    std.testing.refAllDecls(@This());
}

// --- The player's controls -----------------------------------------------------------------

const gameobj = @import("game/gameobj.zig");
const create = @import("game/create.zig");
const camera = @import("game/camera.zig");
const guns = @import("game/guns.zig");
const hud = @import("game/hud.zig");
const ai = @import("game/ai.zig");
const aigeneric = @import("game/aigeneric.zig");
const objects = @import("game/objects.zig");
const missiles = @import("game/missiles.zig");
const math = @import("surrender/math.zig");

/// What the player's controls keep between updates, which the game holds in globals.
pub const Player = struct {
    /// `throttle_setting` (`0x0051CF7C`): the throttle the keys set, which the ship's follows
    /// while the afterburner is off.
    throttle: f32 = 0,
    /// `matching_speed` (`0x00579984`), flipped by MATCH SPEED: the throttle follows the target's
    /// speed (`matchSpeed`).
    matching_speed: bool = false,
    /// `throttle_before_match` (`0x00566794`): the throttle as matching last found it, which
    /// matching puts back as it stops.
    throttle_before_match: f32 = 0,
    /// `afterburner_toggled` (`0x0051CEFE`), flipped by AFTERBURNER TOGGLE.
    afterburner_toggled: bool = false,
    /// `powerball_held` (`0x0051CEF8`): set while POWERBALL WINDOW is held, and for the frame its
    /// locked form opens the power window. The stick then moves the power instead of steering.
    power_held: bool = false,
    /// `0x0051CEFC`: set while SHIELD BALANCING is held. The stick then shifts the shields fore and
    /// aft instead of steering.
    balancing_shields: bool = false,
    /// What SHIELD BALANCING has shifted beyond the fore and aft shields' full charge.
    shield_reserves: gameobj.ShieldReserves = .{},
    /// How the mission is ending, which the player's ship's end decides.
    ending: @import("game/main.zig").Ending = .playing,
    /// `mission_number` (`0x00562DC8`): the number of the mission being flown, from 1; 0 where
    /// none is, as in the sandbox. A few of the game's rules single a mission out by it.
    mission: u8 = 0,
    /// The pilot's kills over the whole campaign.
    kills: Kills = .{},

    /// The pilot's kills over the whole campaign. Only a new pilot starts them again from 0.
    pub const Kills = struct {
        /// `skull_count` (`0x00562DF4`), which `deathmatch.addKills` counts and the display's
        /// skull readout shows.
        count: i32 = 0,
        /// `skull_count_kept` (`0x00562D24`): the count as the last mission the pilot came through
        /// left it (`gameflow.endMission`), which the start of the next puts back
        /// (`winmain.startMission`), undoing the kills of an attempt that failed.
        kept: i32 = 0,
    };
};

/// How far a key steps a steering input each run (`0x004DC4C0`). The flight model clamps the
/// input, so a held key reaches full deflection on the fourth run.
const steering_step: f32 = 0.3;

/// How far a key steps the throttle each run (`0x004DC4AC`): fifty runs from none to full.
const throttle_step: f32 = 0.02;

/// The share of the yaw added to the roll, which banks the ship into its turns (`0x004DC408`).
const bank_share: f32 = 0.5;

/// The factor from joystick axis units to steering input (`0x004DC418`): -1000 to 1000 becomes -1
/// to 1.
const axis_scale: f32 = 0.001;

/// `player_throttle_keys` (`0x004132C0`): ACCELERATE and DECELERATE step the throttle setting and
/// the ship's throttle, and ZERO THROTTLE and FULL THROTTLE set both and stop MATCH SPEED. The
/// ship's throttle then follows the setting, unless its afterburner is burning.
pub fn playerThrottleKeys(player: *Player, devices: *Devices, object: *gameobj.GameObject) void {
    if (devices.active(.accelerate, false)) {
        player.throttle = @min(player.throttle + throttle_step, 1);
        object.throttle = @min(object.throttle + throttle_step, 1);
    } else if (devices.active(.decelerate, false)) {
        player.throttle = @max(player.throttle - throttle_step, 0);
        object.throttle = @max(object.throttle - throttle_step, 0);
    }
    if (devices.active(.zero_throttle, true)) {
        player.throttle = 0;
        object.throttle = 0;
        player.matching_speed = false;
    }
    if (devices.active(.full_throttle, true)) {
        player.throttle = 1;
        object.throttle = 1;
        player.matching_speed = false;
    }
    if (!object.afterburner) object.throttle = player.throttle;
}

/// `player_controls` (`0x00413410`): the update of the Player Control order, which sets the ship's
/// steering inputs, its throttle and its two burns from the controls. It runs once a frame with the
/// ship's orders and once again in each simulation step, before the objects move.
///
/// With the joystick (`control_mode` 0), X yaws and Y pitches; the roll keys roll, and holding
/// JOYSTICK ROLL makes X roll instead of yaw. With `TwistEnable` and a twist axis, the twist rolls.
/// The throttle axis (Z, or else the first slider) sets the throttle directly; without one, the
/// throttle keys change it. With the keyboard, the steering keys change the inputs step by step.
/// In every mode, half the yaw is added to the roll so the ship banks into turns, and turning
/// `JoystickInvert` off reverses pitch.
///
/// While POWERBALL WINDOW or SHIELD BALANCING is held, the stick moves the power or shifts the
/// shields instead (`holdStick`), and the throttle is left as it is.
///
/// FIRE LASERS holds the guns' trigger for the frame (`guns.fire`).
///
/// Not yet ported: the mouse (mouse mode uses the keys for now); matching a target's speed; the
/// missiles and the other actions it reads; the `half_throttle` and `reversed_controls` deathmatch
/// power-ups (`gameobj.PowerUp`); and the objectives window's use of the stick while `0x0051CF04`
/// is set (`0x00413200`).
pub fn playerControls(
    player: *Player,
    devices: *Devices,
    object: *gameobj.GameObject,
    combat: *const create.ShipCombat,
    view: camera.View,
    frame_duration: i32,
    trigger: guns.Trigger,
) void {
    if (player.balancing_shields or player.power_held) {
        holdStick(player, devices, object, combat, frame_duration);
    } else {
        steer(player, devices, object, view);
    }

    // If both strafe keys are held, STRAFE RIGHT wins, since the game checks it last.
    object.lateral_input = 0;
    if (devices.active(.strafe_left, false)) object.lateral_input = -1;
    if (devices.active(.strafe_right, false)) object.lateral_input = 1;
    object.throttle = std.math.clamp(object.throttle, 0, 1);

    if (devices.active(.fire_lasers, false)) guns.fire(object, trigger, guns.held_ticks);

    if (devices.active(.afterburner_toggle, true)) player.afterburner_toggled = !player.afterburner_toggled;
    // `object_orders` clears both before each update, so each lasts until the order runs again.
    object.afterburner = devices.active(.afterburners, false) or player.afterburner_toggled;
    object.reverse_thrust = devices.active(.reverse_thrust, false);
    // What `object_orders` does after the update: neither burns without fuel.
    if (object.afterburner_fuel == 0) {
        object.afterburner = false;
        object.reverse_thrust = false;
    }
}

/// The steering and the throttle of `player_controls`, while the stick is free.
fn steer(player: *Player, devices: *Devices, object: *gameobj.GameObject, view: camera.View) void {
    const pitch_sign: f32 = if (devices.settings.joystick_invert) 1 else -1;
    switch (devices.settings.control_mode) {
        .joystick => {
            const joystick = &devices.joystick;
            const state = joystick.state;
            object.yaw_input = 0;
            object.pitch_input = 0;
            object.roll_input = 0;
            const x = @as(f32, @floatFromInt(state.x)) * axis_scale;
            const y = @as(f32, @floatFromInt(state.y)) * axis_scale;
            if (devices.settings.twist_enabled and joystick.axes.rz) {
                object.yaw_input = x;
                object.pitch_input = y * pitch_sign;
                object.roll_input = @as(f32, @floatFromInt(state.rz)) * axis_scale;
            } else {
                if (devices.active(.joystick_roll, false)) {
                    object.roll_input = x;
                } else {
                    object.yaw_input = x;
                    object.roll_input = rollKeys(devices);
                }
                object.pitch_input = y * pitch_sign;
            }
            const throttle: ?i32 = if (joystick.axes.z) state.z else if (joystick.axes.slider) state.sliders[0] else null;
            if (throttle) |value| {
                object.throttle = 1 - @as(f32, @floatFromInt(value)) * axis_scale;
            } else {
                playerThrottleKeys(player, devices, object);
            }
        },
        .keyboard, .mouse, _ => {
            // The arrow keys orbit the target and external views, so they do not turn the ship in
            // those.
            if (view == .target or view == .external) {
                object.yaw_input = 0;
                object.pitch_input = 0;
            } else {
                // Each pair steps its input while one of its keys is held, in the order the game
                // reads them, and zeroes it while neither is.
                object.yaw_input = if (devices.active(.rotate_clockwise, false))
                    object.yaw_input - steering_step
                else if (devices.active(.rotate_anti_clockwise, false))
                    object.yaw_input + steering_step
                else
                    0;
                object.pitch_input = if (devices.active(.nose_up, false))
                    object.pitch_input + steering_step * pitch_sign
                else if (devices.active(.nose_down, false))
                    object.pitch_input - steering_step * pitch_sign
                else
                    0;
            }
            object.roll_input = rollKeys(devices);
            playerThrottleKeys(player, devices, object);
        },
    }
    object.roll_input += object.yaw_input * bank_share;
}

/// What the stick does while POWERBALL WINDOW or SHIELD BALANCING is held (`player_controls`): the
/// steering inputs are zeroed, and the joystick's X and Y, or with the keyboard the yaw and pitch
/// keys as a whole deflection each, move the power (`power.move`) or, while SHIELD BALANCING is
/// held, shift the shields (`power.balanceShields`).
fn holdStick(player: *Player, devices: *Devices, object: *gameobj.GameObject, combat: *const create.ShipCombat, frame_duration: i32) void {
    object.yaw_input = 0;
    object.pitch_input = 0;
    object.roll_input = 0;
    var stick: [2]f32 = .{ 0, 0 };
    switch (devices.settings.control_mode) {
        .joystick => {
            const state = devices.joystick.state;
            stick = .{ @as(f32, @floatFromInt(state.x)) * axis_scale, @as(f32, @floatFromInt(state.y)) * axis_scale };
        },
        .keyboard, .mouse, _ => {
            if (devices.active(.rotate_clockwise, false)) {
                stick[0] = -1;
            } else if (devices.active(.rotate_anti_clockwise, false)) {
                stick[0] = 1;
            }
            if (devices.active(.nose_up, false)) {
                stick[1] = -1;
            } else if (devices.active(.nose_down, false)) {
                stick[1] = 1;
            }
        },
    }
    if (player.balancing_shields) {
        power.balanceShields(object, &player.shield_reserves, combat, stick[1]);
    } else {
        power.move(object, stick[0], stick[1], frame_duration);
    }
}

/// The roll input from the roll keys: 1 for ROLL SHIP CLOCKWISE, -1 for ROLL SHIP ANTI-CLOCKWISE
/// (clockwise wins if both are held), and 0 for neither.
fn rollKeys(devices: *Devices) f32 {
    if (devices.active(.roll_ship_clockwise, false)) return 1;
    if (devices.active(.roll_ship_anti_clockwise, false)) return -1;
    return 0;
}

// --- The player's devices ------------------------------------------------------------------

/// `player_ecm_set` (`0x00415370`): turns the ECM on or off, on a ship that carries one: the
/// object's `ecm` flag and the display's setting. Not yet ported: what it tells a multiplayer
/// game.
pub fn setEcm(display: *hud.State, object: *gameobj.GameObject, on: bool) void {
    const ecm = display.devices.getPtr(.ecm);
    if (ecm.setting == .absent) return;
    object.flags.ecm = on;
    ecm.setting = if (on) .on else .off;
}

/// `player_spectral_shields_set` (`0x00415430`): turns the spectral shields on or off, on a ship
/// that carries them: the object's `spectral_shields` flag and the display's setting. Turning
/// them on tunes them, into `spectral_gun_type`, to the gun type most dangerous near the ship: it
/// counts the guns of every hostile ship within range, weights each type's count by its first
/// damage value, and takes the highest, leaving out types 13 and 14. Not yet ported: the tuning,
/// which needs the other ships' guns, and what it tells a multiplayer game.
pub fn setSpectralShields(display: *hud.State, object: *gameobj.GameObject, on: bool) void {
    const shields = display.devices.getPtr(.spectral_shields);
    if (shields.setting == .absent) return;
    object.flags.spectral_shields = on;
    shields.setting = if (on) .on else .off;
}

// --- The player's target --------------------------------------------------------------------

/// `0x00415270`: aims the player's Player Control order at `index` and its `component`, which
/// makes that the player's target, and has the display follow it (`hud.State.targetChanged`).
/// Not yet ported: what it tells a multiplayer game (`0x004BB980`).
pub fn setPlayerTarget(display: *hud.State, all: *create.Objects, index: i16, component: i16, multiplayer: bool) void {
    const entry = ai.playerControlEntry(all) orelse return;
    entry.target.index = index;
    entry.target.component = component;
    display.targetChanged(all, multiplayer);
}

/// LAUNCH MISSILE and COUNTERMEASURES, which `player_controls` reads after the guns
/// (`0x00413BE7`, `0x00413E80`), each once a press: the one launches the armed missile
/// (`launchMissile`); the other, outside a mission's ending, drops a countermeasure, Betty
/// warning as they run out: at 6, 4 and 2 left, and with none. `aigeneric.playerControl` runs it
/// after `matchSpeed`, since nothing between reads what it does.
///
/// Not ported: in the mouse's mode, the right button, which launches too; and in a multiplayer
/// game, typing a message, which leaves both unread.
pub fn playerWeapons(world: gameobj.World, devices: *Devices, index: u16) void {
    if (devices.active(.launch_missile, true)) launchMissile(world, index);
    if (devices.active(.countermeasures, true) and world.player.ending == .playing) {
        const left = world.objects.slots[index].object.countermeasures;
        if (world.hearing) |hearing| switch (left) {
            0 => hearing.sound.say(countermeasures_gone),
            2, 4, 6 => hearing.sound.say(countermeasures_low),
            else => {},
        };
        if (world.countermeasures) |dropped| dropped.spend(world, index);
    }
}

/// Betty's warnings: the armed missile run out, countermeasures running low, and gone.
const missiles_gone = 0;
const countermeasures_low = 0xD;
const countermeasures_gone = 0xF;

/// The display's sound for a launch refused (`bank_stdsmp`).
const refused_sample = 1;

/// How long Betty says no more that the armed missile has run out, as a launch is refused, in
/// ticks.
const gone_pause = 500;

/// `player_launch_missile` (`0x00412820`): the armed missile of the missile display
/// (`hud.missile_display`), from the first of the ship's racks of its type that has any, at the
/// ship's target while the lock holds, else at nothing. Nothing is launched while the ship's
/// missiles are disabled or it jumps; nor, for a type that needs a lock, without one, which the
/// display refuses, Betty saying so too where none is left, but no more than once in 500 ticks.
/// A launch opens the missile display and holds it open, Betty says so where the armed type has
/// run out, and the display counts one off.
///
/// Not ported: a cloaked ship dropping its cloak instead
/// ([#89](https://github.com/vdmkenny/openreliant/issues/89)); the Kamov of mission 25 letting the
/// craft it carries go instead; and in a multiplayer game, the missile being a power-up.
pub fn launchMissile(world: gameobj.World, index: u16) void {
    const all = world.objects;
    const ship = &all.slots[index].object;
    if (ship.flags.missiles_disabled or ship.flags.jumping) return;
    const display = world.display orelse return;
    const ring = &display.missiles;
    const armed = ring.armedEntry();
    const locked = display.lock.locked();
    const sound = if (world.hearing) |hearing| hearing.sound else null;
    if (armed.type.needsLock() and !locked) {
        if (sound) |player| if (player.stdsmp) |bank| {
            _ = player.play(bank, refused_sample, 127, 1, 64, 0);
        };
        if (armed.count != 0 or world.clock.game_ticks <= ring.empty_warned_until) return;
        if (sound) |player| player.say(missiles_gone);
        ring.empty_warned_until = world.clock.game_ticks + gone_pause;
        return;
    }
    if (ship.flags.cloaked) return;
    if (display.windows.open(.missiles, false)) display.windows.status.getPtr(.missiles).held = true;
    if (armed.count == 0) if (sound) |player| player.say(missiles_gone);
    for (ship.fittedRacks(), 0..) |rack, at| {
        if (rack.type != armed.type or rack.count < 1) continue;
        const target: aigeneric.Target = if (locked and ship.order_count > 0) all.slots[index].orders[0].target else .none;
        missiles.launch(world, index, at, target);
        armed.count -= 1;
        ring.left -= 1;
        return;
    }
}

/// What `player_controls` (`0x00413410`) does about the target's speed, which reads the objects:
/// while `matching_speed` is set, it matches it (`matchTargetSpeed`); then MATCH SPEED, once for
/// each press, flips it, putting back `throttle_before_match` as it turns off and matching at once
/// as it turns on. The game does this among the keys after the throttle's and the strafe keys;
/// `aigeneric.playerControl` runs it after `playerControls`, since nothing between reads the
/// throttle it sets.
pub fn matchSpeed(player: *Player, devices: *Devices, all: *create.Objects, view: camera.View) void {
    matchTargetSpeed(player, all, view);
    if (!devices.active(.match_speed, true)) return;
    player.matching_speed = !player.matching_speed;
    if (player.matching_speed) {
        matchTargetSpeed(player, all, view);
    } else {
        all.slots[all.player].object.throttle = player.throttle_before_match;
    }
}

/// `match_target_speed` (`0x00412C10`): while `matching_speed` is set, the player's throttle is
/// the target's speed over the ship's cruise speed, to full, while the target is within
/// `hud.pick_range` and not exploding; a cloaked one leaves it as it is. Past that it puts back
/// `throttle_before_match` and stops matching, as it does with no target at all, though then
/// without putting anything back. It keeps the throttle it finds each time, so what it puts back
/// is the throttle of its last match.
pub fn matchTargetSpeed(player: *Player, all: *create.Objects, view: camera.View) void {
    if (!player.matching_speed) return;
    const entry = ai.playerControlEntry(all) orelse return;
    const ship = &all.slots[all.player];
    if (entry.target.index >= 0) {
        const target = &all.slots[@intCast(entry.target.index)];
        if (target.object.flags.cloaked) return;
        const within = math.distance(ship.drawn.position, target.drawn.position) <= hud.pick_range;
        if (within and !target.object.flags.exploding) {
            if (ship.flight) |flight| {
                player.throttle_before_match = ship.object.throttle;
                ship.object.throttle = @min(target.object.speed / ai.cruiseSpeed(&ship.object, flight, view), 1);
            }
            return;
        }
        ship.object.throttle = player.throttle_before_match;
    }
    player.matching_speed = false;
}

/// Which way the targeting keys step through the objects or a target's components.
pub const Step = enum {
    next,
    previous,

    /// The index a step from `at` among `count`, going round: from none, -1, the next is the
    /// first and the previous the last.
    pub fn from(step: Step, at: i16, count: i16) i16 {
        return switch (step) {
            .next => if (at + 1 >= count) 0 else at + 1,
            .previous => if (at < 1) count - 1 else at - 1,
        };
    }
};

/// Which objects `seekTarget` stops at: hostile ones or friendly ones within `hud.pick_reach` of
/// the player's ship, as the next and previous target keys ask; hostile Russian torpedoes, Kamovs
/// and Scimitars within it, as TARGET TORPEDO does (`hud.targetKeys`); or any the player can aim
/// at, which no key asks for.
pub const Among = enum { any, hostile, friendly, torpedo };

/// `0x004150D0`: steps the player's target through the objects to the next one `among` takes
/// (`seekTarget`), losing its component, or leaves the player without a target where none is to
/// be found. The display follows either way. Returns whether one was found. Not yet ported: what
/// it tells a multiplayer game.
pub fn cycleTarget(display: *hud.State, all: *create.Objects, step: Step, among: Among, multiplayer: bool) bool {
    const entry = ai.playerControlEntry(all) orelse return true;
    const found = seekTarget(all, &entry.target, step, among);
    if (!found) entry.target.index = -1;
    display.targetChanged(all, multiplayer);
    return found;
}

/// `0x004150D0`'s search, which TARGET TORPEDO repeats: steps `target` an object at a time, round
/// from the last to the first, with no component, until it names one `among` takes that the
/// player can aim at: not the player's own ship, one ejected from included and, for a friendly
/// one, one cloaked. Having tried every object, it stands where it started.
pub fn seekTarget(all: *const create.Objects, target: *aigeneric.Target, step: Step, among: Among) bool {
    const count: i16 = @intCast(all.count);
    const from = all.slots[all.player].drawn.position;
    for (0..all.count) |_| {
        target.index = step.from(target.index, count);
        target.component = -1;
        const slot = &all.slots[@intCast(target.index)];
        const object = &slot.object;
        if (!ai.targetValid(all, target.*, .{ .ejected = true, .cloaked = object.side == .friendly })) continue;
        if (target.index == all.player) continue;
        const within = math.distance(from, slot.drawn.position) <= hud.pick_reach;
        const taken = switch (among) {
            .any => true,
            .hostile => object.side == .hostile and within,
            .friendly => object.side == .friendly and within,
            .torpedo => object.side == .hostile and within and switch (object.type) {
                .russian_torpedo, .kamov, .scimitar => true,
                else => false,
            },
        };
        if (taken) return true;
    }
    return false;
}

/// `0x00414F90`: steps the player's target's component round its components to the next the
/// player can aim at, targetable and neither hidden nor spent, or to none when it finds none. It first gives
/// both forms of the target display their full time again, and does nothing more for a target
/// that lists no components, or a friendly one; otherwise it opens the target's form of the
/// display, if that is shut. The display follows the new component on its next frame. Not yet
/// ported: what it tells a multiplayer game.
pub fn cycleSubtarget(display: *hud.State, all: *create.Objects, step: Step, multiplayer: bool) void {
    const entry = ai.playerControlEntry(all) orelse return;
    for ([_]hud.windows.Window{ .big_target, .target }) |window| display.windows.renew(window);
    if (entry.target.index < 0) return;
    const slot = &all.slots[@intCast(entry.target.index)];
    if (!slot.object.flags.components or slot.object.side == .friendly) return;
    const window = hud.targetWindow(slot);
    if (display.windows.status.get(window).phase == .shut) _ = display.windows.open(window, multiplayer);

    const count = slot.object.component_count;
    if (count <= 0) return;
    const component = &entry.target.component;
    for (0..@intCast(count)) |_| {
        component.* = step.from(component.*, count);
        const part = slot.components[@intCast(component.*)] orelse continue;
        if (part.targetable and part.standing()) return;
    }
    component.* = -1;
}

test matchSpeed {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const player = try mission.add(.predator, @splat(0));
    try std.testing.expect(try aigeneric.push(mission.orders(), player, .player_control, .none));
    const ship = mission.slot(player);
    const sabre = try mission.add(.sabre, .{ 0, 0, 5000 });
    mission.slot(sabre).object.flags.targetable = true;
    const cruise = ai.cruiseSpeed(&ship.object, ship.flight.?, .cockpit);
    mission.slot(sabre).object.speed = cruise / 4;
    var devices: Devices = .{};
    var display: hud.State = .{};
    const key = controls.binding(.match_speed).key;
    ship.object.throttle = 0.9;

    // With no target, matching stops as soon as the key starts it, and the throttle stands.
    devices.keyboard.down[key] = true;
    matchSpeed(&mission.player, &devices, all, .cockpit);
    try std.testing.expect(!mission.player.matching_speed);
    try std.testing.expectEqual(0.9, ship.object.throttle);
    devices.keyboard.down[key] = false;
    devices.keyboard.read();

    // With one, the throttle follows its speed at once.
    setPlayerTarget(&display, all, @intCast(sabre), -1, false);
    devices.keyboard.down[key] = true;
    matchSpeed(&mission.player, &devices, all, .cockpit);
    try std.testing.expect(mission.player.matching_speed);
    try std.testing.expectApproxEqAbs(0.25, ship.object.throttle, 1e-6);
    devices.keyboard.down[key] = false;
    devices.keyboard.read();
    // Each run keeps the throttle it finds, by now the matched one.
    matchSpeed(&mission.player, &devices, all, .cockpit);
    try std.testing.expectApproxEqAbs(0.25, mission.player.throttle_before_match, 1e-6);

    // Out of range, it puts that back and stops.
    ship.object.throttle = 0.6;
    objects.setPosition(&mission.slot(sabre).object, &mission.slot(sabre).drawn, .{ 0, 0, 400000 });
    matchSpeed(&mission.player, &devices, all, .cockpit);
    try std.testing.expect(!mission.player.matching_speed);
    try std.testing.expectApproxEqAbs(0.25, ship.object.throttle, 1e-6);
}

test cycleTarget {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const player = try mission.add(.predator, @splat(0));
    var display: hud.State = .{};
    // Without Player Control, there is no target to step.
    try std.testing.expect(cycleTarget(&display, all, .next, .hostile, false));
    try std.testing.expect(try aigeneric.push(mission.orders(), player, .player_control, .none));
    const friend = try mission.add(.predator, .{ 0, 0, 1000 });
    const enemy = try mission.add(.sabre, .{ 0, 0, 2000 });
    const cloaked = try mission.add(.sabre, .{ 0, 0, 3000 });
    for ([_]u16{ friend, enemy, cloaked }) |index| mission.slot(index).object.flags.targetable = true;
    mission.slot(cloaked).object.flags.cloaked = true;
    const target = &mission.slot(player).orders[0].target;

    // Hostile, the cloaked one passed over, round and round.
    try std.testing.expect(cycleTarget(&display, all, .next, .hostile, false));
    try std.testing.expectEqual(@as(i32, enemy), target.index);
    try std.testing.expect(cycleTarget(&display, all, .previous, .hostile, false));
    try std.testing.expectEqual(@as(i32, enemy), target.index);
    try std.testing.expectEqual(enemy, display.target.?);
    // A friend is taken cloaked too; never the player's own ship.
    mission.slot(friend).object.flags.cloaked = true;
    try std.testing.expect(cycleTarget(&display, all, .next, .friendly, false));
    try std.testing.expectEqual(@as(i32, friend), target.index);
    try std.testing.expect(!seekTarget(all, target, .next, .torpedo));
    try std.testing.expectEqual(@as(i32, friend), target.index);
    // None to be found leaves no target.
    mission.slot(enemy).object.flags.exploding = true;
    try std.testing.expect(!cycleTarget(&display, all, .next, .hostile, false));
    try std.testing.expectEqual(-1, target.index);
    try std.testing.expectEqual(null, display.target);
}

test cycleSubtarget {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const player = try mission.add(.predator, @splat(0));
    try std.testing.expect(try aigeneric.push(mission.orders(), player, .player_control, .none));
    const reliant = try mission.add(.reliant, .{ 0, 0, 5000 });
    const slot = mission.slot(reliant);
    // Three components, the middle one not targetable; a hostile ship lists them.
    var parts: [3]objects.Model.Part = undefined;
    for (&parts, 0..) |*part, n| {
        part.* = .{ .hidden = false, .parent = null, .origin = @splat(0), .object = .{ .flags = .{}, .position = @splat(0), .radius = 0, .levels = &.{} } };
        part.targetable = n != 1;
        slot.components[n] = part;
    }
    slot.object.component_count = parts.len;
    slot.object.flags.components = true;
    slot.object.side = .hostile;
    var display: hud.State = .{};
    setPlayerTarget(&display, all, @intCast(reliant), -1, false);
    const target = &mission.slot(player).orders[0].target;

    // From none, the first; then past the one not targetable, and round.
    display.windows = .{};
    cycleSubtarget(&display, all, .next, false);
    try std.testing.expectEqual(0, target.component);
    try std.testing.expectEqual(.opening, display.windows.status.get(.big_target).phase);
    cycleSubtarget(&display, all, .next, false);
    try std.testing.expectEqual(2, target.component);
    cycleSubtarget(&display, all, .next, false);
    try std.testing.expectEqual(0, target.component);
    cycleSubtarget(&display, all, .previous, false);
    try std.testing.expectEqual(2, target.component);
    // A friendly target's are not stepped through.
    slot.object.side = .friendly;
    cycleSubtarget(&display, all, .next, false);
    try std.testing.expectEqual(2, target.component);
}

/// The power keys and the preset each puts the power at, in the order `frame_controls` reads them.
const power_keys = [_]struct { action: controls.Action, preset: power.Preset }{
    .{ .action = .full_power_to_gunnery, .preset = .guns },
    .{ .action = .full_power_to_engines, .preset = .engines },
    .{ .action = .full_power_to_shields, .preset = .shields },
    .{ .action = .equalize_power, .preset = .equal },
};

/// The keys `frame_controls` reads after the targeting's, in its order:
///
/// - TOGGLE BLINDFIRE flips blind fire on a ship that carries it.
/// - COMMS WINDOW opens the radio's window held, and closes it once it is open.
/// - WING STATUS WINDOW closes the objectives, then opens the wing status window or, up already,
///   closes it; its locked form holds the window open as it opens it.
/// - GUNNERY WINDOW opens the gunnery window, and its locked form opens it held or closes it once
///   it is open; SYNCHRONISE GUNS opens it too and flips whether the guns fire together.
/// - ECM turns the ECM the other way from the object's flag.
/// - DAMAGE WINDOW and its locked form open and close the damage window as the wing status keys
///   do theirs.
/// - OBJECTIVES WINDOW closes the wing status window and opens the objectives.
/// - SHIELD BALANCING held lets the stick shift the shields fore and aft.
/// - RADAR RANGES moves the radar to its next range, in the view ahead with its rings still.
/// - While the radio's window is shut, each of the power keys held puts the power at its preset
///   and opens the power window. POWERBALL WINDOW held keeps it open and lets the stick move the
///   power, and its locked form holds it open that way or closes it.
/// - SPECTRAL SHIELDS, outside a multiplayer game, turns the spectral shields the other way.
///
/// A device's key is read whether or not the ship carries the device. COMMS WINDOW is read only
/// while the player's order is Player Control, as it always is in the sandbox.
///
/// Not yet ported: FULL GUNS, and GUNNERY WINDOW's turn to the next group of guns, which need the
/// guns the sandbox does not fit; the radio's menu COMMS WINDOW starts; OBJECTIVES WINDOW paging
/// through the objectives once they are open; PRIMARY TARGET and the orders to the wingmen; Betty's
/// word for a device; and the display's sounds. `view` is the camera's view and `game_ticks` the
/// timer's.
pub fn frameKeys(display: *hud.State, player: *Player, devices: *Devices, object: *gameobj.GameObject, view: camera.View, game_ticks: u32, multiplayer: bool) void {
    const windows = &display.windows;
    if (devices.active(.toggle_blindfire, true) and display.blind_fire_fitted) {
        display.blind_fire = !display.blind_fire;
    }
    if (devices.active(.comms_window, true)) {
        const comms = windows.status.getPtr(.comms);
        switch (comms.phase) {
            .shut => if (windows.open(.comms, multiplayer)) {
                comms.held = true;
            },
            .open => {
                comms.held = false;
                windows.close(.comms);
            },
            .opening, .closing => {},
        }
    }
    for ([_]controls.Action{ .wing_status_window, .wing_status_window_locked }) |action| {
        if (!devices.active(action, true)) continue;
        if (windows.up(.objectives)) windows.close(.objectives);
        if (windows.up(.wing_status)) {
            windows.close(.wing_status);
        } else if (windows.open(.wing_status, multiplayer) and action == .wing_status_window_locked) {
            windows.status.getPtr(.wing_status).held = true;
        }
    }
    if (devices.active(.gunnery_window, true)) _ = windows.open(.gunnery, multiplayer);
    if (devices.active(.gunnery_window_locked, true)) {
        if (windows.status.get(.gunnery).phase == .open) {
            windows.close(.gunnery);
        } else if (windows.open(.gunnery, multiplayer)) {
            windows.status.getPtr(.gunnery).held = true;
        }
    }
    if (devices.active(.synchronise_guns, true)) {
        _ = windows.open(.gunnery, multiplayer);
        object.gun_mode.synchronised = !object.gun_mode.synchronised;
    }
    if (devices.active(.ecm, true) and display.devices.get(.ecm).setting != .absent) {
        setEcm(display, object, !object.flags.ecm);
    }
    for ([_]controls.Action{ .damage_window, .damage_window_locked }) |action| {
        if (!devices.active(action, true)) continue;
        if (windows.up(.damage)) {
            windows.close(.damage);
        } else if (windows.open(.damage, multiplayer) and action == .damage_window_locked) {
            windows.status.getPtr(.damage).held = true;
        }
    }
    if (devices.active(.objectives_window, true)) {
        if (windows.up(.wing_status)) windows.close(.wing_status);
        if (windows.status.get(.objectives).phase != .open) _ = windows.open(.objectives, multiplayer);
    }
    player.balancing_shields = devices.active(.shield_balancing, false);
    if (devices.active(.radar_ranges, true)) hud.nextRadarRange(display, view, game_ticks);
    if (windows.status.get(.comms).phase == .shut) {
        for (power_keys) |key| {
            if (!devices.active(key.action, false)) continue;
            power.choose(object, key.preset);
            _ = windows.open(.power, multiplayer);
        }
    }
    player.power_held = devices.active(.powerball_window, false);
    if (player.power_held) _ = windows.open(.power, multiplayer);
    if (devices.active(.powerball_window_locked, true)) {
        if (windows.status.get(.power).phase == .open) {
            windows.close(.power);
        } else if (windows.open(.power, multiplayer)) {
            windows.status.getPtr(.power).held = true;
            player.power_held = true;
        }
    }
    if (!multiplayer and devices.active(.spectral_shields, true) and
        display.devices.get(.spectral_shields).setting != .absent)
    {
        setSpectralShields(display, object, !object.flags.spectral_shields);
    }
}

test frameKeys {
    var object: gameobj.GameObject = std.mem.zeroes(gameobj.GameObject);
    var devices: Devices = .{};
    const keyboard = &devices.keyboard;
    var display: hud.State = .{};
    var player: Player = .{};

    // ECM turns the ECM on, and again off.
    const ecm = controls.binding(.ecm).key;
    keyboard.down[ecm] = true;
    frameKeys(&display, &player, &devices, &object, .cockpit, 0, false);
    try std.testing.expect(object.flags.ecm);
    try std.testing.expectEqual(.on, display.devices.get(.ecm).setting);
    keyboard.read();
    frameKeys(&display, &player, &devices, &object, .cockpit, 0, false);
    try std.testing.expect(object.flags.ecm);
    keyboard.down[ecm] = false;
    keyboard.read();
    keyboard.down[ecm] = true;
    frameKeys(&display, &player, &devices, &object, .cockpit, 0, false);
    try std.testing.expect(!object.flags.ecm);
    keyboard.down[ecm] = false;

    // A ship without spectral shields ignores the key, and a multiplayer game ignores it anyway.
    const shields = controls.binding(.spectral_shields).key;
    display.devices.getPtr(.spectral_shields).setting = .absent;
    keyboard.down[shields] = true;
    frameKeys(&display, &player, &devices, &object, .cockpit, 0, false);
    try std.testing.expect(!object.flags.spectral_shields);
    keyboard.down[shields] = false;
    keyboard.read();
    display.devices.getPtr(.spectral_shields).setting = .off;
    keyboard.down[shields] = true;
    frameKeys(&display, &player, &devices, &object, .cockpit, 0, true);
    try std.testing.expect(!object.flags.spectral_shields);
    keyboard.down[shields] = false;
    keyboard.read();
    keyboard.down[shields] = true;
    frameKeys(&display, &player, &devices, &object, .cockpit, 0, false);
    try std.testing.expect(object.flags.spectral_shields);
    try std.testing.expectEqual(.on, display.devices.get(.spectral_shields).setting);
}

test "the window keys" {
    var object: gameobj.GameObject = std.mem.zeroes(gameobj.GameObject);
    object.power_setting = .{ .x = 1, .y = 1, .z = 1 };
    var devices: Devices = .{};
    var display: hud.State = .{};
    var player: Player = .{};
    const Press = struct {
        devices: *Devices,
        display: *hud.State,
        player: *Player,
        object: *gameobj.GameObject,

        /// A press of `action`'s key, with its modifier, for one frame, and its release.
        fn once(press: @This(), action: controls.Action) void {
            const binding = controls.binding(action);
            const key = std.math.lossyCast(u8, binding.key);
            const modifier: ?u8 = switch (binding.modifier) {
                .shift => scan.left_shift,
                .control => scan.left_control,
                else => null,
            };
            press.devices.keyboard.down[key] = true;
            if (modifier) |held| press.devices.keyboard.down[held] = true;
            frameKeys(press.display, press.player, press.devices, press.object, .cockpit, 0, false);
            press.devices.keyboard.down[key] = false;
            if (modifier) |held| press.devices.keyboard.down[held] = false;
            press.devices.read();
        }
    };
    const press: Press = .{ .devices = &devices, .display = &display, .player = &player, .object = &object };
    const windows = &display.windows;

    // DAMAGE WINDOW opens the damage window, and pressed while it is up closes it.
    press.once(.damage_window);
    try std.testing.expectEqual(.opening, windows.status.get(.damage).phase);
    try std.testing.expect(!windows.status.get(.damage).held);
    press.once(.damage_window);
    try std.testing.expectEqual(.closing, windows.status.get(.damage).phase);

    // The locked form of GUNNERY WINDOW holds its window, and once it is open closes it.
    press.once(.gunnery_window_locked);
    try std.testing.expect(windows.status.get(.gunnery).held);
    _ = windows.step(.gunnery, hud.windows.opening_ticks);
    press.once(.gunnery_window_locked);
    try std.testing.expectEqual(.closing, windows.status.get(.gunnery).phase);

    // WING STATUS WINDOW takes the objectives down, and OBJECTIVES WINDOW the wing status.
    press.once(.objectives_window);
    press.once(.wing_status_window);
    try std.testing.expectEqual(.closing, windows.status.get(.objectives).phase);
    try std.testing.expectEqual(.opening, windows.status.get(.wing_status).phase);
    press.once(.objectives_window);
    try std.testing.expectEqual(.closing, windows.status.get(.wing_status).phase);

    // SYNCHRONISE GUNS opens the gunnery window too, and flips the guns' firing together.
    press.once(.synchronise_guns);
    try std.testing.expect(object.gun_mode.synchronised);

    // COMMS WINDOW opens the radio's window held; while it is up the power keys do nothing.
    press.once(.comms_window);
    try std.testing.expect(windows.status.get(.comms).held);
    press.once(.full_power_to_shields);
    try std.testing.expectEqual(.shut, windows.status.get(.power).phase);
    try std.testing.expectEqual(1, object.power_setting.x);

    // Once it is shut again, a power key puts the power at its preset and opens the power window.
    _ = windows.step(.comms, hud.windows.opening_ticks);
    press.once(.comms_window);
    _ = windows.step(.comms, hud.windows.opening_ticks);
    press.once(.full_power_to_engines);
    try std.testing.expectEqual(power.presets.get(.engines)[0], object.power_setting.x);
    try std.testing.expect(object.speed_factor > 1.45);
    try std.testing.expectEqual(.opening, windows.status.get(.power).phase);
    windows.close(.power);
    _ = windows.step(.power, hud.windows.opening_ticks);

    // SHIELD BALANCING lets the stick shift the shields for as long as it is held.
    press.once(.shield_balancing);
    try std.testing.expect(player.balancing_shields);
    frameKeys(&display, &player, &devices, &object, .cockpit, 0, false);
    try std.testing.expect(!player.balancing_shields);

    // RADAR RANGES moves the radar round to its closest range, and its rings start moving.
    press.once(.radar_ranges);
    try std.testing.expectEqual(0, display.radar_range);
    try std.testing.expect(display.radar_zoom != null);

    // POWERBALL WINDOW held keeps the power window up and says so for the frame.
    press.once(.powerball_window);
    try std.testing.expectEqual(.opening, windows.status.get(.power).phase);
    try std.testing.expect(player.power_held);
    press.once(.damage_window);
    try std.testing.expect(!player.power_held);
}

/// A fighter's combat stats, for the tests below.
const testing_combat = std.mem.zeroInit(create.ShipCombat, .{ .shield_power = 8, .shield_recharge = 10 });

/// A ship with no guns, for the tests that only steer.
const no_guns: guns.Trigger = .{ .fitted = &.{}, .groups = &guns.no_groups, .frame_start = 0 };

test "held, the stick moves the power or shifts the shields" {
    var object: gameobj.GameObject = std.mem.zeroes(gameobj.GameObject);
    object.power_setting = .{ .x = 1, .y = 1, .z = 1 };
    object.throttle = 0.5;
    object.yaw_input = 0.3;
    object.shields = .{ .left = 47, .right = 47, .fore = 47, .aft = 47 };
    var devices: Devices = .{ .settings = .{ .control_mode = .keyboard } };
    const keyboard = &devices.keyboard;
    var player: Player = .{ .throttle = 0.5, .power_held = true };
    keyboard.down[controls.binding(.rotate_clockwise).key] = true;
    keyboard.down[controls.binding(.accelerate).key] = true;
    devices.read();
    // With POWERBALL WINDOW held, the yaw keys move the power a whole deflection, by the frame's
    // ticks, instead of steering, and the throttle keys do nothing.
    playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expectEqual(17, object.power_setting.x);
    try std.testing.expectEqual(0, object.yaw_input);
    try std.testing.expectEqual(0.5, object.throttle);
    // With SHIELD BALANCING held too, the pitch keys shift the shields instead.
    player.balancing_shields = true;
    keyboard.down[controls.binding(.nose_down).key] = true;
    devices.read();
    playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expectEqual(17, object.power_setting.x);
    try std.testing.expectEqual(45, object.shields.fore);
    try std.testing.expectEqual(40, object.shields.aft);
}

test playerControls {
    const gameobj_test = gameobj;
    var object: gameobj_test.GameObject = std.mem.zeroes(gameobj_test.GameObject);
    var devices: Devices = .{ .settings = .{ .control_mode = .keyboard } };
    const keyboard = &devices.keyboard;
    var player: Player = .{};
    const nose_up = controls.binding(.nose_up).key;
    const accelerate = controls.binding(.accelerate).key;

    // A held key steps its input, and the fourth run has it past full deflection.
    keyboard.down[nose_up] = true;
    for (0..4) |_| playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expectApproxEqAbs(1.2, object.pitch_input, 1e-6);
    // Released, the input falls back to nothing on the next run.
    keyboard.down[nose_up] = false;
    playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expectEqual(0, object.pitch_input);

    // The orbiting views take the arrow keys for themselves.
    keyboard.down[nose_up] = true;
    playerControls(&player, &devices, &object, &testing_combat, .external, 16, no_guns);
    try std.testing.expectEqual(0, object.pitch_input);
    keyboard.down[nose_up] = false;

    // Half the yaw banks the ship into its turn.
    keyboard.down[controls.binding(.rotate_anti_clockwise).key] = true;
    playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expectApproxEqAbs(0.3, object.yaw_input, 1e-6);
    try std.testing.expectApproxEqAbs(0.15, object.roll_input, 1e-6);
    keyboard.down[controls.binding(.rotate_anti_clockwise).key] = false;

    // ACCELERATE steps the throttle, fifty runs from none to full.
    keyboard.down[accelerate] = true;
    for (0..50) |_| playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expectApproxEqAbs(1, object.throttle, 1e-5);
    keyboard.down[accelerate] = false;
    // FULL THROTTLE and ZERO THROTTLE set it outright, once for each press.
    keyboard.down[controls.binding(.zero_throttle).key] = true;
    playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expectEqual(0, object.throttle);
    keyboard.down[controls.binding(.zero_throttle).key] = false;

    // With JoystickInvert off, the nose keys pitch the other way.
    devices.settings.joystick_invert = false;
    keyboard.down[nose_up] = true;
    playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expectApproxEqAbs(-0.3, object.pitch_input, 1e-6);
    keyboard.down[nose_up] = false;

    // Both strafe keys held, STRAFE RIGHT wins.
    keyboard.down[controls.binding(.strafe_left).key] = true;
    keyboard.down[controls.binding(.strafe_right).key] = true;
    playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expectEqual(1, object.lateral_input);
}

test "steering with the joystick" {
    var object: gameobj.GameObject = std.mem.zeroes(gameobj.GameObject);
    var stick = testStick();
    var devices: Devices = .{};
    devices.joystick.open(stick.device(), default_dead_zone);
    var player: Player = .{};

    // X yaws (and banks the ship by half as much), Y pitches, and the slider sets the throttle
    // directly: 1000 is none and 0 is full.
    stick.state = .{ .x = 500, .y = -250, .z = 0, .rx = 0, .ry = 0, .rz = 800, .sliders = .{ 250, 0 }, .pov = @splat(JoystickState.centred), .buttons = @splat(0) };
    devices.read();
    playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expectApproxEqAbs(0.5, object.yaw_input, 1e-6);
    try std.testing.expectApproxEqAbs(-0.25, object.pitch_input, 1e-6);
    try std.testing.expectApproxEqAbs(0.25, object.roll_input, 1e-6);
    try std.testing.expectApproxEqAbs(0.75, object.throttle, 1e-6);

    // Holding JOYSTICK ROLL makes X roll instead.
    devices.keyboard.down[controls.binding(.joystick_roll).key] = true;
    playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expectEqual(0, object.yaw_input);
    try std.testing.expectApproxEqAbs(0.5, object.roll_input, 1e-6);
    devices.keyboard.down[controls.binding(.joystick_roll).key] = false;

    // With TwistEnable, the twist rolls, and X still yaws and banks.
    devices.settings.twist_enabled = true;
    playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expectApproxEqAbs(0.5, object.yaw_input, 1e-6);
    try std.testing.expectApproxEqAbs(0.8 + 0.25, object.roll_input, 1e-6);
    devices.settings.twist_enabled = false;

    // Turning JoystickInvert off reverses pitch; in the orbiting views the stick still steers.
    devices.settings.joystick_invert = false;
    playerControls(&player, &devices, &object, &testing_combat, .external, 16, no_guns);
    try std.testing.expectApproxEqAbs(0.25, object.pitch_input, 1e-6);
    try std.testing.expectApproxEqAbs(0.5, object.yaw_input, 1e-6);
}

test "a joystick without a throttle leaves the throttle to the keys" {
    var object: gameobj.GameObject = std.mem.zeroes(gameobj.GameObject);
    var stick: TestDevice = .{ .capabilities = .{ .name = "Two Axes", .axes = .initMany(&.{ .x, .y }), .buttons = 2, .hats = 0 } };
    var devices: Devices = .{};
    devices.joystick.open(stick.device(), default_dead_zone);
    var player: Player = .{};
    devices.read();
    devices.keyboard.down[controls.binding(.accelerate).key] = true;
    for (0..5) |_| playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expectApproxEqAbs(0.1, object.throttle, 1e-6);
}

test "the burns last while their keys are held, and stop without fuel" {
    var object: gameobj.GameObject = std.mem.zeroes(gameobj.GameObject);
    var devices: Devices = .{ .settings = .{ .control_mode = .keyboard } };
    const keyboard = &devices.keyboard;
    var player: Player = .{};
    object.afterburner_fuel = 100;

    keyboard.down[controls.binding(.afterburners).key] = true;
    playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expect(object.afterburner);
    keyboard.down[controls.binding(.afterburners).key] = false;
    playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expect(!object.afterburner);

    // The toggle holds it on until it is pressed again.
    keyboard.down[controls.binding(.afterburner_toggle).key] = true;
    playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expect(object.afterburner);
    keyboard.read();
    playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expect(object.afterburner);

    // Out of fuel, neither burn runs.
    object.afterburner_fuel = 0;
    playerControls(&player, &devices, &object, &testing_combat, .cockpit, 16, no_guns);
    try std.testing.expect(!object.afterburner);
    try std.testing.expect(!object.reverse_thrust);
}

test launchMissile {
    var armed: missiles.testing.Armed = undefined;
    try armed.init(std.testing.allocator);
    defer armed.deinit();
    const player = try armed.add(.friendly, @splat(0));
    const enemy = try armed.add(.hostile, .{ 0, 0, 20000 });
    const target: aigeneric.Target = .{ .kind = .ship, .index = @intCast(enemy), .component = -1 };
    _ = try aigeneric.push(armed.mission.orders(), player, .player_control, target);
    var display: hud.State = .{};
    display.missiles.build(&armed.mission.slot(player).object);
    var world = armed.mission.world();
    world.display = &display;

    // The Havoc armed needs a lock: without one, nothing flies.
    launchMissile(world, player);
    try std.testing.expectEqual(0, armed.live());
    // Locked, it flies at the target, the display holds its window open, and counts one off.
    display.lock.phase = .locked;
    launchMissile(world, player);
    try std.testing.expectEqual(target, armed.missile(0).target);
    try std.testing.expectEqual(0, display.missiles.armedEntry().count);
    try std.testing.expect(display.windows.status.get(.missiles).held);
    // None left on its rack, the next launches nothing.
    launchMissile(world, player);
    try std.testing.expectEqual(1, armed.live());
}

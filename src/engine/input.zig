//! Player input as the game reads it: DirectInput's device states, the control bindings, and the
//! setting that picks the device the player steers with. [`input/controls.zig`](input/controls.zig)
//! transcribes the actions and their default bindings. **Unknown:** the source files. The device
//! code lies between `DPSession.cpp`'s and `srAPI.cpp`'s, the player's controls between
//! `airipper.cpp`'s and `jump.cpp`'s.

const std = @import("std");
const assert = std.debug.assert;

pub const controls = @import("input/controls.zig");

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

    /// A hat's direction when it is not pushed any way: DirectInput's centred point of view.
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

/// The axes of a joystick, in the order of `JoystickState`, as DirectInput names an axis by where
/// its value lies in `DIJOYSTATE`.
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

    /// The values `joystick_object_found` (`0x004BD050`) has the axis report from one end of its
    /// travel to the other, or null for an axis the game leaves alone and never reads.
    pub fn range(which: Axis) ?[2]i32 {
        return switch (which) {
            .x, .y, .rz => .{ -1000, 1000 },
            .z, .slider => .{ 0, 1000 },
            .rx, .ry, .second_slider => null,
        };
    }
};

/// The dead zone `joystick_object_found` gives the whole device, in hundredths of a percent of
/// each axis's travel from its centre: a tenth. `DeadZone` in `starlancer.ini` changes it in the
/// port.
pub const default_dead_zone: u16 = 1000;

/// A joystick as DirectInput gives it to the game: the stand-in for `joystick_device`
/// (`0x005DDD24`), an `IDirectInputDevice7`, with the calls the game makes on it. The platform
/// provides one for each controller it finds, gamepads included.
pub const JoystickDevice = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        capabilities: *const fn (context: *anyopaque) Capabilities,
        setRange: *const fn (context: *anyopaque, axis: Axis, min: i32, max: i32) void,
        setDeadZone: *const fn (context: *anyopaque, zone: u16) void,
        poll: *const fn (context: *anyopaque, state: *JoystickState) error{Unplugged}!void,
    };

    /// What `joystick_found` asks of the device: `GetCapabilities`, the axes `EnumObjects` finds,
    /// and the product name DirectInput's enumeration hands it.
    pub const Capabilities = struct {
        name: []const u8,
        axes: std.EnumSet(Axis),
        /// `DIDEVCAPS.dwButtons`, at most the 32 `JoystickState` holds.
        buttons: u8,
        /// `DIDEVCAPS.dwPOVs`, at most 4.
        hats: u8,
        /// Added for the port: whether the controller is a gamepad, whose buttons are
        /// `GamepadButton`'s and which has bindings of its own.
        kind: Kind = .joystick,
    };

    pub const Kind = enum { joystick, gamepad };

    pub fn capabilities(device: JoystickDevice) Capabilities {
        return device.vtable.capabilities(device.context);
    }

    /// `SetProperty(DIPROP_RANGE)` for one axis: the values it reports from one end to the other.
    pub fn setRange(device: JoystickDevice, axis: Axis, min: i32, max: i32) void {
        device.vtable.setRange(device.context, axis, min, max);
    }

    /// `SetProperty(DIPROP_DEADZONE)` for the whole device: how far from its centre, in hundredths
    /// of a percent of its travel, an axis still reads as centred.
    pub fn setDeadZone(device: JoystickDevice, zone: u16) void {
        device.vtable.setDeadZone(device.context, zone);
    }

    /// `Poll` and `GetDeviceState`. Fails once the device is gone.
    pub fn poll(device: JoystickDevice, state: *JoystickState) error{Unplugged}!void {
        return device.vtable.poll(device.context, state);
    }
};

/// The joystick as the game keeps it: the device (`joystick_device`), its state (`joystick`,
/// `0x00588340`), which axes it set up (`joystick_axes`), its button and hat counts
/// (`joystick_buttons`, `joystick_hats`), its name (`joystick_name`), and the latches
/// `control_active` keeps so that a press counts once (`button_latched`, `0x005DDC98`).
pub const Joystick = struct {
    device: ?JoystickDevice = null,
    state: JoystickState = idle,
    axes: JoystickAxes = std.mem.zeroes(JoystickAxes),
    buttons: u8 = 0,
    hats: u8 = 0,
    name: []const u8 = "",
    kind: JoystickDevice.Kind = .joystick,
    latched: [32]bool = @splat(false),

    /// The state without a device: every value zero, as `read_joystick` leaves it.
    const idle = std.mem.zeroes(JoystickState);

    /// What `joystick_found` (`0x004BD190`) does with the device DirectInput hands it: takes its
    /// button and hat counts and its name, and has `joystick_object_found` give each axis the game
    /// reads its range, mark it in `axes`, and set the dead zone, `zone`. Not yet ported: turning
    /// off a force feedback joystick's centring spring.
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

    /// The device gone, as when it is unplugged: the game reads it as idle from then on.
    pub fn close(joystick: *Joystick) void {
        joystick.* = .{};
    }

    /// `read_joystick` (`0x004BD300`): the device's state, all zero without one, then frees the
    /// latch of each button that is up. A device that is gone is closed.
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

    /// Whether `button` is down: a number past the 32 `JoystickState` holds never is.
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
    /// `HatEnable` (`hat_enabled`, `0x0052029C`): whether the hat glances left, right and back.
    hat_enabled: bool = true,
    /// `TwistEnable` (`twist_enabled`, `0x00595D88`): whether the joystick's twist rolls the ship.
    twist_enabled: bool = false,
    /// `Controller` (`control_mode`, `0x0057E064`).
    control_mode: ControlMode = .joystick,
    /// Added for the port: `DeadZone` in the `JoyConfig` section, the joystick's dead zone in
    /// hundredths of a percent.
    dead_zone: u16 = default_dead_zone,
};

/// `control_bindings` (`0x004E2380`): each action's key, modifier and joystick button, which start
/// as the game's defaults and `load_key_config` changes from `starlancer.ini`.
pub const Bindings = std.EnumArray(controls.Action, controls.Binding);

/// The bindings a controller of `kind` starts with. A joystick has the game's own; a gamepad,
/// added for the port, has `gamepad_buttons` in place of the joystick buttons.
pub fn defaultBindings(kind: JoystickDevice.Kind) Bindings {
    var bindings: Bindings = undefined;
    for (std.enums.values(controls.Action)) |action| bindings.set(action, controls.binding(action));
    if (kind == .gamepad) {
        for (&bindings.values) |*binding| binding.button = null;
        for (gamepad_buttons) |pair| bindings.getPtr(pair[0]).button = @intFromEnum(pair[1]);
    }
    return bindings;
}

/// The buttons a gamepad reaches the game with, added for the port: a gamepad is a joystick whose
/// buttons are these, in this order, so that `JoyConfig`'s `JOY BUTTON` numbers name them. The
/// face buttons go by where they sit, whatever they are labelled. The triggers and the right
/// stick's four directions count as buttons too. Of the axes, the left stick is X and Y and the
/// right stick's left and right the twist; the pad is the hat.
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

/// The actions a gamepad's buttons start with, added for the port, in place of the joystick's.
/// With no throttle axis, the right stick's up and down step the throttle as the keys do.
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

/// The player's devices as the game reads them, and what it reads them by: the state of the
/// keyboard and the joystick, the bindings and the input settings, which the game keeps in
/// globals. Not yet ported: the mouse.
pub const Devices = struct {
    keyboard: Keyboard = .{},
    joystick: Joystick = .{},
    bindings: Bindings = defaultBindings(.joystick),
    settings: Settings = .{},

    /// What `simulation_step` reads at the start of each step: the keyboard, then the joystick.
    pub fn read(devices: *Devices) void {
        devices.keyboard.read();
        devices.joystick.read();
    }

    /// Whether `action` is active (`control_active`, `0x00412630`): its joystick button down, or
    /// its key with its modifier, or with none while neither Shift nor Ctrl is down. With `once`
    /// only once for each press: the button counts while it is not latched, and latches it, and
    /// the key as `key_pressed` counts it. While the keyboard's `numbers_taken`, the keys 1 to 8
    /// count for nothing.
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

/// A joystick device for the tests: `state` is what it reports, and it keeps what the game set.
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
    // The axes the game reads get their ranges and are marked; the dead zone is a tenth.
    try std.testing.expectEqual([2]i32{ -1000, 1000 }, stick.ranges.get(.x).?);
    try std.testing.expectEqual([2]i32{ 0, 1000 }, stick.ranges.get(.slider).?);
    try std.testing.expectEqual(null, stick.ranges.get(.z));
    try std.testing.expect(joystick.axes.x and joystick.axes.rz and joystick.axes.slider and !joystick.axes.z);
    try std.testing.expectEqual(1000, stick.dead_zone.?);
    try std.testing.expectEqual(12, joystick.buttons);
    try std.testing.expectEqualStrings("Test Stick", joystick.name);

    // Reading takes the device's state, and frees the latches of the buttons that are up.
    stick.state.x = 250;
    stick.state.buttons[3] = 0x80;
    joystick.latched[3] = true;
    joystick.latched[4] = true;
    joystick.read();
    try std.testing.expectEqual(250, joystick.state.x);
    try std.testing.expect(joystick.latched[3] and !joystick.latched[4]);
    try std.testing.expect(joystick.down(3) and !joystick.down(4) and !joystick.down(200));

    // Unplugged, it reads as idle and is closed.
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

    // Held, a button counts every time; with `once`, only until the button is let go.
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

    // Its key still counts too.
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
    // The joystick's own buttons are gone from the gamepad's, and every key stays.
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
const camera = @import("game/camera.zig");
const hud = @import("game/hud.zig");

/// What the player's controls keep between updates, which the game holds in globals.
pub const Player = struct {
    /// `throttle_setting` (`0x0051CF7C`): the throttle the keys set, which the ship's follows
    /// while the afterburner is off.
    throttle: f32 = 0,
    /// `matching_speed` (`0x00579984`), flipped by MATCH SPEED. Matching a target's speed needs a
    /// target, so nothing reads it yet.
    matching_speed: bool = false,
    /// `afterburner_toggled` (`0x0051CEFE`), flipped by AFTERBURNER TOGGLE.
    afterburner_toggled: bool = false,
};

/// How far a key steps a steering input each run (`0x004DC4C0`). The flight model clamps the
/// input, so a held key reaches full deflection on the fourth run.
const steering_step: f32 = 0.3;

/// How far a key steps the throttle each run (`0x004DC4AC`): fifty runs from none to full.
const throttle_step: f32 = 0.02;

/// The share of the yaw added to the roll, which banks the ship into its turns (`0x004DC408`).
const bank_share: f32 = 0.5;

/// How far one unit of a joystick axis moves an input (`0x004DC418`): the stick's travel, -1000 to
/// 1000, spans -1 to 1.
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
/// With the joystick (`control_mode` 0), X yaws and Y pitches; the roll keys roll, and JOYSTICK
/// ROLL held has X roll instead of yawing; with `TwistEnable` and a twist axis, the twist rolls.
/// The throttle axis, Z or else the first slider, sets the throttle outright; without one, the
/// keys step it. With the keyboard, the steering keys step the inputs. In each mode half the yaw
/// banks the ship, and `JoystickInvert` off reverses pitch.
///
/// Not yet ported: the mouse, which steers by the keys meanwhile; matching a target's speed; the
/// weapons and the other actions it reads; and what it does while the player's object has 7 or 9
/// at `0x754`, or while any of the flags at `0x0051CEF8`, `0x0051CEFC` and `0x0051CF04` is set.
pub fn playerControls(player: *Player, devices: *Devices, object: *gameobj.GameObject, view: camera.View) void {
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

    // STRAFE RIGHT wins over STRAFE LEFT, as the game reads them in that order.
    object.lateral_input = 0;
    if (devices.active(.strafe_left, false)) object.lateral_input = -1;
    if (devices.active(.strafe_right, false)) object.lateral_input = 1;
    object.throttle = std.math.clamp(object.throttle, 0, 1);

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

/// The roll the roll keys give: 1 for ROLL SHIP CLOCKWISE, -1 for ROLL SHIP ANTI-CLOCKWISE, the
/// first held winning, and 0 without either.
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
/// - RADAR RANGES moves the radar to its next range, in the view ahead with its rings still.
/// - While the radio's window is shut, each of the power keys held opens the power window.
///   POWERBALL WINDOW held keeps it open, and its locked form holds it open or closes it.
/// - SPECTRAL SHIELDS, outside a multiplayer game, turns the spectral shields the other way.
///
/// A device's key is read whether or not the ship carries the device. COMMS WINDOW is read only
/// while the player's order is Player Control, as it always is in the sandbox.
///
/// Not yet ported: FULL GUNS, and GUNNERY WINDOW's turn to the next group of guns, which need the
/// guns the sandbox does not fit; the radio's menu COMMS WINDOW starts; OBJECTIVES WINDOW paging
/// through the objectives once they are open; the shares the power keys give; SHIELD BALANCING,
/// PRIMARY TARGET and the orders to the wingmen; Betty's word for a device; and the display's
/// sounds. `view` is the camera's view and `game_ticks` the timer's.
pub fn frameKeys(display: *hud.State, devices: *Devices, object: *gameobj.GameObject, view: camera.View, game_ticks: u32, multiplayer: bool) void {
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
    if (devices.active(.radar_ranges, true)) hud.nextRadarRange(display, view, game_ticks);
    if (windows.status.get(.comms).phase == .shut) {
        for ([_]controls.Action{ .full_power_to_gunnery, .full_power_to_engines, .full_power_to_shields, .equalize_power }) |action| {
            if (devices.active(action, false)) _ = windows.open(.power, multiplayer);
        }
    }
    display.power_held = devices.active(.powerball_window, false);
    if (display.power_held) _ = windows.open(.power, multiplayer);
    if (devices.active(.powerball_window_locked, true)) {
        if (windows.status.get(.power).phase == .open) {
            windows.close(.power);
        } else if (windows.open(.power, multiplayer)) {
            windows.status.getPtr(.power).held = true;
            display.power_held = true;
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

    // ECM turns the ECM on, and again off.
    const ecm = controls.binding(.ecm).key;
    keyboard.down[ecm] = true;
    frameKeys(&display, &devices, &object, .cockpit, 0, false);
    try std.testing.expect(object.flags.ecm);
    try std.testing.expectEqual(.on, display.devices.get(.ecm).setting);
    keyboard.read();
    frameKeys(&display, &devices, &object, .cockpit, 0, false);
    try std.testing.expect(object.flags.ecm);
    keyboard.down[ecm] = false;
    keyboard.read();
    keyboard.down[ecm] = true;
    frameKeys(&display, &devices, &object, .cockpit, 0, false);
    try std.testing.expect(!object.flags.ecm);
    keyboard.down[ecm] = false;

    // A ship without spectral shields ignores the key, and a multiplayer game ignores it anyway.
    const shields = controls.binding(.spectral_shields).key;
    display.devices.getPtr(.spectral_shields).setting = .absent;
    keyboard.down[shields] = true;
    frameKeys(&display, &devices, &object, .cockpit, 0, false);
    try std.testing.expect(!object.flags.spectral_shields);
    keyboard.down[shields] = false;
    keyboard.read();
    display.devices.getPtr(.spectral_shields).setting = .off;
    keyboard.down[shields] = true;
    frameKeys(&display, &devices, &object, .cockpit, 0, true);
    try std.testing.expect(!object.flags.spectral_shields);
    keyboard.down[shields] = false;
    keyboard.read();
    keyboard.down[shields] = true;
    frameKeys(&display, &devices, &object, .cockpit, 0, false);
    try std.testing.expect(object.flags.spectral_shields);
    try std.testing.expectEqual(.on, display.devices.get(.spectral_shields).setting);
}

test "the window keys" {
    var object: gameobj.GameObject = std.mem.zeroes(gameobj.GameObject);
    var devices: Devices = .{};
    var display: hud.State = .{};
    const Press = struct {
        devices: *Devices,
        display: *hud.State,
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
            frameKeys(press.display, press.devices, press.object, .cockpit, 0, false);
            press.devices.keyboard.down[key] = false;
            if (modifier) |held| press.devices.keyboard.down[held] = false;
            press.devices.read();
        }
    };
    const press: Press = .{ .devices = &devices, .display = &display, .object = &object };
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

    // RADAR RANGES moves the radar round to its closest range, and its rings start moving.
    press.once(.radar_ranges);
    try std.testing.expectEqual(0, display.radar_range);
    try std.testing.expect(display.radar_zoom != null);

    // POWERBALL WINDOW held keeps the power window up and says so for the frame.
    press.once(.powerball_window);
    try std.testing.expectEqual(.opening, windows.status.get(.power).phase);
    try std.testing.expect(display.power_held);
    press.once(.damage_window);
    try std.testing.expect(!display.power_held);
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
    for (0..4) |_| playerControls(&player, &devices, &object, .cockpit);
    try std.testing.expectApproxEqAbs(1.2, object.pitch_input, 1e-6);
    // Released, the input falls back to nothing on the next run.
    keyboard.down[nose_up] = false;
    playerControls(&player, &devices, &object, .cockpit);
    try std.testing.expectEqual(0, object.pitch_input);

    // The orbiting views take the arrow keys for themselves.
    keyboard.down[nose_up] = true;
    playerControls(&player, &devices, &object, .external);
    try std.testing.expectEqual(0, object.pitch_input);
    keyboard.down[nose_up] = false;

    // Half the yaw banks the ship into its turn.
    keyboard.down[controls.binding(.rotate_anti_clockwise).key] = true;
    playerControls(&player, &devices, &object, .cockpit);
    try std.testing.expectApproxEqAbs(0.3, object.yaw_input, 1e-6);
    try std.testing.expectApproxEqAbs(0.15, object.roll_input, 1e-6);
    keyboard.down[controls.binding(.rotate_anti_clockwise).key] = false;

    // ACCELERATE steps the throttle, fifty runs from none to full.
    keyboard.down[accelerate] = true;
    for (0..50) |_| playerControls(&player, &devices, &object, .cockpit);
    try std.testing.expectApproxEqAbs(1, object.throttle, 1e-5);
    keyboard.down[accelerate] = false;
    // FULL THROTTLE and ZERO THROTTLE set it outright, once for each press.
    keyboard.down[controls.binding(.zero_throttle).key] = true;
    playerControls(&player, &devices, &object, .cockpit);
    try std.testing.expectEqual(0, object.throttle);
    keyboard.down[controls.binding(.zero_throttle).key] = false;

    // With JoystickInvert off, the nose keys pitch the other way.
    devices.settings.joystick_invert = false;
    keyboard.down[nose_up] = true;
    playerControls(&player, &devices, &object, .cockpit);
    try std.testing.expectApproxEqAbs(-0.3, object.pitch_input, 1e-6);
    keyboard.down[nose_up] = false;

    // Both strafe keys held, STRAFE RIGHT wins.
    keyboard.down[controls.binding(.strafe_left).key] = true;
    keyboard.down[controls.binding(.strafe_right).key] = true;
    playerControls(&player, &devices, &object, .cockpit);
    try std.testing.expectEqual(1, object.lateral_input);
}

test "steering with the joystick" {
    var object: gameobj.GameObject = std.mem.zeroes(gameobj.GameObject);
    var stick = testStick();
    var devices: Devices = .{};
    devices.joystick.open(stick.device(), default_dead_zone);
    var player: Player = .{};

    // X yaws, banking the ship by half, and Y pitches; the slider sets the throttle outright,
    // none at 1000 and full at 0.
    stick.state = .{ .x = 500, .y = -250, .z = 0, .rx = 0, .ry = 0, .rz = 800, .sliders = .{ 250, 0 }, .pov = @splat(JoystickState.centred), .buttons = @splat(0) };
    devices.read();
    playerControls(&player, &devices, &object, .cockpit);
    try std.testing.expectApproxEqAbs(0.5, object.yaw_input, 1e-6);
    try std.testing.expectApproxEqAbs(-0.25, object.pitch_input, 1e-6);
    try std.testing.expectApproxEqAbs(0.25, object.roll_input, 1e-6);
    try std.testing.expectApproxEqAbs(0.75, object.throttle, 1e-6);

    // JOYSTICK ROLL held, X rolls instead.
    devices.keyboard.down[controls.binding(.joystick_roll).key] = true;
    playerControls(&player, &devices, &object, .cockpit);
    try std.testing.expectEqual(0, object.yaw_input);
    try std.testing.expectApproxEqAbs(0.5, object.roll_input, 1e-6);
    devices.keyboard.down[controls.binding(.joystick_roll).key] = false;

    // With the twist on, the twist rolls, and X still yaws and banks.
    devices.settings.twist_enabled = true;
    playerControls(&player, &devices, &object, .cockpit);
    try std.testing.expectApproxEqAbs(0.5, object.yaw_input, 1e-6);
    try std.testing.expectApproxEqAbs(0.8 + 0.25, object.roll_input, 1e-6);
    devices.settings.twist_enabled = false;

    // JoystickInvert off reverses pitch; the orbiting views leave the stick steering.
    devices.settings.joystick_invert = false;
    playerControls(&player, &devices, &object, .external);
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
    for (0..5) |_| playerControls(&player, &devices, &object, .cockpit);
    try std.testing.expectApproxEqAbs(0.1, object.throttle, 1e-6);
}

test "the burns last while their keys are held, and stop without fuel" {
    var object: gameobj.GameObject = std.mem.zeroes(gameobj.GameObject);
    var devices: Devices = .{ .settings = .{ .control_mode = .keyboard } };
    const keyboard = &devices.keyboard;
    var player: Player = .{};
    object.afterburner_fuel = 100;

    keyboard.down[controls.binding(.afterburners).key] = true;
    playerControls(&player, &devices, &object, .cockpit);
    try std.testing.expect(object.afterburner);
    keyboard.down[controls.binding(.afterburners).key] = false;
    playerControls(&player, &devices, &object, .cockpit);
    try std.testing.expect(!object.afterburner);

    // The toggle holds it on until it is pressed again.
    keyboard.down[controls.binding(.afterburner_toggle).key] = true;
    playerControls(&player, &devices, &object, .cockpit);
    try std.testing.expect(object.afterburner);
    keyboard.read();
    playerControls(&player, &devices, &object, .cockpit);
    try std.testing.expect(object.afterburner);

    // Out of fuel, neither burn runs.
    object.afterburner_fuel = 0;
    playerControls(&player, &devices, &object, .cockpit);
    try std.testing.expect(!object.afterburner);
    try std.testing.expect(!object.reverse_thrust);
}

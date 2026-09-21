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

    comptime {
        assert(@offsetOf(JoystickState, "rz") == 0x14);
        assert(@offsetOf(JoystickState, "buttons") == 0x30);
        assert(@sizeOf(JoystickState) == 0x50);
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

/// Whether an action is active by its binding (`control_active`, `0x00412630`): its key with its
/// modifier, or with none while neither Shift nor Ctrl is down; with `once`, as `key_pressed` counts
/// it. While `numbers_taken`, the word at `0x00501EE8` being 3, the keys 1 to 8 count for nothing.
/// Not yet ported: the joystick's buttons.
pub fn controlActive(keyboard: *Keyboard, binding: controls.Binding, once: bool, numbers_taken: bool) bool {
    if (numbers_taken and binding.key > 1 and binding.key < 10) return false;
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

test controlActive {
    var keyboard: Keyboard = .{};
    const cockpit = controls.binding(.cockpit_camera);
    keyboard.down[cockpit.key] = true;
    try std.testing.expect(controlActive(&keyboard, cockpit, false, false));
    try std.testing.expect(!controlActive(&keyboard, cockpit, false, true));
    try std.testing.expect(controlActive(&keyboard, cockpit, true, false));
    try std.testing.expect(!controlActive(&keyboard, cockpit, true, false));
    // A binding with Ctrl counts only with it held.
    const smart = controls.binding(.smart_target);
    keyboard.down[smart.key] = true;
    try std.testing.expect(!controlActive(&keyboard, smart, false, false));
    keyboard.down[scan.left_control] = true;
    try std.testing.expect(controlActive(&keyboard, smart, false, false));
}

test {
    std.testing.refAllDecls(@This());
}

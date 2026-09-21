//! Player input as the game reads it: DirectInput's device states, the control bindings, and the
//! setting that picks the device the player steers with.

const std = @import("std");
const assert = std.debug.assert;

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

/// One action's bindings, an entry of `control_bindings`; `src/formats/controls.zig` lists the
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

test {
    std.testing.refAllDecls(@This());
}

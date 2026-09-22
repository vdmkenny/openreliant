//! `C:\lancer\game\interface.cpp`: the front end's screens, and the settings they keep. Ported so
//! far: reading the input settings and the bindings from `starlancer.ini` (`load_key_config`).

const std = @import("std");

const input = @import("../input.zig");
const controls = input.controls;
const Modifier = input.ControlBinding.Modifier;
const profile = @import("../profile.zig");
const Profile = profile.Profile;

/// The sections of `starlancer.ini` that hold the input settings and the bindings.
const key_section = "KeyConfig";
const joy_section = "JoyConfig";

/// The buffer `load_key_config` reads each binding into: 128 bytes, the terminator included.
const Buffer = [0x80]u8;

/// What a binding's value starts with to name a joystick button, its number following.
const button_name = "JOY BUTTON ";

/// The modifiers by the names a value gives them. The key's number follows the name and a space.
const modifier_names = [_]struct { name: []const u8, modifier: Modifier }{
    .{ .name = "SHIFT", .modifier = .shift },
    .{ .name = "CONTROL", .modifier = .control },
    .{ .name = "ALT", .modifier = .alt },
};

/// `load_key_config` (`0x0042C800`): reads the input settings from the `KeyConfig` section of
/// `starlancer.ini`, then each action's binding from both sections, by the action's name. With
/// `Controller` 0 and no joystick, the keyboard steers.
///
/// A `KeyConfig` value is a key, as a scan code in decimal after `SHIFT `, `CONTROL ` or `ALT `
/// for a modifier, or `JOY BUTTON ` and a button, counted from 0; a `JoyConfig` value is a button,
/// and has the last word on it. A missing entry keeps the binding the action starts with.
///
/// Two fixes to the game's reading, which leave a file the game wrote itself reading the same:
/// the game looks for `JoyConfig`'s `JOY BUTTON ` past the modifier's name when the `KeyConfig`
/// entry has one, where it never is, so such an action could have no button; the port looks from
/// the value's start. And without a `JoyConfig` entry the game falls back to the button the action
/// started with, over the one `KeyConfig` gave; the port keeps `KeyConfig`'s.
///
/// Each read starts from `input.defaultBindings`, so that the port can read the file again when a
/// joystick is plugged in or out. Added for the port: a gamepad starts with bindings of its own
/// and with `TwistEnable` 1, so that the right stick rolls; and `DeadZone` in `JoyConfig` sets the
/// joystick's dead zone (`deadZone`).
pub fn loadKeyConfig(devices: *input.Devices, settings_file: Profile) void {
    const joystick = devices.joystick;
    const gamepad = joystick.device != null and joystick.kind == .gamepad;
    const settings = &devices.settings;
    settings.force_feedback = settings_file.int(key_section, "ForceFeedback", 1) != 0;
    settings.joystick_invert = settings_file.int(key_section, "JoystickInvert", 1) != 0;
    settings.hat_enabled = settings_file.int(key_section, "HatEnable", 1) != 0;
    settings.twist_enabled = settings_file.int(key_section, "TwistEnable", @intFromBool(gamepad)) != 0;
    settings.control_mode = @enumFromInt(settings_file.int(key_section, "Controller", 0));
    if (settings.control_mode == .joystick and joystick.device == null) settings.control_mode = .keyboard;
    settings.dead_zone = deadZone(settings_file);

    devices.bindings = input.defaultBindings(joystick.kind);
    for (&devices.bindings.values) |*binding| {
        var default_buffer: [32]u8 = undefined;
        const default = defaultValue(&default_buffer, binding.*);
        var buffer: Buffer = @splat(0);
        copy(&buffer, settings_file.string(key_section, binding.name, default, buffer.len));
        binding.button = null;
        var joy_default = default;
        if (std.mem.eql(u8, buffer[0..button_name.len], button_name)) {
            binding.button = buttonNumber(read(buffer[button_name.len..]));
            joy_default = std.mem.sliceTo(&buffer, 0);
        } else {
            binding.modifier = .none;
            var skipped: usize = 0;
            for (modifier_names) |named| {
                if (!std.mem.eql(u8, buffer[0..named.name.len], named.name)) continue;
                binding.modifier = named.modifier;
                skipped = named.name.len + 1;
                break;
            }
            binding.key = @truncate(@as(u32, @bitCast(read(buffer[skipped..]))));
        }
        var joy_buffer: Buffer = @splat(0);
        copy(&joy_buffer, settings_file.string(joy_section, binding.name, joy_default, joy_buffer.len));
        if (std.mem.eql(u8, joy_buffer[0..button_name.len], button_name)) {
            binding.button = buttonNumber(read(joy_buffer[button_name.len..]));
        }
    }
}

/// The joystick's dead zone that `DeadZone` in `JoyConfig` asks for, added for the port: a
/// percentage of each axis's travel from its centre, 10 by default as in the game, in the
/// hundredths of a percent DirectInput counts in.
pub fn deadZone(settings_file: Profile) u16 {
    const percent: u16 = @min(settings_file.int(joy_section, "DeadZone", input.default_dead_zone / 100), 100);
    return percent * 100;
}

/// The value the game writes for a binding, which it reads back as the default when the file has
/// none: `JOY BUTTON ` and its button, or its key after its modifier's name.
fn defaultValue(buffer: *[32]u8, binding: controls.Binding) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    // The longest value, `CONTROL -32768`, fits the buffer with room to spare.
    if (binding.button) |button| {
        writer.print(button_name ++ "{d}", .{button}) catch {};
    } else {
        const code: i16 = @bitCast(binding.key);
        for (modifier_names) |named| {
            if (named.modifier == binding.modifier) writer.print("{s} ", .{named.name}) catch {};
        }
        writer.print("{d}", .{code}) catch {};
    }
    return writer.buffered();
}

/// `GetPrivateProfileStringA`'s copy into the buffer: the value, then its terminator. What lies
/// past that stays from the value before.
fn copy(buffer: *Buffer, value: []const u8) void {
    @memcpy(buffer[0..value.len], value);
    buffer[value.len] = 0;
}

/// `atol` on the buffer from where `text` starts, reading up to its terminator.
fn read(text: []const u8) i32 {
    const end = std.mem.indexOfScalar(u8, text, 0) orelse text.len;
    return profile.atol(text[0..end]);
}

/// A button number as the binding keeps it: -1, or any number past what a byte holds, is none.
fn buttonNumber(number: i32) ?u8 {
    return std.math.cast(u8, number);
}

test loadKeyConfig {
    var devices: input.Devices = .{};
    const settings_file: Profile = .{ .text =
        \\[KeyConfig]
        \\JoystickInvert=0
        \\TwistEnable=1
        \\Controller=0
        \\FIRE LASERS=JOY BUTTON 5
        \\LAUNCH MISSILE=JOY BUTTON 7
        \\AFTERBURNERS=15
        \\NEXT ENEMY TARGET=SHIFT 19
        \\SMART TARGET=CONTROL 18
        \\EJECT=ALT 88
        \\[JoyConfig]
        \\FIRE LASERS=JOY BUTTON 5
        \\AFTERBURNERS=JOY BUTTON 9
        \\NEXT ENEMY TARGET=JOY BUTTON 2
        \\DeadZone=4
        \\
    };
    loadKeyConfig(&devices, settings_file);
    const settings = devices.settings;
    try std.testing.expect(!settings.joystick_invert and settings.twist_enabled and settings.hat_enabled);
    // Without a joystick, the keyboard steers.
    try std.testing.expectEqual(input.ControlMode.keyboard, settings.control_mode);
    try std.testing.expectEqual(400, settings.dead_zone);

    const bindings = devices.bindings;
    // A button in both sections, as the game writes them, keeps the key the action had.
    try std.testing.expectEqual(5, bindings.get(.fire_lasers).button.?);
    try std.testing.expectEqual(controls.binding(.fire_lasers).key, bindings.get(.fire_lasers).key);
    // In `KeyConfig` alone it stands too, fixed from the game, where the old button won.
    try std.testing.expectEqual(7, bindings.get(.launch_missile).button.?);
    // A key in `KeyConfig` and a button in `JoyConfig`.
    try std.testing.expectEqual(15, bindings.get(.afterburners).key);
    try std.testing.expectEqual(9, bindings.get(.afterburners).button.?);
    // A key with a modifier takes `JoyConfig`'s button too, fixed from the game, where it could not.
    try std.testing.expectEqual(Modifier.shift, bindings.get(.next_enemy_target).modifier);
    try std.testing.expectEqual(19, bindings.get(.next_enemy_target).key);
    try std.testing.expectEqual(2, bindings.get(.next_enemy_target).button.?);
    try std.testing.expectEqual(Modifier.control, bindings.get(.smart_target).modifier);
    try std.testing.expectEqual(Modifier.alt, bindings.get(.eject).modifier);
    try std.testing.expectEqual(88, bindings.get(.eject).key);
    // Missing entries keep the defaults: keys, modifiers and buttons alike.
    for (std.enums.values(controls.Action)) |action| {
        switch (action) {
            .fire_lasers, .launch_missile, .afterburners, .next_enemy_target, .smart_target, .eject => continue,
            else => {},
        }
        const default = controls.binding(action);
        try std.testing.expectEqual(default.key, bindings.get(action).key);
        try std.testing.expectEqual(default.modifier, bindings.get(action).modifier);
        try std.testing.expectEqual(default.button, bindings.get(action).button);
    }
}

test "an empty settings file keeps the game's defaults" {
    var devices: input.Devices = .{};
    loadKeyConfig(&devices, .empty);
    const settings = devices.settings;
    try std.testing.expect(settings.joystick_invert and settings.hat_enabled and settings.force_feedback);
    try std.testing.expect(!settings.twist_enabled);
    try std.testing.expectEqual(input.default_dead_zone, settings.dead_zone);
    for (std.enums.values(controls.Action)) |action| {
        const default = controls.binding(action);
        try std.testing.expectEqual(default.key, devices.bindings.get(action).key);
        try std.testing.expectEqual(default.modifier, devices.bindings.get(action).modifier);
        try std.testing.expectEqual(default.button, devices.bindings.get(action).button);
    }
}

test deadZone {
    try std.testing.expectEqual(1000, deadZone(.empty));
    try std.testing.expectEqual(0, deadZone(.{ .text = "[JoyConfig]\nDeadZone=0\n" }));
    try std.testing.expectEqual(10000, deadZone(.{ .text = "[JoyConfig]\nDeadZone=250\n" }));
}

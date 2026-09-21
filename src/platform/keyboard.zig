//! The keyboard, as DirectInput gave it to the game: SDL's scan codes, which follow the USB HID
//! usages, turned into DirectInput's (`DIK_*`), which follow the IBM PC's set 1 with the extended
//! keys from `0x80` up. Both name a key by its place on the keyboard, not what it types.

const std = @import("std");
const c = @import("sdl");

/// The DirectInput scan code of the key SDL names `scancode`, or null for a key DirectInput has no
/// code for.
pub fn directInput(scancode: u32) ?u8 {
    if (scancode >= table.len) return null;
    const code = table[scancode];
    return if (code == 0) null else code;
}

const table = table: {
    var codes: [c.SDL_SCANCODE_COUNT]u8 = @splat(0);
    const pairs = [_]struct { u32, u8 }{
        .{ c.SDL_SCANCODE_ESCAPE, 0x01 },
        .{ c.SDL_SCANCODE_1, 0x02 },
        .{ c.SDL_SCANCODE_2, 0x03 },
        .{ c.SDL_SCANCODE_3, 0x04 },
        .{ c.SDL_SCANCODE_4, 0x05 },
        .{ c.SDL_SCANCODE_5, 0x06 },
        .{ c.SDL_SCANCODE_6, 0x07 },
        .{ c.SDL_SCANCODE_7, 0x08 },
        .{ c.SDL_SCANCODE_8, 0x09 },
        .{ c.SDL_SCANCODE_9, 0x0A },
        .{ c.SDL_SCANCODE_0, 0x0B },
        .{ c.SDL_SCANCODE_MINUS, 0x0C },
        .{ c.SDL_SCANCODE_EQUALS, 0x0D },
        .{ c.SDL_SCANCODE_BACKSPACE, 0x0E },
        .{ c.SDL_SCANCODE_TAB, 0x0F },
        .{ c.SDL_SCANCODE_Q, 0x10 },
        .{ c.SDL_SCANCODE_W, 0x11 },
        .{ c.SDL_SCANCODE_E, 0x12 },
        .{ c.SDL_SCANCODE_R, 0x13 },
        .{ c.SDL_SCANCODE_T, 0x14 },
        .{ c.SDL_SCANCODE_Y, 0x15 },
        .{ c.SDL_SCANCODE_U, 0x16 },
        .{ c.SDL_SCANCODE_I, 0x17 },
        .{ c.SDL_SCANCODE_O, 0x18 },
        .{ c.SDL_SCANCODE_P, 0x19 },
        .{ c.SDL_SCANCODE_LEFTBRACKET, 0x1A },
        .{ c.SDL_SCANCODE_RIGHTBRACKET, 0x1B },
        .{ c.SDL_SCANCODE_RETURN, 0x1C },
        .{ c.SDL_SCANCODE_LCTRL, 0x1D },
        .{ c.SDL_SCANCODE_A, 0x1E },
        .{ c.SDL_SCANCODE_S, 0x1F },
        .{ c.SDL_SCANCODE_D, 0x20 },
        .{ c.SDL_SCANCODE_F, 0x21 },
        .{ c.SDL_SCANCODE_G, 0x22 },
        .{ c.SDL_SCANCODE_H, 0x23 },
        .{ c.SDL_SCANCODE_J, 0x24 },
        .{ c.SDL_SCANCODE_K, 0x25 },
        .{ c.SDL_SCANCODE_L, 0x26 },
        .{ c.SDL_SCANCODE_SEMICOLON, 0x27 },
        .{ c.SDL_SCANCODE_APOSTROPHE, 0x28 },
        .{ c.SDL_SCANCODE_GRAVE, 0x29 },
        .{ c.SDL_SCANCODE_LSHIFT, 0x2A },
        .{ c.SDL_SCANCODE_BACKSLASH, 0x2B },
        .{ c.SDL_SCANCODE_NONUSHASH, 0x2B },
        .{ c.SDL_SCANCODE_Z, 0x2C },
        .{ c.SDL_SCANCODE_X, 0x2D },
        .{ c.SDL_SCANCODE_C, 0x2E },
        .{ c.SDL_SCANCODE_V, 0x2F },
        .{ c.SDL_SCANCODE_B, 0x30 },
        .{ c.SDL_SCANCODE_N, 0x31 },
        .{ c.SDL_SCANCODE_M, 0x32 },
        .{ c.SDL_SCANCODE_COMMA, 0x33 },
        .{ c.SDL_SCANCODE_PERIOD, 0x34 },
        .{ c.SDL_SCANCODE_SLASH, 0x35 },
        .{ c.SDL_SCANCODE_RSHIFT, 0x36 },
        .{ c.SDL_SCANCODE_KP_MULTIPLY, 0x37 },
        .{ c.SDL_SCANCODE_LALT, 0x38 },
        .{ c.SDL_SCANCODE_SPACE, 0x39 },
        .{ c.SDL_SCANCODE_CAPSLOCK, 0x3A },
        .{ c.SDL_SCANCODE_F1, 0x3B },
        .{ c.SDL_SCANCODE_F2, 0x3C },
        .{ c.SDL_SCANCODE_F3, 0x3D },
        .{ c.SDL_SCANCODE_F4, 0x3E },
        .{ c.SDL_SCANCODE_F5, 0x3F },
        .{ c.SDL_SCANCODE_F6, 0x40 },
        .{ c.SDL_SCANCODE_F7, 0x41 },
        .{ c.SDL_SCANCODE_F8, 0x42 },
        .{ c.SDL_SCANCODE_F9, 0x43 },
        .{ c.SDL_SCANCODE_F10, 0x44 },
        .{ c.SDL_SCANCODE_NUMLOCKCLEAR, 0x45 },
        .{ c.SDL_SCANCODE_SCROLLLOCK, 0x46 },
        .{ c.SDL_SCANCODE_KP_7, 0x47 },
        .{ c.SDL_SCANCODE_KP_8, 0x48 },
        .{ c.SDL_SCANCODE_KP_9, 0x49 },
        .{ c.SDL_SCANCODE_KP_MINUS, 0x4A },
        .{ c.SDL_SCANCODE_KP_4, 0x4B },
        .{ c.SDL_SCANCODE_KP_5, 0x4C },
        .{ c.SDL_SCANCODE_KP_6, 0x4D },
        .{ c.SDL_SCANCODE_KP_PLUS, 0x4E },
        .{ c.SDL_SCANCODE_KP_1, 0x4F },
        .{ c.SDL_SCANCODE_KP_2, 0x50 },
        .{ c.SDL_SCANCODE_KP_3, 0x51 },
        .{ c.SDL_SCANCODE_KP_0, 0x52 },
        .{ c.SDL_SCANCODE_KP_PERIOD, 0x53 },
        .{ c.SDL_SCANCODE_NONUSBACKSLASH, 0x56 },
        .{ c.SDL_SCANCODE_F11, 0x57 },
        .{ c.SDL_SCANCODE_F12, 0x58 },
        .{ c.SDL_SCANCODE_KP_ENTER, 0x9C },
        .{ c.SDL_SCANCODE_RCTRL, 0x9D },
        .{ c.SDL_SCANCODE_KP_DIVIDE, 0xB5 },
        .{ c.SDL_SCANCODE_PRINTSCREEN, 0xB7 },
        .{ c.SDL_SCANCODE_RALT, 0xB8 },
        .{ c.SDL_SCANCODE_PAUSE, 0xC5 },
        .{ c.SDL_SCANCODE_HOME, 0xC7 },
        .{ c.SDL_SCANCODE_UP, 0xC8 },
        .{ c.SDL_SCANCODE_PAGEUP, 0xC9 },
        .{ c.SDL_SCANCODE_LEFT, 0xCB },
        .{ c.SDL_SCANCODE_RIGHT, 0xCD },
        .{ c.SDL_SCANCODE_END, 0xCF },
        .{ c.SDL_SCANCODE_DOWN, 0xD0 },
        .{ c.SDL_SCANCODE_PAGEDOWN, 0xD1 },
        .{ c.SDL_SCANCODE_INSERT, 0xD2 },
        .{ c.SDL_SCANCODE_DELETE, 0xD3 },
        .{ c.SDL_SCANCODE_LGUI, 0xDB },
        .{ c.SDL_SCANCODE_RGUI, 0xDC },
        .{ c.SDL_SCANCODE_APPLICATION, 0xDD },
    };
    for (pairs) |pair| codes[pair[0]] = pair[1];
    break :table codes;
};

test directInput {
    try std.testing.expectEqual(0x02, directInput(c.SDL_SCANCODE_1).?);
    try std.testing.expectEqual(0xCB, directInput(c.SDL_SCANCODE_LEFT).?);
    try std.testing.expectEqual(0x36, directInput(c.SDL_SCANCODE_RSHIFT).?);
    try std.testing.expectEqual(null, directInput(c.SDL_SCANCODE_F13));
    try std.testing.expectEqual(null, directInput(100_000));
}

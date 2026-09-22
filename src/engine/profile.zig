//! Windows' private profile functions, `GetPrivateProfileIntA` and `GetPrivateProfileStringA`,
//! which the game reads its settings from `starlancer.ini` with. A profile is lines of text:
//! `[section]` starts a section, and `key=value` gives a key its value. Sections and keys are
//! matched without regard to case, and a value loses the spaces around it and one pair of quotes.

const std = @import("std");

pub const Profile = struct {
    text: []const u8,

    /// A profile with nothing in it, as when the file is missing: every read gives its default.
    pub const empty: Profile = .{ .text = "" };

    /// The value of `key` in `section`, or null when the profile has none.
    pub fn value(profile: Profile, section: []const u8, key: []const u8) ?[]const u8 {
        var in_section = false;
        var lines = std.mem.splitAny(u8, profile.text, "\r\n");
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0) continue;
            if (line[0] == '[') {
                const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
                in_section = std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[1..end], " \t"), section);
                continue;
            }
            if (!in_section) continue;
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, line[0..equals], " \t"), key)) continue;
            const found = std.mem.trim(u8, line[equals + 1 ..], " \t");
            if (found.len >= 2 and (found[0] == '"' or found[0] == '\'') and found[found.len - 1] == found[0]) {
                return found[1 .. found.len - 1];
            }
            return found;
        }
        return null;
    }

    /// `GetPrivateProfileStringA`: the value, or `default` when there is none, cut to `size - 1`
    /// bytes as the game's buffer holds.
    pub fn string(profile: Profile, section: []const u8, key: []const u8, default: []const u8, size: usize) []const u8 {
        const found = profile.value(section, key) orelse default;
        return found[0..@min(found.len, size -| 1)];
    }

    /// `GetPrivateProfileIntA`: the value's leading decimal digits, 0 if it starts with none, or
    /// `default` when there is no value.
    pub fn int(profile: Profile, section: []const u8, key: []const u8, default: u32) u32 {
        const found = profile.value(section, key) orelse return default;
        var number: u32 = 0;
        for (found) |c| {
            if (!std.ascii.isDigit(c)) break;
            number = number *% 10 +% (c - '0');
        }
        return number;
    }
};

/// `atol`, as the C runtime reads a number: spaces, an optional sign, then decimal digits, as many
/// as there are; 0 without any.
pub fn atol(text: []const u8) i32 {
    var rest = std.mem.trimStart(u8, text, " \t");
    var negative = false;
    if (rest.len > 0 and (rest[0] == '-' or rest[0] == '+')) {
        negative = rest[0] == '-';
        rest = rest[1..];
    }
    var number: i32 = 0;
    for (rest) |c| {
        if (!std.ascii.isDigit(c)) break;
        number = number *% 10 +% (c - '0');
    }
    return if (negative) -%number else number;
}

test Profile {
    const profile: Profile = .{ .text =
        \\; the game writes this file itself
        \\[KeyConfig]
        \\JoystickInvert = 0
        \\FIRE LASERS=JOY BUTTON 3
        \\Controller=2 ; trailing words
        \\
        \\[joyconfig]
        \\fire lasers="JOY BUTTON 1"
        \\Empty=
        \\
    };
    try std.testing.expectEqualStrings("0", profile.value("KeyConfig", "JoystickInvert").?);
    try std.testing.expectEqualStrings("JOY BUTTON 3", profile.value("keyconfig", "fire lasers").?);
    try std.testing.expectEqualStrings("JOY BUTTON 1", profile.value("JoyConfig", "FIRE LASERS").?);
    try std.testing.expectEqual(null, profile.value("JoyConfig", "JoystickInvert"));
    try std.testing.expectEqual(0, profile.int("KeyConfig", "JoystickInvert", 1));
    try std.testing.expectEqual(1, profile.int("KeyConfig", "HatEnable", 1));
    try std.testing.expectEqual(2, profile.int("KeyConfig", "Controller", 0));
    try std.testing.expectEqual(0, profile.int("JoyConfig", "Empty", 7));
    try std.testing.expectEqualStrings("JOY", profile.string("JoyConfig", "Fire Lasers", "", 4));
    try std.testing.expectEqualStrings("57", profile.string("JoyConfig", "Missing", "57", 0x80));
    try std.testing.expectEqual(null, Profile.empty.value("KeyConfig", "Controller"));
}

test atol {
    try std.testing.expectEqual(57, atol("57"));
    try std.testing.expectEqual(-1, atol(" -1"));
    try std.testing.expectEqual(12, atol("12abc"));
    try std.testing.expectEqual(0, atol("abc"));
    try std.testing.expectEqual(0, atol(""));
}

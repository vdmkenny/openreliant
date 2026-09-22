//! The display's windows: the panels `hud.cpp` brings over the view when a key or the game asks for
//! one, and takes away again once its time is up. Each has a record at `0x00501D30`, 40 bytes
//! apart: its phase, where it stands, the pieces of its frame, how long it stays, how far it has
//! opened and whether it is held open. `hud_window_open` (`0x0048B510`) and `hud_window_close`
//! (`0x0048B590`) start one opening or closing, for a key, the game or a mission's script
//! (`OpenInstrument` and `CloseInstrument`, which call a window an instrument); `hud_draw` moves
//! each on once a frame and draws it with `hud_window_draw` (`0x00486830`): sliding and shrinking
//! into place as it opens, the reverse as it closes, and in place while it is open.
//!
//! Ported so far: the windows' phases and times, their frames and how they open and close. Not
//! yet: what each window shows inside its frame, which [`hud.md`](../../../../docs/engine/hud.md)
//! lists with the state each reads; the display's sounds for a window opening and closing
//! (`hud_beep` 1 and 2); and, in mission 25 before `0x00587CDC` is set, the gunnery, missile and
//! wing status windows standing still and unseen.

const std = @import("std");
const Allocator = std.mem.Allocator;

const camera = @import("../camera.zig");
const device = @import("../../surrender/srd3d/device.zig");
const hud = @import("../hud.zig");
const math = @import("../../surrender/math.zig");
const spr = @import("../../../formats/spr.zig");

/// The windows, numbered as the game numbers their records.
pub const Window = enum(u4) {
    /// The face of whoever speaks on the radio, from the mission's films, with a caption; it
    /// closes when the film ends. **Unverified:** that the pictures are the speakers'.
    radio = 0,
    /// The guns: the ship as a wire frame, the gun or group that fires, and how.
    gunnery = 1,
    /// The missiles in their ring, the armed one's name and how many are left.
    missiles = 2,
    /// The target display's small form: the target's schematic with its shields, its name, its
    /// range and its speed (`hud_ship_status` for the target).
    target = 3,
    /// A bar each for the weapons, the engines and the shields.
    damage = 4,
    /// Frames alone, which no key opens and a mission's script may (`OpenInstrument`).
    /// **Unknown:** what they are for.
    _unknown_5 = 5,
    _unknown_6 = 6,
    /// The power distribution: the ball and the shares of the guns, the engines and the shields.
    power = 7,
    /// The target display's large form, for a big target: its own picture and its subtarget.
    big_target = 8,
    /// A frame alone, which never opens in a multiplayer game. **Unknown:** what it is for.
    _unknown_9 = 9,
    /// The mission's objectives.
    objectives = 10,
    /// The radio's menu of who can be called.
    comms = 11,
    _unknown_12 = 12,
    /// The wing's fighters, each with a bar for its damage.
    wing_status = 13,
    /// **Unknown:** what it shows.
    _unknown_14 = 14,
};

/// Where a window stands in its opening and closing (`+0x00`).
pub const Phase = enum(u16) {
    shut = 0,
    opening = 1,
    closing = 2,
    open = 3,
};

/// The ticks a window takes to open, and to close.
pub const opening_ticks: i32 = 60;

/// The pane `hud_init` draws a window into as it opens and closes, which is then drawn scaled
/// onto the display (`0x0057998C`, 225 by 170): what of a window falls outside it is cut off
/// meanwhile.
pub const buffer_size: [2]i32 = .{ 225, 170 };

/// A piece of a window's frame, one of the pieces at `0x00502078`, 20 bytes each: one of the
/// display's shapes, where it stands from the window's own place, and how it is flipped.
pub const Piece = struct {
    shape: u16,
    /// From the window's place, in the display's pixels. The record holds each as a float, and
    /// `hud_window_draw` cuts it down to a whole number.
    offset: [2]i32,
    mirror: hud.Mirror = .{},
};

/// The pieces the windows' frames use, by their number at `0x00502078`.
const pieces = struct {
    const p0: Piece = .{ .shape = 0x78, .offset = .{ 12, 1 } };
    const p1: Piece = .{ .shape = 0x79, .offset = .{ 0, 14 } };
    const p2: Piece = .{ .shape = 0x7A, .offset = .{ 1, -58 } };
    const p3: Piece = .{ .shape = 0x7B, .offset = .{ 1, -147 } };
    const p4: Piece = .{ .shape = 0x7C, .offset = .{ 0, 0 } };
    const p6: Piece = .{ .shape = 0x7E, .offset = .{ 1, 35 } };
    const p14: Piece = .{ .shape = 0x78, .offset = .{ -139, 1 }, .mirror = .of(1) };
    const p15: Piece = .{ .shape = 0x79, .offset = .{ -32, 14 }, .mirror = .of(1) };
    const p16: Piece = .{ .shape = 0x7A, .offset = .{ -32, -58 }, .mirror = .of(1) };
    const p17: Piece = .{ .shape = 0x78, .offset = .{ 13, -23 }, .mirror = .of(2) };
    const p18: Piece = .{ .shape = 0x7B, .offset = .{ -32, -146 }, .mirror = .of(1) };
    const p27: Piece = .{ .shape = 0x7D, .offset = .{ -210, -24 } };
};

/// What a window's record holds from the start.
pub const Layout = struct {
    /// Where the window stands, a fraction of the screen across and down (`+0x04`, `+0x08`).
    at: [2]f32,
    /// Where its place falls in `buffer_size`'s pane as it opens and closes, a fraction of the
    /// pane (`0x00501F88`, 16 bytes a window). The same as `at` for all but the target display.
    in_buffer: [2]f32,
    /// The pieces of its frame, drawn in the view ahead (`+0x0C`, their count, and from `+0x0E`
    /// their numbers).
    frame: []const Piece,
    /// The ticks it stays open, unless held (`+0x1C`).
    stay: i32,
};

/// Every window's layout, as the payload holds it.
pub const layouts: std.EnumArray(Window, Layout) = .init(.{
    .radio = .{ .at = .{ 0, 0 }, .in_buffer = .{ 0, 0 }, .frame = &.{ pieces.p1, pieces.p0 }, .stay = 400 },
    .gunnery = .{ .at = .{ 0, 1 }, .in_buffer = .{ 0, 1 }, .frame = &.{ pieces.p3, pieces.p17 }, .stay = 1200 },
    .missiles = .{ .at = .{ 0.5, 0 }, .in_buffer = .{ 0.5, 0 }, .frame = &.{ pieces.p4, pieces.p6 }, .stay = 200 },
    .target = .{ .at = .{ 0.7, 1 }, .in_buffer = .{ 0.2, 1 }, .frame = &.{}, .stay = 2000 },
    .damage = .{ .at = .{ 1, 0 }, .in_buffer = .{ 1, 0 }, .frame = &.{ pieces.p14, pieces.p15 }, .stay = 1000 },
    ._unknown_5 = .{ .at = .{ 0, 0 }, .in_buffer = .{ 0, 0 }, .frame = &.{ pieces.p0, pieces.p1 }, .stay = 200 },
    ._unknown_6 = .{ .at = .{ 0, 0 }, .in_buffer = .{ 0, 0 }, .frame = &.{ pieces.p0, pieces.p1 }, .stay = 200 },
    .power = .{ .at = .{ 0, 0.5 }, .in_buffer = .{ 0, 0.5 }, .frame = &.{pieces.p2}, .stay = 1000 },
    .big_target = .{ .at = .{ 1, 1 }, .in_buffer = .{ 1, 1 }, .frame = &.{ pieces.p27, pieces.p18 }, .stay = 2000 },
    ._unknown_9 = .{ .at = .{ 1, 0.5 }, .in_buffer = .{ 1, 0.5 }, .frame = &.{pieces.p16}, .stay = 1000 },
    .objectives = .{ .at = .{ 1, 0.5 }, .in_buffer = .{ 1, 0.5 }, .frame = &.{pieces.p16}, .stay = 1000 },
    .comms = .{ .at = .{ 0, 0 }, .in_buffer = .{ 0, 0 }, .frame = &.{ pieces.p1, pieces.p0 }, .stay = 1500 },
    ._unknown_12 = .{ .at = .{ 0, 0 }, .in_buffer = .{ 0, 0 }, .frame = &.{ pieces.p0, pieces.p1 }, .stay = 1000 },
    .wing_status = .{ .at = .{ 1, 0.5 }, .in_buffer = .{ 1, 0.5 }, .frame = &.{pieces.p16}, .stay = 1000 },
    ._unknown_14 = .{ .at = .{ 0, 0 }, .in_buffer = .{ 0, 0 }, .frame = &.{ pieces.p1, pieces.p0 }, .stay = 2000 },
});

/// What a window's record holds as the game runs.
pub const Status = struct {
    phase: Phase = .shut,
    /// The ticks left before it closes (`+0x18`).
    left: i32 = 0,
    /// How far it has opened, 0 to `opening_ticks` (`+0x20`).
    progress: i32 = 0,
    /// Held open until its key is pressed again (`+0x24`).
    held: bool = false,
};

/// How a window is drawn this frame.
pub const Shown = struct {
    /// How many times its own size it is drawn, and how much farther than its own place from the
    /// middle of the screen it stands: 1 once open; from 2 down to 1 as it opens, and back up to 2
    /// as it closes.
    scale: f32,
    /// Whether it is drawn through `buffer_size`'s pane, and so cut to it, as it opens and closes.
    buffered: bool,
};

pub const Windows = struct {
    status: std.EnumArray(Window, Status) = .initFill(.{}),

    /// `hud_window_open` (`0x0048B510`): starts `window` opening, and gives it its full time to
    /// stay whatever its phase, so a window closing carries on closing. In a multiplayer game the
    /// missiles, the objectives and window 9 never open. Returns whether the window is up.
    pub fn open(windows: *Windows, window: Window, multiplayer: bool) bool {
        if (multiplayer and (window == .missiles or window == ._unknown_9 or window == .objectives)) return false;
        const status = windows.status.getPtr(window);
        status.left = layouts.get(window).stay;
        if (status.phase == .shut) {
            status.phase = .opening;
            status.progress = 0;
            status.held = false;
        }
        return true;
    }

    /// `hud_window_close` (`0x0048B590`): starts `window` closing if it is open or opening, from
    /// its full size, however far it had opened, and lets go of it. For the target display's two
    /// forms the game also keeps a picture of what they show, which they close with.
    pub fn close(windows: *Windows, window: Window) void {
        const status = windows.status.getPtr(window);
        if (!windows.up(window)) return;
        status.phase = .closing;
        status.held = false;
        status.progress = opening_ticks;
    }

    /// Whether `window` is open or opening, which is what the keys that close a window test.
    pub fn up(windows: *const Windows, window: Window) bool {
        const phase = windows.status.get(window).phase;
        return phase == .open or phase == .opening;
    }

    /// One window's turn of `hud_draw`'s loop (`0x004863F3`): an opening or closing window moves on
    /// by `frame_duration` ticks; an open one counts its time down and, once that has run out and
    /// nothing holds it, starts closing, though it is drawn in place once more. Returns how the
    /// window is drawn, or null for one that is shut.
    pub fn step(windows: *Windows, window: Window, frame_duration: i32) ?Shown {
        const status = windows.status.getPtr(window);
        switch (status.phase) {
            .opening => {
                status.progress += frame_duration;
                if (status.progress >= opening_ticks) {
                    status.phase = .open;
                    status.progress = opening_ticks;
                }
            },
            .closing => {
                status.progress -= frame_duration;
                if (status.progress < 1) {
                    status.phase = .shut;
                    status.progress = 0;
                }
            },
            .shut, .open => {},
        }
        switch (status.phase) {
            .shut => return null,
            .opening, .closing => return .{ .scale = openingScale(status.progress), .buffered = true },
            .open => {
                if (status.left < 0 and !status.held) {
                    status.left = 0;
                    windows.close(window);
                } else {
                    // The time counts down by the frame's ticks as a halfword.
                    status.left -= @as(i16, @truncate(frame_duration));
                }
                return .{ .scale = 1, .buffered = false };
            },
        }
    }

    /// `hud_draw`'s loop over the windows, which it runs in every view: each moves on, and in the
    /// view ahead from the cockpit is drawn over the display.
    pub fn frame(
        windows: *Windows,
        art: *hud.Art,
        gpa: Allocator,
        target: device.Device,
        screen: [2]u32,
        last_view: camera.View,
        frame_duration: i32,
        colour: [4]f32,
        scale: f32,
    ) (spr.Error || Allocator.Error)!void {
        for (std.enums.values(Window)) |window| {
            const shown = windows.step(window, frame_duration) orelse continue;
            if (!hud.instrumented(last_view)) continue;
            try draw(art, gpa, target, screen, window, shown, colour, scale);
        }
    }
};

/// How large a window is drawn `progress` ticks into its opening: twice its size at the start, its
/// own at the end.
fn openingScale(progress: i32) f32 {
    const step: f32 = 1.0 / @as(f32, @floatFromInt(opening_ticks));
    return (1 - @as(f32, @floatFromInt(progress)) * step) + 1;
}

/// Where a window's place stands on the screen when it is drawn as `shown` says: its own place,
/// moved out from the middle of the screen by the scale it is drawn at.
pub fn anchor(screen: [2]u32, window: Window, shown: Shown, scale: f32) [2]i32 {
    const at = layouts.get(window).at;
    return hud.place(screen, .{ 0, 0 }, (at[0] - 0.5) * shown.scale + 0.5, (at[1] - 0.5) * shown.scale + 0.5, scale);
}

/// The part of the screen `buffer_size`'s pane covers with a window's place at `at`, drawn `size`
/// times the pane's own: the window's place stands where `in_buffer` says in it, as
/// `hud_window_draw` draws it there and `VFX_buffer_transform` scales the pane about the place.
pub fn bufferClip(window: Window, at: [2]i32, size: f32) hud.Clip {
    const in_buffer = layouts.get(window).in_buffer;
    var from: [2]f32 = undefined;
    var to: [2]f32 = undefined;
    for (&from, &to, at, buffer_size, in_buffer) |*low, *high, place, extent, fraction| {
        const inside: f32 = @floatFromInt(round(@as(f32, @floatFromInt(extent - 2)) * fraction + 1));
        const centre: f32 = @floatFromInt(place);
        low.* = centre - inside * size;
        high.* = centre + (@as(f32, @floatFromInt(extent)) - inside) * size;
    }
    return .{ .left = from[0], .top = from[1], .right = to[0], .bottom = to[1] };
}

/// `hud_window_draw` (`0x00486830`) for the frame: in the view ahead, each piece of the window's
/// frame, from where its place stands.
fn draw(
    art: *hud.Art,
    gpa: Allocator,
    target: device.Device,
    screen: [2]u32,
    window: Window,
    shown: Shown,
    colour: [4]f32,
    scale: f32,
) (spr.Error || Allocator.Error)!void {
    const at = anchor(screen, window, shown, scale);
    const size = scale * shown.scale;
    const clip: ?hud.Clip = if (shown.buffered) bufferClip(window, at, size) else null;
    for (layouts.get(window).frame) |piece| {
        const from: [2]i32 = .{
            at[0] + round(@as(f32, @floatFromInt(piece.offset[0])) * size),
            at[1] + round(@as(f32, @floatFromInt(piece.offset[1])) * size),
        };
        try hud.drawShapeWith(art, gpa, target, piece.shape, from, colour, size, .{ .mirror = piece.mirror, .clip = clip });
    }
}

fn round(value: f32) i32 {
    return @intFromFloat(math.roundEven(value));
}

test "a window opens, stays its time and closes" {
    var windows: Windows = .{};
    try std.testing.expect(windows.open(.damage, false));
    try std.testing.expectEqual(Phase.opening, windows.status.get(.damage).phase);
    // Half open, it is drawn one and a half times its size; open, its own.
    try std.testing.expectApproxEqAbs(1.5, windows.step(.damage, 30).?.scale, 1e-5);
    try std.testing.expectEqual(Shown{ .scale = 1, .buffered = false }, windows.step(.damage, 30).?);
    try std.testing.expectEqual(Phase.open, windows.status.get(.damage).phase);
    // It stays its 1000 ticks, counted from the frame it opened in.
    _ = windows.step(.damage, 969);
    try std.testing.expectEqual(1, windows.status.get(.damage).left);
    _ = windows.step(.damage, 2);
    try std.testing.expectEqual(Phase.open, windows.status.get(.damage).phase);
    // Past them it starts closing, drawn in place that once more.
    try std.testing.expectEqual(Shown{ .scale = 1, .buffered = false }, windows.step(.damage, 1).?);
    try std.testing.expectEqual(Phase.closing, windows.status.get(.damage).phase);
    try std.testing.expectApproxEqAbs(1.5, windows.step(.damage, 30).?.scale, 1e-5);
    try std.testing.expectEqual(null, windows.step(.damage, 30));
    try std.testing.expectEqual(Phase.shut, windows.status.get(.damage).phase);
}

test "a held window stays open" {
    var windows: Windows = .{};
    _ = windows.open(.gunnery, false);
    windows.status.getPtr(.gunnery).held = true;
    _ = windows.step(.gunnery, 60);
    for (0..10) |_| _ = windows.step(.gunnery, 1000);
    try std.testing.expectEqual(Phase.open, windows.status.get(.gunnery).phase);
    // Closing lets go of it.
    windows.close(.gunnery);
    try std.testing.expectEqual(Phase.closing, windows.status.get(.gunnery).phase);
    try std.testing.expect(!windows.status.get(.gunnery).held);
}

test "opening a closing window only gives it its time" {
    var windows: Windows = .{};
    _ = windows.open(.power, false);
    // Closed while still opening, it closes from its full size.
    _ = windows.step(.power, 20);
    windows.close(.power);
    try std.testing.expectEqual(opening_ticks, windows.status.get(.power).progress);
    try std.testing.expect(!windows.up(.power));
    try std.testing.expect(windows.open(.power, false));
    try std.testing.expectEqual(Phase.closing, windows.status.get(.power).phase);
    try std.testing.expectEqual(layouts.get(.power).stay, windows.status.get(.power).left);
}

test "a multiplayer game refuses three windows" {
    var windows: Windows = .{};
    try std.testing.expect(!windows.open(.missiles, true));
    try std.testing.expect(!windows.open(.objectives, true));
    try std.testing.expect(!windows.open(._unknown_9, true));
    try std.testing.expect(windows.open(.comms, true));
    try std.testing.expect(!windows.up(.missiles));
}

test bufferClip {
    // The gunnery window's place is the pane's lower left, a pixel in: at its own size the pane
    // runs a pixel left of it and 224 right, 169 above it and one below.
    const clip = bufferClip(.gunnery, .{ 100, 500 }, 1);
    try std.testing.expectEqual(hud.Clip{ .left = 99, .top = 331, .right = 324, .bottom = 501 }, clip);
    // Twice the size, twice as far.
    const twice = bufferClip(.power, .{ 0, 0 }, 2);
    try std.testing.expectEqual(hud.Clip{ .left = -2, .top = -170, .right = 448, .bottom = 170 }, twice);
}

test anchor {
    // Open, a window stands in its place; at the start of its opening, twice as far from the
    // middle of the screen.
    const screen: [2]u32 = .{ 1024, 768 };
    const open = anchor(screen, .gunnery, .{ .scale = 1, .buffered = false }, 1);
    try std.testing.expectEqual(hud.place(screen, .{ 0, 0 }, 0, 1, 1), open);
    const starting = anchor(screen, .gunnery, .{ .scale = 2, .buffered = true }, 1);
    try std.testing.expectEqual(hud.place(screen, .{ 0, 0 }, -0.5, 1.5, 1), starting);
}

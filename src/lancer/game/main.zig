//! `C:\lancer\game\main.cpp`: a mission's loop. `mission_run` (`0x00494040`) runs a game tick for
//! each tick of the timer and draws a frame with `mission_frame` (`0x004924B0`). **Unverified:** the
//! two lie after `language.cpp`'s code, where `main.cpp`'s begins; by what they do they are this
//! file's.
//!
//! Ported so far: how `mission_frame` puts the scene together and draws it. Not yet: the ticks, the
//! simulation, the HUD, the cockpit, the effects and the rest of what it adds to the scene.

const std = @import("std");
const Allocator = std.mem.Allocator;

const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const backdrop = @import("backdrop.zig");
const camera = @import("camera.zig");
const nebula = @import("nebula.zig");
const objects = @import("objects.zig");

/// What `mission_frame` draws a frame of.
pub const Frame = struct {
    /// The live objects shown, each by its model's nodes.
    models: []objects.Model,
    space: *backdrop.Backdrop,
    sky: *nebula.Sky,
    view: camera.View,
    cockpit_mode: camera.CockpitMode,
    /// Last frame's view (`camera_view_last`, `0x00539A64`).
    last_view: camera.View,
};

/// Puts the frame's scene together and draws it, in `mission_frame`'s order: the objects, the
/// backdrop, the sky; the star streaks are reset when the view has changed since the last frame;
/// then `sr_render`. `arena` holds what the frame needs until it is drawn.
pub fn drawFrame(gpa: Allocator, arena: Allocator, scene: *srcore.Scene, context: *srapi.Context, frame: Frame, driver: srcore.Driver) Allocator.Error!void {
    scene.clear();
    for (frame.models) |*model| try model.draw(gpa, scene, .world);
    try frame.space.frame(gpa, scene, context, frame.view, frame.cockpit_mode);
    if (context.hardware) try frame.sky.frame(gpa, scene, context);
    if (frame.view != frame.last_view) frame.space.resetStreaks();
    try srcore.render(arena, context, scene, driver);
}

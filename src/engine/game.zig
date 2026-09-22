//! `C:\lancer\game`: the game's own source files, a module for each that this project describes.
//! [`sources.zig`](sources.zig) places their code.

const std = @import("std");

pub const ai = @import("game/ai.zig");
pub const aidefend = @import("game/aidefend.zig");
pub const aifight = @import("game/aifight.zig");
pub const aigeneric = @import("game/aigeneric.zig");
pub const backdrop = @import("game/backdrop.zig");
pub const bigfile = @import("game/bigfile.zig");
pub const camera = @import("game/camera.zig");
pub const create = @import("game/create.zig");
pub const environfx = @import("game/environfx.zig");
pub const hud = @import("game/hud.zig");
pub const executor = @import("game/executor.zig");
pub const gameobj = @import("game/gameobj.zig");
pub const guns = @import("game/guns.zig");
pub const hog_snd = @import("game/hog_snd.zig");
pub const interface = @import("game/interface.zig");
pub const language = @import("game/language.zig");
pub const main = @import("game/main.zig");
pub const matmanager = @import("game/matmanager.zig");
pub const missiles = @import("game/missiles.zig");
pub const nebula = @import("game/nebula.zig");
pub const objects = @import("game/objects.zig");
pub const pilots = @import("game/pilots.zig");
pub const srofiles = @import("game/srofiles.zig");
pub const xtrabits = @import("game/xtrabits.zig");

test {
    std.testing.refAllDecls(@This());
}

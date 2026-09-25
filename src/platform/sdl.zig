//! SDL's errors, as the platform reports them: each failed call logs what SDL says of it and fails
//! with `error.Sdl`.

const std = @import("std");
const c = @import("sdl");

pub const Error = error{Sdl};

/// SDL's last error, logged under the call `what` that failed, as an error.
pub fn fail(what: []const u8) Error {
    std.log.scoped(.sdl).err("{s}: {s}", .{ what, c.SDL_GetError() });
    return error.Sdl;
}

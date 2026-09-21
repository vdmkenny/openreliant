//! The game's window, its events and its presentation, with SDL3: in place of the Win32 window and
//! message loop `WinMain` (`0x004A8B10`) runs, and of DirectDraw's flip.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("sdl");

const keyboard = @import("keyboard.zig");
const macos = @import("macos.zig");

pub const Error = error{Sdl};

/// SDL's last error, logged, as an error.
fn fail(what: []const u8) Error {
    std.log.scoped(.sdl).err("{s}: {s}", .{ what, c.SDL_GetError() });
    return error.Sdl;
}

/// What happened since the last frame.
pub const Event = union(enum) {
    quit,
    /// A key went down or up, by its DirectInput scan code (`keyboard.directInput`): the key's
    /// place on the keyboard, whatever it types. Keys DirectInput has no code for are left out.
    key: struct { scan: u8, down: bool },
};

pub const Window = struct {
    handle: *c.SDL_Window,
    gpu: *c.SDL_GPUDevice,
    /// A frame drawn in memory, and the texture it goes up to on its way to the screen.
    frame: ?struct { width: u32, height: u32, transfer: *c.SDL_GPUTransferBuffer, texture: *c.SDL_GPUTexture } = null,

    pub fn open(title: [*:0]const u8, width: u32, height: u32) Error!Window {
        if (builtin.os.tag == .macos) macos.ignoreSavedState();
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return fail("SDL_Init");
        errdefer c.SDL_Quit();
        const handle = c.SDL_CreateWindow(title, @intCast(width), @intCast(height), c.SDL_WINDOW_RESIZABLE) orelse return fail("SDL_CreateWindow");
        errdefer c.SDL_DestroyWindow(handle);
        const formats = c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_MSL | c.SDL_GPU_SHADERFORMAT_DXIL;
        const gpu = c.SDL_CreateGPUDevice(formats, false, null) orelse return fail("SDL_CreateGPUDevice");
        errdefer c.SDL_DestroyGPUDevice(gpu);
        if (!c.SDL_ClaimWindowForGPUDevice(gpu, handle)) return fail("SDL_ClaimWindowForGPUDevice");
        return .{ .handle = handle, .gpu = gpu };
    }

    pub fn close(window: *Window) void {
        window.releaseFrame();
        c.SDL_ReleaseWindowFromGPUDevice(window.gpu, window.handle);
        c.SDL_DestroyGPUDevice(window.gpu);
        c.SDL_DestroyWindow(window.handle);
        c.SDL_Quit();
    }

    /// The window's size in points, which the game draws at.
    pub fn size(window: Window) [2]u32 {
        var width: c_int = 0;
        var height: c_int = 0;
        _ = c.SDL_GetWindowSize(window.handle, &width, &height);
        return .{ @intCast(@max(width, 1)), @intCast(@max(height, 1)) };
    }

    /// The next event waiting, or null.
    pub fn poll(window: *Window) ?Event {
        _ = window;
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => return .quit,
                c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                    const scan = keyboard.directInput(event.key.scancode) orelse continue;
                    return .{ .key = .{ .scan = scan, .down = event.key.down } };
                },
                else => {},
            }
        }
        return null;
    }

    /// Puts a frame drawn in memory, rows of red, green, blue and alpha from the top, on the screen,
    /// scaled to the window.
    pub fn present(window: *Window, rgba: []const u8, width: u32, height: u32) Error!void {
        const frame = try window.frameOf(width, height);
        const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(window.gpu, frame.transfer, true) orelse return fail("SDL_MapGPUTransferBuffer"));
        @memcpy(mapped[0 .. width * height * 4], rgba[0 .. width * height * 4]);
        c.SDL_UnmapGPUTransferBuffer(window.gpu, frame.transfer);

        const commands = c.SDL_AcquireGPUCommandBuffer(window.gpu) orelse return fail("SDL_AcquireGPUCommandBuffer");
        const copy = c.SDL_BeginGPUCopyPass(commands);
        c.SDL_UploadToGPUTexture(
            copy,
            &.{ .transfer_buffer = frame.transfer, .offset = 0, .pixels_per_row = width, .rows_per_layer = height },
            &.{ .texture = frame.texture, .w = width, .h = height, .d = 1 },
            true,
        );
        c.SDL_EndGPUCopyPass(copy);
        var target: ?*c.SDL_GPUTexture = null;
        var target_width: u32 = 0;
        var target_height: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(commands, window.handle, &target, &target_width, &target_height)) {
            _ = c.SDL_CancelGPUCommandBuffer(commands);
            return fail("SDL_WaitAndAcquireGPUSwapchainTexture");
        }
        if (target) |swapchain| {
            var blit = std.mem.zeroes(c.SDL_GPUBlitInfo);
            blit.source = .{ .texture = frame.texture, .w = width, .h = height };
            blit.destination = .{ .texture = swapchain, .w = target_width, .h = target_height };
            blit.load_op = c.SDL_GPU_LOADOP_DONT_CARE;
            blit.filter = c.SDL_GPU_FILTER_LINEAR;
            c.SDL_BlitGPUTexture(commands, &blit);
        }
        if (!c.SDL_SubmitGPUCommandBuffer(commands)) return fail("SDL_SubmitGPUCommandBuffer");
    }

    /// The texture a frame of `width` by `height` goes up to, made again when the size changes.
    fn frameOf(window: *Window, width: u32, height: u32) Error!@typeInfo(@TypeOf(window.frame)).optional.child {
        if (window.frame) |frame| {
            if (frame.width == width and frame.height == height) return frame;
            window.releaseFrame();
        }
        const transfer = c.SDL_CreateGPUTransferBuffer(window.gpu, &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = width * height * 4,
            .props = 0,
        }) orelse return fail("SDL_CreateGPUTransferBuffer");
        errdefer c.SDL_ReleaseGPUTransferBuffer(window.gpu, transfer);
        var info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
        info.type = c.SDL_GPU_TEXTURETYPE_2D;
        info.format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        info.usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
        info.width = width;
        info.height = height;
        info.layer_count_or_depth = 1;
        info.num_levels = 1;
        const texture = c.SDL_CreateGPUTexture(window.gpu, &info) orelse return fail("SDL_CreateGPUTexture");
        window.frame = .{ .width = width, .height = height, .transfer = transfer, .texture = texture };
        return window.frame.?;
    }

    fn releaseFrame(window: *Window) void {
        const frame = window.frame orelse return;
        c.SDL_ReleaseGPUTexture(window.gpu, frame.texture);
        c.SDL_ReleaseGPUTransferBuffer(window.gpu, frame.transfer);
        window.frame = null;
    }
};

/// Hundredths of a second since SDL started: the game's ticks (`tick_timer` runs 100 times a
/// second).
pub fn ticks() u64 {
    return c.SDL_GetTicks() / 10;
}

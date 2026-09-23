//! What the platform layer does for macOS before SDL starts, and asks of Core Audio.

const std = @import("std");

extern "objc" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern "objc" fn sel_registerName(name: [*:0]const u8) *anyopaque;
extern "objc" fn objc_msgSend() void;

/// Keeps AppKit from restoring the windows of an earlier run, for this run only
/// (`ApplePersistenceIgnoreState` in the registration domain). SDL registers the same only once the
/// application is active, and until then AppKit, handling the launch, can spend seconds looking
/// for state to restore.
pub fn ignoreSavedState() void {
    const Id = ?*anyopaque;
    const Sel = *anyopaque;
    const send = struct {
        fn object(receiver: Id, selector: [*:0]const u8) Id {
            const f: *const fn (Id, Sel) callconv(.c) Id = @ptrCast(&objc_msgSend);
            return f(receiver, sel_registerName(selector));
        }
        fn string(text: [*:0]const u8) Id {
            const f: *const fn (Id, Sel, [*:0]const u8) callconv(.c) Id = @ptrCast(&objc_msgSend);
            return f(objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), text);
        }
        fn yes() Id {
            const f: *const fn (Id, Sel, bool) callconv(.c) Id = @ptrCast(&objc_msgSend);
            return f(objc_getClass("NSNumber"), sel_registerName("numberWithBool:"), true);
        }
        fn pair(value: Id, key: Id) Id {
            const f: *const fn (Id, Sel, Id, Id) callconv(.c) Id = @ptrCast(&objc_msgSend);
            return f(objc_getClass("NSDictionary"), sel_registerName("dictionaryWithObject:forKey:"), value, key);
        }
        fn register(defaults: Id, dictionary: Id) void {
            const f: *const fn (Id, Sel, Id) callconv(.c) void = @ptrCast(&objc_msgSend);
            f(defaults, sel_registerName("registerDefaults:"), dictionary);
        }
    };
    const defaults = send.object(objc_getClass("NSUserDefaults"), "standardUserDefaults") orelse return;
    send.register(defaults, send.pair(send.yes(), send.string("ApplePersistenceIgnoreState")));
}

const AudioObjectPropertyAddress = extern struct {
    selector: u32,
    scope: u32,
    element: u32,
};

extern "c" fn AudioObjectGetPropertyData(object: u32, address: *const AudioObjectPropertyAddress, qualifier_size: u32, qualifier: ?*const anyopaque, size: *u32, data: *anyopaque) i32;

/// A Core Audio four-character code.
fn code(comptime text: *const [4]u8) u32 {
    return std.mem.readInt(u32, text, .big);
}

/// A 32-bit property of a Core Audio object, or null where it has none.
fn property(object: u32, selector: u32, scope: u32) ?u32 {
    const address: AudioObjectPropertyAddress = .{ .selector = selector, .scope = scope, .element = 0 };
    var value: u32 = 0;
    var size: u32 = @sizeOf(u32);
    if (AudioObjectGetPropertyData(object, &address, 0, null, &size, &value) != 0) return null;
    return value;
}

/// Whether the default output is headphones: wired ones on the built-in output, whose data source
/// says so (`kIOAudioOutputPortSubTypeHeadphones`), or a Bluetooth device, which on a Mac is nearly
/// always a pair of headphones.
pub fn outputIsHeadphones() bool {
    const system_object = 1;
    const global = code("glob");
    const device = property(system_object, code("dOut"), global) orelse return false;
    if (property(device, code("tran"), global)) |transport| {
        if (transport == code("blue") or transport == code("blea")) return true;
    }
    return property(device, code("ssrc"), code("outp")) == code("hdpn");
}

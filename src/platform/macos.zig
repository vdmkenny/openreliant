//! What the platform layer does for macOS before SDL starts.

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

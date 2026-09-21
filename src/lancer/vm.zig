//! The mission script VM's run-time structures.
//!
//! A thread runs one block with a stack of its own. While it runs, the interpreter (`vm_run`) keeps
//! its stack pointer and block end in globals (`vm_stack_top`, `vm_block_end`) and hands every
//! opcode handler the addresses of the thread's instruction pointer and frame pointer.

const std = @import("std");
const assert = std.debug.assert;

const dte = @import("../formats/dte.zig");
const vm_commands = @import("../formats/vm_commands.zig");
const lancer = @import("../lancer.zig");
const Code = lancer.Code;
const Pointer = lancer.Pointer;

/// An opcode handler, called through `vm_dispatch_table`. `ip` points at the thread's instruction
/// pointer, already past the opcode, and `frame` at its frame pointer. `previous` is what the last
/// handler returned. A handler returns it to carry on, or zero to end the loop.
pub const Handler = Code("uint __fastcall (byte **ip, uint **frame, uint previous)");

/// A command's implementation. `args` points at its first argument on the stack. The result is
/// stored in `Thread.result`, and a zero result also ends the handler loop.
pub const Command = Code("uint __fastcall (byte **ip, uint *args)");

/// Threads the pool at `vm_threads` holds. `vm_thread_start` starts none while 31 are running.
pub const max_threads = 32;

/// Timers the table at `vm_timers` holds.
pub const max_timers = 16;

/// A script thread.
pub const Thread = extern struct {
    /// Stack pointer, saved while the thread is suspended.
    stack_top: Pointer(u32),
    /// End of the running block, where its constants start. Saved like `stack_top`.
    block_end: Pointer(u8),
    /// The running part's first argument: `push_argument n` reads `frame[n]`.
    frame: Pointer(u32),
    /// Value of `vm_clock` to resume at, or zero when not waiting.
    wake_time: u32,
    /// Next instruction to run. Null for a free slot.
    ip: Pointer(u8),
    /// Block end at which the script debugger's step-over stops.
    step_block_end: Pointer(u8),
    /// The values of the event that started the thread, which `push_local` reads.
    locals: [5]u32,
    stack: [32]u32,
    /// **Unknown.** `0xFF` when the thread starts.
    _unknown_ac: u8,
    /// Parts called and not yet returned from. A `return` at depth zero ends the thread.
    call_depth: u8,
    /// **Unknown.** Zero when the thread starts; cleared when its trigger fires again.
    _unknown_ae: u8,
    /// Index of the trigger that started the thread, or `0xFF` for none.
    trigger: u8,
    /// The last command's result, or the value the last part returned: what `push_result` reads.
    result: u32,
    /// **Unknown.** Zero when the thread starts.
    _unknown_b4: u32,

    comptime {
        assert(@offsetOf(Thread, "wake_time") == 0x0C);
        assert(@offsetOf(Thread, "ip") == 0x10);
        assert(@offsetOf(Thread, "locals") == 0x18);
        assert(@offsetOf(Thread, "stack") == 0x2C);
        assert(@offsetOf(Thread, "call_depth") == 0xAD);
        assert(@offsetOf(Thread, "result") == 0xB0);
        assert(@sizeOf(Thread) == 0xB8);
    }
};

/// What `call_part` pushes above a part's arguments, and `return` pops. The thread's frame pointer
/// then points at the first argument, `4 * arguments + 16` bytes below the stack pointer.
pub const CallRecord = extern struct {
    argument_count: u32,
    return_ip: Pointer(u8),
    caller_frame: Pointer(u32),
    caller_block_end: Pointer(u8),

    comptime {
        assert(@sizeOf(CallRecord) == 0x10);
    }
};

/// An entry of the command catalogue, or of a mission's part table: what `command` and
/// `call_part` call. The catalogue fills every field; a part's entry has only its block and its
/// argument count.
pub const Function = extern struct {
    entry: Entry,
    /// Arguments taken from the stack. The engine reads a byte of the catalogue's dword.
    argument_count: u8,
    _unknown_05: [3]u8,
    name: Pointer(u8),
    params: [max_params]Param,
    description: Pointer(u8),
    /// **Unknown.**
    flag: u32,

    pub const max_params = 8;

    pub const Entry = extern union {
        implementation: Pointer(Command),
        /// The part's block: its length halfword, then its code.
        block: Pointer(u16),
    };

    pub const Param = extern struct {
        kinds: vm_commands.Kinds,
        /// **Unknown.**
        extra: u32,
        label: Pointer(u8),
    };

    comptime {
        assert(@offsetOf(Function, "name") == 0x08);
        assert(@offsetOf(Function, "params") == 0x0C);
        assert(@offsetOf(Function, "description") == 0x6C);
        assert(@sizeOf(Function) == 0x74);
    }
};

/// A timer that `CreateTimer` set.
pub const Timer = extern struct {
    /// The part to start, or -1 for a free entry.
    part: i32,
    /// Countdown to reload after each firing.
    period: u16,
    /// Firings left. Zero for no limit; `DestroyTimer` runs after the last.
    remaining: u16,
    /// Clock ticks to the next firing.
    countdown: u16,
    /// The ID the script gave it, which `DestroyTimer` takes.
    id: u16,
    /// `vm_clock` when it last counted down, so that it counts once per tick.
    last_tick: u32,

    comptime {
        assert(@sizeOf(Timer) == 0x10);
    }
};

/// One condition of the catalogue at `condition_descriptors`.
pub const ConditionDescriptor = extern struct {
    /// The developers' `TT_*` name, without the prefix.
    name: Pointer(u8),
    /// **Unknown.** Zero, except `0x400` for the internal `ExplosionShip`.
    _unknown_04: u16,
    /// The kinds of object whose triggers can have this condition.
    subjects: dte.Object.KindSet,
    /// The values an event of this condition carries, in order, up to an entry with a null label.
    /// Null for none.
    values: Pointer(EventValue),
    /// Index into `ObjectEvents` under which the matcher keeps each object's last event, for
    /// `push_event_value`. `0xFF` for none.
    slot: u8,
    /// Triggers with this repeat mode fire even when `verdict` vetoes the event.
    veto_exempt: dte.Trigger.Repeat,
    _unknown_0e: u16,
    /// Called before an event on a flight group or squad is counted.
    begin: Pointer(anyopaque),
    /// Called once for each member of the flight group.
    add_member: Pointer(anyopaque),
    /// Returns whether the event goes ahead: the value of `condition_verdict`.
    verdict: Pointer(anyopaque),

    comptime {
        assert(@offsetOf(ConditionDescriptor, "subjects") == 0x06);
        assert(@offsetOf(ConditionDescriptor, "slot") == 0x0C);
        assert(@offsetOf(ConditionDescriptor, "begin") == 0x10);
        assert(@sizeOf(ConditionDescriptor) == 0x1C);
    }
};

/// One value an event carries: an entry of a condition's `values` list.
pub const EventValue = extern struct {
    label: Pointer(u8),
    kinds: vm_commands.Kinds,
    /// **Unknown.** `0xFF`, or `0x09` for the weapon of `ShotAt`.
    _unknown_08: u8,
    /// Whether a trigger's operand for this value is checked against the event's.
    checked: bool,
    _unknown_0a: u16,

    comptime {
        assert(@sizeOf(EventValue) == 0x0C);
    }
};

/// An event waiting in the queue at `event_queue` for `events_flush`, which raises it on the ship
/// and, for `groups`, on its flight group and the squads that hold it.
pub const QueuedEvent = extern struct {
    groups: bool,
    _unknown_01: [3]u8,
    ship: Pointer(dte.Ship),
    condition: dte.Condition,
    value_count: u8,
    _unknown_0a: u16,
    /// Room for eight; an event carries at most five.
    values: [8]u32,
    /// The component of the ship the event concerns, or `dte.Trigger.whole_object`.
    qualifier: u8,
    _unknown_2d: [3]u8,

    comptime {
        assert(@offsetOf(QueuedEvent, "ship") == 0x04);
        assert(@offsetOf(QueuedEvent, "values") == 0x0C);
        assert(@offsetOf(QueuedEvent, "qualifier") == 0x2C);
        assert(@sizeOf(QueuedEvent) == 0x30);
    }
};

/// The last events of the conditions that have a `slot`, kept for each object at `event_values`.
pub const ObjectEvents = extern struct {
    shot_at: [5]u32,
    destroyed: [5]u32,

    comptime {
        assert(@sizeOf(ObjectEvents) == 0x28);
    }
};

test {
    std.testing.refAllDecls(@This());
}

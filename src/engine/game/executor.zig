//! `C:\lancer\game\Executor.cpp`: the mission script's commands.
//! [`executor/commands.zig`](executor/commands.zig) transcribes the command catalogue.
//! **Unverified:** the catalogue lies in the data before this file's path, and some commands lie
//! outside this file's code.

const std = @import("std");
const log = std.log.scoped(.mission);

const dte = @import("../../formats/dte.zig");
const engine = @import("../../engine.zig");
const Code = engine.Code;
const vm = @import("../vm.zig");
const aigeneric = @import("aigeneric.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const mission = @import("mission.zig");
const objects = @import("objects.zig");
const pilots = @import("pilots.zig");
const Order = @import("ai/orders.zig").Order;

pub const commands = @import("executor/commands.zig");

const Call = vm.machine.Call;

/// The catalogue's number of the command `name`: the operand of `command` that runs it.
pub fn commandIndex(comptime name: []const u8) u8 {
    return comptime for (commands.table, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, name)) break index;
    } else @compileError("the Executor has no command " ++ name);
}

/// The implementation of command `number`, or null for one not ported yet
/// ([#36](https://github.com/vdmkenny/openreliant/issues/36),
/// [#281](https://github.com/vdmkenny/openreliant/issues/281)).
pub fn implementation(number: u8) ?vm.Implementation {
    return if (number < implementations.len) implementations[number] else null;
}

const implementations = table: {
    var table: [commands.table.len]?vm.Implementation = @splat(null);
    for ([_]struct { []const u8, vm.Implementation }{
        .{ "CreateTimer", vm.Machine.createTimer },
        .{ "DestroyTimer", vm.Machine.destroyTimer },
        .{ "CreateFlightGroup", createFlightGroup },
        .{ "Wait", vm.Machine.wait },
        .{ "SetAI", setAI },
        .{ "InterruptTriggerCode", vm.Machine.interruptTriggerCode },
        .{ "Fly", fly },
        .{ "SetRescueProbabilities", setRescueProbabilities },
        .{ "KillAllScriptExecutionExecptMe", vm.Machine.killAllScriptExecutionExceptMe },
    }) |pair| table[commandIndex(pair[0])] = pair[1];
    break :table table;
};

/// `cmd_CreateFlightGroup` (`0x00457C40`, command `0x03`): creates each ship of the flight group
/// its argument names, in the mission's order (`createShip`), then lists the flight groups in
/// their wings (`mission.buildWings`).
///
/// **Fix:** the game stops with a fatal error where the argument names no flight group; OpenReliant
/// creates nothing.
fn createFlightGroup(call: Call) u32 {
    const machine = call.machine;
    const game = machine.game orelse return 1;
    const group = machine.flightGroupIndex(call.args[0]) orelse return 1;
    const groups = machine.mission.flightGroups() catch return 1;
    if (group >= groups.len) return 1;
    for (machine.mission.groupShips(groups[group])) |ship| createShip(game, machine.mission, ship);
    mission.buildWings(game.world.objects, machine.mission);
    return 1;
}

/// The kinds of a mission's ship records that are nav points and markers, which
/// `mission_ship_create` makes a `gameobj.Type.marker` of.
fn isMarker(kind: u16) bool {
    return switch (kind) {
        nav_point_kind, dte.Ship.waypoint_kind, 0x3E4, 0x3E3 => true,
        else => false,
    };
}

/// The kind of a mission's nav points.
const nav_point_kind = 999;

/// `mission_ship_create` (`0x00457CD0`): creates the object of mission ship `index` in the slot of
/// its index, as its record has it.
///
/// A nav point or a marker is a `gameobj.Type.marker` at its place, turned by its record
/// (`mission.recordOrientation`).
///
/// Any other ship is an object of its kind (`shipType`), fitted by its loadout tier, at its place.
/// It gets its first order: Player Control for the player's ship, whose view the camera takes (view
/// 0), Multiplayer Control for another player's, and Do Nothing for the rest. It is turned by its
/// record. A ship that launches gets a Launch order through the gate it names of the first of the
/// mission's ships of the kind it launches from, which starts at once (`aigeneric.objectOrders`),
/// and a ship flown by a pilot of `pilotstats.bin` gets the pilot.
///
/// Not ported: the count of the nav points made (`0x00565698`), which nothing reads, and the lines
/// it logs.
pub fn createShip(game: aigeneric.Context, bound: *const mission.Mission, index: u16) void {
    const all = game.world.objects;
    const spawn = game.world.spawn orelse return;
    const ships = bound.ships() catch return;
    if (index >= ships.len) return;
    const ship = ships[index];
    const turn = mission.recordOrientation(ship);
    if (isMarker(ship.kind)) {
        const made = create.createObject(all, spawn.tables, spawn.types, index, .marker, 0, ship.position, game.world.random) catch |err| {
            log.warn("mission ship {d} is not made: {s}", .{ index, @errorName(err) });
            return;
        };
        objects.setOrientation(&all.slots[made].object, &all.slots[made].drawn, turn);
        return;
    }
    const made = create.createObject(all, spawn.tables, spawn.types, index, shipType(all, bound, ship), ship.tier, ship.position, game.world.random) catch |err| {
        log.warn("mission ship {d} is not made: {s}", .{ index, @errorName(err) });
        return;
    };
    const first: Order = if (made >= all.players) .do_nothing else if (made == all.player) .player_control else .multiplayer_control;
    _ = aigeneric.push(game, made, first, .none) catch |err| log.warn("mission ship {d} takes no order: {s}", .{ index, @errorName(err) });
    if (made == all.player) if (game.world.camera) |view| {
        _ = view.setView(.cockpit, made, false, false, game.clock.viewTime());
    };
    const slot = &all.slots[made];
    objects.setOrientation(&slot.object, &slot.drawn, turn);
    if (ship.launchGate()) |gate| for (ships, 0..) |carrier, from| {
        if (carrier.kind != ship.launch_from) continue;
        _ = aigeneric.pushShip(game, made, .launch, @intCast(from), gate) catch |err| log.warn("mission ship {d} does not launch: {s}", .{ index, @errorName(err) });
        aigeneric.objectOrders(game, made);
        break;
    };
    if (ship.pilotRecord()) |pilot| pilots.setPilot(&slot.object, pilot);
}

/// The type `mission_ship_create` asks for a mission ship of: its kind, save that from
/// `create.twins_from_mission` on a ship of the player's wing flies the `t_` twin of its kind, or
/// a Kamov in mission 25's first part.
///
/// **Fix:** from `create.twins_from_mission` on, the game takes a ship of the player's wing whose
/// kind is none of the player's ships for the object in the slot its record's address gives, and
/// reads the wing of a ship in no flight group from past the groups; OpenReliant makes the first of
/// its own kind, and takes the second for a ship of no wing.
fn shipType(all: *const create.Objects, bound: *const mission.Mission, ship: dte.Ship) gameobj.Type {
    const kind: gameobj.Type = @enumFromInt(ship.kind);
    if (all.mission_number < create.twins_from_mission) return kind;
    const groups = bound.flightGroups() catch return kind;
    const group = ship.flightGroup() orelse return kind;
    if (group >= groups.len or groups[group].wing != 0) return kind;
    if (all.mission_number == create.kamov_mission and !all.mission25_second_part) return .kamov;
    return kind.twin() orelse kind;
}

/// `cmd_SetAI` (`0x004581F0`, command `0x0B`): each ship the first argument names takes the order
/// the second gives (`setAIShip`), the orders numbered from 0 as they are given
/// (`aigeneric.startNumbering`).
fn setAI(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    aigeneric.startNumbering(game.world.objects);
    vm.Machine.forEachShip(call, setAIShip);
    aigeneric.stopNumbering(game.world.objects);
    return 1;
}

/// `cmd_SetAI_ship` (`0x00458220`): pushes the order the command's second argument gives on the
/// ship's stack, aimed at what its fourth names: a flight group or a squad by its index, or a ship
/// by its slot and the component `push_component` named for it, or nothing. The third, whether the
/// order starts at once, is not read. Aimed at anything else, it pushes no order.
fn setAIShip(call: Call, ship: u16) void {
    const machine = call.machine;
    const game = machine.game.?;
    const aim = call.args[2];
    const target: aigeneric.Target = if (machine.recordKind(aim)) |kind| switch (kind) {
        .flight_group => .{ .kind = .flight_group, .index = targetIndex(machine.flightGroupIndex(aim)), .component = aigeneric.Target.whole },
        .squad => .{ .kind = .squad, .index = targetIndex(machine.squadIndex(aim)), .component = aigeneric.Target.whole },
        .ship => shipTarget(machine, call.thread, aim),
        _ => return,
    } else shipTarget(machine, call.thread, aim);
    const order: Order = @enumFromInt(@as(i16, @truncate(@as(i32, @bitCast(call.args[0])))));
    _ = aigeneric.push(game, ship, order, target) catch |err| log.warn("mission ship {d} takes no order {d}: {s}", .{ ship, @intFromEnum(order), @errorName(err) });
}

/// A record's index as an order's target takes it, -1 for none.
fn targetIndex(record: ?u16) i16 {
    return if (record) |at| @bitCast(at) else -1;
}

/// The target `SetAI` aims at the ship `aim` names: its slot, and the component `push_component`
/// named for the command's fourth argument, or none where `aim` names no ship.
fn shipTarget(machine: *const vm.Machine, thread: u8, aim: u32) aigeneric.Target {
    const ship = machine.shipIndex(aim) orelse return .none;
    const component: i16 = if (machine.argumentComponent(thread, 3)) |part| part else aigeneric.Target.whole;
    return .{ .kind = .ship, .index = @bitCast(ship), .component = component };
}

/// `cmd_Fly` (`0x00458F50`, command `0x28`): each ship the first argument names flies
/// (`flyShip`).
fn fly(call: Call) u32 {
    vm.Machine.forEachShip(call, flyShip);
    return 1;
}

/// `cmd_Fly_ship` (`0x00458F70`): pushes a Fly order on the ship's stack, aimed at the ship the
/// command's second argument names, or at none, which holds the heading it starts on, at the speed
/// the third gives, or 0 for its full throttle.
fn flyShip(call: Call, ship: u16) void {
    const machine = call.machine;
    const game = machine.game.?;
    const target: aigeneric.Target = if (machine.shipIndex(call.args[0])) |to| .at(to, null) else .none;
    const all = game.world.objects;
    _ = aigeneric.push(game, ship, .fly, target) catch |err| log.warn("mission ship {d} does not fly: {s}", .{ ship, @errorName(err) });
    if (aigeneric.current(all, ship)) |entry| entry.data.fly = @bitCast(call.args[1]);
}

/// `cmd_SetRescueProbabilities` (`0x004598D0`, command `0x44`): the odds of how the player fares
/// after ejecting: picked up by a nanny ship, by the enemy, and killed.
fn setRescueProbabilities(call: Call) u32 {
    const game = call.machine.game orelse return 1;
    game.world.player.rescue_odds = .{
        .rescued = @truncate(call.args[0]),
        .captured = @truncate(call.args[1]),
        .killed = @truncate(call.args[2]),
    };
    return 1;
}

/// A command's implementation. `args` points at its first argument on the stack. The result is
/// stored in `Thread.result`, and a zero result also ends the handler loop.
pub const Command = Code("uint __fastcall (byte **ip, uint *args)");

/// What a command hands `for_each_ship` to run for each ship its first argument names: the ship,
/// and the command's remaining arguments.
pub const ShipCommand = Code("uint __fastcall (MissionShip *ship, uint *args)");

test commandIndex {
    try std.testing.expectEqual(0x05, commandIndex("Wait"));
    try std.testing.expectEqualStrings("Wait", commands.table[commandIndex("Wait")].name);
}

test implementation {
    try std.testing.expect(implementation(commandIndex("Wait")) != null);
    try std.testing.expectEqual(null, implementation(commandIndex("PrintShipName")));
    try std.testing.expectEqual(null, implementation(0xFF));
}

/// A mission ship record for the tests: in `group`, of `kind`, flown by `pilot`, launching from
/// none.
fn testShip(id: u32, group: u8, kind: u16, pilot: u8) dte.Ship {
    var ship = std.mem.zeroes(dte.Ship);
    ship.object_id = id;
    ship.flight_group = group;
    ship.kind = kind;
    ship.pilot = pilot;
    ship.launch_gate = dte.Ship.no_launch;
    ship.tier = 0xFF;
    return ship;
}

fn testGroup(id: u16, wing: u8) dte.FlightGroup {
    var group = std.mem.zeroes(dte.FlightGroup);
    group.object_id = id;
    group.wing = wing;
    return group;
}

test "a mission's start part makes its ships and gives them their orders" {
    const gpa = std.testing.allocator;
    const Routine = vm.machine.testing.Routine;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    for (0..4) |group| {
        try routine.op(.push_flight_group, &.{@intCast(group)});
        try routine.command("CreateFlightGroup");
    }
    // The Sabres fight the player's ship.
    try routine.op(.push_flight_group, &.{1});
    try routine.op(.push_byte, &.{@intCast(@intFromEnum(Order.fight))});
    try routine.op(.push_byte, &.{1});
    try routine.op(.push_ship, &.{0});
    try routine.command("SetAI");
    // The Reliant flies at 10, holding its heading.
    try routine.op(.push_ship, &.{5});
    try routine.op(.push_null, &.{});
    try routine.op(.push_byte, &.{10});
    try routine.command("Fly");
    try routine.op(.push_byte, &.{33});
    try routine.op(.push_byte, &.{33});
    try routine.op(.push_byte, &.{34});
    try routine.command("SetRescueProbabilities");
    try routine.op(.push_byte, &.{1});
    try routine.op(.@"return", &.{});
    const code = try routine.finish();
    defer gpa.free(code);

    var sabre = testShip(2, 1, @intFromEnum(gameobj.Type.sabre), 42);
    sabre.yaw = 180;
    var fixture: vm.machine.testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .ships = &.{
            testShip(0, 0, @intFromEnum(gameobj.Type.predator), dte.Ship.no_pilot),
            testShip(1, 0, @intFromEnum(gameobj.Type.grendel), 5),
            sabre,
            testShip(3, 1, @intFromEnum(gameobj.Type.sabre), 42),
            testShip(4, 2, nav_point_kind, dte.Ship.no_pilot),
            testShip(5, 3, @intFromEnum(gameobj.Type.reliant), 60),
        },
        .flight_groups = &.{ testGroup(6, 0), testGroup(7, dte.FlightGroup.no_wing), testGroup(8, dte.FlightGroup.no_wing), testGroup(9, dte.FlightGroup.no_wing) },
    });
    defer fixture.deinit();
    var world: gameobj.testing.Mission = undefined;
    try world.init(gpa);
    defer world.deinit();
    var game = world.orders();
    game.world.spawn = .{ .tables = &world.tables, .types = create.testing.no_models };
    fixture.machine.game = game;
    try fixture.machine.start();

    const all = world.objects;
    // Each ship in the slot of its index, of its kind; the nav point a marker.
    const types = [_]gameobj.Type{ .predator, .grendel, .sabre, .sabre, .marker, .reliant };
    for (types, all.slots[0..types.len]) |made, slot| {
        try std.testing.expect(slot.object.created);
        try std.testing.expectEqual(made, slot.object.type);
    }
    // The player's ship on its controls, the others at rest until the script says otherwise.
    try std.testing.expectEqual(Order.player_control, all.slots[0].orders[0].order);
    try std.testing.expectEqual(Order.do_nothing, all.slots[1].orders[0].order);
    // The Sabres fight the player, numbered in turn, each naming the first of them but the first.
    for ([_]u16{ 2, 3 }, 0..) |at, n| {
        const entry = all.slots[at].orders[0];
        try std.testing.expectEqual(Order.fight, entry.order);
        try std.testing.expectEqual(0, entry.target.ship());
        try std.testing.expectEqual(@as(i16, @intCast(n)), entry.sequence);
        try std.testing.expectEqual(42, all.slots[at].object.pilot);
    }
    try std.testing.expectEqual(0xFF00FFFF, all.slots[2].object._unknown_698);
    try std.testing.expectEqual(0xFF000002, all.slots[3].object._unknown_698);
    // Turned by its record: the first Sabre faces back along Z.
    try std.testing.expectApproxEqAbs(-1, @import("../surrender/math.zig").forward(all.slots[2].object.root.orientation)[2], 1e-6);
    // The Reliant flies at 10, at nothing.
    try std.testing.expectEqual(Order.fly, all.slots[5].orders[0].order);
    try std.testing.expectEqual(null, all.slots[5].orders[0].target.ship());
    try std.testing.expectEqual(10, all.slots[5].orders[0].data.fly);
    // The player's flight group is the player's wing.
    try std.testing.expectEqual(mission.WingSlots{ 0, 1, null, null, null, null }, all.wing);
    try std.testing.expectEqual(.player, all.slots[1].object.wing);
    try std.testing.expectEqual(.none, all.slots[2].object.wing);
    try std.testing.expectEqual(@import("aieject.zig").RescueOdds{ .rescued = 33, .captured = 33, .killed = 34 }, world.player.rescue_odds);
}

test shipType {
    var world: gameobj.testing.Mission = undefined;
    try world.init(std.testing.allocator);
    defer world.deinit();
    const all = world.objects;
    const image = try mission.bind.testing.image(std.testing.allocator, .{
        .ships = &.{ testShip(0, 0, 2, dte.Ship.no_pilot), testShip(1, 1, 2, 5) },
        .flight_groups = &.{ testGroup(2, 0), testGroup(3, dte.FlightGroup.no_wing) },
    });
    var bound: mission.Mission = try .bind(std.testing.allocator, image);
    defer bound.deinit();
    const ships = try bound.ships();
    // Before the 14th mission every ship is of its kind.
    try std.testing.expectEqual(gameobj.Type.grendel, shipType(all, &bound, ships[0]));
    // From it on, the player's wing flies the twins, and mission 25's first part a Kamov.
    all.mission_number = create.twins_from_mission;
    try std.testing.expectEqual(gameobj.Type.grendel.twin().?, shipType(all, &bound, ships[0]));
    try std.testing.expectEqual(gameobj.Type.grendel, shipType(all, &bound, ships[1]));
    all.mission_number = create.kamov_mission;
    try std.testing.expectEqual(gameobj.Type.kamov, shipType(all, &bound, ships[0]));
}

test {
    std.testing.refAllDecls(@This());
}

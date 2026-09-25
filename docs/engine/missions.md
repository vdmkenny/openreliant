# Missions

How a mission's start finds the mission's file, reads it and binds it for play. The file's own
layout is in [`.DTE` missions](../formats/dte.md); what its script does at run time is in [the
script VM](script-vm.md). [`mission/bind.zig`](../../src/engine/game/mission/bind.zig) ports the
reading and the binding.

## The file

`WinMain` names the file of the mission to play, `.\missions\mission<number>.dte` under the game's
directory, by the mission number (`mission_number`, `0x00562DC8`). Two missions have files of
their own for a case of their own (`0x004A9C42`, `0x004AA40A`):

| Mission | File | When |
|---|---|---|
| 25 | `mission251.dte` | Once its first part is won (`mission25_second_part`, `0x00587CDC`): the second part |
| 3 | `mission311.dte` | In a multiplayer game |

`mission_file_read` (`0x0045A300`) reads the file. A loose file at that path comes first, where
`file_exists` (`0x004AD6E0`, through `_access`) finds one: it is read as it is, up to `0xFA000`
bytes, the size of the buffer, so it must be stored expanded. Otherwise `hog_load` reads the member
of `resource.hog` of the file's name, `mission<number>.dte`, and expands it where RefPack packed it
([`.HOG` archives](../formats/hog.md)). With neither, the mission's start stops the game: "The
mission number is invalid".

A retail install carries two loose missions, `missions\mission18.dte` and `missions\mission25.dte`,
which stand in for their archive copies. A mission added to the `missions` folder under a mission's
name takes that mission's place the same way. OpenReliant finds the loose file whatever the case of
its names, as Windows does, on every system
([`files.zig`](../../src/engine/files.zig)).

## Binding

`mission_bind_sections` (`0x00451D90`) runs at the mission's start. It reads the file, then binds
the directory's 27 entries in turn (`mission_bind_section`, `0x00452A20`): each section's count and
its offset, made a pointer into the file, into the section's globals (`mission_ships` and the
rest). Each entry's byte 3 carries four flags, and any section that has one sets the matching
`mission_format_flags` (`0x00525F9A`, `0x00525FA4`, `0x005267C6`, `0x005294E8`); nothing reads
them.

Then it sets each ship's run-time place and angles to those it is placed at
(`mission_ships_reset`, `0x00452010`), and makes the mission's tables (`mission_bind_tables`,
`0x00453050`):

1. The script's part tables (`mission_build_part_tables`, `0x00452F50`).
2. The waypoints (`mission_list_waypoints`, `0x00452100`): the ships of kind `0x3E5` in a flight
   group, a group at a time, in `waypoints` (`0x00525710`), a flight group and a ship each. It
   takes the first waypoint not yet listed, then every later one of its group, marking each
   listed at the ship's `+0x1B`, until none is left. A Patrol Route flies a group's waypoints from
   the entry its target names (`order_patrol_route_init`).
3. Each flight group's ships (`mission_list_group_ships`, `0x00452EC0`), in the order the mission
   lists them, into one list, `flight_group_ships` (`0x004EF2F8`): the group's count at `+0x09` and
   its first ship's place at `+0x0C`, or -1 for none.
4. The record each entry of the object table stands for (`mission_resolve_objects`, `0x00452DB0`),
   in `object_records` (`0x00538C90`): of the entry's kind, the first ship, flight group or squad
   whose object ID, taken as 16 bits, is the entry's (`mission_object_record`, `0x00452DF0`).
5. The trigger lists (`0x0045AE10`), for three of the conditions.

Last it starts the script's clock (`vm_clock_start`) and the script (`mission_script_start`). The
mission's start then sets the game's object count to the mission's ship count, so the objects and
the mission's ships share their numbers, and loads the model of each ship type the mission places.

A mission may carry a name for OpenReliant in section 21, which the game binds into a local variable
and never reads ([OpenReliant's mission name](../formats/dte.md#openreliants-mission-name)).

OpenReliant binds all 44 shipped missions. `openreliant missions` lists the missions a game's folder
holds and binds each ([Platform](../port/platform.md)). A section that runs past the file fails to
bind, where the game would read past its buffer.

Not yet ported: the part tables, the script's start and the trigger lists (the script VM, [#36](https://github.com/vdmkenny/openreliant/issues/36), and the triggers, [#37](https://github.com/vdmkenny/openreliant/issues/37)), and the wings ([#256](https://github.com/vdmkenny/openreliant/issues/256)).

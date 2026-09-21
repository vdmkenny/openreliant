# Orders

What each object is doing: flying in formation, escorting, docking, exploding, or following the
player's controls. An object keeps a stack of orders, the current one on top, which the AI, the
mission scripts and the player's controls push and pop, and `object_orders` runs the current one.
[`src/lancer/orders.zig`](../../src/lancer/orders.zig) defines the structures, and
[`src/formats/orders.zig`](../../src/formats/orders.zig) lists the orders with their flags,
priorities and routines; `make order-tables` transcribes it from the executable. The names below
are those `make ghidra-annotate` gives the Ghidra project, which names each order's routines
`order_` and the order's name, with `_init` and `_exit` for those two.

## The order table

`order_groups` (`0x4E06E0`) points at the records of each hundred order numbers: order `n` is
record `n % 100` of group `n / 100`. Group 0 holds orders 0 to 45, group 1 orders 100 to 122, and
group 2 one empty record, order 200. Each record is an `OrderRecord`:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | `init`: runs before the order's first update; null for none |
| `0x04` | 4 | `update`: runs each time `object_orders` runs the order |
| `0x08` | 4 | `exit`: runs when the order is popped or replaced after it has started; null for none |
| `0x0C` | 4 | Flags |
| `0x10` | 4 | Name: the developers' name, which fatal errors show |
| `0x14` | 4 | Priority |

| Flag | Name | Meaning |
|---|---|---|
| `0x1` | `players` | The order may be given to a player's ship. A player's ship refuses the other orders numbered below 100. |
| `0x2` to `0x10` | | **Unknown.** Set on some orders; nothing in the payload tests them. |
| `0x20` | `one_shot` | The order runs its update once and pops itself, and the order below carries on without starting again. Its `init` never runs. |
| `0x40` | `retaliate` | While it runs, the ship can turn on its attacker (see [Retaliation](#retaliation)). |
| `0x80` | `avoidance` | While it runs, `avoidance_scan` (`0x00492190`) lists the objects the ship could hit, unless the object has `no_avoidance`, which `SetShipAvoidance` sets to disable "Avoidance code": up to ten objects with listed components whose collision spheres, widened by a constant, overlap its own, at `GameObject` offsets `0x6B4` (the count) and `0x6B8`, and up to ten others for which `0x00401980`, which projects the two objects' motion, answers yes for a time of 50 updates and a margin of 2000 units, at `0x6E0` and `0x6E4`. |
| `0x400` | `send_flight` | While it runs, a multiplayer game sends the ship's steering inputs, throttle, rates and velocity. |

Most orders have priority 0. Warp In, Warp Out, Land, Jump In, Jump Out, the fixed gate jumps,
Launch, Dock and Friendly Fire have 1; Eject Player 97, Eject and Eject Spin 98, and Explode 99.

## The stack

An object's stack, `orders` (`0x684`), holds up to 20 `OrderEntry` records, the current order
first, with `order_count` (`0x680`) saying how many. It is allocated with the object's first order,
together with 0x90 bytes at `order_state` (`0x68C`) where the current order keeps whatever it
needs between updates.

| Offset | Size | Field |
|---|---|---|
| `0x00` | 2 | The order's number |
| `0x02` | 2 | Target kind: 0 a ship, 1 a flight group, 2 a squad, as in the mission's [object table](../formats/dte.md) |
| `0x04` | 2 | Target: the ship's slot, or the flight group's or squad's index; -1 for none |
| `0x06` | 2 | Target component, or -1 for the whole ship |
| `0x08` | 2 | A running count from `0x5185A8` while the byte at `0x5185B1` is set, otherwise zero |
| `0x0A` | 16 | The order's own data, zero when the order is pushed |

`player_controls` keeps the mouse's stick position in the first two words of its data.

`order_push` (`0x0040CC10`) takes a slot, an order and its target, and:

1. fails if the ship refuses the order (`order_refused`, `0x0040CA00`): the ship is a player's,
   its slot being below `player_slots` (`0x58832C`), which is 1 in a single-player game and the
   player count or 8 in multiplayer, and the order is numbered below 100 without `players`;
2. succeeds at once if the current order is the same order with the same target;
3. fails unless the current order gives way (`order_give_way`, `0x0040CA50`);
4. removes any equal order, with the same target, from deeper in the stack;
5. fails if the stack holds 20 orders;
6. pushes the order with its data zeroed. Unless the order is one-shot, it marks the order as
   starting (`order_starting`, `0x688`), sets the word at `0x620` to -1 and zeroes the state.

An object that is exploding, whose pilot has ejected, or with object flag `0x10000000` takes no
order. Otherwise the current order gives way at once when there is none, when it has yet to
start, or when the new order is one-shot. A started order gives way to Explode, and to any order
when its own priority is zero or the new order's is higher, running its `exit` as it does. Pushing
any other order on it is a fatal error, "Cannot set ai %s on ship %s: Still %s".

`order_pop` (`0x0040CE70`) runs the current order's `exit` if it has started and removes it. Unless
the popped order was one-shot, the order below starts again: it is marked as starting and the state
is zeroed. `orders_pop_all` (`0x0040CF80`) pops every order, and `orders_clear` (`0x0040CF50`) drops
them all at once when the current order gives way to clearing, so only that order's `exit` runs.

The script command `SetAI` pushes an order aimed at the ship, flight group or squad it names, on
each ship it applies to, and `ClearAI` clears the orders of each ship that is not a player's.

## Running orders

`object_orders` (`0x0040C5F0`) runs an object's current order:

1. It starts the queued orders from other players that are due (see [below](#orders-from-other-players)).
2. With a `retaliate` order, it runs `order_retaliate`.
3. It clears the object's `afterburner` and `reverse_thrust`, so an order that burns sets them
   again each time it runs.
4. A one-shot order runs its update and pops itself, and `object_orders` then runs the order below.
   Any other order runs its `init` first if it is starting, then its update.
5. Afterwards it clears the throttle and both burns while the object's engines are disabled
   (`DisableEngines`), both burns when it has no afterburner fuel, and reverse thrust unless the
   object has `can_reverse`.

It runs from two places:

- `orders_update` (`0x0040C8F0`) runs `object_orders` once a frame for every object that is not
  disabled (`DisableObject`), the player's ship included.
  `mission_frame` (`0x004924B0`), `mission_run`'s work for each frame, calls it (see
  [the game loop](loop.md)).
- `simulation_step` runs it for the player's ship, before the objects move, while the ship's
  current order is `Player Control`.

So the orders of AI ships run once a frame, and the player's [controls](controls.md) once a frame
and once each simulation step.

## Retaliation

Damage of kinds 0, 1 and 5 adds to an object's `recent_damage` (`0x690`), which `orders_update`
zeroes every 500 ticks, and each hit records the attacker's slot in `last_attacker` (`0x694`).
While the current order has `retaliate`, `order_retaliate` (`0x0040C520`) pushes Fight (105),
aimed at the attacker, once `recent_damage` reaches 4.2 times the ship's armor class. It does so
only when the attacker is on the other side, is not already the current order's target, and both
ships' combat stats hold 1 at `+0x28`, and not while the ship has `do_not_disturb`
(`DoNotDisturb`).
**Unknown:** what the word at `+0x28` of the combat stats means.

## Orders from other players

In a multiplayer game, orders from the other machines wait in a queue of up to 20, `queued_orders`
(`0xB90`) with `queued_order_count` (`0xB8C`). A `QueuedOrder` is the order's entry, a value the
sender passes, and the frame it is due. `order_queue` (`0x00402660`) adds one due a given number of
frames after the count at `0x5883B0`. An equal order already queued stays if it is due no sooner,
and is replaced otherwise; a full queue is a fatal error.

`object_orders` takes each queued order that is due by the count at `0x587CC4` and has a priority
no lower than the current order's, pushes it with its data, and removes it from the queue. It
removes a due order without pushing it while the object has not been created.

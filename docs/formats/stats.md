# Stat tables

`shipstats.bin`, `gunstats.bin`, `missilestats.bin` and `pilotstats.bin` define every ship, gun,
missile and pilot. Each ships twice, identically: loose in the installer's `LANCER.CAB`, and as a
RefPack member of `resource.hog`.

```
sltool stats list <file>
```

lists a table with its fields named, marking records the engine never loads.

## Frame

Each file is a flat array of **352-byte (`0x160`) records** with no header. All four share one
frame: a 64-byte NUL-padded name, then the table's fields.

| File | Records | Fields end at |
|---|---|---|
| `shipstats.bin` | 256 | `0x7C` |
| `gunstats.bin` | 15 | `0x58` |
| `missilestats.bin` | 16 | `0x64` |
| `pilotstats.bin` | 124 | `0x5C` |

Each table has its own loader in the payload executable. It opens the file with `fopen(..., "rb")`,
reads one record at a time with `fread` into a buffer on its stack, and copies the fields it wants
into a runtime table. **No loader reads the name, nor anything past its table's last field.** In the
shipped files those bytes are zero in every record of every table, so the fields are a record's whole
content.

| Table | Loader | Records read | Runtime table |
|---|---|---|---|
| Ships | `FUN_00466500` | Exactly 256 | Two parallel arrays, strides `0x28` and `0x30` |
| Guns | `FUN_004788F0` | Until end of file | 15 entries of `0x2C` at `0x500CE4` |
| Missiles | `FUN_00494BC0` | **At most 11** | Two parallel arrays of `0x28` |
| Pilots | `FUN_0049CAE0` | Until end of file | 194 entries of `0x24` at `0x58A968` |

The gun and pilot loaders have no bound: a file with more records than its runtime table writes past
the end of it. The missile loader stops after 11, so of the 16 shipped missiles the last five,
Blazer, Iron Tooth, Death Claw, Brute and Hell Fire, are never read. They are zero throughout, as is
the eleventh, Stalker, which is loaded but mostly hidden on the loadout screen.

## Where the names come from

The loadout screen shows ship and missile stats with labels from `LANGUAGE.DLL`, and a layout table
in the executable, eight 8-byte rows at `0x4EC020`, pairs each on-screen row with a string ID and a
display kind: a ten-segment bar or a number. Row `r` shows the ship's `r`th loadout value, and the
code that fills those values gives the field behind each label. That fixes the names marked
**Screen** below.

Names marked **Mods** come from
[Starlancer-OSS `stats-format.md`](https://github.com/LordBlacksun/Starlancer-OSS/blob/main/docs/stats-format.md),
which located fields by diffing known mods. Where the loader's handling bears on those names it is
noted.

## Ships

| Offset | Field | Loaded as | Evidence |
|---|---|---|---|
| `0x40` | Max speed | float | Screen: **Max Speed** bar |
| `0x44` | Inertia | float | Screen: **Acceleration** bar. Mods: Inertia |
| `0x48` | Yaw rate | float | Screen: **Agility** bar. Mods: YawMax |
| `0x4C` | Yaw inertia | float | Mods |
| `0x50` | Pitch rate | float | Mods |
| `0x54` | Pitch inertia | float | Mods |
| `0x58` | Roll rate | float | Mods |
| `0x5C` | Roll inertia | float | Mods |
| `0x60` | Shield power | truncated | Screen: **Shield Power** bar |
| `0x64` | Armor class | truncated | Screen: **Armor Class** bar |
| `0x68` | Afterburner fuel | truncated | Screen: **Afterburner Fuel**, a number labelled ` SECS` |
| `0x6C` | Shield recharge | float; 0 becomes 10 | Screen: **Shield Recharge** bar |
| `0x70` | | float | **Unknown.** Mods: GunEnergy, unverified |
| `0x74` | | float | **Unknown.** Mods: GunRecharge, unverified |
| `0x78` | | truncated | **Unknown.** Mods: Ammo, unverified |

"Truncated" means the loader converts the float to an integer with `_ftol`.

The loader copies `0x40` to `0x5C` into one runtime array in the order speed, `0x58`, `0x50`, `0x48`,
`0x44`, `0x5C`, `0x54`, `0x4C`: the three rates together, then the four inertias together, which
agrees with the pairing the mod diffs found. After loading it derives one more value per ship,
`0x40 / 0x50`.

The loadout screen scales each bar to the spread of that stat across the ships it lists: it widens a
minimum and a maximum over every listed ship, then places each ship within that range on ten
segments. It lists the 12 Alliance fighters the player can fly, in the order Coyote, Crusader,
Grendal, Mirage, Naginata, Patriot, Phoenix, Predator, Reaper, Shroud, Tempest and Wolverine, and in
a second list nine Coalition fighters.

## Guns

| Offset | Field | Loaded as | Evidence |
|---|---|---|---|
| `0x40` | Range | truncated | Mods |
| `0x44` | | float | **Unknown.** 1,200 to 2,000 in every gun |
| `0x48` | Damage | float | Weighted by the threat check below. Mods: DamageMin |
| `0x4C` | Damage | float | Mods: DamageMax |
| `0x50` | Fire rate | `100 / x`, truncated | Mods: CyclicRate |
| `0x54` | | truncated | **Unknown.** Mods: energy or heat per shot, unverified |

The loader stores `100 / fire_rate`, the interval between shots, rather than the rate.

The two damage values are **not a minimum and a maximum**: the first is the larger in seven of the
fifteen guns, and equal in seven. `FUN_00415430` uses the first on its own: it counts each gun type
among nearby ships, weights each count by that type's first damage value, and records the most
dangerous type other than the two capital-ship guns.

## Missiles

| Offset | Field | Loaded as | Evidence |
|---|---|---|---|
| `0x40` | Speed | float | Screen: **Speed** bar. Mods: MaxVelocity |
| `0x44` | | float, copied to three places | **Unknown** |
| `0x48` | Flight time | `x * 100`, truncated | Screen: **Range** is `speed * flight_time`. Mods: Range |
| `0x4C` | Damage | float | Screen: **Damage** is `0x4C + 0x50` |
| `0x50` | Damage | float | Screen |
| `0x54` | Lock time | truncated | Screen: **Locking Time** is `0x54 * 0.01`, labelled ` SECS` |
| `0x58` | | truncated | **Unknown** |
| `0x5C` | | float | **Unknown** |
| `0x60` | | float | **Unknown** |

`0x48` is the missile's flight time rather than its range: the loadout screen computes range as
speed times this field, which is why doubling it doubles the range. `0x54` is in hundredths of a
second.

The screen hides the locking time for Screamer and Solomon, pins Jack Hammer's damage bar at full,
and hides Stalker's speed, range and damage.

## Pilots

The record index is the pilot ID that missions use. The loader first fills all 194 runtime slots
with defaults, then applies each record read. Three fields are **tier selectors**: 0, 1 or 2 picks
one of three presets for a group of runtime values, and any other value leaves that group at its
default. The other four are copied through with a 16-bit move, so only their low halves count. The
shipped data uses tiers 1 and 2 only.

| Offset | Field | Effect |
|---|---|---|
| `0x40` | Tier A | Six 16-bit values |
| `0x44` | Tier B | One float |
| `0x48` | Tier C | Two floats and a 16-bit value |
| `0x4C` to `0x58` | Four values | Copied through, low 16 bits |

| Tier | A | B | C |
|---|---|---|---|
| 0 | 10, 40, 800, 1600, 400, 800 | 5.0 | 0.6, 0.4, 100 |
| 1 | 30, 50, 400, 800, 300, 600 | 3.0 | 0.8, 0.2, 50 |
| 2 | 100, 100, 200, 400, 200, 400 | 1.5 | 1.0, 0.0, 25 |
| Default | 30, 50, 400, 800, 200, 400 | 3.0 | 0.8, 0.2, 50 |

The loader applies B, then A, then C, and tier 2 of C also sets the last two values of A, to 50 and
100.

**Unknown:** what the runtime values do. Every group moves monotonically from tier 0 to tier 2,
which fits a skill level, but nothing ties a value to a behaviour yet.

## Prior art

The record frame, the counts, and the mod-derived names above are from
[Starlancer-OSS `stats-format.md`](https://github.com/LordBlacksun/Starlancer-OSS/blob/main/docs/stats-format.md),
built on Userunfriendly's hexcheat mod pack. It treated the bytes past each table's fields as an
undecoded tail to preserve verbatim; they are unread and zero.

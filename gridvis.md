# gridvis

A visibility compiler for Quake maps built for **top-down cameras**. `gridvis.exe` replaces `vis` in the [ericw-tools](https://github.com/ericwa/ericw-tools) pipeline (`qbsp` → `light` → **`gridvis`**). It culls what is drawn and sent over the network based on the area the screen can show around the camera focus, not on line of sight through portals.

## Why

Quake's `vis` computes a PVS (potentially visible set) for every BSP leaf by tracing visibility through portals at eye level. That fits corridors and rooms (dungeon crawlers, boomer shooters). It fits games with a top-down or high isometric camera badly, such as strategy games, Vampire Survivors-likes, RPGs, and ARPGs:

| Problem | Effect with a top-down camera |
|---|---|
| Open areas have no occluders | Every leaf sees every other leaf, so nothing is culled. With hundreds or thousands of entities on screen, all of them are sent and drawn. |
| Occlusion is computed at eye level | The camera looks *over* walls. Real portal vis can hide a neighbouring room that is clearly on screen, so it is wrong as well as useless. |
| Cost | `vis` on large maps can take hours. A grid PVS takes seconds. |

What a top-down camera can see depends on the **screen footprint**: the patch of ground inside the view around the camera focus. `gridvis` builds the PVS from that footprint.

## Quick start

```bat
build.bat                 :: ericw-tools: qbsp, vklight, vis, gridvis... (or build.bat gridvis)
mod\build.bat             :: test mod (QuakeC) -> D:\quake\gridvis\progs.dat
compile.bat               :: test map, twice: gridtest_vis.bsp and gridtest_grid.bsp
play.bat grid             :: watch the run on the gridvis map (play.bat vis for the normal one)
python tools\bench.py     :: record + timedemo both maps, append to testmap\bench_history.txt
python tools\netcheck.py  :: count the entities the client really receives on both maps
```

Using it on your own map:

```bat
python tools\hintgrid.py mymap.map mymap_hint.map --grid 512
qbsp mymap_hint
light mymap_hint
gridvis -stats -rectx 3328 -recty 1536 -offsety 464 -margin 128 mymap_hint
```

## How gridvis works

Input: a `.bsp` from `qbsp`. The `.prt` file is not needed. Output: the same `.bsp` with new visdata. Engines need no changes, because the format is standard Quake 1 PVS (BSP29, BSP2 and Hexen 2 are supported; Quake 2 is not).

1. Read every vis leaf and its XY bounding box. Solid and sky leafs get no PVS and are never visible, as with `vis`.
2. For each leaf **A**, move A's XY box by the offset and grow it by the footprint plus the margin. The PVS point can be anywhere inside A.
3. Leaf **B** is visible from A if B's XY box overlaps that box (or, with `-radius`, is within that distance of it). Z is ignored, so everything in the column is visible.
4. Compress each row (the same run-length encoding as `vis`), share identical rows, and write the visdata lump.

It runs in O(leafs²) box tests, in parallel. See [Compile speed](#compile-speed).

Ambient sounds (`vis` computes them from the PVS) are not computed: the leafs keep the zero levels that `qbsp` writes.

Source: [ericw-tools/gridvis/gridvis.cc](ericw-tools/gridvis/gridvis.cc), options in [ericw-tools/include/gridvis/gridvis.hh](ericw-tools/include/gridvis/gridvis.hh).

### Options

| Option | Default | Meaning |
|---|---|---|
| `-rectx W` | 2048 | Footprint width (world X) in units: the ground the screen shows at the furthest zoom you want to support. For a fixed-yaw camera, such as north-up strategy games. |
| `-recty H` | 2048 | Footprint depth (world Y). |
| `-offsetx X`, `-offsety Y` | 0 | Moves the footprint relative to the PVS point. A tilted camera sees more ground ahead than behind. |
| `-radius R` | 0 (off) | Circular footprint instead of the rectangle. Use it when the camera can rotate (yaw). |
| `-margin M` | 64 | Extra border so that big entities and leaf-boundary cases don't pop at the screen edge. |
| `-stats` | off | Prints a leaf size histogram. Always printed: average and maximum visible leafs, unique rows, largest leaf. |

`gridvis` warns when a leaf is bigger than the footprint, because culling can't be finer than the leafs.

## Compile speed

`vis` traces visibility through portals; its cost explodes with map complexity, and open areas are its worst case. `gridvis` only compares 2D leaf boxes, so it stays fast even with tens of thousands of leafs.

Times are from the `ERICW_BENCH` logs on an RTX 5060 Laptop machine (16 threads). The ratios are rounded:

| Map | `vis` (full) | `gridvis` | Times faster | Time saved | Speed increase |
|---|---|---|---|---|---|
| `gridtest`, whole run (1607 leafs, 3349 portals) | 44–47.5 s | 0.2 s | ~220× | 99.5% | ~22,000% |
| `gridtest`, visibility step only | 47.5 s | 0.06 s | ~800× | 99.9% | ~79,000% |
| quakemash (40,988 leafs, 12,427 portals) | not measured | 1.0 s (0.43 s visibility step) | — | — | — |

"Time saved" is the reduction in compile time. "Speed increase" is the same speed-up written as a percentage: 220× faster is about 22,000% faster.

For quakemash, vklight only ran `vis -fast` (3 s), which is a rough approximation and not comparable. A full `vis` run on it with `ERICW_TIMELIMIT` would give the large-map comparison.

## Key constraints

1. **Leaf size.** The PVS is per leaf. If a big open field is a single leaf, an entity anywhere in it is visible from anywhere in it, and gridvis can cull nothing. In ericw-tools 2.0, `-blocksize` no longer does anything, and `-maxnodesize` only makes `qbsp` pick *existing brush planes* near the middle of big nodes. Empty air has no brush planes, so it stays in a few huge leafs. The fix is a grid of **hint brushes**: [tools/hintgrid.py](tools/hintgrid.py) adds one hint plane every N units in X and Y. On the test map, a 512 grid gives 1607 leafs, all at most 512 units wide.
2. **Which point the engine uses for the PVS.**
   - Server (`SV_WriteEntitiesToClient`): the client's player entity origin + `view_ofs`. Entities outside its PVS are **not sent**.
   - Client (`R_MarkLeaves`): the leaf of the actual render origin (the camera, high in the air). This culls world surfaces and static entities.

   The test mod uses the player entity as the camera: QuakeC puts it above and behind the focus, and sets `view_ofs` to point from the camera to the focus in XY. The server takes the PVS at `origin + view_ofs`, so it culls around the **focus**; the client only uses `view_ofs_z` (0 here) and renders from the camera. This avoids `svc_setview` to a separate camera entity, which the server would stop sending when the camera is outside the footprint, about 1835 units behind the focus at far zoom. The client's own PVS is taken at the camera, so it would cut the floor at far zoom. The mod sets `r_novis 1` on the client: the whole floor is drawn and only the monsters are culled.
   Pitfalls found on the way, all from the QuakeSpasm lineage: the client doesn't update the position of an entity without a model, so the view stays at `(0 0 0)`. The server doesn't send entities with alpha 0, not even the client's own. And a `stuffcmd` from `PutClientInServer` is lost during the connection, so the mod sends its client settings on the first game frame. The player has `progs/player.mdl`, which the client never draws in first person.
3. **The map must be sealed** (no leaks), with a sky ceiling high enough that the far camera is still inside the map. Otherwise there are no leafs and no vis.
4. **Monster AI uses the PVS.** `checkclient()` and target finding only wake monsters whose leaf is in the player's PVS. With gridvis, monsters wake when they are near the screen, not when they have line of sight. That is probably what a top-down game wants, but it changes gameplay. The test mod uses this same builtin to count the monsters the server sends.
5. **Engine limits.** ironwail handles 4000 networked monsters on a local game. An unchanged entity costs about 3.3 bytes per frame, so the vis map sends about 13 KB per frame. The datagram limit (32000 bytes in the QuakeSpasm lineage) caps a full PVS at roughly 9000 entities; above that the server silently drops entities. Over the internet, the limit is much lower.

## Test mod and demo

The same map is compiled with `vis` and with `gridvis`. It should look the same at gameplay zoom, but at a far zoom only the area around the focus is sent and drawn.

### Map: `testmap/gridtest.map`

Generated by [tools/makemap.py](tools/makemap.py): an 8000×8000 sealed field with a sky ceiling at 3072. The floor is tiled with alternating textures, there are crates as landmarks, and there is a 512 hint grid. `compile.bat` runs `qbsp -bsp2` and `light` once, then makes two copies:

- `gridtest_vis.bsp`: `vis` (full, 44 s; 1605 of 1607 leafs visible from each leaf)
- `gridtest_grid.bsp`: `gridvis -rectx 3328 -recty 1536 -offsety 464 -margin 128` (0.2 s; 10.6% visible). The footprint covers the normal-zoom screen (16:9, `fov 90`): from about 280 units behind the focus to 1200 ahead, and up to ±1640 wide at the top edge.

Both have identical leafs, so only the visdata differs. Change the footprint with `set GRIDVIS_ARGS=...` and the map with `set MAP_ARGS=...` before `compile.bat`.

### Mod: `mod/src/gridvis.qc`

A standalone progs: the standard defs plus one file, compiled with fteqcc.

- On map start, it spawns 4000 idle monsters (soldiers, dogs, knights, ogres, zombies, fiends) in a jittered grid. They have no AI and no think.
- The camera follows a focus point that QuakeC moves along a "U" path on the ground, at 800 units per second. The camera looks down at the focus at 55°, with yaw fixed (+Y is up on screen).
  1. 1.5 s wait, then pass 1 at normal zoom: 600 units from the focus, 490 high.
  2. Zoom out in 3 s to the far camera: 3200 units from the focus, 2620 high.
  3. Pass 2: the same path backwards, at far zoom.
- Every 0.25 s it counts the monsters in the player's PVS (`checkclient()`) and shows `monsters sent: N / 4000` at the top of the screen. At the end of each pass it prints `GRIDVIS map=... pass=... avg=... min=... max=...` to the console.
- Cvars, read at map start:

| Cvar | Meaning |
|---|---|
| `scratch1` | number of monsters (0 = 4000). More than about 8000 needs `max_edicts` raised. |
| `scratch2` | 1 = `makestatic` monsters: no network traffic, culled by the client through efrags and the camera's PVS. With the `r_novis 1` the mod sets, nothing is culled in this mode. |
| `scratch3` | 1 = bench mode: `disconnect; quit` at the end. The command is recorded in the demo, so on playback it also ends the timedemo and quits. |
| `scratch4` | 1 = four screenshots (start, normal pass, far pass ×2) into `D:\quake\gridvis\screenshots`, plus the server's and the client's camera position in the console (`viewpos`). |

### Measurements (`tools/bench.py`)

For each map, it records a demo of the run, reads the `GRIDVIS` lines from `qconsole.log`, and plays the demo back with `timedemo`. It reports:

- **sent**: the average (min–max) number of monsters in the PVS per pass;
- **net/frame**: demo size divided by frames, which is what the server sends per frame;
- **fps**: the timedemo result.

First `bench.py` results (RTX 5060 Laptop, 4000 monsters). They were measured with an earlier footprint (`-rectx 2048 -recty 1536 -offsety 128`) and before the camera fixes, but the server side was already working:

| Map | Normal pass, sent | Far pass, sent | Demo size |
|---|---|---|---|
| `gridtest_vis` | 3984 / 4000 | 3984 / 4000 | 38 MB |
| `gridtest_grid` | 511 / 4000 (392–620) | 514 / 4000 (323–620) | 5.6 MB |

### Network check (`tools/netcheck.py`)

This checks from the client side, without QuakeC, that the server really doesn't send every monster. In debug mode (`scratch4 1`), at four points of the run the mod turns on `cl_shownet 2` for a couple of frames. The client then logs every message it receives, with one `fast update` line per entity. `netcheck.py` counts those lines per packet. Results with the current footprint (monsters received, the player entity not counted):

| Map | Moment | `checkclient()` count | Received by the client |
|---|---|---|---|
| `gridtest_vis` | all four samples | 3984 | 3999 |
| `gridtest_grid` | start, normal zoom | 573 | 582 |
| `gridtest_grid` | pass 1, normal zoom | 569 | 586 |
| `gridtest_grid` | pass 2, far zoom (start) | 622 | 811 |
| `gridtest_grid` | pass 2, far zoom (middle) | 462 | 536 |

On the vis map, every packet carries all the monsters. On the gridvis map, 13–20% arrive. The on-screen counter (`checkclient()`) runs a little low, especially while the camera moves: it reuses a PVS up to 0.1 s old, it only tests the leaf of each monster's origin while the server tests every leaf its box touches, and the server's PVS is 8 units "fat" (`SV_FatPVS`). The on-screen number is indicative; `netcheck.py` gives the real one.

**FPS caveat:** on this laptop, ironwail's timedemo runs at about 59 fps whatever is set (`vid_vsync 0`, `host_maxfps 0` or `1000`, windowed or fullscreen). The engine does not throttle timedemo, so vsync is being forced outside the game (NVIDIA control panel or the Optimus path). Until it is disabled there, fps can't show the gain, and `sent` and `net/frame` are the reliable metrics.

Other useful checks in game: `r_novis 1` (ignore vis), `r_speeds 1`, `r_showbboxes 1`.

## Success criteria

- [x] At normal zoom, the gridvis map shows every monster on screen (checked with screenshots and by eye).
- [x] At the far camera, the number of entities sent is roughly the footprint area over the map area, not 4000. With the first footprint it was about 514 of 4000 (13%). That footprint with margin is 2304 × 1792. Rounded out to whole 512-unit leafs on both sides, it is about 3300 × 2800, which is 14% of the field, so about 580 were expected. With the current footprint (`-rectx 3328 -recty 1536 -offsety 464`), checked in game: about 680 of 4000 (17%) in both passes. At normal zoom nothing on screen is missing, and at far zoom only a patch around the focus has monsters.
- [ ] Measurable FPS gain in `timedemo` on the far pass. *Blocked by the forced vsync, see above.*
- [x] `gridvis` compiles the test map in seconds: 0.2 s, against 44 s for `vis` (~220× faster, see [Compile speed](#compile-speed)).

## Development

The project started as a copy of `d:/code/vklight`: the vendored ericw-tools (with `deps/`, but not its build folder), `build.bat`/`build.sh`, `.gitignore`, and the ironwail test loop. vklight's GPU `light` (`vklight.exe`) lights the test map in under 2 s. The ericw-tools `ERICW_BENCH` / `ERICW_TIMELIMIT` logging works for `gridvis` too.

| Path | What |
|---|---|
| `ericw-tools/gridvis/` | the new tool (CMake target `gridvis`) |
| `tools/hintgrid.py` | adds a hint grid to any `.map` |
| `tools/makemap.py` | generates the test map |
| `tools/bench.py` | A/B benchmark with ironwail |
| `tools/netcheck.py` | counts the entities the client really receives (`cl_shownet 2`) |
| `mod/` | test mod: `src/` (QuakeC), `bin/fteqcc64.exe`, `build.bat` |
| `compile.bat`, `play.bat` | build the two test maps; open one in ironwail |

### Phases

- [x] **G0. Setup.** Copy vklight, game dir `gridvis`.
- [x] **G1. Skeleton.** `gridvis` CMake target that reuses the BSP loading, row compression, and BSP writing from ericw-tools.
- [x] **G2. Grid PVS.** Footprint options, overlap test, shared rows, and `-stats`.
- [x] **G3. Test map and leaf size.** Done with a hint grid, because the `qbsp` options can't split empty air.
- [x] **G4. Mod.** Monsters (networked and static), camera script, counter, bench mode.
- [x] **G5. A/B scripts.** `compile.bat`, `play.bat`, `tools/bench.py`.
- [ ] **G6. Extras.** A trapezoid footprint from camera parameters (`-fov`, `-pitch`, `-height`), `-zrange` for multi-floor maps, a 2D bucket grid for maps with many leafs, ambient sounds, and a `qbsp -gridsplit N` option as an alternative to hint brushes.

## Open questions

- Fixed-yaw camera (`-rectx/-recty`) or a rotating one (`-radius`)?
- In a real game, is the PVS point the player at the focus (as in the test mod), or a camera entity set with `svc_setview`? With the second, `-offsety` must cover the distance between the camera and the focus.
- Target engines: only ironwail, or also QuakeSpasm and vkQuake?
- Is it ever useful to combine the grid with real portal vis (`grid AND vis`), for example for indoor levels in a top-down game?

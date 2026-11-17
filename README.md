# Lane Renumber v0.1.0 – renumber markers and regions by ruler lane in REAPER

REAPER's own *Renumber all markers/regions in timeline order* ignores ruler lanes: a marker on lane 2 sitting
between two lane-1 markers breaks the lane-1 sequence. **Lane Renumber** numbers each lane on its own:
the markers on lane 1 get consecutive numbers in time order, no matter what other lanes have before or in
between them, then lane 2, and so on. Markers and regions are separate series, as in REAPER.

Two actions:
- `LaneRenumber.lua` – ReaImGui window with a live preview (old → new) and the settings below.
- `LaneRenumber_Quick.lua` – no window: renumbers at once with the settings last used in the window. Put it on a
  toolbar or a shortcut. Does not need ReaImGui.

## Quick start (macOS)

```bash
cd lane-renumber
./install_mac.sh
```

Then in REAPER: *Actions → Show action list → search "LaneRenumber" → run **Script: LaneRenumber.lua***.
(REAPER open during the install? *New action → Load ReaScript…* and pick the files in
`~/Library/Application Support/REAPER/Scripts/LaneRenumber/`.)

Needs **REAPER 7 with ruler lanes** and, for the window, **ReaImGui** (*Extensions → ReaPack → Browse packages →
"ReaImGui"*). Portable REAPER: `./install_mac.sh --portable <folder>`. Uninstall: `./install_mac.sh --uninstall`.
Or add the `_n_plugins` ReaPack repository.

## Using it

1. Open the window. Every marker and region is listed with its lane, position, current number and the new one.
2. Pick a mode and the first number; untick lanes that must keep their numbers.
3. **Renumber (n)** – writes the numbers. One undo step.

| Setting | What it does |
|---|---|
| Markers / Regions | Which of the two series are renumbered |
| Mode: Continuous | Lane 1 gets 1..N in time order, lane 2 continues at N+1, … (default) |
| Mode: Block per lane | Lane *k* starts at *start + (k−1) × block*: 1, 101, 201 … A warning appears if a lane overflows its block |
| Mode: Restart on every lane | Every lane starts again at *start*. Duplicate marker numbers across lanes are allowed (warning); for regions this is refused, because REAPER does not accept duplicate region numbers |
| First number | Where numbering starts (default 1) |
| Skip numbers used by kept ones | A marker/region that keeps its number reserves it, so nothing is doubled (default on) |
| Locked lanes keep their numbers | Default on |
| Hidden markers/regions keep their numbers | Default off |
| Lane ticks | Unticked lanes keep their numbers. Remembered per project, by lane GUID (survives re-ordering lanes) |

Order inside a lane: position, then end (shorter region first), then the old number.
The numbers are written in two passes (first to temporary numbers above everything in use, then to the final
ones), so swapping numbers between lanes never collides; every number is read back afterwards and anything
REAPER did not accept is reported and put back.

## Verified vs. NOT verified

Verified offline (`dev/tools/run_tests.sh`, 103 checks, any Lua 5.3+):
- the numbering logic (all three modes, ties, kept lanes, locked / hidden, overflow, duplicates),
- the REAPER-facing code against an in-memory fake of the API (reading lanes, two-phase write, refused numbers,
  per-project lane ticks, tab switches, old REAPER without the lane API),
- the window with a stubbed ImGui, and both built bundles through their real defer loop / single run.

**Not run inside REAPER – I could not.** Things only REAPER can confirm:
- that `I_LANENUMBER` uses the same 0-based index as `RULER_LANE_NAME:X` / `RULER_LANE_LOCKED:X`
  (the window would then show the wrong lane names – the numbering itself only depends on `I_LANENUMBER`),
- that `SetRegionOrMarkerInfo_Value(…, "I_NUMBER", n)` refuses a duplicate region number the way
  `SetProjectMarkerByIndex2` is documented to (if it accepts it, the read-back simply finds nothing to report),
- how the window looks.

Treat the first run as a test: check the preview, apply, look at the ruler, undo if needed.

# Changelog

## 0.1.0
* Renumber markers and regions **per ruler lane**, in time order: lane 1 gets consecutive numbers whatever the
  other lanes have before or in between.
* Modes: continuous across lanes, block per lane (1, 101, 201 …), restart on every lane.
* Markers and regions as separate series; either can be left alone.
* Untick lanes to keep their numbers (remembered per project by lane GUID); locked lanes and hidden markers can be kept;
  kept numbers are skipped so nothing is doubled.
* Live preview old → new; one undo step; two-phase write (temporary numbers first) and read-back verification.
* `LaneRenumber_Quick.lua`: same with the last settings, no window, no ReaImGui needed.
* ReaImGui window in the 262° theme, single instance (run again to close, toolbar toggle state);
  macOS installer; offline tests: 103 checks.

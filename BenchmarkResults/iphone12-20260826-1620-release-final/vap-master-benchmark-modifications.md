# vap-master benchmark-only modifications

`vap-master/` is excluded by the parent repository's `.gitignore`, so these
changes are intentionally recorded here for reproducibility. They were used
only by the signed benchmark build and do not claim to be upstream changes.

## Files changed

- `vap-master/iOS/QGVAPlayer/QGVAPlayer/Classes/UIView+VAP.h/.m`
  - Added the metrics sink/event types.
  - Started the prepare clock at `playHWDMP4` entry.
  - Moved the prepare event after `hwd_loadMetalDataIfNeed` so the old side
    includes the work required before the render loop is ready.
  - Recorded rendered and first-frame events at the legacy display boundary.
- `vap-master/iOS/QGVAPlayer/QGVAPlayer/Classes/Controllers/QGAnimatedImageDecodeManager.h/.m`
- `vap-master/iOS/QGVAPlayer/QGVAPlayer/Classes/Controllers/Decoders/QGBaseDecoder.h`
- `vap-master/iOS/QGVAPlayer/QGVAPlayer/Classes/Controllers/Decoders/QGMP4FrameHWDecoder.m`
  - Added decoded, dropped, and decoder-rebuild counters.
- `vap-master/iOS/QGVAPlayerDemo/QGVAPlayerDemo/ViewController.m`
  - Added the same five-run, two-second benchmark flow and JSON report.
  - Added the API→ready wall-clock field and validity filtering.

The final paired raw reports are `vapplayerkit.json` and `vap-master.json` in
this directory. If the benchmark is to be shared or rerun by another
developer, export these ignored changes as a patch or commit them in the
nested source before relying on the command-line collector.

The multi-asset run also adds the same 1.mp4 fixture to the old demo resource
folder. The paired optimized reports are stored in
BenchmarkResults/iphone12-20260826-optimized-multimedia-release.

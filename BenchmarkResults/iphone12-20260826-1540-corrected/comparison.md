# VAPPlayerKit vs vap-master corrected benchmark

- device: iPhone, iOS 26.5.2
- asset: demo.mp4, 1519065 bytes
- valid runs: new 5/5, old 5/5
- build: Debug, signed device build
- window: 2 seconds; one process-cold run and four same-process warm runs

| phase | metric | VAPPlayerKit | vap-master | improvement |
| --- | --- | ---: | ---: | ---: |
| cold | prepare API -> ready (ms) | 37.13 | 39.14 | +5.1% |
| cold | API -> first GPU submission (ms) | 80.80 | 89.60 | +9.8% |
| warm | prepare API -> ready (ms) | 10.37 | 11.40 | +9.0% |
| warm | API -> first GPU submission (ms) | 48.79 | 53.43 | +8.7% |

## Diagnostic counters

| phase | metric | VAPPlayerKit median | vap-master median | interpretation |
| --- | --- | ---: | ---: | --- |
| cold | rendered | 51.00 | 52.00 | same layer, but not a strict cross-implementation equivalence |
| cold | decoded | 57.00 | 56.00 | same layer, but not a strict cross-implementation equivalence |
| cold | dropped | 0.00 | 0.00 | zero in this run; not a stress-test result |
| warm | rendered | 51.00 | 52.00 | same layer, but not a strict cross-implementation equivalence |
| warm | decoded | 58.00 | 57.00 | same layer, but not a strict cross-implementation equivalence |
| warm | dropped | 0.00 | 0.00 | zero in this run; not a stress-test result |

## Metric validity

| metric | status | reason |
| --- | --- | --- |
| prepare_ms | usable for this run | both sides now include work up to the ready/render-loop boundary; internal lifecycle is still not identical |
| play_to_first_frame_ms | primary comparison | both sides measure API call to first GPU/display submission; excludes later GPU completion |
| first_frame_ms | diagnostic only | implementation-specific duration origin differs; do not compare directly |
| rendered / decoded | diagnostic only | event layers and decoder APIs differ; use for regressions within one implementation |
| dropped / drawable_failures / decoder_rebuilds | trigger counters | zero means no trigger in this asset/window, not a general performance guarantee |
| session_finished | excluded | the collector stops after reading the sample, so it is not a stable per-sample metric |

p95 is intentionally not reported: four warm samples and one cold sample are exploratory, not enough for a reliable tail estimate.

# VAPPlayerKit vs vap-master corrected benchmark

- device: iPhone, iOS 26.5.2
- asset: 1.mp4, 4858621 bytes
- valid runs: new 5/5, old 5/5
- build: Release, signed device build
- window: 2 seconds; one process-cold run and four same-process warm runs

| phase | metric | VAPPlayerKit | vap-master | improvement |
| --- | --- | ---: | ---: | ---: |
| cold | API -> ready (ms) | 38.01 | 48.73 | +22.0% |
| cold | API -> first GPU submission (ms) | 82.49 | 97.41 | +15.3% |
| warm | API -> ready (ms) | 2.89 | 11.89 | +75.7% |
| warm | API -> first GPU submission (ms) | 50.84 | 54.04 | +5.9% |

## Diagnostic counters

| phase | metric | VAPPlayerKit median | vap-master median | interpretation |
| --- | --- | ---: | ---: | --- |
| cold | rendered | 41.00 | 39.00 | same layer, but not a strict cross-implementation equivalence |
| cold | decoded | 47.00 | 44.00 | same layer, but not a strict cross-implementation equivalence |
| cold | dropped | 0.00 | 0.00 | zero in this run; not a stress-test result |
| warm | rendered | 42.00 | 41.00 | same layer, but not a strict cross-implementation equivalence |
| warm | decoded | 48.00 | 46.00 | same layer, but not a strict cross-implementation equivalence |
| warm | dropped | 0.00 | 0.00 | zero in this run; not a stress-test result |

## VAPPlayerKit prepare stages (new implementation only)

| phase | stage | median ms |
| --- | --- | ---: |
| cold | inspection | 27.22 |
| cold | frame_source | 0.04 |
| cold | renderer | 6.44 |
| cold | dynamic_resolve | 0.03 |
| cold | dynamic_upload | 0.08 |
| cold | audio | 0.00 |
| warm | inspection | 1.55 |
| warm | frame_source | 0.03 |
| warm | renderer | 0.13 |
| warm | dynamic_resolve | 0.01 |
| warm | dynamic_upload | 0.05 |
| warm | audio | 0.00 |

## Metric validity

| metric | status | reason |
| --- | --- | --- |
| prepare_api_to_ready_ms | primary comparison | both sides start at the benchmark API call and stop at the ready/prepare callback; callback scheduling is included |
| prepare_ms | diagnostic only | implementation-internal prepare duration; useful for stage analysis but not the headline cross-implementation metric |
| play_to_first_frame_ms | primary comparison | both sides measure API call to first GPU/display submission; excludes later GPU completion |
| first_frame_ms | diagnostic only | implementation-specific duration origin differs; do not compare directly |
| rendered / decoded | diagnostic only | event layers and decoder APIs differ; use for regressions within one implementation |
| dropped / drawable_failures / decoder_rebuilds | trigger counters | zero means no trigger in this asset/window, not a general performance guarantee |
| session_finished | excluded | the collector stops after reading the sample, so it is not a stable per-sample metric |

p95 is intentionally not reported: four warm samples and one cold sample are exploratory, not enough for a reliable tail estimate.

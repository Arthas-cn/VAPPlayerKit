# VAPPlayerKit vs vap-master corrected benchmark

- device: iPhone, iOS 26.5.2
- asset: demo.mp4, 1519065 bytes
- valid runs: new 5/5, old 5/5
- build: Release, signed device build
- window: 2 seconds; one process-cold run and four same-process warm runs

| phase | metric | VAPPlayerKit | vap-master | improvement |
| --- | --- | ---: | ---: | ---: |
| cold | API -> ready (ms) | 30.00 | 34.09 | +12.0% |
| cold | API -> first GPU submission (ms) | 69.49 | 85.39 | +18.6% |
| warm | API -> ready (ms) | 2.79 | 8.11 | +65.6% |
| warm | API -> first GPU submission (ms) | 37.73 | 51.32 | +26.5% |

## Diagnostic counters

| phase | metric | VAPPlayerKit median | vap-master median | interpretation |
| --- | --- | ---: | ---: | --- |
| cold | rendered | 51.00 | 51.00 | same layer, but not a strict cross-implementation equivalence |
| cold | decoded | 57.00 | 56.00 | same layer, but not a strict cross-implementation equivalence |
| cold | dropped | 0.00 | 0.00 | zero in this run; not a stress-test result |
| warm | rendered | 52.00 | 50.00 | same layer, but not a strict cross-implementation equivalence |
| warm | decoded | 58.00 | 55.00 | same layer, but not a strict cross-implementation equivalence |
| warm | dropped | 0.00 | 0.00 | zero in this run; not a stress-test result |

## VAPPlayerKit prepare stages (new implementation only)

| phase | stage | median ms |
| --- | --- | ---: |
| cold | inspection | 20.76 |
| cold | frame_source | 0.02 |
| cold | renderer | 8.29 |
| cold | dynamic_resolve | 0.00 |
| cold | dynamic_upload | 0.11 |
| cold | audio | 0.00 |
| warm | inspection | 1.49 |
| warm | frame_source | 0.03 |
| warm | renderer | 0.13 |
| warm | dynamic_resolve | 0.00 |
| warm | dynamic_upload | 0.06 |
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

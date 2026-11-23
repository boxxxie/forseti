# Tech Stack: `forseti`

- **Core Language:** Odin (`dev-2026+`, `base:*` and `core:*` standard packages only; zero external C dependencies in `forseti/`).
- **Language Server & Checker:** `ols` ([`../ols.json`](../ols.json)) aligned with `-vet -vet-tabs -strict-style -disallow-do -warnings-as-errors`.
- **Fact & Audit Store Substrate:** Local Odin `xitdb` (`../xitdb/xitdb`) providing:
  - `Core_Memory` (`vmem.reserve`-backed in-memory store, default standalone backend)
  - `Core_Buffered_File` / `Core_File` (attachable durable disk backend)
  - `Core_Overlay` (zero-copy copy-on-write snapshot forks for counterfactual `diff_replay`)
  - `diff_collection` (slot-skipping structural delta detection)
- **Multi-Threaded Actor Runtime (`actors/` only):** Sibling Odin [**Sleipnir (`package actor`)**](https://github.com/boxxxie/sleipnir) (`../sleipnir/actor`, `v1.1.3+`) providing work-stealing `M:N` scheduling, intrusive MPSC / `Sharded_SPSC_Mailbox` lanes, `Partitioned_Supervisor`, `Registry(string)`, and trapped `try_call` fault isolation. Core `forseti/` stays zero-actor.
- **Benchmarking & Longitudinal History:**
  - `obench` (`../hugi/deps/obench/obench`) for allocation-aware micro-benchmarks and `Counting_Allocator` checks
  - `hugi` (`../hugi/hugi`, [`../hugi.json`](../hugi.json)) for stateful multi-phase pipelines, hardware performance counters, `.hugidb` history tracking, and statistical regression gating (`Mann-Whitney U` / `Welch's t-test`)
- **Telemetry:** Built-in Forseti profiler (`time.tick_now`, arena/heap watermark counters, JSONL & Chrome Trace Event Format export, compile-time `#config(FORSETI_TELEMETRY, true)` toggle).
- **Testing & Verification:**
  - `odin test` with `-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`
  - Sibling black-box 4-layer ATDD executable specifications (`specs/`, `package forseti_specs` importing `../forseti`, `&World` DSL + `#caller_location` attribution + Protocol Drivers)
  - Pattern D `t.seed` property invariants, Pattern E direct unit tests (`tests/` / `forseti/`), and differential oracle fuzz suites with `-sanitize:address`
- **Reference Architectures (`reference/`):** 16 shallow/sparse reference repos ([`../reference/README.md`](../reference/README.md)) including `tablex`, `zen`, `runic`, `clara-rules`, `odoyle-rules`, `pararules`, `soar`, `clips`, `drools`, `ascent`, `souffle`, `egglog`, `feldera-dbsp`, `propaganda`, `propagators-chirho`, and `provsql`.

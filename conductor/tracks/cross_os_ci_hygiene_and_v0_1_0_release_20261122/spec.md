# Specification: Cross-OS CI Matrix, Repo Hygiene & `v0.1.0` Release Prep

> - **Track ID:** `cross_os_ci_hygiene_and_v0_1_0_release_20261122`
> - **Type:** `chore`
> - **Status:** `new`
> - **Dependencies:** Track 7 (`agent_dsl_docs_examples_and_cli_tooling_20261121`)

---

## 1. Problem Statement & Motivation

Tracks 1–7 established Forseti's core compiler, verified decision tables, `xitdb` substrate, lazy PHREAK matcher, Z-set JTMS/Datalog/provenance engine, 1M-rule benchmark suite, CLI, and docs. Before downstream projects depend on Forseti or cutting the inaugural `v0.1.0` release, the repository needs:
1. Clean GitHub Actions dependency pinning (`boxxxie/odin-xitdb` on `v2.2.0` instead of a merged PR branch), `actions/checkout@v7` to eliminate Node.js 20 deprecation warnings, MIT `LICENSE` landed on `origin/master`, and merged local branch cleanup.
2. Continuous verification across **Linux (`ubuntu-latest`)**, **macOS (`macos-latest`)**, and **Windows (`windows-latest`)**—including portable executable suffixes (`.exe`) and temp-directory / path handling in `specs/` and `tests/`—plus a dedicated AddressSanitizer (`-sanitize:address`) CI job.
3. Keep-a-Changelog `CHANGELOG.md`, verified `hugi` benchmark history, and a reproducible `v0.1.0` release checklist.

---

## 2. Architecture & Scope

- **CI Pipeline (`.github/workflows/ci.yml`):**
  - Upgrade `actions/checkout` from `v4` to `v7` across all checkouts (`forseti`, `boxxxie/odin-xitdb@v2.2.0`, `boxxxie/hugi@v0.2.0`).
  - Expand `check-and-test` across `matrix.os: [ubuntu-latest, macos-latest, windows-latest]` (`fail-fast: false`), adding `ilammy/msvc-dev-cmd@v1` on Windows and `shell: bash` for unified shell steps.
  - Add an `asan` job on `ubuntu-latest` running `odin test tests -sanitize:address -collection:xitdb=../xitdb/xitdb -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`.
- **Cross-OS Test & Driver Portability (`specs/driver_test.odin`, `tests/test_examples_verify.odin`):**
  - Append `.exe` to compiled CLI and example binary output paths when `ODIN_OS == .Windows`.
  - Verify `os.make_directory_temp` cleanup, `os.process_exec` path resolution, and `Core_Buffered_File` lock/handle cleanup across Linux, macOS, and Windows.
- **Release Readiness (`CHANGELOG.md`, `docs/benchmarks.md`, `README.md`):**
  - Add `CHANGELOG.md` following Keep a Changelog / SemVer conventions summarizing Tracks 1–7 and cross-OS verification.
  - Verify `benchmarks/history.hugidb` history integrity (`hugi history`, `hugi inspect`) and align `README.md` / `docs/benchmarks.md` version badges on `v0.1.0`.

---

## 3. Functional Requirements

### FR-1: CI Hygiene & Repo Cleanup
- Land `boxxxie/odin-xitdb` `v2.2.0` tag pin (PR #1) and upgrade all `actions/checkout` steps to `@v7` with zero Node.js 20 runtime warnings.
- Land `LICENSE` on `origin/master` (with explicit user approval) and prune merged local `track/*` and `ci/*` branches via `git branch -d`.
- Audit all relative links in `README.md` and `docs/` plus `odin doc forseti`.

### FR-2: Cross-OS Portability & 3-OS CI Matrix
- Make `specs/driver_test.odin` and `tests/test_examples_verify.odin` compile and execute cleanly on Windows (`.exe` output paths, CRLF-tolerant string assertions if needed, clean temp-dir removal) and macOS.
- Run `odin check`, leak-checked `odin test tests`, leak-checked `odin test specs`, and `odin doc forseti` across `[ubuntu-latest, macos-latest, windows-latest]`.
- Add dedicated Linux `-sanitize:address` CI check.

### FR-3: `v0.1.0` Release Artifacts
- Create `CHANGELOG.md` covering `[0.1.0]` (compiler/IR, decision tables, `xitdb`, PHREAK/VM, JTMS/Datalog/provenance, benchmarks, CLI/docs, cross-OS CI).
- Verify `hugi` benchmark history/docs and run full release gate before tagging `v0.1.0` (only after explicit user sign-off).

---

## 4. Non-Functional & Verification Requirements

- Zero `ODIN_TEST_FAIL_ON_BAD_MEMORY=true` failures or bad frees on all 3 OS targets.
- Strict `-vet -vet-tabs -strict-style -warnings-as-errors` clean across `forseti`, `cmd/forseti`, `benchmarks`, `tests`, and `specs`.
- Never push to `master`, merge PRs into `master`, or push `v0.1.0` tags without explicit user authorization in that turn.

---

## 5. Out of Scope

- Multi-threaded actor runtime (`Track 9`).
- `.forseti` LSP server and editor grammars (`Track 10`).
- C ABI shared library (`Track 11`).

---

## 6. Acceptance Criteria

- [ ] `.github/workflows/ci.yml` uses `actions/checkout@v7`, pins `odin-xitdb` at `v2.2.0`, passes across `ubuntu-latest`, `macos-latest`, and `windows-latest`, and passes the `-sanitize:address` job.
- [ ] All 8 merged local branches are pruned cleanly and `LICENSE` / PR #1 state is reconciled cleanly.
- [ ] `CHANGELOG.md` and `v0.1.0` release notes are verified against `hugi` benchmark history and all test gates.

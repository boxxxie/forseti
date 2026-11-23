# Implementation Plan: Cross-OS CI Matrix, Repo Hygiene & `v0.1.0` Release Prep

> - **Track ID:** `cross_os_ci_hygiene_and_v0_1_0_release_20261122`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Dependencies:** Track 7 (`agent_dsl_docs_examples_and_cli_tooling_20261121`)
> - **Workflow:** Follow [`../../workflow.md`](../../workflow.md) (`track/cross-os-ci-hygiene-and-v0-1-0-release` branch, strict `-vet` + `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`).

---

## Phase 1: CI Hygiene, Actions Upgrade & Repo Polish

- [x] Task: Reconcile `odin-xitdb` `v2.2.0` pin, upgrade `actions/checkout@v7`, and clear CI deprecation warnings
    - [x] Verify PR #1 (`boxxxie/odin-xitdb` pinned to `v2.2.0`) and `boxxxie/hugi` pinned to `v0.2.0` in `.github/workflows/ci.yml`
    - [x] Upgrade all `actions/checkout@v4` usages in `.github/workflows/ci.yml` to `actions/checkout@v7`
- [x] Task: Reconcile `LICENSE`, prune merged local branches, and verify docs/package hygiene
    - [x] Confirm MIT `LICENSE` (`7b219ca`) and clean branch graph; prune merged local branches (`feat/benchmark-blind-spots`, `perf/engine-alloc-accum-hydration`) with `git branch -d`
    - [x] Verify all `README.md` / `docs/` links and `odin doc forseti -collection:xitdb=../xitdb/xitdb > /dev/null`
- [x] Task: Conductor - User Manual Verification 'Phase 1: CI Hygiene, Actions Upgrade & Repo Polish' (Protocol in workflow.md)

---

## Phase 2: Cross-OS CI Matrix (`ubuntu-latest`, `macos-latest`, `windows-latest`) & ASan Job

- [x] Task: Audit and fix Windows/macOS path, executable suffix, and temp-dir portability in `specs/` and `tests/` (TDD)
    - [x] Update `specs/driver_test.odin` (`"forseti.exe"` when `ODIN_OS == .Windows`) and `tests/test_examples_verify.odin` (`"example_bin.exe"` on Windows)
    - [x] Audit `os.make_directory_temp`, `filepath.join`, `os.remove_all` (file handles closed before deletion on Windows), and CRLF handling in `cmd/forseti`, `tests/`, and `specs/`
- [x] Task: Expand `.github/workflows/ci.yml` with `[ubuntu-latest, macos-latest, windows-latest]` matrix and Linux ASan job
    - [x] Configure `strategy.matrix.os` with `fail-fast: false`, `ilammy/msvc-dev-cmd@v1` on `Windows`, `shell: bash`, and portable `odin doc` check
    - [x] Add dedicated `ubuntu-latest` ASan job executing `odin test tests -sanitize:address -collection:xitdb=../xitdb/xitdb -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`
- [x] Task: Conductor - User Manual Verification 'Phase 2: Cross-OS CI Matrix & ASan Job' (Protocol in workflow.md)

---

## Phase 3: `v0.1.0` Release Prep (`CHANGELOG.md`, Benchmarks & Release Gate)

- [x] Task: Author `CHANGELOG.md` and reconcile `v0.1.0` benchmark/version documentation
    - [x] Write Keep-a-Changelog / SemVer `CHANGELOG.md` summarizing Tracks 1–11 and Cross-OS CI support
    - [x] Verify `benchmarks/history.hugidb` (`hugi history`, `hugi inspect`) matches `docs/benchmarks.md` and add/update version badge in `README.md`
- [~] Task: Run full pre-release verification gate and tag `v0.1.0` (only upon explicit user approval)
    - [x] Execute `odin check`, leak-checked `tests` and `specs` / `specs_actors`, ASan check, `hugi run --test`, and `odin doc forseti`
    - [ ] Prepare annotated `v0.1.0` tag / GitHub Release notes and obtain explicit user authorization before pushing `master` or `v0.1.0`
- [ ] Task: Conductor - User Manual Verification 'Phase 3: v0.1.0 Release Prep' (Protocol in workflow.md)

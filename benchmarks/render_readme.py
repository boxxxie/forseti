#!/usr/bin/env python3
"""Render Forseti benchmark SVG charts and grouped Markdown tables from benchmarks/history.hugidb."""

from __future__ import annotations

import argparse
import collections
import html
import json
import math
import pathlib
import subprocess
import sys
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parent.parent
BENCH_DIR = ROOT / "benchmarks"
RENDERS_DIR = BENCH_DIR / "renders"
README_PATH = BENCH_DIR / "README.md"

GROUP_META: list[tuple[str, str, str]] = [
    ("decision_tables", "Decision Tables (`First`, `Unique`, `Priority`, `Collect_Sum`, `Merge`, AOT)", "Cost-ordered lazy decision trees, ternary `u64` bitset matrices, and `\"contextless\"` AOT Odin codegen (all `0` heap allocs)."),
    ("scale_rules", "`10` to `1,000,000` Rule Scaling (Alpha DAG & Lazy Session)", "Immutable `Rulebase` compilation, `O(1)` lazy `session_init`, and sparse matching up to `1,000,000` rules."),
    ("scale_join_rules", "Multi-Rule Join Scaling", "Compiled join networks and sparse `1,000`-fact working-memory matching across `10` to `10,000` join rules."),
    ("beta_joins", "Beta Joins, Queries & `@zero_alloc` Hot Match", "Cold 2/3-way joins, skewed fanouts, parameterized queries, and `@zero_alloc` `.Fast` PHREAK updates."),
    ("mdm_e2e", "End-to-End MDM Pipeline (`xitdb` Sync + Fire + Commit)", "Incremental `O(delta)` `Delta_Syncer` ingestion, PHREAK matching, and atomic `.decisions` + `.__tx` persistence."),
    ("jtms_churn", "Z-Set JTMS Cascades & Retractable Accumulators", "Logical assertion/retraction cascades in `.Audit_Full` vs `.Fast`, plus `O(1)` incremental accumulator updates."),
    ("recursive_strata", "Tarjan SCC Semi-Naive Datalog & Cycle Breaking", "Transitive closure over DAGs and cyclic graphs with incremental cycle-break retraction."),
    ("provenance_and_replay", "Causal Explain, Impact, Semirings, `Core_Overlay` & Async Effects", "Minimal proof-tree `explain`, `impact` blast radius, `Why`/`How`/`Viterbi` semirings, `diff_replay`, and 3-phase async effects."),
    ("sleipnir_actors", "Sleipnir Multi-Threaded Actor Runtime (`1`–`8` Workers)", "`Session_Actor` `Chain=K` batching, `Partitioned_Supervisor` tenant fanout, and `Parallel_Diff_Replay`."),
    ("frontend_and_verify", "Compiler Frontend, Static Table Verifier & AOT Codegen", "Lexing/parsing/sema, 4/8-column static table domain partitioning, and `" + "contextless" + "` Odin codegen."),
    ("vm_guard_eval", "32-Bit `#must_tail` Bytecode Guard VM", "Arithmetic, string built-in, `decide` call, and fact field evaluation inside the zero-alloc VM."),
    ("xitdb_modes", "`xitdb` v2 Storage Substrate & File Hydration", "Safe SHA-1 HAMT + CRC-64/XZ inserts, prehashed lookups, slot-skipping diffs, and `Core_Buffered_File` commits."),
    ("hasher_raw_verify", "Hardware SHA-NI vs Software SHA-1 Throughput", "Raw `xitdb` SHA-NI accelerated SHA-1/SHA-256 vs Odin `core:crypto` software hashing across `10`–`4096` byte keys."),
    ("hasher_xitdb_verify", "`xitdb` HAMT Lookup & Insert Key-Length Scaling", "End-to-end `Hash_Map` point lookups (hashed vs `Prehashed_Key`) and inserts across `10`–`1024` byte keys."),
]

PALETTE = [
    "#58a6ff",  # blue
    "#3fb950",  # green
    "#f78166",  # coral/orange
    "#d2a8ff",  # purple
    "#ffa657",  # amber
    "#79c0ff",  # sky
    "#ff7b72",  # red
]


def fmt_ns(ns: float) -> str:
    if ns < 1.0:
        return f"{ns * 1000.0:.2f} ps"
    if ns < 1_000.0:
        return f"{ns:.2f} ns"
    if ns < 1_000_000.0:
        return f"{ns / 1_000.0:.2f} us"
    if ns < 1_000_000_000.0:
        return f"{ns / 1_000_000.0:.2f} ms"
    return f"{ns / 1_000_000_000.0:.3f} s"


def fmt_bytes(b: float) -> str:
    if b < 1024.0:
        return f"{b:.0f} B"
    if b < 1024.0 * 1024.0:
        return f"{b / 1024.0:.2f} KiB"
    if b < 1024.0 * 1024.0 * 1024.0:
        return f"{b / (1024.0 * 1024.0):.2f} MiB"
    return f"{b / (1024.0 * 1024.0 * 1024.0):.2f} GiB"


def fmt_ops(ops: float) -> str:
    if ops >= 1_000_000_000.0:
        return f"{ops / 1_000_000_000.0:.2f}B/s"
    if ops >= 1_000_000.0:
        return f"{ops / 1_000_000.0:.2f}M/s"
    if ops >= 1_000.0:
        return f"{ops / 1_000.0:.1f}K/s"
    return f"{ops:.0f}/s"


def extract_scale(full_name: str) -> int | None:
    if "[" in full_name and full_name.endswith("]"):
        raw = full_name.rsplit("[", 1)[1][:-1]
        if raw.isdigit():
            return int(raw)
    return None


def hugi_export(args: list[str]) -> list[dict[str, Any]]:
    cmd = ["hugi", "export", "--db", str(BENCH_DIR / "history.hugidb"), "--format", "json", "--out", "-", *args]
    raw = subprocess.check_output(cmd, cwd=ROOT, text=True)
    return json.loads(raw)


def hugi_latest_commit() -> str:
    raw = subprocess.check_output(["hugi", "history", "--db", str(BENCH_DIR / "history.hugidb"), "--limit", "1"], cwd=ROOT, text=True)
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("Commit") or line.startswith("-"):
            continue
        return line.split("|")[0].strip()
    raise RuntimeError("No commits found in benchmarks/history.hugidb")


def render_line_chart_svg(
    out_path: pathlib.Path,
    title: str,
    subtitle: str,
    x_labels: list[str],
    series: list[tuple[str, list[float | None], str]],
    *,
    y_log: bool = True,
    y_unit_label: str = "Latency (p50, lower is better)",
    width: int = 880,
    height: int = 440,
) -> None:
    pad_l, pad_r, pad_t, pad_b = 82, 96, 74, 96
    pw = width - pad_l - pad_r
    ph = height - pad_t - pad_b

    vals = [v for _, ys, _ in series for v in ys if v is not None and v > 0]
    if not vals:
        raise RuntimeError(f"No positive values for {out_path.name}")

    if y_log:
        min_exp = math.floor(math.log10(min(vals)))
        max_exp = math.ceil(math.log10(max(vals)))
        if min_exp == max_exp:
            max_exp += 1
        y_ticks = [10.0 ** e for e in range(min_exp, max_exp + 1)]
        y_min_t, y_max_t = float(min_exp), float(max_exp)

        def y_px(v: float) -> float:
            t = (math.log10(v) - y_min_t) / (y_max_t - y_min_t)
            return pad_t + ph - t * ph
    else:
        max_v = max(vals) * 1.12
        step = 10.0 ** math.floor(math.log10(max_v)) / 2.0
        if max_v / step > 7:
            step *= 2.0
        if max_v / step < 3:
            step /= 2.0
        n_ticks = max(2, math.ceil(max_v / step))
        y_max_val = n_ticks * step
        y_ticks = [i * step for i in range(n_ticks + 1)]

        def y_px(v: float) -> float:
            t = v / y_max_val
            return pad_t + ph - t * ph

    n_x = len(x_labels)

    def x_px(i: int) -> float:
        if n_x <= 1:
            return pad_l + pw * 0.5
        return pad_l + (i / (n_x - 1)) * pw

    parts: list[str] = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}" role="img" aria-label="{html.escape(title)}">',
        '<style>',
        '  .bg { fill: #0d1117; }',
        '  .panel { fill: #161b22; stroke: #30363d; stroke-width: 1; }',
        '  .grid { stroke: #21262d; stroke-width: 1; }',
        '  .axis { stroke: #30363d; stroke-width: 1.2; }',
        '  .title { fill: #f0f6fc; font: 700 16px -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }',
        '  .sub { fill: #8b949e; font: 400 12px -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }',
        '  .tick { fill: #8b949e; font: 500 11px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }',
        '  .legend { fill: #c9d1d9; font: 500 11.5px -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }',
        '  .val { font: 600 10.5px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }',
        '</style>',
        f'<rect class="bg" width="{width}" height="{height}" rx="10"/>',
        f'<rect class="panel" x="{pad_l}" y="{pad_t}" width="{pw}" height="{ph}" rx="4"/>',
        f'<text class="title" x="{pad_l}" y="30">{html.escape(title)}</text>',
        f'<text class="sub" x="{pad_l}" y="49">{html.escape(subtitle)} · {html.escape(y_unit_label)}</text>',
    ]

    for yt in y_ticks:
        yp = y_px(yt) if yt > 0 or not y_log else pad_t + ph
        parts.append(f'<line class="grid" x1="{pad_l}" y1="{yp:.1f}" x2="{pad_l + pw}" y2="{yp:.1f}"/>')
        lbl = "0" if yt == 0 else fmt_ns(yt).replace(".00 ", " ").replace(".000 ", " ")
        parts.append(f'<text class="tick" x="{pad_l - 8}" y="{yp + 4:.1f}" text-anchor="end">{html.escape(lbl)}</text>')

    for xi, xl in enumerate(x_labels):
        xp = x_px(xi)
        parts.append(f'<line class="grid" x1="{xp:.1f}" y1="{pad_t}" x2="{xp:.1f}" y2="{pad_t + ph}"/>')
        parts.append(f'<text class="tick" x="{xp:.1f}" y="{pad_t + ph + 18}" text-anchor="middle">{html.escape(xl)}</text>')

    parts.append(f'<line class="axis" x1="{pad_l}" y1="{pad_t + ph}" x2="{pad_l + pw}" y2="{pad_t + ph}"/>')
    parts.append(f'<line class="axis" x1="{pad_l}" y1="{pad_t}" x2="{pad_l}" y2="{pad_t + ph}"/>')

    end_labels: list[tuple[float, str, str]] = []
    for _, ys, color in series:
        pts: list[tuple[int, float, float, float]] = []
        for xi, val in enumerate(ys):
            if val is not None and (val > 0 or not y_log):
                pts.append((xi, x_px(xi), y_px(val), val))
        if len(pts) >= 2:
            d = " ".join(f"{'M' if idx == 0 else 'L'} {xp:.1f} {yp:.1f}" for idx, (_, xp, yp, _) in enumerate(pts))
            parts.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>')
        for _, xp, yp, _ in pts:
            parts.append(f'<circle cx="{xp:.1f}" cy="{yp:.1f}" r="4" fill="{color}" stroke="#0d1117" stroke-width="1.5"/>')
        if pts:
            _, _, last_yp, last_val = pts[-1]
            end_labels.append((last_yp, fmt_ns(last_val), color))

    # Place endpoint labels cleanly in the right margin in exact vertical order with >= 14px spacing.
    end_labels.sort(key=lambda item: item[0])
    placed_y: list[float] = []
    for raw_y, _, _ in end_labels:
        y = max(pad_t + 10.0, min(pad_t + ph - 4.0, raw_y + 4.0))
        if placed_y and y < placed_y[-1] + 14.0:
            y = placed_y[-1] + 14.0
        placed_y.append(y)
    # Pull up from bottom if any label was pushed past the plot floor.
    if placed_y and placed_y[-1] > pad_t + ph + 4.0:
        shift = placed_y[-1] - (pad_t + ph + 4.0)
        placed_y[-1] -= shift
        for idx in range(len(placed_y) - 2, -1, -1):
            if placed_y[idx] > placed_y[idx + 1] - 14.0:
                placed_y[idx] = placed_y[idx + 1] - 14.0
    for (_, text_val, color), ly in zip(end_labels, placed_y):
        parts.append(
            f'<text class="val" x="{pad_l + pw + 8:.1f}" y="{ly:.1f}" text-anchor="start" fill="{color}">{html.escape(text_val)}</text>'
        )

    # Legend in two clean rows below x-axis
    cols = 3
    col_w = pw / cols
    for idx, (label, _, color) in enumerate(series):
        row = idx // cols
        col = idx % cols
        lx = pad_l + col * col_w
        ly = pad_t + ph + 44 + row * 20
        parts.append(f'<rect x="{lx:.1f}" y="{ly - 9:.1f}" width="12" height="4" rx="2" fill="{color}"/>')
        parts.append(f'<text class="legend" x="{lx + 18:.1f}" y="{ly - 3:.1f}">{html.escape(label)}</text>')

    parts.append("</svg>")
    out_path.write_text("\n".join(parts) + "\n", encoding="utf-8")


def render_bar_chart_svg(
    out_path: pathlib.Path,
    title: str,
    subtitle: str,
    bars: list[tuple[str, float, str, str]],
    *,
    x_log: bool = True,
    width: int = 900,
) -> None:
    pad_l, pad_r, pad_t, pad_b = 260, 175, 68, 42
    row_h = 34
    ph = len(bars) * row_h + 12
    height = pad_t + ph + pad_b
    pw = width - pad_l - pad_r

    vals = [v for _, v, _, _ in bars if v > 0]
    min_exp = math.floor(math.log10(min(vals)))
    max_exp = math.ceil(math.log10(max(vals)))
    if min_exp == max_exp:
        max_exp += 1

    def x_len(v: float) -> float:
        if x_log:
            t = (math.log10(v) - min_exp) / (max_exp - min_exp)
            return max(4.0, t * pw)
        return max(4.0, (v / (max(vals) * 1.1)) * pw)

    parts: list[str] = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}" role="img" aria-label="{html.escape(title)}">',
        '<style>',
        '  .bg { fill: #0d1117; }',
        '  .panel { fill: #161b22; stroke: #30363d; stroke-width: 1; }',
        '  .grid { stroke: #21262d; stroke-width: 1; }',
        '  .title { fill: #f0f6fc; font: 700 16px -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }',
        '  .sub { fill: #8b949e; font: 400 12px -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }',
        '  .lbl { fill: #c9d1d9; font: 500 11.5px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }',
        '  .tick { fill: #8b949e; font: 500 10.5px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }',
        '  .val { fill: #e6edf3; font: 600 11px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }',
        '</style>',
        f'<rect class="bg" width="{width}" height="{height}" rx="10"/>',
        f'<rect class="panel" x="{pad_l}" y="{pad_t}" width="{pw}" height="{ph}" rx="4"/>',
        f'<text class="title" x="24" y="30">{html.escape(title)}</text>',
        f'<text class="sub" x="24" y="49">{html.escape(subtitle)}</text>',
    ]

    if x_log:
        for e in range(min_exp, max_exp + 1):
            t = (e - min_exp) / (max_exp - min_exp)
            xp = pad_l + t * pw
            parts.append(f'<line class="grid" x1="{xp:.1f}" y1="{pad_t}" x2="{xp:.1f}" y2="{pad_t + ph}"/>')
            lbl = fmt_ns(10.0 ** e).replace(".00 ", " ").replace(".000 ", " ")
            parts.append(f'<text class="tick" x="{xp:.1f}" y="{pad_t + ph + 18}" text-anchor="middle">{html.escape(lbl)}</text>')

    for idx, (label, val, note, color) in enumerate(bars):
        ry = pad_t + 10 + idx * row_h
        w_bar = x_len(val)
        parts.append(f'<text class="lbl" x="{pad_l - 10}" y="{ry + 16:.1f}" text-anchor="end">{html.escape(label)}</text>')
        parts.append(f'<rect x="{pad_l}" y="{ry + 3:.1f}" width="{w_bar:.1f}" height="20" rx="4" fill="{color}"/>')
        parts.append(f'<text class="val" x="{pad_l + w_bar + 8:.1f}" y="{ry + 17:.1f}">{html.escape(fmt_ns(val))} ({html.escape(note)})</text>')

    parts.append("</svg>")
    out_path.write_text("\n".join(parts) + "\n", encoding="utf-8")


def generate_renders(latest_rows: list[dict[str, Any]], all_rows: list[dict[str, Any]], commit: str) -> None:
    RENDERS_DIR.mkdir(parents=True, exist_ok=True)
    by_full = {r["full_name"]: r for r in latest_rows}

    # 1. 10 to 1,000,000 Rule Scaling
    scales_1m = [10, 100, 1000, 10000, 100000, 1000000]
    x_1m = ["10", "100", "1k", "10k", "100k", "1M"]
    render_line_chart_svg(
        RENDERS_DIR / "1m_rule_scaling.svg",
        "10 to 1,000,000 Rule Scaling (scale_rules)",
        f"Commit {commit} · Ryzen 7 7735U · -o:speed -microarch:native",
        x_1m,
        [
            ("sparse_alpha_match (.Fast)", [by_full.get(f"scale_rules::sparse_alpha_match[{n}]", {}).get("p50_ns") for n in scales_1m], PALETTE[1]),
            ("audit_full_sparse_match (.Audit_Full)", [by_full.get(f"scale_rules::audit_full_sparse_match[{n}]", {}).get("p50_ns") for n in scales_1m], PALETTE[0]),
            ("lazy_session_init (O(1))", [by_full.get(f"scale_rules::lazy_session_init[{n}]", {}).get("p50_ns") for n in scales_1m], PALETTE[3]),
            ("batch_100_alpha_match", [by_full.get(f"scale_rules::batch_100_alpha_match[{n}]", {}).get("p50_ns") for n in scales_1m], PALETTE[4]),
            ("compile_rules (Rulebase)", [by_full.get(f"scale_rules::compile_rules[{n}]", {}).get("p50_ns") for n in scales_1m], PALETTE[2]),
        ],
        y_log=True,
        y_unit_label="Log10 latency (p50)",
    )

    # 2. Decision Tables at 10,000 Rows (0 Heap Allocs)
    tbl_benchmarks = [
        ("aot_native_fast_path[10000]", "Tier 3 AOT (proc \"contextless\")", "0 allocs", PALETTE[1]),
        ("wide_string_range_table[10000]", "wide_string_range_table (10k)", "0 allocs", PALETTE[5]),
        ("priority_table_hit[10000]", "priority_table_hit (10k)", "0 allocs", PALETTE[0]),
        ("cost_tree_single_hit[10000]", "cost_tree_single_hit (10k)", "0 allocs", PALETTE[3]),
        ("lazy_cost_skip[10000]", "lazy_cost_skip (10k)", "0 allocs", PALETTE[4]),
        ("reverse_merge_table_outputs[10000]", "reverse_merge_table (10k)", "0 allocs", PALETTE[2]),
        ("bitset_collect_sum[10000]", "bitset_collect_sum (10k)", "0 allocs", PALETTE[6]),
    ]
    bars = []
    for key, lbl, note, col in tbl_benchmarks:
        row = by_full.get(f"decision_tables::{key}")
        if row:
            bars.append((lbl, row["p50_ns"], note, col))
    render_bar_chart_svg(
        RENDERS_DIR / "decision_tables.svg",
        "Decision Tables at 10,000 Rows (Zero Heap Allocations)",
        f"Commit {commit} · Lazy cost trees, ternary u64 bitsets & Tier 3 AOT",
        bars,
        x_log=True,
    )

    # 3. PHREAK & MDM Working-Memory Scaling (10 to 10,000 facts)
    scales_10k = [10, 100, 1000, 10000]
    x_10k = ["10", "100", "1,000", "10,000"]
    render_line_chart_svg(
        RENDERS_DIR / "phreak_and_mdm_scaling.svg",
        "PHREAK Hot Match & Incremental MDM Sync Scaling (10–10,000 Facts)",
        f"Commit {commit} · O(delta) incremental updates vs cold 2-way join",
        x_10k,
        [
            ("phreak_hot_match_zero_alloc (.Fast)", [by_full.get(f"beta_joins::phreak_hot_match_zero_alloc[{n}]", {}).get("p50_ns") for n in scales_10k], PALETTE[1]),
            ("incremental_join_audit_full", [by_full.get(f"beta_joins::incremental_join_audit_full[{n}]", {}).get("p50_ns") for n in scales_10k], PALETTE[5]),
            ("incremental_sync_fire_fast_safe_v2", [by_full.get(f"mdm_e2e::incremental_sync_fire_fast_safe_v2[{n}]", {}).get("p50_ns") for n in scales_10k], PALETTE[0]),
            ("incremental_sync_fire_audit_full_safe_v2", [by_full.get(f"mdm_e2e::incremental_sync_fire_audit_full_safe_v2[{n}]", {}).get("p50_ns") for n in scales_10k], PALETTE[3]),
            ("two_way_mdm_join (cold build)", [by_full.get(f"beta_joins::two_way_mdm_join[{n}]", {}).get("p50_ns") for n in scales_10k], PALETTE[2]),
        ],
        y_log=True,
        y_unit_label="Log10 latency (p50)",
    )

    # 4. Sleipnir Multi-Threaded Actor Runtime (1, 2, 4, 8 workers)
    workers = [1, 2, 4, 8]
    x_w = ["1 worker", "2 workers", "4 workers", "8 workers"]
    render_line_chart_svg(
        RENDERS_DIR / "sleipnir_actors.svg",
        "Sleipnir Multi-Threaded Actor Runtime Scaling (1–8 Workers)",
        f"Commit {commit} · Session_Actor Chain=K, Partitioned Tenants & Parallel Core_Overlay",
        x_w,
        [
            ("parallel_diff_replay_4_cands", [by_full.get(f"sleipnir_actors::parallel_diff_replay_4_cands[{w}]", {}).get("p50_ns") for w in workers], PALETTE[0]),
            ("session_actor_chain_k_batch", [by_full.get(f"sleipnir_actors::session_actor_chain_k_batch[{w}]", {}).get("p50_ns") for w in workers], PALETTE[1]),
            ("tenant_runtime_fanout", [by_full.get(f"sleipnir_actors::tenant_runtime_fanout[{w}]", {}).get("p50_ns") for w in workers], PALETTE[4]),
        ],
        y_log=False,
        y_unit_label="Linear latency (p50, lower is better)",
    )

    # 5. Longitudinal Optimization Progression across history.hugidb
    commits_order = ["be8f675", "e9cd4fc0fe6f", "4887f749eb7e", "05b9229bba93", "7444ff06ce0f", "434960b28fd0"]
    c_labels = ["be8f675", "e9cd4fc", "4887f74", "05b9229", "7444ff0", "434960b"]
    by_cm: dict[str, dict[str, float]] = collections.defaultdict(dict)
    for r in all_rows:
        by_cm[r["commit"]][r["full_name"]] = r["p50_ns"]

    # Note: mdm_e2e in be8f675 had a shallow-copy bug fixed in e9cd4fc, so start its series at e9cd4fc0fe6f.
    render_line_chart_svg(
        RENDERS_DIR / "longitudinal_history.svg",
        "Longitudinal Optimization Progression Across Commits",
        "Tracked in benchmarks/history.hugidb (up to 101,000x speedup on hot PHREAK match)",
        c_labels,
        [
            ("phreak_hot_match_zero_alloc[10000]", [by_cm.get(c, {}).get("beta_joins::phreak_hot_match_zero_alloc[10000]") for c in commits_order], PALETTE[1]),
            ("sparse_alpha_match[1000000]", [by_cm.get(c, {}).get("scale_rules::sparse_alpha_match[1000000]") for c in commits_order], PALETTE[0]),
            ("incremental_sync_fire_audit_full[10000]", [None if c == "be8f675" else by_cm.get(c, {}).get("mdm_e2e::incremental_sync_fire_audit_full_safe_v2[10000]") for c in commits_order], PALETTE[3]),
            ("overlay_diff_replay[5000]", [by_cm.get(c, {}).get("provenance_and_replay::overlay_diff_replay[5000]") for c in commits_order], PALETTE[4]),
            ("compile_rules[1000000]", [by_cm.get(c, {}).get("scale_rules::compile_rules[1000000]") for c in commits_order], PALETTE[2]),
        ],
        y_log=True,
        y_unit_label="Log10 latency (p50)",
    )


def render_markdown(latest_rows: list[dict[str, Any]], commit: str) -> str:
    by_group: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
    for r in latest_rows:
        by_group[r["group_name"]].append(r)

    total_samples = sum(int(r.get("samples", 0)) for r in latest_rows)
    lines: list[str] = [
        "[Root README](../README.md) · [Docs Hub](../docs/README.md) · [Benchmarks Analysis](../docs/benchmarks.md) · **Suite Renders**",
        "",
        "# Forseti Benchmarks & Visual Renders",
        "",
        f"This directory contains Forseti's longitudinal [`hugi`](https://github.com/boxxxie/hugi) + [`obench`](https://github.com/zeybek/obench) benchmark suite (`{len(latest_rows)}` benchmarks across `{len(by_group)}` groups, `{total_samples:,}` samples at commit `{commit}` in [`history.hugidb`](history.hugidb)), visual SVG charts under [`renders/`](renders/), and a `--profile-1m` telemetry sweep.",
        "",
        "> For architectural deep dives, hardware PMU counters, and Phase 2 optimization notes, see [`docs/benchmarks.md`](../docs/benchmarks.md).",
        "",
        "---",
        "",
        "## Visual Renders (`v0.1.0` Snapshot)",
        "",
        "### 1. `10` to `1,000,000` Rule Scaling",
        "",
        "Lazy `session_init` holds flat at **`20.17 us` (`O(1)`)** and `sparse_alpha_match` stays at **`1.87 us`** (`2.64 us` `.Audit_Full`) even when `1,000,000` rules are compiled into the `Rulebase`:",
        "",
        "![10 to 1,000,000 Rule Scaling](renders/1m_rule_scaling.svg)",
        "",
        "### 2. Decision Tables at `10,000` Rows (`0` Heap Allocations)",
        "",
        "Tier 3 `" + "contextless" + "` AOT tables execute in **`775.58 ps`**, while runtime cost-ordered decision trees (`38.78–42.90 ns`) and `u64` ternary bitset matrices (`476.20–484.96 ns`) run with **`0` heap allocations**:",
        "",
        "![Decision Tables at 10,000 Rows](renders/decision_tables.svg)",
        "",
        "### 3. PHREAK Hot Match & Incremental MDM Sync (`10`–`10,000` Facts)",
        "",
        "`phreak_hot_match_zero_alloc` holds flat at **`3.16 us` (`O(1)`, `0` allocs)** across `10`–`10,000` background facts, and `O(delta)` `xitdb` sync+fire executes in **`119.58 us` (`.Fast`) / `352.65 us` (`.Audit_Full`)**:",
        "",
        "![PHREAK Hot Match and Incremental MDM Sync](renders/phreak_and_mdm_scaling.svg)",
        "",
        "### 4. Sleipnir Multi-Threaded Actor Runtime (`1`–`8` Workers)",
        "",
        "`Parallel_Diff_Replay` over `4` candidate rulebases scales from `1.62 ms` (`1w`) down to **`939.51 us` (`4w`)**, and `Session_Actor` `Chain=K` batching drops from `1.11 ms` to **`686.03 us` (`4w`)**:",
        "",
        "![Sleipnir Multi-Threaded Actor Runtime Scaling](renders/sleipnir_actors.svg)",
        "",
        "### 5. Longitudinal Optimization Progression",
        "",
        "Tracked in [`history.hugidb`](history.hugidb) across commits `be8f675` through `434960b` (`~101,000x` speedup on `phreak_hot_match_zero_alloc[10000]` and `111x` on `incremental_sync_fire_audit_full_safe_v2[10000]` since `e9cd4fc`):",
        "",
        "![Longitudinal Optimization Progression](renders/longitudinal_history.svg)",
        "",
        "---",
        "",
        "## Reproducing & Regenerating Renders",
        "",
        "```bash",
        "# 1. Run smoke checks (@zero_alloc verification across non-1M groups)",
        "hugi run --test --groups decision_tables,xitdb_modes,beta_joins,jtms_churn,recursive_strata,mdm_e2e",
        "",
        "# 2. Run the full suite and record into benchmarks/history.hugidb",
        "hugi run --runs 1 --warmup 1",
        "",
        "# 3. Regenerate SVG charts in benchmarks/renders/ and tables below",
        "python3 benchmarks/render_readme.py",
        "",
        "# 4. Run the standalone 10..1,000,000 rule telemetry sweep",
        "XITDB=\"-collection:xitdb=../xitdb/xitdb\"",
        "ACTOR=\"-collection:actor=../sleipnir/actor\"",
        "HUGI=\"-collection:hugi=../hugi/hugi -collection:obench=../hugi/deps/obench/obench\"",
        "odin build benchmarks -out:/tmp/forseti_bench -o:speed -microarch:native $XITDB $ACTOR $HUGI",
        "/tmp/forseti_bench --profile-1m",
        "```",
        "",
        "---",
        "",
        "## Full Benchmark Results (`253` Benchmarks at `" + commit + "`)",
        "",
        "<!-- BEGIN_BENCHMARK_TABLE -->",
    ]

    ordered_groups = [g for g, _, _ in GROUP_META if g in by_group] + [g for g in by_group if g not in {x[0] for x in GROUP_META}]
    meta_map = {g: (title, desc) for g, title, desc in GROUP_META}

    for g in ordered_groups:
        items = by_group[g]
        title, desc = meta_map.get(g, (f"`{g}`", ""))
        lines.append(f"### {title} (`{len(items)}` benchmarks)")
        lines.append("")
        if desc:
            lines.append(desc)
            lines.append("")
        lines.append("| Benchmark | Median (`p50`) | `P95` | Ops/s | `CV%` | Allocs / op |")
        lines.append("| :--- | ---: | ---: | ---: | ---: | ---: |")
        for r in items:
            short = r["full_name"]
            if short.startswith(f"{g}::"):
                short = short[len(g) + 2:]
            med = fmt_ns(r["p50_ns"])
            p95 = fmt_ns(r["p95_ns"])
            ops = fmt_ops(r["ops_per_sec"])
            cv = f"{r['cv_pct']:.1f}%"
            allocs = r["allocs_per_op"]
            ab = r["alloc_bytes_per_op"]
            alloc_str = "**0**" if allocs == 0 and ab == 0 else f"{allocs:.1f} ({fmt_bytes(ab)})"
            lines.append(f"| `{short}` | **{med}** | {p95} | {ops} | {cv} | {alloc_str} |")
        lines.append("")

    lines.append("<!-- END_BENCHMARK_TABLE -->")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Render Forseti benchmark SVGs and benchmarks/README.md.")
    parser.add_argument("--commit", default="", help="Target commit prefix in benchmarks/history.hugidb (default: latest).")
    args = parser.parse_args()

    commit = args.commit or hugi_latest_commit()
    latest_rows = hugi_export(["--commit", commit])
    all_rows = hugi_export(["--all-commits"])
    if not latest_rows:
        print(f"error: no benchmark rows found for commit {commit}", file=sys.stderr)
        return 1

    generate_renders(latest_rows, all_rows, commit)
    README_PATH.write_text(render_markdown(latest_rows, commit), encoding="utf-8")
    print(f"Rendered 5 SVGs in {RENDERS_DIR.relative_to(ROOT)} and {len(latest_rows)} rows into {README_PATH.relative_to(ROOT)} (commit {commit}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

package bench_render

import "core:encoding/json"
import "core:fmt"
import "core:math"
import vmem "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"

DEFAULT_HUGI_BIN :: "/home/pauli/.local/bin/hugi"
DEFAULT_DB_PATH :: "benchmarks/history.hugidb"
RENDERS_DIR :: "benchmarks/renders"
README_PATH :: "benchmarks/README.md"

PALETTE :: [7]string{
	"#58a6ff", // blue
	"#3fb950", // green
	"#f78166", // coral/orange
	"#d2a8ff", // purple
	"#ffa657", // amber
	"#79c0ff", // sky
	"#ff7b72", // red
}

Group_Meta :: struct {
	key:   string,
	title: string,
	desc:  string,
}

GROUP_META :: [14]Group_Meta{
	{"decision_tables", "Decision Tables (`First`, `Unique`, `Priority`, `Collect_Sum`, `Merge`, AOT)", "Cost-ordered lazy decision trees, ternary `u64` bitset matrices, and `\"contextless\"` AOT Odin codegen (all `0` heap allocs)."},
	{"scale_rules", "`10` to `1,000,000` Rule Scaling (Alpha DAG & Lazy Session)", "Immutable `Rulebase` compilation, `O(1)` lazy `session_init`, and sparse matching up to `1,000,000` rules."},
	{"scale_join_rules", "Multi-Rule Join Scaling", "Compiled join networks and sparse `1,000`-fact working-memory matching across `10` to `10,000` join rules."},
	{"beta_joins", "Beta Joins, Queries & `@zero_alloc` Hot Match", "Cold 2/3-way joins, skewed fanouts, parameterized queries, and `@zero_alloc` `.Fast` PHREAK updates."},
	{"mdm_e2e", "End-to-End MDM Pipeline (`xitdb` Sync + Fire + Commit)", "Incremental `O(delta)` `Delta_Syncer` ingestion, PHREAK matching, and atomic `.decisions` + `.__tx` persistence."},
	{"jtms_churn", "Z-Set JTMS Cascades & Retractable Accumulators", "Logical assertion/retraction cascades in `.Audit_Full` vs `.Fast`, plus `O(1)` incremental accumulator updates."},
	{"recursive_strata", "Tarjan SCC Semi-Naive Datalog & Cycle Breaking", "Transitive closure over DAGs and cyclic graphs with incremental cycle-break retraction."},
	{"provenance_and_replay", "Causal Explain, Impact, Semirings, `Core_Overlay` & Async Effects", "Minimal proof-tree `explain`, `impact` blast radius, `Why`/`How`/`Viterbi` semirings, `diff_replay`, and 3-phase async effects."},
	{"sleipnir_actors", "Sleipnir Multi-Threaded Actor Runtime (`1`–`8` Workers)", "`Session_Actor` `Chain=K` batching, `Partitioned_Supervisor` tenant fanout, and `Parallel_Diff_Replay`."},
	{"frontend_and_verify", "Compiler Frontend, Static Table Verifier & AOT Codegen", "Lexing/parsing/sema, 4/8-column static table domain partitioning, and `\"contextless\"` Odin codegen."},
	{"vm_guard_eval", "32-Bit `#must_tail` Bytecode Guard VM", "Arithmetic, string built-in, `decide` call, and fact field evaluation inside the zero-alloc VM."},
	{"xitdb_modes", "`xitdb` v2 Storage Substrate & File Hydration", "Safe SHA-1 HAMT + CRC-64/XZ inserts, prehashed lookups, slot-skipping diffs, and `Core_Buffered_File` commits."},
	{"hasher_raw_verify", "Hardware SHA-NI vs Software SHA-1 Throughput", "Raw `xitdb` SHA-NI accelerated SHA-1/SHA-256 vs Odin `core:crypto` software hashing across `10`–`4096` byte keys."},
	{"hasher_xitdb_verify", "`xitdb` HAMT Lookup & Insert Key-Length Scaling", "End-to-end `Hash_Map` point lookups (hashed vs `Prehashed_Key`) and inserts across `10`–`1024` byte keys."},
}

Hugi_Record :: struct {
	commit:             string,
	lang:               string,
	suite_name:         string,
	group_name:         string,
	name:               string,
	full_name:          string,
	run_id:             string,
	timestamp_unix:     i64,
	rank:               int,
	run_count:          int,
	ops_per_sample:     int,
	samples:            int,
	p50_ns:             f64,
	p95_ns:             f64,
	cv_pct:             f64,
	ops_per_sec:        f64,
	allocs_per_op:      f64,
	alloc_bytes_per_op: f64,
}

Svg_Tick_View :: struct {
	pos:      string,
	text_pos: string,
	label:    string,
}

Svg_Point_View :: struct {
	x: string,
	y: string,
}

Line_Series_View :: struct {
	has_path: bool,
	path_d:   string,
	color:    string,
	points:   []Svg_Point_View,
}

End_Label_View :: struct {
	raw_y: f64,
	y:     string,
	text:  string,
	color: string,
}

Legend_Item_View :: struct {
	x:      string,
	rect_y: string,
	text_x: string,
	text_y: string,
	label:  string,
	color:  string,
}

Line_Chart_View :: struct {
	title:        string,
	subtitle:     string,
	y_unit_label: string,
	width:        int,
	height:       int,
	pad_l:        int,
	pad_t:        int,
	pw:           int,
	ph:           int,
	plot_right:   int,
	plot_bottom:  int,
	y_label_x:    int,
	x_label_y:    int,
	end_label_x:  int,
	y_ticks:      []Svg_Tick_View,
	x_ticks:      []Svg_Tick_View,
	series:       []Line_Series_View,
	end_labels:   []End_Label_View,
	legend:       []Legend_Item_View,
}

Bar_View :: struct {
	label:    string,
	text_y:   string,
	rect_y:   string,
	width:    string,
	val_x:    string,
	val_y:    string,
	val_text: string,
	color:    string,
}

Bar_Chart_View :: struct {
	title:       string,
	subtitle:    string,
	width:       int,
	height:      int,
	pad_l:       int,
	pad_t:       int,
	pw:          int,
	ph:          int,
	plot_bottom: int,
	label_x:     int,
	x_label_y:   int,
	x_ticks:     []Svg_Tick_View,
	bars:        []Bar_View,
}

Report_Row_View :: struct {
	name:   string,
	median: string,
	p95:    string,
	ops:    string,
	cv:     string,
	allocs: string,
}

Report_Group_View :: struct {
	title:    string,
	desc:     string,
	has_desc: bool,
	count:    int,
	rows:     []Report_Row_View,
}

Suite_Report_View :: struct {
	commit:            string,
	total_benchmarks:  int,
	total_samples_str: string,
	group_count:       int,
	groups:            []Report_Group_View,
}

Line_Series_Input :: struct {
	label:  string,
	values: []Maybe(f64),
	color:  string,
}

Bar_Input :: struct {
	label: string,
	value: f64,
	note:  string,
	color: string,
}

line_chart_tmpl := compiled("templates/line_chart.temple.twig", Line_Chart_View)
bar_chart_tmpl := compiled("templates/bar_chart.temple.twig", Bar_Chart_View)
suite_report_tmpl := compiled("templates/suite_report.temple.twig", Suite_Report_View)

@(require_results)
fmt_commas_u64 :: proc(val: u64, allocator := context.allocator) -> string {
	buf: [32]byte
	pos := len(buf)
	v := val
	digits := 0
	if v == 0 {
		pos -= 1
		buf[pos] = '0'
	} else {
		for v > 0 {
			if digits > 0 && digits % 3 == 0 {
				pos -= 1
				buf[pos] = ','
			}
			pos -= 1
			buf[pos] = byte('0' + (v % 10))
			v /= 10
			digits += 1
		}
	}
	return strings.clone(string(buf[pos:]), allocator)
}

@(require_results)
fmt_ns :: proc(ns: f64, allocator := context.allocator) -> string {
	if ns < 1.0 {
		return fmt.aprintf("%.2f ps", ns * 1000.0, allocator = allocator)
	}
	if ns < 1_000.0 {
		return fmt.aprintf("%.2f ns", ns, allocator = allocator)
	}
	if ns < 1_000_000.0 {
		return fmt.aprintf("%.2f us", ns / 1_000.0, allocator = allocator)
	}
	if ns < 1_000_000_000.0 {
		return fmt.aprintf("%.2f ms", ns / 1_000_000.0, allocator = allocator)
	}
	return fmt.aprintf("%.3f s", ns / 1_000_000_000.0, allocator = allocator)
}

@(require_results)
fmt_axis_ns :: proc(ns: f64, allocator := context.allocator) -> string {
	if ns <= 0 {
		return strings.clone("0", allocator)
	}
	raw := fmt_ns(ns, context.temp_allocator)
	if s, ok := strings.replace_all(raw, ".000 ", " ", context.temp_allocator); ok {
		raw = s
	}
	if s, ok := strings.replace_all(raw, ".00 ", " ", context.temp_allocator); ok {
		raw = s
	}
	return strings.clone(raw, allocator)
}

@(require_results)
fmt_bytes :: proc(b: f64, allocator := context.allocator) -> string {
	if b < 1024.0 {
		return fmt.aprintf("%.0f B", b, allocator = allocator)
	}
	if b < 1024.0 * 1024.0 {
		return fmt.aprintf("%.2f KiB", b / 1024.0, allocator = allocator)
	}
	if b < 1024.0 * 1024.0 * 1024.0 {
		return fmt.aprintf("%.2f MiB", b / (1024.0 * 1024.0), allocator = allocator)
	}
	return fmt.aprintf("%.2f GiB", b / (1024.0 * 1024.0 * 1024.0), allocator = allocator)
}

@(require_results)
fmt_ops :: proc(ops: f64, allocator := context.allocator) -> string {
	if ops >= 1_000_000_000.0 {
		return fmt.aprintf("%.2fB/s", ops / 1_000_000_000.0, allocator = allocator)
	}
	if ops >= 1_000_000.0 {
		return fmt.aprintf("%.2fM/s", ops / 1_000_000.0, allocator = allocator)
	}
	if ops >= 1_000.0 {
		return fmt.aprintf("%.1fK/s", ops / 1_000.0, allocator = allocator)
	}
	return fmt.aprintf("%.0f/s", ops, allocator = allocator)
}

@(require_results)
exec_hugi :: proc(args: []string, allocator := context.allocator) -> (stdout: []byte, ok: bool) {
	hugi_bin := DEFAULT_HUGI_BIN if os.exists(DEFAULT_HUGI_BIN) else "hugi"
	cmd := make([dynamic]string, 0, len(args) + 1, context.temp_allocator)
	append(&cmd, hugi_bin)
	for a in args {
		append(&cmd, a)
	}

	state, out, stderr, exec_err := os.process_exec(os.Process_Desc{command = cmd[:]}, allocator)
	if exec_err != nil && hugi_bin != "hugi" {
		delete(out, allocator)
		delete(stderr, allocator)
		cmd[0] = "hugi"
		state, out, stderr, exec_err = os.process_exec(os.Process_Desc{command = cmd[:]}, allocator)
	}
	defer delete(stderr, allocator)

	if exec_err != nil || !state.success {
		err_txt := strings.trim_space(string(stderr))
		delete(out, allocator)
		fmt.eprintfln("bench_render: hugi failed (%v, exit=%d): %s", exec_err, state.exit_code, err_txt)
		return nil, false
	}
	return out, true
}

@(require_results)
latest_commit_from_hugi :: proc(db_path: string, allocator := context.allocator) -> (commit: string, ok: bool) {
	out, exec_ok := exec_hugi({"history", "--db", db_path, "--limit", "1"}, context.temp_allocator)
	if !exec_ok {
		return "", false
	}
	lines := strings.split_lines(string(out), context.temp_allocator)
	for line in lines {
		t := strings.trim_space(line)
		if len(t) == 0 || strings.has_prefix(t, "Commit") || strings.has_prefix(t, "-") {
			continue
		}
		if pipe_idx := strings.index_byte(t, '|'); pipe_idx > 0 {
			return strings.clone(strings.trim_space(t[:pipe_idx]), allocator), true
		}
	}
	return "", false
}

@(require_results)
build_line_chart_view :: proc(
	title: string,
	subtitle: string,
	x_labels: []string,
	inputs: []Line_Series_Input,
	y_log: bool,
	y_unit_label: string,
	allocator := context.allocator,
) -> (view: Line_Chart_View, ok: bool) {
	width := 880
	height := 440
	pad_l := 82
	pad_r := 96
	pad_t := 74
	pad_b := 96
	pw := width - pad_l - pad_r
	ph := height - pad_t - pad_b

	min_val := max(f64)
	max_val := 0.0
	any_val := false
	for inp in inputs {
		for mv in inp.values {
			if v, has := mv.?; has && v > 0 {
				min_val = min(min_val, v)
				max_val = max(max_val, v)
				any_val = true
			}
		}
	}
	if !any_val {
		return {}, false
	}

	y_ticks_vals := make([dynamic]f64, 0, 12, context.temp_allocator)
	y_min_exp := 0.0
	y_max_exp := 1.0
	y_max_lin := 1.0

	if y_log {
		lo := int(math.floor(math.log10(min_val)))
		hi := int(math.ceil(math.log10(max_val)))
		if lo == hi {
			hi += 1
		}
		y_min_exp = f64(lo)
		y_max_exp = f64(hi)
		for e := lo; e <= hi; e += 1 {
			append(&y_ticks_vals, math.pow10(f64(e)))
		}
	} else {
		top := max_val * 1.12
		step := math.pow10(math.floor(math.log10(top))) / 2.0
		if top / step > 7.0 {
			step *= 2.0
		}
		if top / step < 3.0 {
			step /= 2.0
		}
		n_ticks := max(2, int(math.ceil(top / step)))
		y_max_lin = f64(n_ticks) * step
		for i := 0; i <= n_ticks; i += 1 {
			append(&y_ticks_vals, f64(i) * step)
		}
	}

	y_px :: proc(v: f64, y_log: bool, pad_t, ph: int, y_min_exp, y_max_exp, y_max_lin: f64) -> f64 {
		t := 0.0
		if y_log {
			t = (math.log10(v) - y_min_exp) / (y_max_exp - y_min_exp)
		} else {
			t = v / y_max_lin
		}
		return f64(pad_t) + f64(ph) - t * f64(ph)
	}

	x_px :: proc(i, n_x, pad_l, pw: int) -> f64 {
		if n_x <= 1 {
			return f64(pad_l) + f64(pw) * 0.5
		}
		return f64(pad_l) + (f64(i) / f64(n_x - 1)) * f64(pw)
	}

	y_ticks := make([]Svg_Tick_View, len(y_ticks_vals), allocator)
	for yt, yi in y_ticks_vals {
		yp := y_px(yt, y_log, pad_t, ph, y_min_exp, y_max_exp, y_max_lin) if (yt > 0 || !y_log) else f64(pad_t + ph)
		y_ticks[yi] = Svg_Tick_View{
			pos      = fmt.aprintf("%.1f", yp, allocator = allocator),
			text_pos = fmt.aprintf("%.1f", yp + 4.0, allocator = allocator),
			label    = fmt_axis_ns(yt, allocator),
		}
	}

	n_x := len(x_labels)
	x_ticks := make([]Svg_Tick_View, n_x, allocator)
	for xl, xi in x_labels {
		xp := x_px(xi, n_x, pad_l, pw)
		x_ticks[xi] = Svg_Tick_View{
			pos   = fmt.aprintf("%.1f", xp, allocator = allocator),
			label = strings.clone(xl, allocator),
		}
	}

	series := make([]Line_Series_View, len(inputs), allocator)
	end_labels_dyn := make([dynamic]End_Label_View, 0, len(inputs), allocator)

	for inp, si in inputs {
		pts := make([dynamic]Svg_Point_View, 0, len(inp.values), allocator)
		path_b: strings.Builder
		strings.builder_init(&path_b, context.temp_allocator)
		last_yp := 0.0
		last_val := 0.0
		has_last := false

		for mv, xi in inp.values {
			if v, has := mv.?; has && (v > 0 || !y_log) {
				xp := x_px(xi, n_x, pad_l, pw)
				yp := y_px(v, y_log, pad_t, ph, y_min_exp, y_max_exp, y_max_lin)
				fmt.sbprintf(&path_b, "%s %.1f %.1f", "M" if len(pts) == 0 else " L", xp, yp)
				append(&pts, Svg_Point_View{
					x = fmt.aprintf("%.1f", xp, allocator = allocator),
					y = fmt.aprintf("%.1f", yp, allocator = allocator),
				})
				last_yp = yp
				last_val = v
				has_last = true
			}
		}

		series[si] = Line_Series_View{
			has_path = len(pts) >= 2,
			path_d   = strings.clone(strings.trim_space(strings.to_string(path_b)), allocator),
			color    = strings.clone(inp.color, allocator),
			points   = pts[:],
		}
		if has_last {
			append(&end_labels_dyn, End_Label_View{
				raw_y = last_yp,
				text  = fmt_ns(last_val, allocator),
				color = strings.clone(inp.color, allocator),
			})
		}
	}

	slice.sort_by(end_labels_dyn[:], proc(a, b: End_Label_View) -> bool {
		return a.raw_y < b.raw_y
	})
	placed := make([]f64, len(end_labels_dyn), context.temp_allocator)
	for el, i in end_labels_dyn {
		y := max(f64(pad_t) + 10.0, min(f64(pad_t + ph) - 4.0, el.raw_y + 4.0))
		if i > 0 && y < placed[i - 1] + 14.0 {
			y = placed[i - 1] + 14.0
		}
		placed[i] = y
	}
	if len(placed) > 0 && placed[len(placed) - 1] > f64(pad_t + ph) + 4.0 {
		shift := placed[len(placed) - 1] - (f64(pad_t + ph) + 4.0)
		placed[len(placed) - 1] -= shift
		for i := len(placed) - 2; i >= 0; i -= 1 {
			if placed[i] > placed[i + 1] - 14.0 {
				placed[i] = placed[i + 1] - 14.0
			}
		}
	}
	for &el, i in end_labels_dyn {
		el.y = fmt.aprintf("%.1f", placed[i], allocator = allocator)
	}

	cols := 3
	col_w := f64(pw) / f64(cols)
	legend := make([]Legend_Item_View, len(inputs), allocator)
	for inp, idx in inputs {
		row := idx / cols
		col := idx % cols
		lx := f64(pad_l) + f64(col) * col_w
		ly := f64(pad_t + ph) + 44.0 + f64(row) * 20.0
		legend[idx] = Legend_Item_View{
			x      = fmt.aprintf("%.1f", lx, allocator = allocator),
			rect_y = fmt.aprintf("%.1f", ly - 9.0, allocator = allocator),
			text_x = fmt.aprintf("%.1f", lx + 18.0, allocator = allocator),
			text_y = fmt.aprintf("%.1f", ly - 3.0, allocator = allocator),
			label  = strings.clone(inp.label, allocator),
			color  = strings.clone(inp.color, allocator),
		}
	}

	return Line_Chart_View{
		title        = strings.clone(title, allocator),
		subtitle     = strings.clone(subtitle, allocator),
		y_unit_label = strings.clone(y_unit_label, allocator),
		width        = width,
		height       = height,
		pad_l        = pad_l,
		pad_t        = pad_t,
		pw           = pw,
		ph           = ph,
		plot_right   = pad_l + pw,
		plot_bottom  = pad_t + ph,
		y_label_x    = pad_l - 8,
		x_label_y    = pad_t + ph + 18,
		end_label_x  = pad_l + pw + 8,
		y_ticks      = y_ticks,
		x_ticks      = x_ticks,
		series       = series,
		end_labels   = end_labels_dyn[:],
		legend       = legend,
	}, true
}

@(require_results)
build_bar_chart_view :: proc(
	title: string,
	subtitle: string,
	inputs: []Bar_Input,
	allocator := context.allocator,
) -> (view: Bar_Chart_View, ok: bool) {
	if len(inputs) == 0 {
		return {}, false
	}
	width := 900
	pad_l := 260
	pad_r := 175
	pad_t := 68
	pad_b := 42
	row_h := 34
	ph := len(inputs) * row_h + 12
	height := pad_t + ph + pad_b
	pw := width - pad_l - pad_r

	min_v := max(f64)
	max_v := 0.0
	for b in inputs {
		if b.value > 0 {
			min_v = min(min_v, b.value)
			max_v = max(max_v, b.value)
		}
	}
	if max_v <= 0 {
		return {}, false
	}

	lo := int(math.floor(math.log10(min_v)))
	hi := int(math.ceil(math.log10(max_v)))
	if lo == hi {
		hi += 1
	}

	x_ticks := make([]Svg_Tick_View, hi - lo + 1, allocator)
	for e := lo; e <= hi; e += 1 {
		t := f64(e - lo) / f64(hi - lo)
		xp := f64(pad_l) + t * f64(pw)
		x_ticks[e - lo] = Svg_Tick_View{
			pos   = fmt.aprintf("%.1f", xp, allocator = allocator),
			label = fmt_axis_ns(math.pow10(f64(e)), allocator),
		}
	}

	bars := make([]Bar_View, len(inputs), allocator)
	for b, idx in inputs {
		ry := pad_t + 10 + idx * row_h
		t := (math.log10(b.value) - f64(lo)) / f64(hi - lo)
		w_bar := max(4.0, t * f64(pw))
		dur := fmt_ns(b.value, context.temp_allocator)
		bars[idx] = Bar_View{
			label    = strings.clone(b.label, allocator),
			text_y   = fmt.aprintf("%.1f", f64(ry) + 16.0, allocator = allocator),
			rect_y   = fmt.aprintf("%.1f", f64(ry) + 3.0, allocator = allocator),
			width    = fmt.aprintf("%.1f", w_bar, allocator = allocator),
			val_x    = fmt.aprintf("%.1f", f64(pad_l) + w_bar + 8.0, allocator = allocator),
			val_y    = fmt.aprintf("%.1f", f64(ry) + 17.0, allocator = allocator),
			val_text = fmt.aprintf("%s (%s)", dur, b.note, allocator = allocator),
			color    = strings.clone(b.color, allocator),
		}
	}

	return Bar_Chart_View{
		title       = strings.clone(title, allocator),
		subtitle    = strings.clone(subtitle, allocator),
		width       = width,
		height      = height,
		pad_l       = pad_l,
		pad_t       = pad_t,
		pw          = pw,
		ph          = ph,
		plot_bottom = pad_t + ph,
		label_x     = pad_l - 10,
		x_label_y   = pad_t + ph + 18,
		x_ticks     = x_ticks,
		bars        = bars,
	}, true
}

@(require_results)
render_line_svg :: proc(view: Line_Chart_View, out_path: string, allocator := context.allocator) -> bool {
	sb := strings.builder_make(0, line_chart_tmpl.approx_bytes, allocator)
	defer strings.builder_destroy(&sb)
	if _, err := line_chart_tmpl.with(strings.to_writer(&sb), view); err != nil {
		return false
	}
	return os.write_entire_file(out_path, transmute([]byte)strings.to_string(sb)) == nil
}

@(require_results)
render_bar_svg :: proc(view: Bar_Chart_View, out_path: string, allocator := context.allocator) -> bool {
	sb := strings.builder_make(0, bar_chart_tmpl.approx_bytes, allocator)
	defer strings.builder_destroy(&sb)
	if _, err := bar_chart_tmpl.with(strings.to_writer(&sb), view); err != nil {
		return false
	}
	return os.write_entire_file(out_path, transmute([]byte)strings.to_string(sb)) == nil
}

@(require_results)
lookup_p50 :: proc(m: map[string]Hugi_Record, full_name: string) -> Maybe(f64) {
	if rec, ok := m[full_name]; ok {
		return rec.p50_ns
	}
	return nil
}

@(require_results)
build_suite_report_view :: proc(records: []Hugi_Record, commit: string, allocator := context.allocator) -> Suite_Report_View {
	grouped := make(map[string][dynamic]Hugi_Record, context.temp_allocator)
	extra_groups := make([dynamic]string, context.temp_allocator)
	total_samples := u64(0)

	for rec in records {
		total_samples += u64(max(rec.samples, 0))
		g := rec.group_name if len(rec.group_name) > 0 else "default"
		if g not_in grouped {
			grouped[g] = make([dynamic]Hugi_Record, context.temp_allocator)
			known := false
			for gm in GROUP_META {
				if gm.key == g {
					known = true
					break
				}
			}
			if !known {
				append(&extra_groups, g)
			}
		}
		append(&grouped[g], rec)
	}

	ordered := make([dynamic]string, 0, len(grouped), context.temp_allocator)
	for gm in GROUP_META {
		if gm.key in grouped {
			append(&ordered, gm.key)
		}
	}
	for eg in extra_groups {
		append(&ordered, eg)
	}

	groups := make([]Report_Group_View, len(ordered), allocator)
	for gkey, gi in ordered {
		recs := grouped[gkey][:]
		title := gkey
		desc := ""
		for gm in GROUP_META {
			if gm.key == gkey {
				title = gm.title
				desc = gm.desc
				break
			}
		}

		rows := make([]Report_Row_View, len(recs), allocator)
		for rec, ri in recs {
			short := rec.full_name
			prefix := fmt.tprintf("%s::", gkey)
			if strings.has_prefix(short, prefix) {
				short = short[len(prefix):]
			}
			alloc_str := "**0**"
			if rec.allocs_per_op > 0 || rec.alloc_bytes_per_op > 0 {
				b_txt := fmt_bytes(rec.alloc_bytes_per_op, context.temp_allocator)
				alloc_str = fmt.aprintf("%.1f (%s)", rec.allocs_per_op, b_txt, allocator = allocator)
			} else {
				alloc_str = strings.clone("**0**", allocator)
			}
			rows[ri] = Report_Row_View{
				name   = strings.clone(short, allocator),
				median = fmt_ns(rec.p50_ns, allocator),
				p95    = fmt_ns(rec.p95_ns, allocator),
				ops    = fmt_ops(rec.ops_per_sec, allocator),
				cv     = fmt.aprintf("%.1f%%", rec.cv_pct, allocator = allocator),
				allocs = alloc_str,
			}
		}

		groups[gi] = Report_Group_View{
			title    = strings.clone(title, allocator),
			desc     = strings.clone(desc, allocator),
			has_desc = len(desc) > 0,
			count    = len(recs),
			rows     = rows,
		}
	}

	return Suite_Report_View{
		commit            = strings.clone(commit, allocator),
		total_benchmarks  = len(records),
		total_samples_str = fmt_commas_u64(total_samples, allocator),
		group_count       = len(groups),
		groups            = groups,
	}
}

@(require_results)
render_all :: proc(db_path: string, commit_arg: string, allocator := context.allocator) -> bool {
	if !os.exists(db_path) {
		fmt.eprintfln("bench_render: missing %q", db_path)
		return false
	}

	arena: vmem.Arena
	if vmem.arena_init_growing(&arena) != nil {
		return false
	}
	defer vmem.arena_destroy(&arena)
	arena_alloc := vmem.arena_allocator(&arena)

	commit := commit_arg
	if len(commit) == 0 {
		c, c_ok := latest_commit_from_hugi(db_path, arena_alloc)
		if !c_ok {
			fmt.eprintln("bench_render: could not determine latest commit from hugi history")
			return false
		}
		commit = c
	}

	latest_json, l_ok := exec_hugi({"export", "--db", db_path, "--commit", commit, "--format", "json", "--out", "-"}, arena_alloc)
	if !l_ok {
		return false
	}
	latest_rows: []Hugi_Record
	if json.unmarshal(latest_json, &latest_rows, allocator = arena_alloc) != nil || len(latest_rows) == 0 {
		fmt.eprintln("bench_render: failed to parse latest hugi JSON export")
		return false
	}

	all_json, a_ok := exec_hugi({"export", "--db", db_path, "--all-commits", "--format", "json", "--out", "-"}, arena_alloc)
	if !a_ok {
		return false
	}
	all_rows: []Hugi_Record
	if json.unmarshal(all_json, &all_rows, allocator = arena_alloc) != nil {
		fmt.eprintln("bench_render: failed to parse all-commits hugi JSON export")
		return false
	}

	if !os.exists(RENDERS_DIR) {
		if os.make_directory(RENDERS_DIR) != nil {
			fmt.eprintfln("bench_render: unable to create %q", RENDERS_DIR)
			return false
		}
	}

	by_full := make(map[string]Hugi_Record, len(latest_rows), arena_alloc)
	for rec in latest_rows {
		by_full[rec.full_name] = rec
	}

	by_commit := make(map[string]map[string]Hugi_Record, 16, arena_alloc)
	for rec in all_rows {
		if rec.commit not_in by_commit {
			by_commit[rec.commit] = make(map[string]Hugi_Record, 64, arena_alloc)
		}
		cm := &by_commit[rec.commit]
		cm[rec.full_name] = rec
	}

	// 1. 1M Rule Scaling SVG
	scales_1m := [6]string{"10", "100", "1000", "10000", "100000", "1000000"}
	x_1m := [6]string{"10", "100", "1k", "10k", "100k", "1M"}
	s1 := make([]Maybe(f64), 6, arena_alloc)
	s2 := make([]Maybe(f64), 6, arena_alloc)
	s3 := make([]Maybe(f64), 6, arena_alloc)
	s4 := make([]Maybe(f64), 6, arena_alloc)
	s5 := make([]Maybe(f64), 6, arena_alloc)
	for sc, i in scales_1m {
		s1[i] = lookup_p50(by_full, fmt.tprintf("scale_rules::sparse_alpha_match[%s]", sc))
		s2[i] = lookup_p50(by_full, fmt.tprintf("scale_rules::audit_full_sparse_match[%s]", sc))
		s3[i] = lookup_p50(by_full, fmt.tprintf("scale_rules::lazy_session_init[%s]", sc))
		s4[i] = lookup_p50(by_full, fmt.tprintf("scale_rules::batch_100_alpha_match[%s]", sc))
		s5[i] = lookup_p50(by_full, fmt.tprintf("scale_rules::compile_rules[%s]", sc))
	}
	v_1m, v1_ok := build_line_chart_view(
		"10 to 1,000,000 Rule Scaling (scale_rules)",
		fmt.tprintf("Commit %s · Ryzen 7 7735U · -o:speed -microarch:native", commit),
		x_1m[:],
		{
			{"sparse_alpha_match (.Fast)", s1, PALETTE[1]},
			{"audit_full_sparse_match (.Audit_Full)", s2, PALETTE[0]},
			{"lazy_session_init (O(1))", s3, PALETTE[3]},
			{"batch_100_alpha_match", s4, PALETTE[4]},
			{"compile_rules (Rulebase)", s5, PALETTE[2]},
		},
		y_log = true,
		y_unit_label = "Log10 latency (p50)",
		allocator = arena_alloc,
	)
	if !v1_ok || !render_line_svg(v_1m, fmt.tprintf("%s/1m_rule_scaling.svg", RENDERS_DIR), allocator) {
		return false
	}

	// 2. Decision Tables at 10,000 Rows SVG
	tbl_defs := [7]struct{ full, lbl, color: string }{
		{"decision_tables::aot_native_fast_path[10000]", "Tier 3 AOT (proc \"contextless\")", PALETTE[1]},
		{"decision_tables::wide_string_range_table[10000]", "wide_string_range_table (10k)", PALETTE[5]},
		{"decision_tables::priority_table_hit[10000]", "priority_table_hit (10k)", PALETTE[0]},
		{"decision_tables::cost_tree_single_hit[10000]", "cost_tree_single_hit (10k)", PALETTE[3]},
		{"decision_tables::lazy_cost_skip[10000]", "lazy_cost_skip (10k)", PALETTE[4]},
		{"decision_tables::reverse_merge_table_outputs[10000]", "reverse_merge_table (10k)", PALETTE[2]},
		{"decision_tables::bitset_collect_sum[10000]", "bitset_collect_sum (10k)", PALETTE[6]},
	}
	bar_inputs := make([dynamic]Bar_Input, 0, 7, arena_alloc)
	for td in tbl_defs {
		if v, has := lookup_p50(by_full, td.full).?; has {
			append(&bar_inputs, Bar_Input{label = td.lbl, value = v, note = "0 allocs", color = td.color})
		}
	}
	v_tbl, vt_ok := build_bar_chart_view(
		"Decision Tables at 10,000 Rows (Zero Heap Allocations)",
		fmt.tprintf("Commit %s · Lazy cost trees, ternary u64 bitsets & Tier 3 AOT", commit),
		bar_inputs[:],
		arena_alloc,
	)
	if !vt_ok || !render_bar_svg(v_tbl, fmt.tprintf("%s/decision_tables.svg", RENDERS_DIR), allocator) {
		return false
	}

	// 3. PHREAK & MDM Working-Memory Scaling SVG
	scales_10k := [4]string{"10", "100", "1000", "10000"}
	x_10k := [4]string{"10", "100", "1,000", "10,000"}
	m1 := make([]Maybe(f64), 4, arena_alloc)
	m2 := make([]Maybe(f64), 4, arena_alloc)
	m3 := make([]Maybe(f64), 4, arena_alloc)
	m4 := make([]Maybe(f64), 4, arena_alloc)
	m5 := make([]Maybe(f64), 4, arena_alloc)
	for sc, i in scales_10k {
		m1[i] = lookup_p50(by_full, fmt.tprintf("beta_joins::phreak_hot_match_zero_alloc[%s]", sc))
		m2[i] = lookup_p50(by_full, fmt.tprintf("beta_joins::incremental_join_audit_full[%s]", sc))
		m3[i] = lookup_p50(by_full, fmt.tprintf("mdm_e2e::incremental_sync_fire_fast_safe_v2[%s]", sc))
		m4[i] = lookup_p50(by_full, fmt.tprintf("mdm_e2e::incremental_sync_fire_audit_full_safe_v2[%s]", sc))
		m5[i] = lookup_p50(by_full, fmt.tprintf("beta_joins::two_way_mdm_join[%s]", sc))
	}
	v_mdm, vm_ok := build_line_chart_view(
		"PHREAK Hot Match & Incremental MDM Sync Scaling (10–10,000 Facts)",
		fmt.tprintf("Commit %s · O(delta) incremental updates vs cold 2-way join", commit),
		x_10k[:],
		{
			{"phreak_hot_match_zero_alloc (.Fast)", m1, PALETTE[1]},
			{"incremental_join_audit_full", m2, PALETTE[5]},
			{"incremental_sync_fire_fast_safe_v2", m3, PALETTE[0]},
			{"incremental_sync_fire_audit_full_safe_v2", m4, PALETTE[3]},
			{"two_way_mdm_join (cold build)", m5, PALETTE[2]},
		},
		y_log = true,
		y_unit_label = "Log10 latency (p50)",
		allocator = arena_alloc,
	)
	if !vm_ok || !render_line_svg(v_mdm, fmt.tprintf("%s/phreak_and_mdm_scaling.svg", RENDERS_DIR), allocator) {
		return false
	}

	// 4. Sleipnir Multi-Threaded Actor Scaling SVG
	workers := [4]string{"1", "2", "4", "8"}
	x_w := [4]string{"1 worker", "2 workers", "4 workers", "8 workers"}
	a1 := make([]Maybe(f64), 4, arena_alloc)
	a2 := make([]Maybe(f64), 4, arena_alloc)
	a3 := make([]Maybe(f64), 4, arena_alloc)
	for w, i in workers {
		a1[i] = lookup_p50(by_full, fmt.tprintf("sleipnir_actors::parallel_diff_replay_4_cands[%s]", w))
		a2[i] = lookup_p50(by_full, fmt.tprintf("sleipnir_actors::session_actor_chain_k_batch[%s]", w))
		a3[i] = lookup_p50(by_full, fmt.tprintf("sleipnir_actors::tenant_runtime_fanout[%s]", w))
	}
	v_act, va_ok := build_line_chart_view(
		"Sleipnir Multi-Threaded Actor Runtime Scaling (1–8 Workers)",
		fmt.tprintf("Commit %s · Session_Actor Chain=K, Partitioned Tenants & Parallel Core_Overlay", commit),
		x_w[:],
		{
			{"parallel_diff_replay_4_cands", a1, PALETTE[0]},
			{"session_actor_chain_k_batch", a2, PALETTE[1]},
			{"tenant_runtime_fanout", a3, PALETTE[4]},
		},
		y_log = false,
		y_unit_label = "Linear latency (p50, lower is better)",
		allocator = arena_alloc,
	)
	if !va_ok || !render_line_svg(v_act, fmt.tprintf("%s/sleipnir_actors.svg", RENDERS_DIR), allocator) {
		return false
	}

	// 5. Longitudinal Progression SVG
	commits_full := [6]string{"be8f675", "e9cd4fc0fe6f", "4887f749eb7e", "05b9229bba93", "7444ff06ce0f", "434960b28fd0"}
	c_labels := [6]string{"be8f675", "e9cd4fc", "4887f74", "05b9229", "7444ff0", "434960b"}
	l1 := make([]Maybe(f64), 6, arena_alloc)
	l2 := make([]Maybe(f64), 6, arena_alloc)
	l3 := make([]Maybe(f64), 6, arena_alloc)
	l4 := make([]Maybe(f64), 6, arena_alloc)
	l5 := make([]Maybe(f64), 6, arena_alloc)
	for cm_sha, i in commits_full {
		if cm_map, ok_c := by_commit[cm_sha]; ok_c {
			l1[i] = lookup_p50(cm_map, "beta_joins::phreak_hot_match_zero_alloc[10000]")
			l2[i] = lookup_p50(cm_map, "scale_rules::sparse_alpha_match[1000000]")
			if cm_sha != "be8f675" {
				l3[i] = lookup_p50(cm_map, "mdm_e2e::incremental_sync_fire_audit_full_safe_v2[10000]")
			}
			l4[i] = lookup_p50(cm_map, "provenance_and_replay::overlay_diff_replay[5000]")
			l5[i] = lookup_p50(cm_map, "scale_rules::compile_rules[1000000]")
		}
	}
	v_long, vl_ok := build_line_chart_view(
		"Longitudinal Optimization Progression Across Commits",
		"Tracked in benchmarks/history.hugidb (up to 101,000x speedup on hot PHREAK match)",
		c_labels[:],
		{
			{"phreak_hot_match_zero_alloc[10000]", l1, PALETTE[1]},
			{"sparse_alpha_match[1000000]", l2, PALETTE[0]},
			{"incremental_sync_fire_audit_full[10000]", l3, PALETTE[3]},
			{"overlay_diff_replay[5000]", l4, PALETTE[4]},
			{"compile_rules[1000000]", l5, PALETTE[2]},
		},
		y_log = true,
		y_unit_label = "Log10 latency (p50)",
		allocator = arena_alloc,
	)
	if !vl_ok || !render_line_svg(v_long, fmt.tprintf("%s/longitudinal_history.svg", RENDERS_DIR), allocator) {
		return false
	}

	// 6. Render benchmarks/README.md via AOT temple template
	rep_view := build_suite_report_view(latest_rows, commit, arena_alloc)
	sb := strings.builder_make(0, suite_report_tmpl.approx_bytes, allocator)
	defer strings.builder_destroy(&sb)
	if _, werr := suite_report_tmpl.with(strings.to_writer(&sb), rep_view); werr != nil {
		fmt.eprintfln("bench_render: failed rendering suite_report.temple.twig: %v", werr)
		return false
	}
	if os.write_entire_file(README_PATH, transmute([]byte)strings.to_string(sb)) != nil {
		fmt.eprintfln("bench_render: failed writing %q", README_PATH)
		return false
	}

	fmt.printfln(
		"bench_render: rendered 5 SVGs in %s/ and %d rows (%d groups, commit %s) into %s",
		RENDERS_DIR,
		rep_view.total_benchmarks,
		rep_view.group_count,
		rep_view.commit,
		README_PATH,
	)
	free_all(context.temp_allocator)
	return true
}

main :: proc() {
	commit := ""
	args := os.args[1:] if len(os.args) > 1 else nil
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--commit" && i + 1 < len(args) {
			commit = args[i + 1]
			i += 1
		}
	}
	if !render_all(DEFAULT_DB_PATH, commit, context.allocator) {
		os.exit(1)
	}
}

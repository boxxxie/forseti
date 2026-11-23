package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import xitdb "xitdb:."
import "../../forseti"

Cli_Format :: enum u8 {
	Human,
	Json,
	Jsonl,
	Chrome_Trace,
}

Graph_Kind :: enum u8 {
	Rulebase,
	Derivations,
}

Cli_Options :: struct {
	subcmd:             string,
	file_path:          string,
	format:             Cli_Format,
	warnings_as_errors: bool,
	telemetry_path:     string,
	out_path:           string,
	pkg_name:           string,
	facts_path:         string,
	store_path:         string,
	candidate_path:     string,
	rule_name:          string,
	rule_version:       string,
	binding_name:       string,
	fact_key:           string,
	fact_id:            forseti.Fact_Id,
	has_fact_id:        bool,
	prov_mode:          forseti.Provenance_Mode,
	graph_kind:         Graph_Kind,
	fmt_write:          bool,
	fmt_check:          bool,
	extra_files:        [dynamic]string,
}

Loaded_Fact_Spec :: struct {
	binding: string,
	key:     string,
	fields:  json.Object,
}

Loaded_Facts_Bundle :: struct {
	has_root: bool,
	root:     json.Value,
	items:    []Loaded_Fact_Spec,
}

Seed_Store_Ctx :: struct {
	rbs:    []^forseti.Rulebase,
	bundle: ^Loaded_Facts_Bundle,
}

Cli_Exec_Context :: struct {
	sess:             ^forseti.Session,
	bridge:           forseti.Store_Bridge,
	has_bridge:       bool,
	fork:             forseti.Fork_Handle,
	fired_count:      u64,
	committed_moment: i64,
}

cli_exec_destroy :: proc(exec: ^Cli_Exec_Context) {
	if exec == nil {
		return
	}
	if exec.sess != nil {
		forseti.session_destroy(exec.sess)
		free(exec.sess)
		exec.sess = nil
	}
	if exec.fork.active {
		forseti.fork_destroy(&exec.fork)
	}
	if exec.has_bridge {
		forseti.store_bridge_destroy(&exec.bridge)
		exec.has_bridge = false
	}
}

print_usage :: proc() {
	fmt.println(`Usage: forseti <command> [options] <file.forseti>

Commands:
  check           Validate syntax, types, variable bindings, and lints
  verify-tables   Run domain-partitioning static verification across all tables
  fmt             Format .forseti policy files and align decision-table columns
  gen             Generate standalone "contextless" Odin procedures for tables
  ast             Parse source and print deterministic S-expression AST
  ir              Compile source and print canonical Rulebase_IR summary
  run             Execute policy against --facts and/or --store and print derivations
  explain         Print causal explanation proof tree(s) for derived facts
  impact          Analyze direct & transitive impact of --rule <name>
  diff-replay     Counterfactual replay comparing baseline <file> vs --candidate <file>
  telemetry       Print or export phase timings, counters, and peak watermarks
  export-dot      Export compiled rulebase or derivation DAG as Graphviz DOT
  export-mermaid  Export compiled rulebase or derivation DAG as Mermaid flowchart

Options:
  --format=human|json|jsonl|chrome-trace  Output format (command-dependent)
  --warnings-as-errors     Treat compiler warnings (W*) as non-zero exit failures
  --write, -w              Overwrite input file(s) in-place for 'fmt'
  --check                  Exit 1 if any file is not canonically formatted ('fmt')
  --out <file>             Write command output to <file> instead of stdout
  --package <name>         Package name for 'gen' (default: generated_tables)
  --facts <facts.json>     JSON facts input ({"facts":[...]} or [...])
  --store <db.xit>         Attach/open xitdb v2 file store
  --candidate <file>       Candidate .forseti policy for 'diff-replay'
  --rule <name>            Target rule name for 'impact'
  --version <ver>          Optional rule version filter for 'impact'
  --binding <name>         Filter binding name for 'explain' / '--graph=derivations'
  --key <key>              Filter fact key for 'explain' / '--graph=derivations'
  --fact-id <id>           Target numeric Fact_Id for 'explain' / '--graph=derivations'
  --mode=audit|support|fast  Provenance mode for 'run'/'telemetry' (default: audit)
  --graph=rulebase|derivations  Graph kind for 'export-dot' / 'export-mermaid'
  --derivations            Shorthand for --graph=derivations
  --telemetry <out.json>   Export telemetry (Chrome Trace JSON, or JSONL for .jsonl)
  -h, --help               Show this help message`)
}

parse_cli_value_arg :: proc(args: []string, idx: ^int, flag: string) -> (val: string, ok: bool) {
	if idx^ + 1 >= len(args) {
		fmt.eprintfln("error: %s requires an argument", flag)
		return "", false
	}
	idx^ += 1
	return args[idx^], true
}

parse_cli_format :: proc(raw: string) -> (fmt_kind: Cli_Format, ok: bool) {
	switch raw {
	case "human":        return .Human, true
	case "json":         return .Json, true
	case "jsonl":        return .Jsonl, true
	case "chrome-trace": return .Chrome_Trace, true
	}
	fmt.eprintfln("error: unknown format %q (expected human, json, jsonl, or chrome-trace)", raw)
	return .Human, false
}

parse_cli_args :: proc(args: []string) -> (opts: Cli_Options, show_help: bool, ok: bool) {
	defer if !ok || show_help {
		delete(opts.extra_files)
	}
	if len(args) < 2 {
		return {}, true, true
	}
	first := args[1]
	if first == "-h" || first == "--help" || first == "help" {
		return {}, true, true
	}
	opts.subcmd = first

	i := 2
	for i < len(args) {
		arg := args[i]
		if arg == "-h" || arg == "--help" {
			return {}, true, true
		} else if arg == "--warnings-as-errors" {
			opts.warnings_as_errors = true
		} else if arg == "--write" || arg == "-w" {
			opts.fmt_write = true
		} else if arg == "--check" {
			opts.fmt_check = true
		} else if arg == "--derivations" {
			opts.graph_kind = .Derivations
		} else if strings.has_prefix(arg, "--format=") {
			opts.format = parse_cli_format(arg[len("--format="):]) or_return
		} else if arg == "--format" {
			val := parse_cli_value_arg(args, &i, "--format") or_return
			opts.format = parse_cli_format(val) or_return
		} else if arg == "--telemetry" {
			opts.telemetry_path = parse_cli_value_arg(args, &i, "--telemetry") or_return
		} else if strings.has_prefix(arg, "--telemetry=") {
			opts.telemetry_path = arg[len("--telemetry="):]
		} else if arg == "--out" {
			opts.out_path = parse_cli_value_arg(args, &i, "--out") or_return
		} else if strings.has_prefix(arg, "--out=") {
			opts.out_path = arg[len("--out="):]
		} else if arg == "--package" {
			opts.pkg_name = parse_cli_value_arg(args, &i, "--package") or_return
		} else if strings.has_prefix(arg, "--package=") {
			opts.pkg_name = arg[len("--package="):]
		} else if arg == "--facts" {
			opts.facts_path = parse_cli_value_arg(args, &i, "--facts") or_return
		} else if strings.has_prefix(arg, "--facts=") {
			opts.facts_path = arg[len("--facts="):]
		} else if arg == "--store" {
			opts.store_path = parse_cli_value_arg(args, &i, "--store") or_return
		} else if strings.has_prefix(arg, "--store=") {
			opts.store_path = arg[len("--store="):]
		} else if arg == "--candidate" {
			opts.candidate_path = parse_cli_value_arg(args, &i, "--candidate") or_return
		} else if strings.has_prefix(arg, "--candidate=") {
			opts.candidate_path = arg[len("--candidate="):]
		} else if arg == "--rule" {
			opts.rule_name = parse_cli_value_arg(args, &i, "--rule") or_return
		} else if strings.has_prefix(arg, "--rule=") {
			opts.rule_name = arg[len("--rule="):]
		} else if arg == "--version" {
			opts.rule_version = parse_cli_value_arg(args, &i, "--version") or_return
		} else if strings.has_prefix(arg, "--version=") {
			opts.rule_version = arg[len("--version="):]
		} else if arg == "--binding" {
			opts.binding_name = parse_cli_value_arg(args, &i, "--binding") or_return
		} else if strings.has_prefix(arg, "--binding=") {
			opts.binding_name = arg[len("--binding="):]
		} else if arg == "--key" {
			opts.fact_key = parse_cli_value_arg(args, &i, "--key") or_return
		} else if strings.has_prefix(arg, "--key=") {
			opts.fact_key = arg[len("--key="):]
		} else if arg == "--fact-id" || strings.has_prefix(arg, "--fact-id=") {
			raw_id := arg[len("--fact-id="):] if strings.has_prefix(arg, "--fact-id=") else (parse_cli_value_arg(args, &i, "--fact-id") or_return)
			v, pok := strconv.parse_u64(raw_id)
			if !pok || v > u64(max(u32)) {
				fmt.eprintfln("error: invalid --fact-id %q", raw_id)
				return {}, false, false
			}
			opts.fact_id = forseti.Fact_Id(u32(v))
			opts.has_fact_id = true
		} else if strings.has_prefix(arg, "--mode=") || arg == "--mode" {
			raw_mode := arg[len("--mode="):] if strings.has_prefix(arg, "--mode=") else (parse_cli_value_arg(args, &i, "--mode") or_return)
			switch raw_mode {
			case "audit", "audit-full":
				opts.prov_mode = .Audit_Full
			case "support", "support-only":
				opts.prov_mode = .Support_Only
			case "fast":
				opts.prov_mode = .Fast
			case:
				fmt.eprintfln("error: unknown --mode %q (expected audit, support, or fast)", raw_mode)
				return {}, false, false
			}
		} else if strings.has_prefix(arg, "--graph=") || arg == "--graph" {
			raw_g := arg[len("--graph="):] if strings.has_prefix(arg, "--graph=") else (parse_cli_value_arg(args, &i, "--graph") or_return)
			switch raw_g {
			case "rulebase":
				opts.graph_kind = .Rulebase
			case "derivations":
				opts.graph_kind = .Derivations
			case:
				fmt.eprintfln("error: unknown --graph %q (expected rulebase or derivations)", raw_g)
				return {}, false, false
			}
		} else if arg != "-" && strings.has_prefix(arg, "-") {
			fmt.eprintfln("error: unknown option %q", arg)
			return {}, false, false
		} else if len(opts.file_path) == 0 {
			opts.file_path = arg
		} else if opts.subcmd == "fmt" {
			append(&opts.extra_files, arg)
		} else {
			fmt.eprintfln("error: unexpected positional argument %q", arg)
			return {}, false, false
		}
		i += 1
	}

	if len(opts.file_path) == 0 {
		fmt.eprintln("error: missing <file.forseti> argument")
		return {}, false, false
	}
	return opts, false, true
}

write_text_output :: proc(text: string, out_path: string) -> bool {
	if len(out_path) > 0 {
		if w_err := os.write_entire_file(out_path, text); w_err != nil {
			fmt.eprintfln("error: failed writing %q: %v", out_path, w_err)
			return false
		}
		return true
	}
	fmt.print(text)
	return true
}

write_telemetry_file :: proc(sink: ^forseti.Telemetry_Sink, path: string) -> bool {
	if len(path) == 0 {
		return true
	}
	data: string
	err: mem.Allocator_Error
	if strings.has_suffix(path, ".jsonl") {
		data, err = forseti.telemetry_export_jsonl(sink, context.allocator)
	} else {
		data, err = forseti.telemetry_export_chrome_trace(sink, context.allocator)
	}
	if err != nil {
		fmt.eprintfln("error: failed formatting telemetry: %v", err)
		return false
	}
	defer delete(data)

	if write_err := os.write_entire_file(path, data); write_err != nil {
		fmt.eprintfln("error: failed writing telemetry to %q: %v", path, write_err)
		return false
	}
	return true
}

emit_human_diagnostics :: proc(diags: ^forseti.Diagnostic_List, src, path: string) {
	for d in diags.items {
		formatted, f_err := forseti.format_diagnostic_human(d, src, path, context.allocator)
		if f_err == nil {
			fmt.eprint(formatted)
			delete(formatted)
		}
	}
}

loaded_facts_destroy :: proc(b: ^Loaded_Facts_Bundle) {
	delete(b.items)
	if b.has_root {
		json.destroy_value(b.root)
	}
	b^ = {}
}

load_facts_json :: proc(path: string) -> (bundle: Loaded_Facts_Bundle, ok: bool) {
	if len(path) == 0 {
		return {}, true
	}
	raw, r_err := os.read_entire_file(path, context.allocator)
	if r_err != nil {
		fmt.eprintfln("error: unable to read facts file %q: %v", path, r_err)
		return {}, false
	}
	defer delete(raw)

	val, p_err := json.parse_string(strings.trim_space(string(raw)), parse_integers = true, allocator = context.allocator)
	if p_err != nil {
		fmt.eprintfln("error: invalid JSON in %q: %v", path, p_err)
		return {}, false
	}
	bundle.has_root = true
	bundle.root = val

	arr: json.Array
	if root_arr, is_arr := val.(json.Array); is_arr {
		arr = root_arr
	} else if root_obj, is_obj := val.(json.Object); is_obj {
		fv, has_facts := root_obj["facts"]
		farr, f_is_arr := fv.(json.Array)
		if !has_facts || !f_is_arr {
			fmt.eprintfln("error: %q must be a JSON array or {\"facts\": [...]} object", path)
			loaded_facts_destroy(&bundle)
			return {}, false
		}
		arr = farr
	} else {
		fmt.eprintfln("error: %q must contain a JSON array or object", path)
		loaded_facts_destroy(&bundle)
		return {}, false
	}

	items := make([]Loaded_Fact_Spec, len(arr))
	for elem, idx in arr {
		obj, is_obj := elem.(json.Object)
		if !is_obj {
			fmt.eprintfln("error: facts[%d] in %q must be a JSON object", idx, path)
			delete(items)
			loaded_facts_destroy(&bundle)
			return {}, false
		}
		bind_v, has_bind := obj["binding"]
		bind_s, b_is_str := bind_v.(json.String)
		key_v, has_key := obj["key"]
		key_s, k_is_str := key_v.(json.String)
		flds_v, has_flds := obj["fields"]
		flds_obj, f_is_obj := flds_v.(json.Object)
		if !has_bind || !b_is_str || !has_key || !k_is_str || !has_flds || !f_is_obj {
			fmt.eprintfln("error: facts[%d] in %q requires string 'binding', string 'key', and object 'fields'", idx, path)
			delete(items)
			loaded_facts_destroy(&bundle)
			return {}, false
		}
		items[idx] = Loaded_Fact_Spec{
			binding = string(bind_s),
			key     = string(key_s),
			fields  = flds_obj,
		}
	}
	bundle.items = items
	return bundle, true
}

json_to_forseti_value :: proc(
	s: ^forseti.Session,
	kind: forseti.Type_Kind,
	jv: json.Value,
) -> (val: forseti.Value, ok: bool) {
	switch kind {
	case .Bool:
		bv, is_b := jv.(json.Boolean)
		if !is_b {
			return nil, false
		}
		return bool(bv), true
	case .I32:
		if iv, is_i := jv.(json.Integer); is_i {
			if i64(iv) < i64(min(i32)) || i64(iv) > i64(max(i32)) {
				return nil, false
			}
			return i32(iv), true
		}
		return nil, false
	case .I64:
		if iv, is_i := jv.(json.Integer); is_i {
			return i64(iv), true
		}
		return nil, false
	case .F64:
		if fv, is_f := jv.(json.Float); is_f {
			return f64(fv), true
		}
		if iv, is_i := jv.(json.Integer); is_i {
			return f64(iv), true
		}
		return nil, false
	case .String, .Enum:
		sv, is_s := jv.(json.String)
		if !is_s {
			return nil, false
		}
		if s == nil {
			return nil, true
		}
		sid, _ := forseti.intern_session_string(&s.rb.interner, &s.interner, string(sv))
		return sid, true
	case .Entity:
		if iv, is_i := jv.(json.Integer); is_i && iv >= 0 {
			return forseti.Entity_Id(u64(iv)), true
		}
		return nil, false
	case .Time:
		if iv, is_i := jv.(json.Integer); is_i {
			return forseti.Time_Ns(i64(iv)), true
		}
		return nil, false
	case .Unknown, .Fact, .Table_Result:
		switch v in jv {
		case json.Boolean:
			return bool(v), true
		case json.Integer:
			return i64(v), true
		case json.Float:
			return f64(v), true
		case json.String:
			if s == nil {
				return nil, true
			}
			sid, _ := forseti.intern_session_string(&s.rb.interner, &s.interner, string(v))
			return sid, true
		case json.Null, json.Array, json.Object:
			return nil, false
		}
	}
	return nil, false
}

find_binding_in_rbs :: proc(rbs: []^forseti.Rulebase, name: string) -> (rb: ^forseti.Rulebase, bidx: u16, ok: bool) {
	for candidate in rbs {
		if candidate == nil {
			continue
		}
		if bi, found := forseti.rulebase_find_binding(candidate, name); found {
			return candidate, bi, true
		}
	}
	return nil, 0, false
}

validate_facts_bundle_for_store :: proc(rbs: []^forseti.Rulebase, bundle: ^Loaded_Facts_Bundle) -> bool {
	path_buf: [256]u8 = ---
	for item in bundle.items {
		rb, bidx, has_b := find_binding_in_rbs(rbs, item.binding)
		if !has_b {
			fmt.eprintfln("error: unknown binding %q in facts file", item.binding)
			return false
		}
		dot_path := forseti.rulebase_binding_dot_path(rb, bidx, path_buf[:])
		if len(dot_path) == 0 {
			fmt.eprintfln("error: binding %q has no store selector path", item.binding)
			return false
		}
		bdef := rb.bindings[bidx]
		schema := rb.schemas[bdef.schema_id]
		for sf in schema.fields {
			fname := forseti.interner_get(&rb.interner, sf.name)
			jv, has_f := item.fields[fname]
			if !has_f {
				continue
			}
			if sf.type.kind == .Unknown || sf.type.kind == .Fact || sf.type.kind == .Table_Result {
				fmt.eprintfln("error: unsupported store schema field type %v for %s.%s", sf.type.kind, item.binding, fname)
				return false
			}
			if _, valid := json_to_forseti_value(nil, sf.type.kind, jv); !valid {
				fmt.eprintfln("error: invalid value for %s.%s in key %q", item.binding, fname, item.key)
				return false
			}
		}
	}
	return true
}

seed_facts_tx_cb :: proc(wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ctx := (^Seed_Store_Ctx)(user_data)
	path_buf: [256]u8 = ---
	for item in ctx.bundle.items {
		rb, bidx, has_b := find_binding_in_rbs(ctx.rbs, item.binding)
		if !has_b {
			return xitdb.Xitdb_Error.Write_Failed
		}
		bdef := rb.bindings[bidx]
		schema := rb.schemas[bdef.schema_id]
		dot_path := forseti.rulebase_binding_dot_path(rb, bidx, path_buf[:])
		if len(dot_path) == 0 {
			return xitdb.Xitdb_Error.Write_Failed
		}
		col_map, cm_err := forseti.store_write_path_ensure_map(wc, dot_path)
		if cm_err != nil {
			return xitdb.Xitdb_Error.Write_Failed
		}
		rec_wc := xitdb.hash_map_put_cursor(&col_map, item.key) or_return
		rec_m := xitdb.write_hash_map_init(rec_wc) or_return
		for sf in schema.fields {
			fname := forseti.interner_get(&rb.interner, sf.name)
			jv, has_f := item.fields[fname]
			if !has_f {
				continue
			}
			switch sf.type.kind {
			case .Bool:
				bv, is_b := jv.(json.Boolean)
				if !is_b {
					return xitdb.Xitdb_Error.Write_Failed
				}
				if werr := forseti.write_bool_to_hash_map(&rec_m, fname, bool(bv)); werr != nil {
					return xitdb.Xitdb_Error.Write_Failed
				}
			case .I32:
				iv, is_i := jv.(json.Integer)
				if !is_i || i64(iv) < i64(min(i32)) || i64(iv) > i64(max(i32)) {
					return xitdb.Xitdb_Error.Write_Failed
				}
				xitdb.hash_map_put(&rec_m, fname, i64(iv)) or_return
			case .I64, .Time:
				iv, is_i := jv.(json.Integer)
				if !is_i {
					return xitdb.Xitdb_Error.Write_Failed
				}
				xitdb.hash_map_put(&rec_m, fname, i64(iv)) or_return
			case .F64:
				if fv, is_f := jv.(json.Float); is_f {
					xitdb.hash_map_put(&rec_m, fname, f64(fv)) or_return
				} else if iv, is_i := jv.(json.Integer); is_i {
					xitdb.hash_map_put(&rec_m, fname, f64(iv)) or_return
				} else {
					return xitdb.Xitdb_Error.Write_Failed
				}
			case .String, .Enum:
				sv, is_s := jv.(json.String)
				if !is_s {
					return xitdb.Xitdb_Error.Write_Failed
				}
				xitdb.hash_map_put(&rec_m, fname, string(sv)) or_return
			case .Entity:
				iv, is_i := jv.(json.Integer)
				if !is_i || iv < 0 {
					return xitdb.Xitdb_Error.Write_Failed
				}
				xitdb.hash_map_put(&rec_m, fname, u64(iv)) or_return
			case .Unknown, .Fact, .Table_Result:
				return xitdb.Xitdb_Error.Write_Failed
			}
		}
	}
	return nil
}

insert_loaded_facts_direct :: proc(s: ^forseti.Session, bundle: ^Loaded_Facts_Bundle) -> bool {
	for item in bundle.items {
		bidx, has_b := forseti.session_find_binding(s, item.binding)
		if !has_b {
			fmt.eprintfln("error: unknown binding %q in facts file", item.binding)
			return false
		}
		bdef := s.rb.bindings[bidx]
		schema := s.rb.schemas[bdef.schema_id]
		vals := make([]forseti.Value, len(schema.fields), context.temp_allocator)
		for sf, fi in schema.fields {
			fname := forseti.interner_get(&s.rb.interner, sf.name)
			jv, has_f := item.fields[fname]
			if !has_f {
				continue
			}
			converted, cv_ok := json_to_forseti_value(s, sf.type.kind, jv)
			if !cv_ok {
				fmt.eprintfln("error: invalid value for %s.%s in key %q", item.binding, fname, item.key)
				return false
			}
			vals[fi] = converted
		}
		_, ierr := forseti.session_insert_fact(s, item.binding, item.key, vals)
		if ierr != .None {
			fmt.eprintfln("error: failed inserting %s[%s]: %v", item.binding, item.key, ierr)
			return false
		}
	}
	return true
}

compile_source_to_rulebase :: proc(
	src, file_path: string,
	diags: ^forseti.Diagnostic_List,
	telemetry: ^forseti.Telemetry_Sink,
	warnings_as_errors: bool,
) -> (
	rb: forseti.Rulebase,
	exit_code: int,
	ok: bool,
) {
	ir, c_err := forseti.compile_source(src, file_path, diags, telemetry, context.allocator)
	if c_err != nil {
		fmt.eprintfln("error: compilation failed: %v", c_err)
		return {}, 2, false
	}
	defer forseti.ir_destroy(&ir)

	emit_human_diagnostics(diags, src, file_path)
	if diags.error_count > 0 || (warnings_as_errors && diags.warning_count > 0) {
		return {}, 1, false
	}

	compiled_rb, rb_err := forseti.rulebase_compile(&ir, telemetry, context.allocator)
	if rb_err != .None {
		forseti.rulebase_destroy(&compiled_rb)
		fmt.eprintfln("error: rulebase compile failed: %v", rb_err)
		return {}, 2, false
	}
	return compiled_rb, 0, true
}

watch_source_paths :: proc(syncer: ^forseti.Delta_Syncer, rbs: []^forseti.Rulebase) -> bool {
	seen := make(map[string]bool, 8, context.temp_allocator)
	buf: [256]u8 = ---
	for rb in rbs {
		for bdef, bi in rb.bindings {
			if bdef.kind != .Source {
				continue
			}
			p := forseti.rulebase_binding_dot_path(rb, u16(bi), buf[:])
			if len(p) == 0 || (p in seen) {
				continue
			}
			cloned := strings.clone(p, context.temp_allocator)
			seen[cloned] = true
			if w_err := forseti.delta_syncer_watch(syncer, cloned); w_err != nil {
				fmt.eprintfln("error: failed watching %q: %v", cloned, w_err)
				return false
			}
		}
	}
	return true
}

execute_session_with_inputs :: proc(
	exec: ^Cli_Exec_Context,
	rb: ^forseti.Rulebase,
	bundle: ^Loaded_Facts_Bundle,
	store_path: string,
	prov_mode: forseti.Provenance_Mode,
	telemetry: ^forseti.Telemetry_Sink,
	commit_to_store: bool,
) -> (
	exit_code: int,
	ok: bool,
) {
	exec^ = {committed_moment = -1}
	exec.sess = new(forseti.Session)
	s_err := forseti.session_init(exec.sess, rb, forseti.Session_Config{provenance_mode = prov_mode}, telemetry, context.allocator)
	if s_err != .None {
		cli_exec_destroy(exec)
		fmt.eprintfln("error: session_init failed: %v", s_err)
		return 2, false
	}

	if len(store_path) > 0 {
		if b_err := forseti.store_bridge_open_file(&exec.bridge, store_path, forseti.Xitdb_Config{}, telemetry, context.allocator); b_err != nil {
			cli_exec_destroy(exec)
			fmt.eprintfln("error: failed opening store %q: %v", store_path, b_err)
			return 2, false
		}
		exec.has_bridge = true

		rbs := [1]^forseti.Rulebase{rb}
		active_bridge := &exec.bridge
		if len(bundle.items) > 0 {
			if !validate_facts_bundle_for_store(rbs[:], bundle) {
				cli_exec_destroy(exec)
				return 1, false
			}
			if !commit_to_store {
				if fk_err := forseti.fork_create(&exec.fork, &exec.bridge, context.allocator); fk_err != nil {
					cli_exec_destroy(exec)
					fmt.eprintfln("error: failed forking store %q: %v", store_path, fk_err)
					return 2, false
				}
				active_bridge = &exec.fork.bridge
			}
			seed_ctx := Seed_Store_Ctx{rbs = rbs[:], bundle = bundle}
			if _, m_err := forseti.store_bridge_commit_moment(active_bridge, seed_facts_tx_cb, &seed_ctx); m_err != nil {
				cli_exec_destroy(exec)
				fmt.eprintfln("error: failed seeding store %q: %v", store_path, m_err)
				return 2, false
			}
		}

		syncer: forseti.Delta_Syncer
		if d_err := forseti.delta_syncer_init(&syncer, telemetry, context.allocator); d_err != nil {
			cli_exec_destroy(exec)
			fmt.eprintfln("error: delta_syncer_init failed: %v", d_err)
			return 2, false
		}
		defer forseti.delta_syncer_destroy(&syncer)

		if !watch_source_paths(&syncer, rbs[:]) {
			cli_exec_destroy(exec)
			return 2, false
		}

		cnt, f_err := forseti.session_sync_and_fire(exec.sess, active_bridge, &syncer, commit_derived = commit_to_store)
		if f_err != nil {
			cli_exec_destroy(exec)
			fmt.eprintfln("error: sync/fire failed: %v", f_err)
			return 2, false
		}
		exec.fired_count = cnt
		if commit_to_store {
			mc, mc_err := forseti.store_bridge_moment_count(active_bridge)
			if mc_err == nil && mc > 0 {
				exec.committed_moment = mc - 1
			}
		}
		return 0, true
	}

	if len(bundle.items) > 0 {
		if !insert_loaded_facts_direct(exec.sess, bundle) {
			cli_exec_destroy(exec)
			return 1, false
		}
	}
	cnt, f_err := forseti.session_fire(exec.sess)
	if f_err != .None {
		cli_exec_destroy(exec)
		fmt.eprintfln("error: session_fire failed: %v", f_err)
		return 2, false
	}
	exec.fired_count = cnt
	return 0, true
}

select_matching_fact_ids :: proc(s: ^forseti.Session, opts: Cli_Options) -> []forseti.Fact_Id {
	if opts.has_fact_id {
		if opts.fact_id != forseti.INVALID_FACT && int(opts.fact_id) < len(s.facts) && s.facts[opts.fact_id].alive {
			res := make([]forseti.Fact_Id, 1, context.temp_allocator)
			res[0] = opts.fact_id
			return res
		}
		return nil
	}

	target_bidx := u16(max(u16))
	if len(opts.binding_name) > 0 {
		bi, ok := forseti.session_find_binding(s, opts.binding_name)
		if !ok {
			return nil
		}
		target_bidx = bi
	}

	out := make([dynamic]forseti.Fact_Id, 0, 8, context.temp_allocator)
	for &f in s.facts {
		if !f.alive || f.id == forseti.INVALID_FACT {
			continue
		}
		if len(opts.binding_name) > 0 {
			if f.binding_idx != target_bidx {
				continue
			}
		} else if s.rb.bindings[f.binding_idx].kind != .Derived {
			continue
		}
		if len(opts.fact_key) > 0 && forseti.session_string(s, f.key) != opts.fact_key {
			continue
		}
		append(&out, f.id)
	}
	return out[:]
}

format_telemetry_human :: proc(sink: ^forseti.Telemetry_Sink) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, context.allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	fmt.sbprintf(
		&b,
		"Telemetry: spans=%d peak_heap=%dB peak_arena=%dB live_mem=%d\n",
		len(sink.events),
		sink.watermarks.peak_heap_bytes,
		sink.watermarks.peak_arena_bytes,
		sink.watermarks.live_session_memories,
	)
	for ev in sink.events {
		fmt.sbprintf(&b, "  span [%v] %s dur_ns=%d alloc_delta=%d\n", ev.phase, ev.name, ev.duration_ns, ev.alloc_bytes_delta)
	}
	for c in forseti.Telemetry_Counter {
		val := sink.counters[c]
		if val > 0 || c == .Rules_Fired || c == .Derivations_Recorded {
			fmt.sbprintf(&b, "  counter %-26s %d\n", forseti.telemetry_counter_names[c], val)
		}
	}
	return strings.to_string(b), nil
}

run_cmd_diff_replay :: proc(
	opts: Cli_Options,
	base_src, file_path: string,
	diags: ^forseti.Diagnostic_List,
	telemetry: ^forseti.Telemetry_Sink,
) -> int {
	if len(opts.candidate_path) == 0 {
		fmt.eprintln("error: diff-replay requires --candidate <candidate.forseti>")
		return 2
	}
	cand_raw, c_read_err := os.read_entire_file(opts.candidate_path, context.allocator)
	if c_read_err != nil {
		fmt.eprintfln("error: unable to read candidate %q: %v", opts.candidate_path, c_read_err)
		return 2
	}
	defer delete(cand_raw)
	cand_src := string(cand_raw)

	bundle, f_ok := load_facts_json(opts.facts_path)
	if !f_ok {
		return 2
	}
	defer loaded_facts_destroy(&bundle)

	base_rb, base_code, base_ok := compile_source_to_rulebase(base_src, file_path, diags, telemetry, opts.warnings_as_errors)
	if !base_ok {
		return base_code
	}
	defer forseti.rulebase_destroy(&base_rb)

	cand_diags: forseti.Diagnostic_List
	if cd_err := forseti.diag_list_init(&cand_diags); cd_err != nil {
		fmt.eprintfln("error: out of memory: %v", cd_err)
		return 2
	}
	defer forseti.diag_list_destroy(&cand_diags)

	cand_rb, cand_code, cand_ok := compile_source_to_rulebase(cand_src, opts.candidate_path, &cand_diags, telemetry, opts.warnings_as_errors)
	if !cand_ok {
		return cand_code
	}
	defer forseti.rulebase_destroy(&cand_rb)

	bridge: forseti.Store_Bridge
	if len(opts.store_path) > 0 {
		if b_err := forseti.store_bridge_open_file(&bridge, opts.store_path, forseti.Xitdb_Config{}, telemetry, context.allocator); b_err != nil {
			fmt.eprintfln("error: failed opening store %q: %v", opts.store_path, b_err)
			return 2
		}
	} else {
		if b_err := forseti.store_bridge_init_standalone(&bridge, forseti.Xitdb_Config{}, telemetry, context.allocator); b_err != nil {
			fmt.eprintfln("error: failed creating store: %v", b_err)
			return 2
		}
	}
	defer forseti.store_bridge_destroy(&bridge)

	rbs := [2]^forseti.Rulebase{&base_rb, &cand_rb}
	seed_fork: forseti.Fork_Handle
	defer forseti.fork_destroy(&seed_fork)
	replay_bridge := &bridge

	if len(bundle.items) > 0 {
		if !validate_facts_bundle_for_store(rbs[:], &bundle) {
			return 1
		}
		if len(opts.store_path) > 0 {
			if fk_err := forseti.fork_create(&seed_fork, &bridge, context.allocator); fk_err != nil {
				fmt.eprintfln("error: failed forking store %q: %v", opts.store_path, fk_err)
				return 2
			}
			replay_bridge = &seed_fork.bridge
		}
		seed_ctx := Seed_Store_Ctx{rbs = rbs[:], bundle = &bundle}
		if _, m_err := forseti.store_bridge_commit_moment(replay_bridge, seed_facts_tx_cb, &seed_ctx); m_err != nil {
			fmt.eprintfln("error: failed seeding facts into store: %v", m_err)
			return 2
		}
	}

	watch_set := make(map[string]bool, 8, context.temp_allocator)
	watch_paths := make([dynamic]string, 0, 8, context.temp_allocator)
	path_buf: [256]u8 = ---
	for rbp in rbs {
		for bdef, bi in rbp.bindings {
			if bdef.kind != .Source {
				continue
			}
			p := forseti.rulebase_binding_dot_path(rbp, u16(bi), path_buf[:])
			if len(p) > 0 && !(p in watch_set) {
				cloned := strings.clone(p, context.temp_allocator)
				watch_set[cloned] = true
				append(&watch_paths, cloned)
			}
		}
	}

	rep, d_err := forseti.diff_replay(replay_bridge, &base_rb, &cand_rb, watch_paths[:], telemetry, context.allocator)
	if d_err != nil {
		fmt.eprintfln("error: diff-replay failed: %v", d_err)
		return 2
	}
	defer forseti.diff_replay_report_destroy(&rep)

	out_txt: string
	fmt_err: mem.Allocator_Error
	if opts.format == .Json {
		out_txt, fmt_err = forseti.diff_replay_format_json(&rep, context.allocator)
	} else {
		out_txt, fmt_err = forseti.diff_replay_format_human(&rep, context.allocator)
	}
	if fmt_err != nil {
		fmt.eprintfln("error: formatting diff-replay output failed: %v", fmt_err)
		return 2
	}
	defer delete(out_txt)

	if !write_text_output(out_txt, opts.out_path) {
		return 2
	}
	if opts.format == .Json && len(opts.out_path) == 0 {
		fmt.println("")
	}
	if !write_telemetry_file(telemetry, opts.telemetry_path) {
		return 2
	}
	return 0
}

run_cmd_fmt :: proc(opts: ^Cli_Options) -> int {
	if opts.format != .Human {
		fmt.eprintln("error: command \"fmt\" does not support --format")
		return 2
	}
	if opts.fmt_write && opts.fmt_check {
		fmt.eprintln("error: cannot combine --write and --check")
		return 2
	}

	paths := make([dynamic]string, 0, 1 + len(opts.extra_files), context.allocator)
	defer delete(paths)
	append(&paths, opts.file_path)
	for ep in opts.extra_files {
		append(&paths, ep)
	}

	unformatted := false
	for p in paths {
		raw: []u8
		read_err: os.Error
		if p == "-" {
			if opts.fmt_write {
				fmt.eprintln("error: cannot use --write with stdin '-'")
				return 2
			}
			raw, read_err = os.read_entire_file(os.stdin, context.allocator)
		} else {
			raw, read_err = os.read_entire_file(p, context.allocator)
		}
		if read_err != nil {
			fmt.eprintfln("error: unable to read %q: %v", p, read_err)
			return 2
		}
		defer delete(raw)
		src := string(raw)

		formatted, fmt_err := forseti.format_source(src, context.allocator)
		if fmt_err != nil {
			fmt.eprintfln("error: formatting failed for %q: %v", p, fmt_err)
			return 2
		}
		defer delete(formatted)

		if opts.fmt_check {
			if formatted != src {
				fmt.eprintfln("would reformat: %s", p)
				unformatted = true
			}
			continue
		}
		if opts.fmt_write {
			if formatted != src {
				if w_err := os.write_entire_file(p, formatted); w_err != nil {
					fmt.eprintfln("error: failed writing %q: %v", p, w_err)
					return 2
				}
			}
			continue
		}
		if !write_text_output(formatted, opts.out_path) {
			return 2
		}
	}
	return 1 if unformatted else 0
}

run_cli :: proc() -> int {
	opts, show_help, ok := parse_cli_args(os.args)
	defer delete(opts.extra_files)
	if !ok {
		return 2
	}
	if show_help {
		print_usage()
		return 0
	}
	if opts.subcmd == "fmt" {
		return run_cmd_fmt(&opts)
	}

	raw, read_err := os.read_entire_file(opts.file_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("error: unable to read %q: %v", opts.file_path, read_err)
		return 2
	}
	defer delete(raw)
	src := string(raw)

	diags: forseti.Diagnostic_List
	if d_err := forseti.diag_list_init(&diags); d_err != nil {
		fmt.eprintfln("error: out of memory: %v", d_err)
		return 2
	}
	defer forseti.diag_list_destroy(&diags)

	tel_enabled := len(opts.telemetry_path) > 0 || opts.subcmd == "telemetry"
	telemetry: forseti.Telemetry_Sink
	if t_err := forseti.telemetry_init(&telemetry, enabled = tel_enabled); t_err != nil {
		fmt.eprintfln("error: out of memory: %v", t_err)
		return 2
	}
	defer forseti.telemetry_destroy(&telemetry)

	switch opts.subcmd {
	case "check", "verify-tables", "run", "explain", "impact", "diff-replay":
		if opts.format != .Human && opts.format != .Json {
			fmt.eprintfln("error: command %q only supports --format=human or --format=json", opts.subcmd)
			return 2
		}
	case "ast", "ir", "gen", "export-dot", "export-mermaid":
		if opts.format != .Human {
			fmt.eprintfln("error: command %q does not support --format", opts.subcmd)
			return 2
		}
	}

	switch opts.subcmd {
	case "check", "verify-tables":
		ir, c_err := forseti.compile_source(src, opts.file_path, &diags, &telemetry, context.allocator)
		if c_err != nil {
			fmt.eprintfln("error: compilation failed: %v", c_err)
			return 2
		}
		defer forseti.ir_destroy(&ir)

		if opts.format == .Json {
			json_out, j_err := forseti.format_diagnostics_json(&diags, opts.file_path, context.allocator)
			if j_err != nil {
				fmt.eprintfln("error: failed formatting json: %v", j_err)
				return 2
			}
			defer delete(json_out)
			if !write_text_output(json_out, opts.out_path) {
				return 2
			}
			if len(opts.out_path) == 0 {
				fmt.println("")
			}
		} else {
			emit_human_diagnostics(&diags, src, opts.file_path)
			if len(diags.items) == 0 {
				if opts.subcmd == "verify-tables" {
					fmt.printfln("OK: %s (%d table(s) verified, 0 errors, 0 warnings)", opts.file_path, len(ir.tables))
				} else {
					fmt.printfln("OK: %s (0 errors, 0 warnings)", opts.file_path)
				}
			}
		}

		if !write_telemetry_file(&telemetry, opts.telemetry_path) {
			return 2
		}
		if diags.error_count > 0 || (opts.warnings_as_errors && diags.warning_count > 0) {
			return 1
		}
		return 0

	case "gen":
		ir, c_err := forseti.compile_source(src, opts.file_path, &diags, &telemetry, context.allocator)
		if c_err != nil {
			fmt.eprintfln("error: compile failed: %v", c_err)
			return 2
		}
		defer forseti.ir_destroy(&ir)

		emit_human_diagnostics(&diags, src, opts.file_path)
		if diags.error_count > 0 || (opts.warnings_as_errors && diags.warning_count > 0) {
			return 1
		}

		pkg := opts.pkg_name if len(opts.pkg_name) > 0 else "generated_tables"
		gen_src, g_err := forseti.codegen_odin_module(&ir, pkg, context.allocator)
		if g_err != nil {
			fmt.eprintfln("error: codegen failed: %v", g_err)
			return 2
		}
		defer delete(gen_src)

		if !write_text_output(gen_src, opts.out_path) {
			return 2
		}
		if !write_telemetry_file(&telemetry, opts.telemetry_path) {
			return 2
		}
		return 0

	case "ast":
		parsed, p_err := forseti.parse_source_to_ast(src, opts.file_path, &diags, &telemetry, context.allocator)
		if p_err != nil {
			fmt.eprintfln("error: parse failed: %v", p_err)
			return 2
		}
		defer forseti.parsed_ast_destroy(&parsed)

		emit_human_diagnostics(&diags, src, opts.file_path)
		sexp, s_err := forseti.ast_print_sexp(&parsed.pool, &parsed.interner, context.allocator)
		if s_err != nil {
			fmt.eprintfln("error: failed formatting ast: %v", s_err)
			return 2
		}
		defer delete(sexp)
		if !write_text_output(sexp, opts.out_path) {
			return 2
		}
		if len(opts.out_path) == 0 {
			fmt.println("")
		}

		if !write_telemetry_file(&telemetry, opts.telemetry_path) {
			return 2
		}
		return 1 if diags.error_count > 0 else 0

	case "ir":
		ir, c_err := forseti.compile_source(src, opts.file_path, &diags, &telemetry, context.allocator)
		if c_err != nil {
			fmt.eprintfln("error: compile failed: %v", c_err)
			return 2
		}
		defer forseti.ir_destroy(&ir)

		emit_human_diagnostics(&diags, src, opts.file_path)
		text, f_err := forseti.ir_format_text(&ir, context.allocator)
		if f_err != nil {
			fmt.eprintfln("error: failed formatting ir: %v", f_err)
			return 2
		}
		defer delete(text)
		if !write_text_output(text, opts.out_path) {
			return 2
		}

		if !write_telemetry_file(&telemetry, opts.telemetry_path) {
			return 2
		}
		if diags.error_count > 0 || (opts.warnings_as_errors && diags.warning_count > 0) {
			return 1
		}
		return 0

	case "run":
		bundle, f_ok := load_facts_json(opts.facts_path)
		if !f_ok {
			return 2
		}
		defer loaded_facts_destroy(&bundle)

		rb, comp_code, rb_ok := compile_source_to_rulebase(src, opts.file_path, &diags, &telemetry, opts.warnings_as_errors)
		if !rb_ok {
			return comp_code
		}
		defer forseti.rulebase_destroy(&rb)

		exec: Cli_Exec_Context
		defer cli_exec_destroy(&exec)
		run_code, run_ok := execute_session_with_inputs(
			&exec,
			&rb,
			&bundle,
			opts.store_path,
			opts.prov_mode,
			&telemetry,
			commit_to_store = true,
		)
		if !run_ok {
			return run_code
		}

		out_txt, fmt_err := forseti.session_format_run_output(exec.sess, exec.fired_count, exec.committed_moment, opts.format == .Json, context.allocator)
		if fmt_err != nil {
			fmt.eprintfln("error: failed formatting run output: %v", fmt_err)
			return 2
		}
		defer delete(out_txt)
		if !write_text_output(out_txt, opts.out_path) {
			return 2
		}
		if !write_telemetry_file(&telemetry, opts.telemetry_path) {
			return 2
		}
		return 0

	case "explain":
		bundle, f_ok := load_facts_json(opts.facts_path)
		if !f_ok {
			return 2
		}
		defer loaded_facts_destroy(&bundle)

		rb, comp_code, rb_ok := compile_source_to_rulebase(src, opts.file_path, &diags, &telemetry, opts.warnings_as_errors)
		if !rb_ok {
			return comp_code
		}
		defer forseti.rulebase_destroy(&rb)

		exec: Cli_Exec_Context
		defer cli_exec_destroy(&exec)
		run_code, run_ok := execute_session_with_inputs(
			&exec,
			&rb,
			&bundle,
			opts.store_path,
			.Audit_Full,
			&telemetry,
			commit_to_store = false,
		)
		if !run_ok {
			return run_code
		}

		fids := select_matching_fact_ids(exec.sess, opts)
		has_filter := opts.has_fact_id || len(opts.binding_name) > 0 || len(opts.fact_key) > 0
		if has_filter && len(fids) == 0 {
			fmt.eprintln("error: no matching alive fact found to explain")
			return 1
		}

		b: strings.Builder
		if _, b_err := strings.builder_init(&b, context.allocator); b_err != nil {
			fmt.eprintfln("error: out of memory: %v", b_err)
			return 2
		}
		defer strings.builder_destroy(&b)

		if opts.format == .Json {
			strings.write_string(&b, `{"explanations":[`)
			for fid, i in fids {
				if i > 0 {
					strings.write_byte(&b, ',')
				}
				tree := forseti.explain(exec.sess, fid, context.allocator)
				j_txt, j_err := forseti.explain_format_json(&tree, context.allocator)
				forseti.explain_tree_destroy(&tree)
				if j_err != nil {
					fmt.eprintfln("error: failed formatting explain JSON: %v", j_err)
					return 2
				}
				strings.write_string(&b, j_txt)
				delete(j_txt)
			}
			strings.write_string(&b, "]}\n")
		} else {
			if len(fids) == 0 {
				strings.write_string(&b, "<no explanations>\n")
			} else {
				for fid in fids {
					tree := forseti.explain(exec.sess, fid, context.allocator)
					txt := forseti.explain_format(&tree, context.allocator)
					forseti.explain_tree_destroy(&tree)
					strings.write_string(&b, txt)
					delete(txt)
				}
			}
		}

		if !write_text_output(strings.to_string(b), opts.out_path) {
			return 2
		}
		if !write_telemetry_file(&telemetry, opts.telemetry_path) {
			return 2
		}
		return 0

	case "impact":
		if len(opts.rule_name) == 0 {
			fmt.eprintln("error: impact requires --rule <rule_name>")
			return 2
		}
		bundle, f_ok := load_facts_json(opts.facts_path)
		if !f_ok {
			return 2
		}
		defer loaded_facts_destroy(&bundle)

		rb, comp_code, rb_ok := compile_source_to_rulebase(src, opts.file_path, &diags, &telemetry, opts.warnings_as_errors)
		if !rb_ok {
			return comp_code
		}
		defer forseti.rulebase_destroy(&rb)

		exec: Cli_Exec_Context
		defer cli_exec_destroy(&exec)
		run_code, run_ok := execute_session_with_inputs(
			&exec,
			&rb,
			&bundle,
			opts.store_path,
			.Audit_Full,
			&telemetry,
			commit_to_store = false,
		)
		if !run_ok {
			return run_code
		}

		rid := max(u32)
		for &r, i in rb.rules {
			if forseti.interner_get(&rb.interner, r.name) == opts.rule_name {
				rid = u32(i)
				break
			}
		}
		if rid == max(u32) {
			fmt.eprintfln("error: unknown rule %q", opts.rule_name)
			return 1
		}

		rep := forseti.impact(exec.sess, rid, opts.rule_version, context.allocator)
		defer forseti.impact_report_destroy(&rep)

		out_txt: string
		fmt_err: mem.Allocator_Error
		if opts.format == .Json {
			out_txt, fmt_err = forseti.impact_format_json(exec.sess, &rep, context.allocator)
		} else {
			out_txt, fmt_err = forseti.impact_format_human(exec.sess, &rep, context.allocator)
		}
		if fmt_err != nil {
			fmt.eprintfln("error: failed formatting impact output: %v", fmt_err)
			return 2
		}
		defer delete(out_txt)

		if !write_text_output(out_txt, opts.out_path) {
			return 2
		}
		if opts.format == .Json && len(opts.out_path) == 0 {
			fmt.println("")
		}
		if !write_telemetry_file(&telemetry, opts.telemetry_path) {
			return 2
		}
		return 0

	case "diff-replay":
		return run_cmd_diff_replay(opts, src, opts.file_path, &diags, &telemetry)

	case "telemetry":
		bundle, f_ok := load_facts_json(opts.facts_path)
		if !f_ok {
			return 2
		}
		defer loaded_facts_destroy(&bundle)

		rb, comp_code, rb_ok := compile_source_to_rulebase(src, opts.file_path, &diags, &telemetry, opts.warnings_as_errors)
		if !rb_ok {
			return comp_code
		}
		defer forseti.rulebase_destroy(&rb)

		exec: Cli_Exec_Context
		defer cli_exec_destroy(&exec)
		run_code, run_ok := execute_session_with_inputs(
			&exec,
			&rb,
			&bundle,
			opts.store_path,
			opts.prov_mode,
			&telemetry,
			commit_to_store = false,
		)
		if !run_ok {
			return run_code
		}

		out_txt: string
		fmt_err: mem.Allocator_Error
		switch opts.format {
		case .Jsonl:
			out_txt, fmt_err = forseti.telemetry_export_jsonl(&telemetry, context.allocator)
		case .Json, .Chrome_Trace:
			out_txt, fmt_err = forseti.telemetry_export_chrome_trace(&telemetry, context.allocator)
		case .Human:
			out_txt, fmt_err = format_telemetry_human(&telemetry)
		}
		if fmt_err != nil {
			fmt.eprintfln("error: failed formatting telemetry: %v", fmt_err)
			return 2
		}
		defer delete(out_txt)

		if !write_text_output(out_txt, opts.out_path) {
			return 2
		}
		if (opts.format == .Json || opts.format == .Chrome_Trace) && len(opts.out_path) == 0 {
			fmt.println("")
		}
		if !write_telemetry_file(&telemetry, opts.telemetry_path) {
			return 2
		}
		return 0

	case "export-dot", "export-mermaid":
		rb, comp_code, rb_ok := compile_source_to_rulebase(src, opts.file_path, &diags, &telemetry, opts.warnings_as_errors)
		if !rb_ok {
			return comp_code
		}
		defer forseti.rulebase_destroy(&rb)

		is_dot := opts.subcmd == "export-dot"
		out_txt: string
		exp_err: mem.Allocator_Error
		if opts.graph_kind == .Derivations {
			bundle, f_ok := load_facts_json(opts.facts_path)
			if !f_ok {
				return 2
			}
			defer loaded_facts_destroy(&bundle)

			exec: Cli_Exec_Context
			defer cli_exec_destroy(&exec)
			run_code, run_ok := execute_session_with_inputs(
				&exec,
				&rb,
				&bundle,
				opts.store_path,
				.Audit_Full,
				&telemetry,
				commit_to_store = false,
			)
			if !run_ok {
				return run_code
			}

			focus_fid := forseti.INVALID_FACT
			if opts.has_fact_id || len(opts.binding_name) > 0 || len(opts.fact_key) > 0 {
				matches := select_matching_fact_ids(exec.sess, opts)
				if len(matches) == 0 {
					fmt.eprintln("error: no matching fact found for derivation export focus")
					return 1
				}
				focus_fid = matches[0]
			}
			if is_dot {
				out_txt, exp_err = forseti.export_derivations_dot(exec.sess, focus_fid, context.allocator)
			} else {
				out_txt, exp_err = forseti.export_derivations_mermaid(exec.sess, focus_fid, context.allocator)
			}
		} else {
			if is_dot {
				out_txt, exp_err = forseti.export_rulebase_dot(&rb, context.allocator)
			} else {
				out_txt, exp_err = forseti.export_rulebase_mermaid(&rb, context.allocator)
			}
		}
		if exp_err != nil {
			fmt.eprintfln("error: export failed: %v", exp_err)
			return 2
		}
		defer delete(out_txt)

		if !write_text_output(out_txt, opts.out_path) {
			return 2
		}
		if !write_telemetry_file(&telemetry, opts.telemetry_path) {
			return 2
		}
		return 0

	case:
		fmt.eprintfln("error: unknown command %q", opts.subcmd)
		print_usage()
		return 2
	}
}

main :: proc() {
	exit_code: int
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		exit_code = run_cli()

		for _, entry in track.allocation_map {
			fmt.eprintfln("%v leaked %m", entry.location, entry.size)
		}
		for entry in track.bad_free_array {
			fmt.eprintfln("%v bad free at %p", entry.location, entry.memory)
		}
		mem.tracking_allocator_destroy(&track)
	} else {
		exit_code = run_cli()
	}

	if exit_code != 0 {
		os.exit(exit_code)
	}
}

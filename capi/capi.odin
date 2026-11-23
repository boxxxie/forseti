package forseti_capi

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import xitdb "xitdb:."
import "../forseti"

FORSETI_CAPI_VERSION :: cstring("0.1.0")

Forseti_Status :: enum c.int {
	OK              = 0,
	ERR_INVALID_ARG = 1,
	ERR_COMPILE     = 2,
	ERR_ALLOC       = 3,
	ERR_UNKNOWN_BINDING = 4,
	ERR_UNKNOWN_QUERY   = 5,
	ERR_UNKNOWN_RULE    = 6,
	ERR_STORE       = 7,
	ERR_LIMIT       = 8,
	ERR_INTERNAL    = 9,
}

Forseti_Provenance_Mode :: enum c.int {
	AUDIT_FULL   = 0,
	SUPPORT_ONLY = 1,
	FAST         = 2,
}

Forseti_Val_Kind :: enum c.int {
	NIL     = 0,
	BOOL    = 1,
	I32     = 2,
	I64     = 3,
	F64     = 4,
	STRING  = 5,
	ENTITY  = 6,
	TIME_NS = 7,
	ENUM    = 8,
}

Forseti_Enum_Val :: struct {
	enum_id: u32,
	variant: u32,
}

Forseti_Value_Union :: struct #raw_union {
	b:        bool,
	i32_val:  i32,
	i64_val:  i64,
	f64_val:  f64,
	str:      cstring,
	entity:   u64,
	time_ns:  i64,
	enum_val: Forseti_Enum_Val,
}

Forseti_Value :: struct {
	kind: Forseti_Val_Kind,
	as:   Forseti_Value_Union,
}

Forseti_Rulebase :: struct {
	rb:        forseti.Rulebase,
	telemetry: forseti.Telemetry_Sink,
}

Forseti_Session :: struct {
	sess:      forseti.Session,
	telemetry: forseti.Telemetry_Sink,
}

Forseti_Store :: struct {
	bridge:    forseti.Store_Bridge,
	telemetry: forseti.Telemetry_Sink,
}

@(private)
_cstr_or_empty :: proc(s: cstring) -> string {
	return string(s) if s != nil else ""
}

@(private)
_dup_cstring :: proc(s: string, out_cstr: ^cstring) -> Forseti_Status {
	if out_cstr == nil {
		return .OK
	}
	cstr, err := strings.clone_to_cstring(s, context.allocator)
	if err != nil {
		out_cstr^ = nil
		return .ERR_ALLOC
	}
	out_cstr^ = cstr
	return .OK
}

@(private)
_map_session_err :: proc(err: forseti.Session_Error) -> Forseti_Status {
	switch err {
	case .None:
		return .OK
	case .Invalid_Arg:
		return .ERR_INVALID_ARG
	case .Alloc_Failed:
		return .ERR_ALLOC
	case .Unknown_Binding:
		return .ERR_UNKNOWN_BINDING
	case .Unknown_Query:
		return .ERR_UNKNOWN_QUERY
	case .Max_Activations_Exceeded:
		return .ERR_LIMIT
	case .Vm_Eval_Failed:
		return .ERR_INTERNAL
	}
	return .ERR_INTERNAL
}

@(private)
_map_prov_mode :: proc(m: Forseti_Provenance_Mode) -> (forseti.Provenance_Mode, bool) {
	switch m {
	case .AUDIT_FULL:
		return .Audit_Full, true
	case .SUPPORT_ONLY:
		return .Support_Only, true
	case .FAST:
		return .Fast, true
	}
	return .Audit_Full, false
}

@(private)
_convert_c_value :: proc(sess: ^forseti.Session, cv: Forseti_Value) -> (v: forseti.Value, st: Forseti_Status) {
	switch cv.kind {
	case .NIL:
		return nil, .OK
	case .BOOL:
		return cv.as.b, .OK
	case .I32:
		return cv.as.i32_val, .OK
	case .I64:
		return cv.as.i64_val, .OK
	case .F64:
		return cv.as.f64_val, .OK
	case .STRING:
		sid, err := forseti.intern_session_string(&sess.rb.interner, &sess.interner, _cstr_or_empty(cv.as.str))
		if err != nil {
			return nil, .ERR_ALLOC
		}
		return sid, .OK
	case .ENTITY:
		return forseti.Entity_Id(cv.as.entity), .OK
	case .TIME_NS:
		return forseti.Time_Ns(cv.as.time_ns), .OK
	case .ENUM:
		return forseti.Enum_Val{enum_id = cv.as.enum_val.enum_id, variant = cv.as.enum_val.variant}, .OK
	}
	return nil, .ERR_INVALID_ARG
}

@(private)
_convert_c_fields :: proc(
	sess: ^forseti.Session,
	fields: [^]Forseti_Value,
	count: c.size_t,
) -> ([]forseti.Value, Forseti_Status) {
	n := int(count)
	if n == 0 {
		return nil, .OK
	}
	if fields == nil {
		return nil, .ERR_INVALID_ARG
	}
	vals, err := make([]forseti.Value, n, context.temp_allocator)
	if err != nil {
		return nil, .ERR_ALLOC
	}
	for i := 0; i < n; i += 1 {
		v, st := _convert_c_value(sess, fields[i])
		if st != .OK {
			return nil, st
		}
		vals[i] = v
	}
	return vals, .OK
}

@(private)
_collect_watched_paths :: proc(paths: [^]cstring, count: c.size_t) -> ([]string, Forseti_Status) {
	n := int(count)
	if n == 0 {
		return nil, .OK
	}
	if paths == nil {
		return nil, .ERR_INVALID_ARG
	}
	out, err := make([]string, n, context.temp_allocator)
	if err != nil {
		return nil, .ERR_ALLOC
	}
	for i := 0; i < n; i += 1 {
		if paths[i] == nil {
			return nil, .ERR_INVALID_ARG
		}
		out[i] = string(paths[i])
	}
	return out, .OK
}

@(export)
forseti_abi_version :: proc "c" () -> cstring {
	return FORSETI_CAPI_VERSION
}

@(export)
forseti_free_string :: proc "c" (str: cstring) {
	if str == nil {
		return
	}
	context = runtime.default_context()
	delete(str, context.allocator)
}

@(export)
forseti_rulebase_compile :: proc "c" (
	source: cstring,
	source_name: cstring,
	warnings_as_errors: bool,
	out_rb: ^(^Forseti_Rulebase),
	out_diags_json: ^cstring,
) -> Forseti_Status {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if out_diags_json != nil {
		out_diags_json^ = nil
	}
	if out_rb != nil {
		out_rb^ = nil
	}
	if source == nil || out_rb == nil {
		return .ERR_INVALID_ARG
	}

	wrap := new(Forseti_Rulebase, context.allocator)
	if wrap == nil {
		return .ERR_ALLOC
	}
	ok_ret := false
	defer if !ok_ret {
		forseti.telemetry_destroy(&wrap.telemetry)
		free(wrap, context.allocator)
	}

	if forseti.telemetry_init(&wrap.telemetry, true, context.allocator) != nil {
		return .ERR_ALLOC
	}

	diags: forseti.Diagnostic_List
	if forseti.diag_list_init(&diags, context.allocator) != nil {
		return .ERR_ALLOC
	}
	defer forseti.diag_list_destroy(&diags)

	sname := _cstr_or_empty(source_name)
	ir, c_err := forseti.compile_source(string(source), sname, &diags, &wrap.telemetry, context.allocator)
	if c_err != nil {
		return .ERR_ALLOC
	}
	defer forseti.ir_destroy(&ir)

	if out_diags_json != nil {
		jstr, j_err := forseti.format_diagnostics_json(&diags, sname, context.temp_allocator)
		if j_err != nil {
			return .ERR_ALLOC
		}
		if st := _dup_cstring(jstr, out_diags_json); st != .OK {
			return st
		}
	}

	if diags.error_count > 0 || (warnings_as_errors && diags.warning_count > 0) {
		return .ERR_COMPILE
	}

	rb, rb_err := forseti.rulebase_compile(&ir, &wrap.telemetry, context.allocator)
	if rb_err != .None {
		forseti.rulebase_destroy(&rb)
		return .ERR_ALLOC if rb_err == .Alloc_Failed else .ERR_COMPILE
	}

	wrap.rb = rb
	wrap.rb.telemetry = &wrap.telemetry
	out_rb^ = wrap
	ok_ret = true
	return .OK
}

@(export)
forseti_rulebase_destroy :: proc "c" (rb: ^Forseti_Rulebase) {
	if rb == nil {
		return
	}
	context = runtime.default_context()
	forseti.rulebase_destroy(&rb.rb)
	forseti.telemetry_destroy(&rb.telemetry)
	free(rb, context.allocator)
}

@(export)
forseti_session_create :: proc "c" (
	rb: ^Forseti_Rulebase,
	prov_mode: Forseti_Provenance_Mode,
	max_activations: u64,
	out_sess: ^(^Forseti_Session),
) -> Forseti_Status {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if out_sess != nil {
		out_sess^ = nil
	}
	pm, pm_ok := _map_prov_mode(prov_mode)
	if rb == nil || out_sess == nil || !pm_ok {
		return .ERR_INVALID_ARG
	}

	wrap := new(Forseti_Session, context.allocator)
	if wrap == nil {
		return .ERR_ALLOC
	}
	ok_ret := false
	defer if !ok_ret {
		forseti.telemetry_destroy(&wrap.telemetry)
		free(wrap, context.allocator)
	}

	if forseti.telemetry_init(&wrap.telemetry, true, context.allocator) != nil {
		return .ERR_ALLOC
	}

	cfg := forseti.Session_Config{
		provenance_mode = pm,
		max_activations = max_activations,
	}
	if s_err := forseti.session_init(&wrap.sess, &rb.rb, cfg, &wrap.telemetry, context.allocator); s_err != .None {
		return _map_session_err(s_err)
	}

	out_sess^ = wrap
	ok_ret = true
	return .OK
}

@(export)
forseti_session_destroy :: proc "c" (sess: ^Forseti_Session) {
	if sess == nil {
		return
	}
	context = runtime.default_context()
	forseti.session_destroy(&sess.sess)
	forseti.telemetry_destroy(&sess.telemetry)
	free(sess, context.allocator)
}

@(export)
forseti_session_insert_fact :: proc "c" (
	sess: ^Forseti_Session,
	binding: cstring,
	key: cstring,
	fields: [^]Forseti_Value,
	field_count: c.size_t,
	out_fact_id: ^u64,
) -> Forseti_Status {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if sess == nil || binding == nil || key == nil {
		return .ERR_INVALID_ARG
	}
	vals, st := _convert_c_fields(&sess.sess, fields, field_count)
	if st != .OK {
		return st
	}
	fid, err := forseti.session_insert_fact(&sess.sess, string(binding), string(key), vals)
	if err != .None {
		return _map_session_err(err)
	}
	if out_fact_id != nil {
		out_fact_id^ = u64(fid)
	}
	return .OK
}

@(export)
forseti_session_modify_fact :: proc "c" (
	sess: ^Forseti_Session,
	binding: cstring,
	key: cstring,
	fields: [^]Forseti_Value,
	field_count: c.size_t,
) -> Forseti_Status {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if sess == nil || binding == nil || key == nil {
		return .ERR_INVALID_ARG
	}
	vals, st := _convert_c_fields(&sess.sess, fields, field_count)
	if st != .OK {
		return st
	}
	return _map_session_err(forseti.session_modify_fact_by_key(&sess.sess, string(binding), string(key), vals))
}

@(export)
forseti_session_retract_fact :: proc "c" (
	sess: ^Forseti_Session,
	binding: cstring,
	key: cstring,
) -> Forseti_Status {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if sess == nil || binding == nil || key == nil {
		return .ERR_INVALID_ARG
	}
	return _map_session_err(forseti.session_retract_fact_by_key(&sess.sess, string(binding), string(key)))
}

@(export)
forseti_session_retract_fact_id :: proc "c" (
	sess: ^Forseti_Session,
	fact_id: u64,
) -> Forseti_Status {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if sess == nil {
		return .ERR_INVALID_ARG
	}
	return _map_session_err(forseti.session_retract_fact(&sess.sess, forseti.Fact_Id(fact_id)))
}

@(export)
forseti_session_fire :: proc "c" (
	sess: ^Forseti_Session,
	out_fired_count: ^u64,
) -> Forseti_Status {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if sess == nil {
		return .ERR_INVALID_ARG
	}
	cnt, err := forseti.session_fire(&sess.sess)
	if out_fired_count != nil {
		out_fired_count^ = cnt
	}
	return _map_session_err(err)
}

@(private)
_write_json_str :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case:
			if ch < 0x20 {
				fmt.sbprintf(b, `\u%04x`, ch)
			} else {
				strings.write_byte(b, ch)
			}
		}
	}
	strings.write_byte(b, '"')
}

@(private)
_write_query_value_json :: proc(b: ^strings.Builder, s: ^forseti.Session, v: forseti.Value) {
	switch x in v {
	case bool:
		strings.write_string(b, "true" if x else "false")
	case i32:
		fmt.sbprintf(b, "%d", x)
	case i64:
		fmt.sbprintf(b, "%d", x)
	case f64:
		fmt.sbprintf(b, "%v", x)
	case forseti.String_Id:
		_write_json_str(b, forseti.session_string(s, x))
	case forseti.Entity_Id:
		fmt.sbprintf(b, "%d", u64(x))
	case forseti.Time_Ns:
		fmt.sbprintf(b, "%d", i64(x))
	case forseti.Enum_Val:
		strings.write_string(b, `{"enum_id":`)
		fmt.sbprintf(b, "%d", x.enum_id)
		strings.write_string(b, `,"variant":`)
		fmt.sbprintf(b, "%d", x.variant)
		strings.write_byte(b, '}')
	case:
		strings.write_string(b, "null")
	}
}

@(export)
forseti_session_query_json :: proc "c" (
	sess: ^Forseti_Session,
	query_name: cstring,
	arg_names: [^]cstring,
	arg_values: [^]Forseti_Value,
	arg_count: c.size_t,
	out_json: ^cstring,
) -> Forseti_Status {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if out_json != nil {
		out_json^ = nil
	}
	if sess == nil || query_name == nil || out_json == nil {
		return .ERR_INVALID_ARG
	}

	n := int(arg_count)
	args: []forseti.Query_Arg
	if n > 0 {
		if arg_names == nil || arg_values == nil {
			return .ERR_INVALID_ARG
		}
		var_err: mem.Allocator_Error
		args, var_err = make([]forseti.Query_Arg, n, context.temp_allocator)
		if var_err != nil {
			return .ERR_ALLOC
		}
		for i := 0; i < n; i += 1 {
			if arg_names[i] == nil {
				return .ERR_INVALID_ARG
			}
			v, st := _convert_c_value(&sess.sess, arg_values[i])
			if st != .OK {
				return st
			}
			args[i] = forseti.Query_Arg{name = string(arg_names[i]), value = v}
		}
	}

	res: forseti.Query_Result
	if err := forseti.session_query(&sess.sess, string(query_name), args, &res); err != .None {
		return _map_session_err(err)
	}
	defer forseti.query_result_destroy(&res)

	b: strings.Builder
	if _, b_err := strings.builder_init(&b, context.temp_allocator); b_err != nil {
		return .ERR_ALLOC
	}
	strings.write_string(&b, `{"row_count":`)
	fmt.sbprintf(&b, "%d", len(res.rows))
	strings.write_string(&b, `,"rows":[`)
	for row, ri in res.rows {
		if ri > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, `{"fact_ids":[`)
		for fid, fi in row.fact_ids {
			if fi > 0 {
				strings.write_byte(&b, ',')
			}
			fmt.sbprintf(&b, "%d", u32(fid))
		}
		strings.write_string(&b, `],"vars":{`)
		for vname, vi in row.var_names {
			if vi > 0 {
				strings.write_byte(&b, ',')
			}
			_write_json_str(&b, vname)
			strings.write_byte(&b, ':')
			_write_query_value_json(&b, &sess.sess, row.var_values[vi])
		}
		strings.write_string(&b, "}}")
	}
	strings.write_string(&b, "]}")

	return _dup_cstring(strings.to_string(b), out_json)
}

@(export)
forseti_store_open :: proc "c" (
	path: cstring,
	out_store: ^(^Forseti_Store),
) -> Forseti_Status {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if out_store != nil {
		out_store^ = nil
	}
	if out_store == nil {
		return .ERR_INVALID_ARG
	}

	wrap := new(Forseti_Store, context.allocator)
	if wrap == nil {
		return .ERR_ALLOC
	}
	ok_ret := false
	defer if !ok_ret {
		forseti.telemetry_destroy(&wrap.telemetry)
		free(wrap, context.allocator)
	}

	if forseti.telemetry_init(&wrap.telemetry, true, context.allocator) != nil {
		return .ERR_ALLOC
	}

	s_err: forseti.Store_Error
	if path == nil || len(string(path)) == 0 {
		s_err = forseti.store_bridge_init_standalone(&wrap.bridge, forseti.Xitdb_Config{}, &wrap.telemetry, context.allocator)
	} else {
		s_err = forseti.store_bridge_open_file(&wrap.bridge, string(path), forseti.Xitdb_Config{}, &wrap.telemetry, context.allocator)
	}
	if s_err != nil {
		return .ERR_STORE
	}

	out_store^ = wrap
	ok_ret = true
	return .OK
}

@(export)
forseti_store_destroy :: proc "c" (store: ^Forseti_Store) {
	if store == nil {
		return
	}
	context = runtime.default_context()
	forseti.store_bridge_destroy(&store.bridge)
	forseti.telemetry_destroy(&store.telemetry)
	free(store, context.allocator)
}

@(private)
_Store_Put_Ctx :: struct {
	dot_path: string,
	key:      string,
	names:    [^]cstring,
	vals:     [^]Forseti_Value,
	count:    int,
}

@(private)
_store_put_record_cb :: proc(wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ctx := (^_Store_Put_Ctx)(user_data)
	col_map, cm_err := forseti.store_write_path_ensure_map(wc, ctx.dot_path)
	if cm_err != nil {
		return xitdb.Xitdb_Error.Write_Failed
	}
	rec_wc := xitdb.hash_map_put_cursor(&col_map, ctx.key) or_return
	rec_m := xitdb.write_hash_map_init(rec_wc) or_return
	for i := 0; i < ctx.count; i += 1 {
		fname := string(ctx.names[i])
		v := ctx.vals[i]
		#partial switch v.kind {
		case .BOOL:
			if forseti.write_bool_to_hash_map(&rec_m, fname, v.as.b) != nil {
				return xitdb.Xitdb_Error.Write_Failed
			}
		case .I32:
			xitdb.hash_map_put(&rec_m, fname, i64(v.as.i32_val)) or_return
		case .I64, .TIME_NS:
			xitdb.hash_map_put(&rec_m, fname, v.as.i64_val) or_return
		case .F64:
			xitdb.hash_map_put(&rec_m, fname, v.as.f64_val) or_return
		case .STRING:
			xitdb.hash_map_put(&rec_m, fname, _cstr_or_empty(v.as.str)) or_return
		case .ENTITY:
			xitdb.hash_map_put(&rec_m, fname, v.as.entity) or_return
		case:
			return xitdb.Xitdb_Error.Write_Failed
		}
	}
	return nil
}

@(export)
forseti_store_put_record :: proc "c" (
	store: ^Forseti_Store,
	dot_path: cstring,
	key: cstring,
	field_names: [^]cstring,
	field_values: [^]Forseti_Value,
	field_count: c.size_t,
) -> Forseti_Status {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if store == nil || dot_path == nil || key == nil {
		return .ERR_INVALID_ARG
	}
	n := int(field_count)
	if n > 0 && (field_names == nil || field_values == nil) {
		return .ERR_INVALID_ARG
	}
	for i := 0; i < n; i += 1 {
		if field_names[i] == nil {
			return .ERR_INVALID_ARG
		}
	}
	ctx := _Store_Put_Ctx{
		dot_path = string(dot_path),
		key      = string(key),
		names    = field_names,
		vals     = field_values,
		count    = n,
	}
	if _, err := forseti.store_bridge_commit_moment(&store.bridge, _store_put_record_cb, &ctx); err != nil {
		return .ERR_STORE
	}
	return .OK
}

@(export)
forseti_session_sync_and_fire :: proc "c" (
	sess: ^Forseti_Session,
	store: ^Forseti_Store,
	watched_paths: [^]cstring,
	watched_count: c.size_t,
	commit_derived: bool,
	out_fired_count: ^u64,
) -> Forseti_Status {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if sess == nil || store == nil {
		return .ERR_INVALID_ARG
	}
	paths, st := _collect_watched_paths(watched_paths, watched_count)
	if st != .OK {
		return st
	}

	syncer: forseti.Delta_Syncer
	if forseti.delta_syncer_init(&syncer, &sess.telemetry, context.allocator) != nil {
		return .ERR_ALLOC
	}
	defer forseti.delta_syncer_destroy(&syncer)

	for p in paths {
		if forseti.delta_syncer_watch(&syncer, p) != nil {
			return .ERR_STORE
		}
	}

	fired, s_err := forseti.session_sync_and_fire(&sess.sess, &store.bridge, &syncer, commit_derived)
	if out_fired_count != nil {
		out_fired_count^ = fired
	}
	if s_err != nil {
		return .ERR_STORE
	}
	return .OK
}

@(export)
forseti_diff_replay_json :: proc "c" (
	store: ^Forseti_Store,
	baseline_rb: ^Forseti_Rulebase,
	candidate_rb: ^Forseti_Rulebase,
	watched_paths: [^]cstring,
	watched_count: c.size_t,
	out_json: ^cstring,
) -> Forseti_Status {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if out_json != nil {
		out_json^ = nil
	}
	if store == nil || baseline_rb == nil || candidate_rb == nil || out_json == nil {
		return .ERR_INVALID_ARG
	}
	paths, st := _collect_watched_paths(watched_paths, watched_count)
	if st != .OK {
		return st
	}

	rep, r_err := forseti.diff_replay(&store.bridge, &baseline_rb.rb, &candidate_rb.rb, paths, &store.telemetry, context.temp_allocator)
	if r_err != nil {
		return .ERR_STORE
	}
	defer forseti.diff_replay_report_destroy(&rep)

	jstr, j_err := forseti.diff_replay_format_json(&rep, context.temp_allocator)
	if j_err != nil {
		return .ERR_ALLOC
	}
	return _dup_cstring(jstr, out_json)
}

@(export)
forseti_session_diff_replay_json :: proc "c" (
	sess: ^Forseti_Session,
	store: ^Forseti_Store,
	candidate_rb: ^Forseti_Rulebase,
	watched_paths: [^]cstring,
	watched_count: c.size_t,
	out_json: ^cstring,
) -> Forseti_Status {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if out_json != nil {
		out_json^ = nil
	}
	if sess == nil || store == nil || candidate_rb == nil || out_json == nil {
		return .ERR_INVALID_ARG
	}
	paths, st := _collect_watched_paths(watched_paths, watched_count)
	if st != .OK {
		return st
	}

	rep, r_err := forseti.session_diff_replay(&sess.sess, &store.bridge, &candidate_rb.rb, paths, context.temp_allocator, &sess.telemetry)
	if r_err != nil {
		return .ERR_STORE
	}
	defer forseti.diff_replay_report_destroy(&rep)

	jstr, j_err := forseti.diff_replay_format_json(&rep, context.temp_allocator)
	if j_err != nil {
		return .ERR_ALLOC
	}
	return _dup_cstring(jstr, out_json)
}

@(export)
forseti_session_explain_json :: proc "c" (
	sess: ^Forseti_Session,
	fact_id: u64,
	out_json: ^cstring,
) -> Forseti_Status {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if out_json != nil {
		out_json^ = nil
	}
	if sess == nil || out_json == nil {
		return .ERR_INVALID_ARG
	}

	tree := forseti.explain(&sess.sess, forseti.Fact_Id(fact_id), context.temp_allocator)
	defer forseti.explain_tree_destroy(&tree)

	jstr, j_err := forseti.explain_format_json(&tree, context.temp_allocator)
	if j_err != nil {
		return .ERR_ALLOC
	}
	return _dup_cstring(jstr, out_json)
}

@(export)
forseti_session_impact_json :: proc "c" (
	sess: ^Forseti_Session,
	rule_name: cstring,
	rule_version: cstring,
	out_json: ^cstring,
) -> Forseti_Status {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if out_json != nil {
		out_json^ = nil
	}
	if sess == nil || rule_name == nil || out_json == nil {
		return .ERR_INVALID_ARG
	}

	target := string(rule_name)
	rid := max(u32)
	for &r, i in sess.sess.rb.rules {
		if forseti.interner_get(&sess.sess.rb.interner, r.name) == target {
			rid = u32(i)
			break
		}
	}
	if rid == max(u32) {
		return .ERR_UNKNOWN_RULE
	}

	rep := forseti.impact(&sess.sess, rid, _cstr_or_empty(rule_version), context.temp_allocator)
	defer forseti.impact_report_destroy(&rep)

	jstr, j_err := forseti.impact_format_json(&sess.sess, &rep, context.temp_allocator)
	if j_err != nil {
		return .ERR_ALLOC
	}
	return _dup_cstring(jstr, out_json)
}

@(export)
forseti_session_telemetry_jsonl :: proc "c" (
	sess: ^Forseti_Session,
	out_jsonl: ^cstring,
) -> Forseti_Status {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if out_jsonl != nil {
		out_jsonl^ = nil
	}
	if sess == nil || out_jsonl == nil {
		return .ERR_INVALID_ARG
	}

	jstr, j_err := forseti.telemetry_export_jsonl(&sess.telemetry, context.temp_allocator)
	if j_err != nil {
		return .ERR_ALLOC
	}
	return _dup_cstring(jstr, out_jsonl)
}

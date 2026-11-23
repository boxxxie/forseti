package forseti

import "base:runtime"
import "core:reflect"

Typed_Error :: enum u8 {
	None = 0,
	Invalid_Arg,
	Not_Struct,
	Unknown_Binding,
	Unknown_Table,
	Missing_Field,
	Type_Mismatch,
	Alloc_Failed,
	Session_Failed,
}

@(private)
_forseti_field_name :: proc(field: reflect.Struct_Field) -> (name: string, skip: bool) {
	if tag_val, ok := reflect.struct_tag_lookup(field.tag, "forseti"); ok {
		if tag_val == "-" {
			return "", true
		}
		if len(tag_val) > 0 {
			return tag_val, false
		}
	}
	return field.name, false
}

@(private)
_read_struct_field_value :: proc(
	ptr: rawptr,
	ti: ^runtime.Type_Info,
	expected_kind: Type_Kind,
	rb_interner: ^String_Interner,
	sess_interner: ^String_Interner,
	ct: ^Compiled_Table,
) -> (val: Value, err: Typed_Error) {
	if ti == nil {
		return nil, .Type_Mismatch
	}
	if ti == type_info_of(Entity_Id) {
		if expected_kind != .Entity && expected_kind != .Unknown {
			return nil, .Type_Mismatch
		}
		return (^Entity_Id)(ptr)^, .None
	}
	if ti == type_info_of(Time_Ns) {
		if expected_kind != .Time && expected_kind != .I64 && expected_kind != .Unknown {
			return nil, .Type_Mismatch
		}
		return (^Time_Ns)(ptr)^, .None
	}
	if ti == type_info_of(Enum_Val) {
		if expected_kind != .Enum && expected_kind != .Unknown {
			return nil, .Type_Mismatch
		}
		return (^Enum_Val)(ptr)^, .None
	}

	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Boolean:
		if expected_kind != .Bool && expected_kind != .Unknown {
			return nil, .Type_Mismatch
		}
		return (^bool)(ptr)^, .None

	case runtime.Type_Info_Integer:
		if v.signed {
			iv: i64
			switch base.size {
			case 1:
				iv = i64((^i8)(ptr)^)
			case 2:
				iv = i64((^i16)(ptr)^)
			case 4:
				iv = i64((^i32)(ptr)^)
			case 8:
				iv = (^i64)(ptr)^
			case:
				return nil, .Type_Mismatch
			}
			#partial switch expected_kind {
			case .I32:
				if iv < i64(min(i32)) || iv > i64(max(i32)) {
					return nil, .Type_Mismatch
				}
				return i32(iv), .None
			case .I64, .Unknown:
				return iv, .None
			case .Time:
				return Time_Ns(iv), .None
			case .F64:
				return f64(iv), .None
			case:
				return nil, .Type_Mismatch
			}
		} else {
			uv: u64
			switch base.size {
			case 1:
				uv = u64((^u8)(ptr)^)
			case 2:
				uv = u64((^u16)(ptr)^)
			case 4:
				uv = u64((^u32)(ptr)^)
			case 8:
				uv = (^u64)(ptr)^
			case:
				return nil, .Type_Mismatch
			}
			#partial switch expected_kind {
			case .Entity:
				return Entity_Id(uv), .None
			case .I64, .Unknown:
				if uv > u64(max(i64)) {
					return nil, .Type_Mismatch
				}
				return i64(uv), .None
			case:
				return nil, .Type_Mismatch
			}
		}

	case runtime.Type_Info_Float:
		if expected_kind != .F64 && expected_kind != .Unknown {
			return nil, .Type_Mismatch
		}
		switch base.size {
		case 4:
			return f64((^f32)(ptr)^), .None
		case 8:
			return (^f64)(ptr)^, .None
		}
		return nil, .Type_Mismatch

	case runtime.Type_Info_String:
		if v.is_cstring {
			return nil, .Type_Mismatch
		}
		if expected_kind != .String && expected_kind != .Enum && expected_kind != .Unknown {
			return nil, .Type_Mismatch
		}
		s := (^string)(ptr)^
		if ct != nil {
			return compiled_table_string_value(ct, s), .None
		}
		sid, i_err := intern_session_string(rb_interner, sess_interner, s)
		if i_err != nil {
			return nil, .Alloc_Failed
		}
		return sid, .None
	}
	return nil, .Type_Mismatch
}

@(private)
_write_struct_field_value :: proc(
	ptr: rawptr,
	ti: ^runtime.Type_Info,
	val: Value,
	sess: ^Session,
	ct: ^Compiled_Table,
) -> Typed_Error {
	if ti == nil {
		return .Type_Mismatch
	}
	if ti == type_info_of(Entity_Id) {
		if e, ok := val.(Entity_Id); ok {
			(^Entity_Id)(ptr)^ = e
			return .None
		}
		return .Type_Mismatch
	}
	if ti == type_info_of(Time_Ns) {
		#partial switch x in val {
		case Time_Ns:
			(^Time_Ns)(ptr)^ = x
			return .None
		case i64:
			(^Time_Ns)(ptr)^ = Time_Ns(x)
			return .None
		case:
			return .Type_Mismatch
		}
	}
	if ti == type_info_of(Enum_Val) {
		if ev, ok := val.(Enum_Val); ok {
			(^Enum_Val)(ptr)^ = ev
			return .None
		}
		return .Type_Mismatch
	}

	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Boolean:
		b, ok := val.(bool)
		if !ok {
			return .Type_Mismatch
		}
		(^bool)(ptr)^ = b
		return .None

	case runtime.Type_Info_Integer:
		iv, ok := value_to_i64(val)
		if !ok {
			if eid, eok := val.(Entity_Id); eok && !v.signed && base.size == 8 {
				(^u64)(ptr)^ = u64(eid)
				return .None
			}
			return .Type_Mismatch
		}
		if v.signed {
			switch base.size {
			case 4:
				if iv < i64(min(i32)) || iv > i64(max(i32)) {
					return .Type_Mismatch
				}
				(^i32)(ptr)^ = i32(iv)
				return .None
			case 8:
				(^i64)(ptr)^ = iv
				return .None
			}
		} else if iv >= 0 && base.size == 8 {
			(^u64)(ptr)^ = u64(iv)
			return .None
		}
		return .Type_Mismatch

	case runtime.Type_Info_Float:
		fv, ok := value_to_f64(val)
		if !ok {
			return .Type_Mismatch
		}
		switch base.size {
		case 4:
			(^f32)(ptr)^ = f32(fv)
			return .None
		case 8:
			(^f64)(ptr)^ = fv
			return .None
		}
		return .Type_Mismatch

	case runtime.Type_Info_String:
		if v.is_cstring {
			return .Type_Mismatch
		}
		sid, ok := val.(String_Id)
		if !ok {
			return .Type_Mismatch
		}
		if ct != nil {
			(^string)(ptr)^ = compiled_table_output_string(ct, val)
			return .None
		}
		if sess != nil {
			(^string)(ptr)^ = session_string(sess, sid)
			return .None
		}
		return .Type_Mismatch
	}
	return .Type_Mismatch
}

@(private)
_pack_struct_fact_fields :: proc(
	s: ^Session,
	bidx: u16,
	item: $T,
	out_vals: []Value,
) -> Typed_Error {
	if !reflect.is_struct(type_info_of(T)) {
		return .Not_Struct
	}
	bdef := s.rb.bindings[bidx]
	schema := s.rb.schemas[bdef.schema_id]
	if len(schema.fields) > len(out_vals) {
		return .Invalid_Arg
	}

	local_item := item
	base_ptr := uintptr(&local_item)
	matched_mask: [64]bool

	for sf in reflect.struct_fields_zipped(T) {
		fname, skip := _forseti_field_name(sf)
		if skip {
			continue
		}
		for sch_f, fi in schema.fields {
			if interner_get(&s.rb.interner, sch_f.name) == fname {
				val, r_err := _read_struct_field_value(
					rawptr(base_ptr + sf.offset),
					sf.type,
					sch_f.type.kind,
					&s.rb.interner,
					&s.interner,
					nil,
				)
				if r_err != .None {
					return r_err
				}
				out_vals[fi] = val
				matched_mask[fi] = true
				break
			}
		}
	}

	for fi in 0 ..< len(schema.fields) {
		if !matched_mask[fi] {
			return .Missing_Field
		}
	}
	return .None
}

// Inserts a fact into `s` from a typed Odin struct using `forseti:"..."` field tags (or field names).
session_insert_struct :: proc(
	s: ^Session,
	binding_name: string,
	key: string,
	item: $T,
	origin: Fact_Origin = .External,
) -> (fid: Fact_Id, err: Typed_Error) {
	if s == nil || s.rb == nil {
		return INVALID_FACT, .Invalid_Arg
	}
	bidx, ok := session_find_binding(s, binding_name)
	if !ok {
		return INVALID_FACT, .Unknown_Binding
	}
	schema := s.rb.schemas[s.rb.bindings[bidx].schema_id]
	vals_buf: [64]Value
	if err = _pack_struct_fact_fields(s, bidx, item, vals_buf[:]); err != .None {
		return INVALID_FACT, err
	}
	s_err: Session_Error
	fid, s_err = session_insert_fact_by_idx(s, bidx, key, vals_buf[:len(schema.fields)], origin)
	if s_err != .None {
		return INVALID_FACT, .Alloc_Failed if s_err == .Alloc_Failed else .Session_Failed
	}
	return fid, .None
}

// Modifies an existing fact by key in `s` from a typed Odin struct.
session_modify_struct :: proc(
	s: ^Session,
	binding_name: string,
	key: string,
	item: $T,
) -> Typed_Error {
	if s == nil || s.rb == nil {
		return .Invalid_Arg
	}
	bidx, ok := session_find_binding(s, binding_name)
	if !ok {
		return .Unknown_Binding
	}
	schema := s.rb.schemas[s.rb.bindings[bidx].schema_id]
	vals_buf: [64]Value
	if err := _pack_struct_fact_fields(s, bidx, item, vals_buf[:]); err != .None {
		return err
	}
	s_err := session_modify_fact_by_key(s, binding_name, key, vals_buf[:len(schema.fields)])
	if s_err != .None {
		return .Alloc_Failed if s_err == .Alloc_Failed else .Session_Failed
	}
	return .None
}

// Evaluates `ct` using tagged Odin struct `input` and writes winning outputs into `out`.
// String fields written into `out` borrow `ct.interner` storage.
decide_table_struct :: proc(
	ct: ^Compiled_Table,
	input: $In,
	out: ^$Out,
) -> (matched: bool, err: Typed_Error) {
	if ct == nil || out == nil {
		return false, .Invalid_Arg
	}
	if !reflect.is_struct(type_info_of(In)) || !reflect.is_struct(type_info_of(Out)) {
		return false, .Not_Struct
	}
	if ct.col_count > 64 {
		return false, .Invalid_Arg
	}

	in_copy := input
	in_ptr := uintptr(&in_copy)
	in_vals: [64]Value
	in_seen: [64]bool

	for sf in reflect.struct_fields_zipped(In) {
		fname, skip := _forseti_field_name(sf)
		if skip {
			continue
		}
		for ci in 0 ..< ct.col_count {
			if compiled_table_string(ct, ct.col_names[ci]) == fname {
				val, r_err := _read_struct_field_value(
					rawptr(in_ptr + sf.offset),
					sf.type,
					ct.col_types[ci].kind,
					nil,
					nil,
					ct,
				)
				if r_err != .None {
					return false, r_err
				}
				in_vals[ci] = val
				in_seen[ci] = true
				break
			}
		}
	}
	for ci in 0 ..< ct.col_count {
		if !in_seen[ci] {
			return false, .Missing_Field
		}
	}

	res := decide_values(ct, in_vals[:ct.col_count])
	if !res.matched {
		return false, .None
	}

	out^ = {}
	out_ptr := uintptr(out)
	for sf in reflect.struct_fields_zipped(Out) {
		fname, skip := _forseti_field_name(sf)
		if skip {
			continue
		}
		for oi in 0 ..< ct.out_count {
			if oi >= len(ct.out_names) || !res.output_set[oi] {
				continue
			}
			if compiled_table_string(ct, ct.out_names[oi]) == fname {
				w_err := _write_struct_field_value(rawptr(out_ptr + sf.offset), sf.type, res.outputs[oi], nil, ct)
				if w_err != .None {
					return false, w_err
				}
				break
			}
		}
	}
	return true, .None
}

// Evaluates a named decision table inside `rb` using typed Odin input/output structs.
decide_struct :: proc(
	rb: ^Rulebase,
	table_name: string,
	input: $In,
	out: ^$Out,
) -> (matched: bool, err: Typed_Error) {
	if rb == nil || out == nil {
		return false, .Invalid_Arg
	}
	if tid, ok := rb.interner.lookup[table_name]; ok {
		if tbl_idx, has_t := rb.table_by_name[tid]; has_t && int(tbl_idx) < len(rb.tables) {
			return decide_table_struct(&rb.tables[tbl_idx], input, out)
		}
	}
	return false, .Unknown_Table
}

// Projects rows from `res` into typed Odin structs inside `out_rows`.
// String fields borrow `s` / `res` storage while both remain alive.
query_unmarshal :: proc(
	s: ^Session,
	res: ^Query_Result,
	out_rows: ^[dynamic]$T,
) -> Typed_Error {
	if s == nil || res == nil || out_rows == nil {
		return .Invalid_Arg
	}
	if !reflect.is_struct(type_info_of(T)) {
		return .Not_Struct
	}

	clear(out_rows)
	for &row in res.rows {
		item: T
		base_ptr := uintptr(&item)
		for sf in reflect.struct_fields_zipped(T) {
			fname, skip := _forseti_field_name(sf)
			if skip {
				continue
			}
			for vn, vi in row.var_names {
				vn_norm := vn[1:] if len(vn) > 1 && vn[0] == '?' && fname[0] != '?' else vn
				if vn_norm == fname {
					w_err := _write_struct_field_value(rawptr(base_ptr + sf.offset), sf.type, row.var_values[vi], s, nil)
					if w_err != .None {
						return w_err
					}
					break
				}
			}
		}
		if _, a_err := append(out_rows, item); a_err != nil {
			return .Alloc_Failed
		}
	}
	return .None
}

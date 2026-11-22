package forseti

import "core:encoding/endian"
import xitdb "xitdb:."

@(rodata)
BOOL_FORMAT_TAG := [2]u8{'b', 'l'}

@(rodata)
_BOOL_TRUE_BYTES := [1]u8{'1'}

@(rodata)
_BOOL_FALSE_BYTES := [1]u8{'0'}

write_bool_to_hash_map :: proc(m: ^xitdb.Write_Hash_Map, key: string, val: bool) -> Store_Error {
	raw := _BOOL_TRUE_BYTES[:] if val else _BOOL_FALSE_BYTES[:]
	data := xitdb.new_tagged_bytes(raw, BOOL_FORMAT_TAG[:])
	if err := xitdb.hash_map_put(m, key, data); err != nil {
		return xitdb_to_store_err(err)
	}
	return nil
}

write_bool_to_hash_map_prehashed :: proc(m: ^xitdb.Write_Hash_Map, pk: ^Prehashed_Key, val: bool) -> Store_Error {
	raw := _BOOL_TRUE_BYTES[:] if val else _BOOL_FALSE_BYTES[:]
	data := xitdb.new_tagged_bytes(raw, BOOL_FORMAT_TAG[:])
	if err := hash_map_put_prehashed(m, pk, data); err != nil {
		return xitdb_to_store_err(err)
	}
	return nil
}

// Converts a Forseti Value to xitdb Writeable_Data (bool encodes inline as 9-byte Short_Bytes with "bl" format tag).
value_to_writeable_data :: proc(
	val: Value,
	interner: ^String_Interner,
) -> (data: xitdb.Writeable_Data, ok: bool, err: Store_Error) {
	switch v in val {
	case bool:
		raw := _BOOL_TRUE_BYTES[:] if v else _BOOL_FALSE_BYTES[:]
		return xitdb.new_tagged_bytes(raw, BOOL_FORMAT_TAG[:]), true, nil
	case i32:
		return i64(v), true, nil
	case i64:
		return v, true, nil
	case f64:
		return v, true, nil
	case String_Id:
		if interner == nil && v != EMPTY_STRING {
			return nil, false, .Invalid_Config
		}
		return interner_get(interner, v), true, nil
	case Entity_Id:
		return u64(v), true, nil
	case Time_Ns:
		return i64(v), true, nil
	case Enum_Val:
		return i64(v.variant), true, nil
	}
	return nil, false, nil
}

// Decodes a 9-byte xitdb Slot directly into Forseti's 16-byte Value without heap allocation for scalars or pre-interned Short_Bytes.
decode_slot_to_value :: proc(
	db: ^xitdb.Database,
	slot: xitdb.Slot,
	interner: ^String_Interner,
	expected_type: Type_Kind = .Unknown,
) -> (val: Value, found: bool, err: Store_Error) {
	#partial switch slot.tag {
	case .None:
		return {}, false, nil

	case .Int:
		#partial switch expected_type {
		case .I32:
			if slot.value < i64(min(i32)) || slot.value > i64(max(i32)) {
				return nil, false, .Unsupported_Value_Type
			}
			return i32(slot.value), true, nil
		case .Time:
			return Time_Ns(slot.value), true, nil
		case:
			return slot.value, true, nil
		}

	case .Uint:
		u := u64(slot.value)
		#partial switch expected_type {
		case .Entity:
			return Entity_Id(u), true, nil
		case .Time:
			if u > u64(max(i64)) {
				return nil, false, .Unsupported_Value_Type
			}
			return Time_Ns(i64(u)), true, nil
		case .I32:
			if u > u64(max(i32)) {
				return nil, false, .Unsupported_Value_Type
			}
			return i32(u), true, nil
		case:
			if u > u64(max(i64)) {
				return nil, false, .Unsupported_Value_Type
			}
			return i64(u), true, nil
		}

	case .Float:
		return transmute(f64)slot.value, true, nil

	case .Short_Bytes:
		buf: [8]u8 = ---
		endian.unchecked_put_u64be(buf[:], u64(slot.value))
		total_size := 6 if slot.full else 8
		n := 0
		for n < total_size && buf[n] != 0 {
			n += 1
		}
		if slot.full && buf[6] == BOOL_FORMAT_TAG[0] && buf[7] == BOOL_FORMAT_TAG[1] {
			is_true := n > 0 && buf[0] != '0' && buf[0] != 0
			return is_true, true, nil
		}
		s := string(buf[:n])
		if interner == nil {
			if n == 0 {
				return EMPTY_STRING, true, nil
			}
			return {}, false, .Invalid_Config
		}
		sid, i_err := intern(interner, s)
		if i_err != nil {
			return {}, false, i_err
		}
		return sid, true, nil

	case .Bytes:
		if db == nil {
			return {}, false, .Invalid_Config
		}
		if slot.value < 0 {
			return {}, false, xitdb.Xitdb_Error.Expected_Unsigned_Long
		}
		byte_len, len_err := xitdb.core_read_long_at(db.core, slot.value)
		if len_err != nil {
			return {}, false, xitdb_to_store_err(len_err)
		}
		if byte_len < 0 {
			return {}, false, xitdb.Xitdb_Error.Expected_Unsigned_Long
		}
		if byte_len <= 256 {
			stack_buf: [258]u8 = ---
			read_n := int(byte_len) + (2 if slot.full else 0)
			if r_err := xitdb.core_read_exact_at(db.core, slot.value + 8, stack_buf[:read_n]); r_err != nil {
				return {}, false, xitdb_to_store_err(r_err)
			}
			if slot.full && stack_buf[byte_len] == BOOL_FORMAT_TAG[0] && stack_buf[byte_len + 1] == BOOL_FORMAT_TAG[1] {
				return byte_len > 0 && stack_buf[0] != '0' && stack_buf[0] != 0, true, nil
			}
			if interner == nil {
				if byte_len == 0 {
					return EMPTY_STRING, true, nil
				}
				return {}, false, .Invalid_Config
			}
			sid, i_err := intern(interner, string(stack_buf[:byte_len]))
			if i_err != nil {
				return {}, false, i_err
			}
			return sid, true, nil
		}
		if interner == nil {
			return {}, false, .Invalid_Config
		}
		raw, r_err := xitdb.cursor_read_bytes(
			xitdb.Read_Cursor{slot_ptr = xitdb.Slot_Pointer{slot = slot}, db = db},
			0,
			context.allocator,
		)
		if r_err != nil {
			return {}, false, xitdb_to_store_err(r_err)
		}
		defer delete(raw)
		sid, i_err := intern(interner, string(raw))
		if i_err != nil {
			return {}, false, i_err
		}
		return sid, true, nil
	}

	return {}, false, .Unsupported_Value_Type
}

cursor_read_value :: proc(
	cur: xitdb.Read_Cursor,
	interner: ^String_Interner,
	expected_type: Type_Kind = .Unknown,
) -> (val: Value, found: bool, err: Store_Error) {
	sp, sp_err := xitdb.cursor_resolved(cur)
	if sp_err != nil {
		return {}, false, xitdb_to_store_err(sp_err)
	}
	return decode_slot_to_value(cur.db, sp.slot, interner, expected_type)
}

// Lazily projects a nested field path (e.g. `{"address", "country"}` or `{"locked_fields", "domain"}`)
// on a record Read_Cursor without copying or decoding sibling fields.
cursor_read_field_path :: proc(
	record_cur: xitdb.Read_Cursor,
	fields: []string,
	interner: ^String_Interner,
	expected_type: Type_Kind = .Unknown,
) -> (val: Value, found: bool, err: Store_Error) {
	cur := record_cur
	for i := 0; i < len(fields); i += 1 {
		sp, sp_err := xitdb.cursor_resolved(cur)
		if sp_err != nil {
			return {}, false, xitdb_to_store_err(sp_err)
		}
		is_last := i == len(fields) - 1
		#partial switch sp.slot.tag {
		case .None:
			return {}, false, nil
		case .Hash_Set, .Counted_Hash_Set:
			if !is_last {
				return {}, false, .Not_A_Collection
			}
			hs := xitdb.Read_Hash_Set{cursor = cur}
			mc, g_err := xitdb.hash_set_get_slot(hs, fields[i])
			if g_err != nil {
				return {}, false, xitdb_to_store_err(g_err)
			}
			_, present := mc.?
			return Value(present), true, nil
		case .Sorted_Set:
			if !is_last {
				return {}, false, .Not_A_Collection
			}
			ss := xitdb.Read_Sorted_Set{cursor = cur}
			present, c_err := xitdb.sorted_set_contains(ss, fields[i])
			if c_err != nil {
				return {}, false, xitdb_to_store_err(c_err)
			}
			return Value(present), true, nil
		case .Hash_Map, .Counted_Hash_Map:
			rm := xitdb.Read_Hash_Map{cursor = cur}
			mc, g_err := xitdb.hash_map_get_cursor(rm, fields[i])
			if g_err != nil {
				return {}, false, xitdb_to_store_err(g_err)
			}
			next_cur, ok := mc.?
			if !ok {
				return {}, false, nil
			}
			cur = next_cur
		case .Sorted_Map:
			sm := xitdb.Read_Sorted_Map{cursor = cur}
			mc, g_err := xitdb.sorted_map_get_cursor(sm, fields[i])
			if g_err != nil {
				return {}, false, xitdb_to_store_err(g_err)
			}
			next_cur, ok := mc.?
			if !ok {
				return {}, false, nil
			}
			cur = next_cur
		case:
			return {}, false, .Not_A_Collection
		}
	}
	return cursor_read_value(cur, interner, expected_type)
}

// Walks pre-hashed static path segments on a record cursor, reading leaf slots directly
// without runtime string hashing or redundant Read_Cursor construction.
cursor_read_field_path_prehashed :: proc(
	record_cur: xitdb.Read_Cursor,
	keys: []Prehashed_Key,
	interner: ^String_Interner,
	expected_type: Type_Kind = .Unknown,
) -> (val: Value, found: bool, err: Store_Error) {
	cur := record_cur
	for i := 0; i < len(keys); i += 1 {
		pk := &keys[i]
		sp, sp_err := xitdb.cursor_resolved(cur)
		if sp_err != nil {
			return {}, false, xitdb_to_store_err(sp_err)
		}
		is_last := i == len(keys) - 1
		#partial switch sp.slot.tag {
		case .None:
			return {}, false, nil
		case .Hash_Set, .Counted_Hash_Set:
			if !is_last {
				return {}, false, .Not_A_Collection
			}
			hs := xitdb.Read_Hash_Set{cursor = cur}
			mc, g_err := hash_set_get_slot_prehashed(hs, pk)
			if g_err != nil {
				return {}, false, xitdb_to_store_err(g_err)
			}
			_, present := mc.?
			return Value(present), true, nil
		case .Sorted_Set:
			if !is_last {
				return {}, false, .Not_A_Collection
			}
			ss := xitdb.Read_Sorted_Set{cursor = cur}
			present, c_err := xitdb.sorted_set_contains(ss, pk.key)
			if c_err != nil {
				return {}, false, xitdb_to_store_err(c_err)
			}
			return Value(present), true, nil
		case .Hash_Map, .Counted_Hash_Map:
			rm := xitdb.Read_Hash_Map{cursor = cur}
			if is_last {
				ms, s_err := hash_map_get_slot_prehashed(rm, pk)
				if s_err != nil {
					return {}, false, xitdb_to_store_err(s_err)
				}
				slot, ok := ms.?
				if !ok {
					return {}, false, nil
				}
				return decode_slot_to_value(cur.db, slot, interner, expected_type)
			}
			mc, g_err := hash_map_get_cursor_prehashed(rm, pk)
			if g_err != nil {
				return {}, false, xitdb_to_store_err(g_err)
			}
			next_cur, ok := mc.?
			if !ok {
				return {}, false, nil
			}
			cur = next_cur
		case .Sorted_Map:
			sm := xitdb.Read_Sorted_Map{cursor = cur}
			mc, g_err := xitdb.sorted_map_get_cursor(sm, pk.key)
			if g_err != nil {
				return {}, false, xitdb_to_store_err(g_err)
			}
			next_cur, ok := mc.?
			if !ok {
				return {}, false, nil
			}
			cur = next_cur
		case:
			return {}, false, .Not_A_Collection
		}
	}
	return cursor_read_value(cur, interner, expected_type)
}

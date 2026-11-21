package forseti

import "base:runtime"
import "core:bytes"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import xitdb "xitdb:."

// Xitdb_Mode selects between wire-compatible crash-safe defaults and opt-in trusted in-memory speedups.
Xitdb_Mode :: enum u8 {
	Safe_V2,
	Fast_Memory,
}

// Xitdb_Config configures xitdb initialization guardrails and opt-in fast-memory features.
Xitdb_Config :: struct {
	mode:            Xitdb_Mode,
	custom_hasher:   xitdb.Hasher,
	skip_memory_crc: bool,
}

Store_Mode :: enum u8 {
	Standalone_Memory,
	Managed_Buffered_File,
	Attached,
}

Store_Bridge_Error :: enum u8 {
	None = 0,
	Empty_Path,
	Moment_Missing,
	Disk_Fast_Mode_Forbidden,
	Not_A_Collection,
	Unsupported_Value_Type,
	Invalid_Config,
}

Store_Error :: union #shared_nil {
	Store_Bridge_Error,
	xitdb.Xitdb_Error,
	os.Error,
	io.Error,
	mem.Allocator_Error,
}

// Store_Bridge adapts xitdb moments and collections for Forseti.
// Pinned handle (internal self-pointers): initialize in-place or heap-allocate via new(Store_Bridge) and never copy by value.
Store_Bridge :: struct {
	mode:       Store_Mode,
	cfg:        Xitdb_Config,
	owns_core:  bool,
	owns_db:    bool,
	close_file: bool,
	owned_core: xitdb.Core,
	owned_db:   xitdb.Database,
	db:         ^xitdb.Database,
	telemetry:  ^Telemetry_Sink,
	allocator:  runtime.Allocator,
}

xitdb_to_store_err :: #force_inline proc "contextless" (err: xitdb.Error) -> Store_Error {
	if err == nil {
		return nil
	}
	switch v in err {
	case xitdb.Xitdb_Error:
		return v
	case os.Error:
		return v
	case io.Error:
		return v
	}
	return nil
}

@(private)
_core_has_disk_backing :: proc(core: ^xitdb.Core) -> bool {
	c := core
	for c != nil {
		switch &v in c {
		case xitdb.Core_Memory:
			return false
		case xitdb.Core_File, xitdb.Core_Buffered_File:
			return true
		case xitdb.Core_Overlay:
			c = v.base
		}
	}
	return true
}

@(private)
_resolve_xitdb_hasher_and_opts :: proc(
	cfg: Xitdb_Config,
	is_disk: bool,
) -> (h: xitdb.Hasher, opts: xitdb.Database_Options, err: Store_Error) {
	if is_disk {
		if cfg.mode == .Fast_Memory || cfg.custom_hasher.id == xitdb.FAST_HASH_ID {
			return {}, {}, .Disk_Fast_Mode_Forbidden
		}
		if cfg.skip_memory_crc {
			return {}, {}, .Invalid_Config
		}
	}

	switch cfg.mode {
	case .Safe_V2:
		if cfg.skip_memory_crc || cfg.custom_hasher.id == xitdb.FAST_HASH_ID {
			return {}, {}, .Invalid_Config
		}
		h = cfg.custom_hasher if cfg.custom_hasher.hash_proc != nil else xitdb.sha1_hasher()
		opts = xitdb.Database_Options{skip_memory_crc = false}
	case .Fast_Memory:
		h = cfg.custom_hasher if cfg.custom_hasher.hash_proc != nil else xitdb.fast_hasher()
		opts = xitdb.Database_Options{skip_memory_crc = cfg.skip_memory_crc}
	}
	return h, opts, nil
}

// Initializes an in-memory xitdb store inside `b` (never move `b` after calling).
store_bridge_init_standalone :: proc(
	b: ^Store_Bridge,
	cfg := Xitdb_Config{},
	telemetry: ^Telemetry_Sink = nil,
	allocator := context.allocator,
) -> Store_Error {
	if b == nil {
		return .Invalid_Config
	}
	h, opts, r_err := _resolve_xitdb_hasher_and_opts(cfg, is_disk = false)
	if r_err != nil {
		return r_err
	}

	b^ = Store_Bridge{
		mode      = .Standalone_Memory,
		cfg       = cfg,
		owns_core = true,
		owns_db   = true,
		telemetry = telemetry,
		allocator = allocator,
	}
	b.owned_core = xitdb.core_memory_init(allocator)
	db, db_err := xitdb.database_init_with_options(&b.owned_core, h, opts)
	if db_err != nil {
		_ = xitdb.core_destroy(&b.owned_core)
		b^ = {}
		return xitdb_to_store_err(db_err)
	}
	b.owned_db = db
	b.owned_db.core = &b.owned_core
	b.db = &b.owned_db
	return nil
}

// Opens or initializes a disk-backed Core_Buffered_File store inside `b` (always enforces Safe_V2 guardrails).
store_bridge_open_file :: proc(
	b: ^Store_Bridge,
	path: string,
	cfg := Xitdb_Config{},
	telemetry: ^Telemetry_Sink = nil,
	allocator := context.allocator,
) -> Store_Error {
	if b == nil || len(path) == 0 {
		return .Invalid_Config if b == nil else .Empty_Path
	}
	h, opts, r_err := _resolve_xitdb_hasher_and_opts(cfg, is_disk = true)
	if r_err != nil {
		return r_err
	}

	core, c_err := xitdb.core_buffered_file_open(path, xitdb.DEFAULT_BUFFER_SIZE, {.Read, .Write, .Create}, true, allocator)
	if c_err != nil {
		return xitdb_to_store_err(c_err)
	}

	b^ = Store_Bridge{
		mode       = .Managed_Buffered_File,
		cfg        = cfg,
		owns_core  = true,
		owns_db    = true,
		close_file = true,
		owned_core = core,
		telemetry  = telemetry,
		allocator  = allocator,
	}
	db, db_err := xitdb.database_init_with_options(&b.owned_core, h, opts)
	if db_err != nil {
		_ = xitdb.core_destroy(&b.owned_core, close_file = true)
		b^ = {}
		return xitdb_to_store_err(db_err)
	}
	b.owned_db = db
	b.owned_db.core = &b.owned_core
	b.db = &b.owned_db
	return nil
}

// Attaches `b` to an existing caller-owned `xitdb.Database` without taking ownership.
store_bridge_init_attached :: proc(
	b: ^Store_Bridge,
	db: ^xitdb.Database,
	cfg := Xitdb_Config{},
	telemetry: ^Telemetry_Sink = nil,
) -> Store_Error {
	if b == nil || db == nil || db.core == nil {
		return .Invalid_Config
	}
	is_disk := _core_has_disk_backing(db.core)
	_, _, r_err := _resolve_xitdb_hasher_and_opts(cfg, is_disk)
	if r_err != nil {
		return r_err
	}

	b^ = Store_Bridge{
		mode      = .Attached,
		cfg       = cfg,
		owns_core = false,
		owns_db   = false,
		db        = db,
		telemetry = telemetry,
	}
	return nil
}

store_bridge_destroy :: proc(b: ^Store_Bridge) {
	if b == nil {
		return
	}
	if b.owns_core {
		_ = xitdb.core_destroy(&b.owned_core, close_file = b.close_file)
	}
	b^ = {}
}

// Compacts an owned in-memory database into a fresh single-moment Core_Memory, swapping in-place.
store_bridge_compact :: proc(b: ^Store_Bridge) -> Store_Error {
	if b == nil || b.db == nil || !b.owns_core || !b.owns_db || b.mode != .Standalone_Memory {
		return .Invalid_Config
	}
	alloc := b.allocator if b.allocator.procedure != nil else context.allocator
	new_core := xitdb.core_memory_init(alloc)
	new_db, c_err := xitdb.database_compact(b.db, &new_core)
	if c_err != nil {
		_ = xitdb.core_destroy(&new_core)
		return xitdb_to_store_err(c_err)
	}

	old_core := b.owned_core
	b.owned_core = new_core
	b.owned_db = new_db
	b.owned_db.core = &b.owned_core
	b.db = &b.owned_db
	_ = xitdb.core_destroy(&old_core)
	return nil
}

store_bridge_moment_count :: proc(b: ^Store_Bridge) -> (count: i64, err: Store_Error) {
	if b == nil || b.db == nil {
		return 0, .Invalid_Config
	}
	rc := xitdb.database_root_cursor(b.db)
	root_slot, rs_err := xitdb.cursor_slot(rc.read_cursor)
	if rs_err != nil {
		return 0, xitdb_to_store_err(rs_err)
	}
	#partial switch root_slot.tag {
	case .None:
		return 0, nil
	case .Array_List:
		hist, h_err := xitdb.read_array_list_init(rc.read_cursor)
		if h_err != nil {
			return 0, xitdb_to_store_err(h_err)
		}
		cnt, c_err := xitdb.array_list_count(hist)
		if c_err != nil {
			return 0, xitdb_to_store_err(c_err)
		}
		return cnt, nil
	case:
		return 1, nil
	}
}

store_bridge_moment_cursor :: proc(
	b: ^Store_Bridge,
	moment_idx: i64 = -1,
) -> (cur: xitdb.Read_Cursor, ok: bool, err: Store_Error) {
	if b == nil || b.db == nil {
		return {}, false, .Invalid_Config
	}
	rc := xitdb.database_root_cursor(b.db)
	root_slot, rs_err := xitdb.cursor_slot(rc.read_cursor)
	if rs_err != nil {
		return {}, false, xitdb_to_store_err(rs_err)
	}
	#partial switch root_slot.tag {
	case .None:
		return {}, false, nil
	case .Array_List:
		hist, h_err := xitdb.read_array_list_init(rc.read_cursor)
		if h_err != nil {
			return {}, false, xitdb_to_store_err(h_err)
		}
		cnt, c_err := xitdb.array_list_count(hist)
		if c_err != nil {
			return {}, false, xitdb_to_store_err(c_err)
		}
		if cnt == 0 {
			return {}, false, nil
		}
		target := moment_idx
		if target < 0 {
			target = cnt + target
		}
		if target < 0 || target >= cnt {
			return {}, false, nil
		}
		mc, g_err := xitdb.array_list_get_cursor(hist, target)
		if g_err != nil {
			return {}, false, xitdb_to_store_err(g_err)
		}
		res, has := mc.?
		return res, has, nil
	case:
		if moment_idx == 0 || moment_idx == -1 {
			return rc.read_cursor, true, nil
		}
		return {}, false, nil
	}
}

// Appends a structurally-shared moment derived from the latest moment and runs `fn` inside a single atomic transaction.
store_bridge_commit_moment :: proc(
	b: ^Store_Bridge,
	fn: xitdb.Context_Function,
	user_data: rawptr = nil,
) -> (moment_idx: i64, err: Store_Error) {
	if b == nil || b.db == nil || fn == nil {
		return -1, .Invalid_Config
	}
	span := telemetry_span_begin(b.telemetry, .Commit, "moment_commit")
	defer telemetry_span_end(b.telemetry, span)

	rc := xitdb.database_root_cursor(b.db)
	history, h_err := xitdb.write_array_list_init(rc)
	if h_err != nil {
		return -1, xitdb_to_store_err(h_err)
	}
	cnt, c_err := xitdb.array_list_count(history.read_array_list)
	if c_err != nil {
		return -1, xitdb_to_store_err(c_err)
	}
	base_slot := xitdb.Slot{}
	if cnt > 0 {
		sm, s_err := xitdb.array_list_get_slot(history.read_array_list, cnt - 1)
		if s_err != nil {
			return -1, xitdb_to_store_err(s_err)
		}
		if s, ok := sm.?; ok {
			base_slot = s
		}
	}
	if tx_err := xitdb.array_list_append_context(&history, base_slot, fn, user_data); tx_err != nil {
		return -1, xitdb_to_store_err(tx_err)
	}
	return cnt, nil
}

// Splits `dot_path` lazily without allocating (`".orgs.raw"` -> next segment iterator).
@(private)
_next_path_segment :: proc(rest: ^string) -> (seg: string, ok: bool) {
	for len(rest^) > 0 {
		idx := strings.index_byte(rest^, '.')
		if idx < 0 {
			seg = rest^
			rest^ = ""
		} else {
			seg = rest^[:idx]
			rest^ = rest^[idx + 1:]
		}
		if len(seg) > 0 {
			return seg, true
		}
	}
	return "", false
}

// Resolves a dotted collection path (e.g. `.orgs.raw` or `.facts.eav`) relative to `moment_cur`.
store_resolve_path :: proc(
	moment_cur: xitdb.Read_Cursor,
	dot_path: string,
) -> (cur: xitdb.Read_Cursor, found: bool, err: Store_Error) {
	cur = moment_cur
	rest := dot_path
	for {
		seg, has := _next_path_segment(&rest)
		if !has {
			return cur, true, nil
		}
		next_cur, next_ok, l_err := store_lookup_record(cur, seg)
		if l_err != nil {
			return {}, false, l_err
		}
		if !next_ok {
			return {}, false, nil
		}
		cur = next_cur
	}
}

// Looks up a key inside a map-like xitdb cursor (`Hash_Map`, `Counted_Hash_Map`, `Sorted_Map`, or sets).
store_lookup_record :: proc(
	col_cur: xitdb.Read_Cursor,
	key: string,
) -> (cur: xitdb.Read_Cursor, found: bool, err: Store_Error) {
	sp, sp_err := xitdb.cursor_resolved(col_cur)
	if sp_err != nil {
		return {}, false, xitdb_to_store_err(sp_err)
	}
	#partial switch sp.slot.tag {
	case .None:
		return {}, false, nil
	case .Hash_Map, .Counted_Hash_Map:
		rm := xitdb.Read_Hash_Map{cursor = col_cur}
		mc, g_err := xitdb.hash_map_get_cursor(rm, key)
		if g_err != nil {
			return {}, false, xitdb_to_store_err(g_err)
		}
		res, ok := mc.?
		return res, ok, nil
	case .Sorted_Map:
		sm := xitdb.Read_Sorted_Map{cursor = col_cur}
		mc, g_err := xitdb.sorted_map_get_cursor(sm, key)
		if g_err != nil {
			return {}, false, xitdb_to_store_err(g_err)
		}
		res, ok := mc.?
		return res, ok, nil
	case .Hash_Set, .Counted_Hash_Set:
		hs := xitdb.Read_Hash_Set{cursor = col_cur}
		mc, g_err := xitdb.hash_set_get_cursor(hs, key)
		if g_err != nil {
			return {}, false, xitdb_to_store_err(g_err)
		}
		res, ok := mc.?
		return res, ok, nil
	case .Sorted_Set:
		ss := xitdb.Read_Sorted_Set{cursor = col_cur}
		contains, c_err := xitdb.sorted_set_contains(ss, key)
		if c_err != nil {
			return {}, false, xitdb_to_store_err(c_err)
		}
		return col_cur, contains, nil
	case:
		return {}, false, .Not_A_Collection
	}
}

@(private)
_walk_write_path_parent :: proc(
	moment_wc: ^xitdb.Write_Cursor,
	dot_path: string,
) -> (leaf_wc: xitdb.Write_Cursor, err: Store_Error) {
	if moment_wc == nil {
		return {}, .Invalid_Config
	}
	cur := moment_wc^
	rest := dot_path
	for {
		seg, has := _next_path_segment(&rest)
		if !has {
			return cur, nil
		}
		hm, h_err := xitdb.write_hash_map_init(cur)
		if h_err != nil {
			return {}, xitdb_to_store_err(h_err)
		}
		next_wc, n_err := xitdb.hash_map_put_cursor(&hm, seg)
		if n_err != nil {
			return {}, xitdb_to_store_err(n_err)
		}
		cur = next_wc
	}
}

// Ensures intermediate Hash_Map nodes exist along `dot_path` and initializes the leaf as a Write_Hash_Map.
store_write_path_ensure_map :: proc(
	moment_wc: ^xitdb.Write_Cursor,
	dot_path: string,
) -> (m: xitdb.Write_Hash_Map, err: Store_Error) {
	leaf_wc := _walk_write_path_parent(moment_wc, dot_path) or_return
	hm, h_err := xitdb.write_hash_map_init(leaf_wc)
	if h_err != nil {
		return {}, xitdb_to_store_err(h_err)
	}
	return hm, nil
}

// Ensures intermediate Hash_Map nodes exist along `dot_path` and initializes the leaf as a Write_Sorted_Map.
store_write_path_ensure_sorted_map :: proc(
	moment_wc: ^xitdb.Write_Cursor,
	dot_path: string,
) -> (sm: xitdb.Write_Sorted_Map, err: Store_Error) {
	leaf_wc := _walk_write_path_parent(moment_wc, dot_path) or_return
	s, s_err := xitdb.write_sorted_map_init(leaf_wc)
	if s_err != nil {
		return {}, xitdb_to_store_err(s_err)
	}
	return s, nil
}

// Streams Sorted_Map / Sorted_Set entries whose raw key bytes start with `prefix` in O(log N + K).
store_sorted_prefix_scan :: proc(
	sorted_cur: xitdb.Read_Cursor,
	prefix: []u8,
	cb: proc(key: []u8, val: xitdb.Read_Cursor, user_data: rawptr) -> bool,
	user_data: rawptr = nil,
) -> Store_Error {
	if cb == nil {
		return nil
	}
	sp, sp_err := xitdb.cursor_resolved(sorted_cur)
	if sp_err != nil {
		return xitdb_to_store_err(sp_err)
	}
	if sp.slot.tag == .None {
		return nil
	}
	if sp.slot.tag != .Sorted_Map && sp.slot.tag != .Sorted_Set {
		return .Not_A_Collection
	}

	it, it_err := xitdb.cursor_iterator_sorted_from_key(sorted_cur, prefix)
	if it_err != nil {
		return xitdb_to_store_err(it_err)
	}

	stack_buf: [256]u8 = ---
	for {
		item_maybe, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil {
			return xitdb_to_store_err(n_err)
		}
		item_cur, ok := item_maybe.?
		if !ok {
			break
		}
		kc, vc, kv_err := xitdb.cursor_read_kv_pair_slots(item_cur)
		if kv_err != nil {
			return xitdb_to_store_err(kv_err)
		}

		key_bytes: []u8
		kb, k_err := xitdb.cursor_read_bytes_buf(kc, stack_buf[:])
		if k_err == nil {
			key_bytes = kb.value
		} else if k_err == .Stream_Too_Long {
			raw, r_err := xitdb.cursor_read_bytes(kc, 0, context.temp_allocator)
			if r_err != nil {
				return xitdb_to_store_err(r_err)
			}
			key_bytes = raw
		} else {
			return xitdb_to_store_err(k_err)
		}

		if !bytes.has_prefix(key_bytes, prefix) {
			break
		}
		if !cb(key_bytes, vc, user_data) {
			break
		}
	}
	return nil
}

// Encodes an EAV composite key `<entity>\x00<attr>` into `buf` for lexicographically-grouped Sorted_Map storage.
store_eav_encode_key :: proc "contextless" (buf: []u8, entity: string, attr: string) -> (key: []u8, ok: bool) {
	need := len(entity) + 1 + len(attr)
	if need > len(buf) {
		return nil, false
	}
	copy(buf[:len(entity)], entity)
	buf[len(entity)] = 0
	copy(buf[len(entity) + 1:need], attr)
	return buf[:need], true
}

store_eav_put_string :: proc(
	sm: ^xitdb.Write_Sorted_Map,
	entity: string,
	attr: string,
	val: string,
) -> Store_Error {
	stack_buf: [256]u8 = ---
	key, ok := store_eav_encode_key(stack_buf[:], entity, attr)
	if !ok {
		need := len(entity) + 1 + len(attr)
		dyn, alloc_err := make([]u8, need, context.allocator)
		if alloc_err != nil {
			return alloc_err
		}
		defer delete(dyn)
		key, _ = store_eav_encode_key(dyn, entity, attr)
		if p_err := xitdb.sorted_map_put_by_bytes(sm, key, val); p_err != nil {
			return xitdb_to_store_err(p_err)
		}
		return nil
	}
	if p_err := xitdb.sorted_map_put_by_bytes(sm, key, val); p_err != nil {
		return xitdb_to_store_err(p_err)
	}
	return nil
}

store_eav_put :: proc(
	sm: ^xitdb.Write_Sorted_Map,
	entity: string,
	attr: string,
	val: Value,
	interner: ^String_Interner,
) -> Store_Error {
	data, ok, d_err := value_to_writeable_data(val, interner)
	if d_err != nil {
		return d_err
	}
	if !ok {
		return .Unsupported_Value_Type
	}
	stack_buf: [256]u8 = ---
	key, fit := store_eav_encode_key(stack_buf[:], entity, attr)
	if !fit {
		need := len(entity) + 1 + len(attr)
		dyn, alloc_err := make([]u8, need, context.allocator)
		if alloc_err != nil {
			return alloc_err
		}
		defer delete(dyn)
		key, _ = store_eav_encode_key(dyn, entity, attr)
		if p_err := xitdb.sorted_map_put_by_bytes(sm, key, data); p_err != nil {
			return xitdb_to_store_err(p_err)
		}
		return nil
	}
	if p_err := xitdb.sorted_map_put_by_bytes(sm, key, data); p_err != nil {
		return xitdb_to_store_err(p_err)
	}
	return nil
}

@(private)
_Eav_Scan_Ctx :: struct {
	prefix_len: int,
	cb:         proc(attr: string, val: xitdb.Read_Cursor, user_data: rawptr) -> bool,
	user_data:  rawptr,
}

@(private)
_eav_scan_adapter :: proc(key: []u8, val: xitdb.Read_Cursor, user_data: rawptr) -> bool {
	c := (^_Eav_Scan_Ctx)(user_data)
	if len(key) < c.prefix_len {
		return true
	}
	attr := string(key[c.prefix_len:])
	return c.cb(attr, val, c.user_data)
}

store_eav_scan_entity :: proc(
	eav_cur: xitdb.Read_Cursor,
	entity: string,
	cb: proc(attr: string, val: xitdb.Read_Cursor, user_data: rawptr) -> bool,
	user_data: rawptr = nil,
) -> Store_Error {
	if cb == nil {
		return nil
	}
	stack_buf: [256]u8 = ---
	prefix: []u8
	dyn: []u8
	need := len(entity) + 1
	if need <= len(stack_buf) {
		copy(stack_buf[:len(entity)], entity)
		stack_buf[len(entity)] = 0
		prefix = stack_buf[:need]
	} else {
		alloc_err: mem.Allocator_Error
		dyn, alloc_err = make([]u8, need, context.allocator)
		if alloc_err != nil {
			return alloc_err
		}
		copy(dyn[:len(entity)], entity)
		dyn[len(entity)] = 0
		prefix = dyn
	}
	defer if dyn != nil {
		delete(dyn)
	}

	ctx := _Eav_Scan_Ctx{
		prefix_len = need,
		cb         = cb,
		user_data  = user_data,
	}
	return store_sorted_prefix_scan(eav_cur, prefix, _eav_scan_adapter, &ctx)
}

package forseti

import "base:runtime"
import "core:encoding/endian"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import xitdb "xitdb:."

MAX_HYDRATE_SNAPSHOT_BYTES :: 32 * 1024 * 1024

Fact_Delta_Kind :: enum u8 {
	Added,
	Removed,
	Changed_Old,
	Changed_New,
}

Fact_Delta :: struct {
	collection: string,
	key:        string,
	kind:       Fact_Delta_Kind,
	old_value:  xitdb.Read_Cursor,
	new_value:  xitdb.Read_Cursor,
}

Sync_Result :: struct {
	arena:           vmem.Arena,
	deltas:          [dynamic]Fact_Delta,
	was_compacted:   bool,
	slots_skipped:   u64,
	blocks_compared: u64,
	keys_decoded:    u64,
}

@(private)
Watched_Collection :: struct {
	path:                 string,
	path_keys:            []Prehashed_Key,
	has_prev:             bool,
	prev_collection_slot: xitdb.Slot,
	logical_keys:         map[string]u64,
}

// Delta_Syncer incrementally syncs watched xitdb collections into Z-set (+1/-1) Fact_Delta streams,
// automatically falling back to logical fingerprint resync if compaction invalidates prior physical slots.
Delta_Syncer :: struct {
	watched:           [dynamic]Watched_Collection,
	has_synced:        bool,
	last_file_id:      u64,
	last_moment_index: i64,
	last_moment_slot:  xitdb.Slot,
	key_arena:         vmem.Arena,
	scratch_arena:     vmem.Arena,
	telemetry:         ^Telemetry_Sink,
	allocator:         mem.Allocator,
}

@(require_results)
delta_syncer_init :: proc(
	s: ^Delta_Syncer,
	telemetry: ^Telemetry_Sink = nil,
	allocator := context.allocator,
) -> (err: mem.Allocator_Error) {
	if s == nil {
		return .Invalid_Pointer
	}
	s^ = {}
	vmem.arena_init_growing(&s.key_arena) or_return
	defer if err != nil {
		vmem.arena_destroy(&s.key_arena)
	}
	vmem.arena_init_growing(&s.scratch_arena) or_return
	defer if err != nil {
		delta_syncer_destroy(s)
	}
	s.watched = make([dynamic]Watched_Collection, 0, 8, allocator) or_return
	s.telemetry = telemetry
	s.allocator = allocator
	s.last_moment_index = -1
	return nil
}

delta_syncer_destroy :: proc(s: ^Delta_Syncer) {
	if s == nil {
		return
	}
	vmem.arena_check_temp(&s.scratch_arena)
	vmem.arena_check_temp(&s.key_arena)
	for &wc in s.watched {
		delete(wc.logical_keys)
		delete(wc.path_keys, s.allocator)
		delete(wc.path, s.allocator)
	}
	delete(s.watched)
	vmem.arena_destroy(&s.scratch_arena)
	vmem.arena_destroy(&s.key_arena)
	s^ = {}
}

delta_syncer_watch :: proc(s: ^Delta_Syncer, path: string) -> Store_Error {
	if s == nil || len(path) == 0 {
		return .Invalid_Config if s == nil else .Empty_Path
	}
	for &wc in s.watched {
		if wc.path == path {
			return nil
		}
	}
	cloned, err1 := strings.clone(path, s.allocator)
	if err1 != nil {
		return err1
	}
	lkeys, err2 := make(map[string]u64, 16, s.allocator)
	if err2 != nil {
		delete(cloned, s.allocator)
		return err2
	}
	seg_count := 0
	rest := cloned
	for {
		_, has := _next_path_segment(&rest)
		if !has {
			break
		}
		seg_count += 1
	}
	path_keys, err3 := make([]Prehashed_Key, seg_count, s.allocator)
	if err3 != nil {
		delete(lkeys)
		delete(cloned, s.allocator)
		return err3
	}
	rest = cloned
	pi := 0
	for {
		seg, has := _next_path_segment(&rest)
		if !has {
			break
		}
		path_keys[pi] = prehashed_key_make(seg)
		pi += 1
	}
	_, aerr := append(&s.watched, Watched_Collection{
		path         = cloned,
		path_keys    = path_keys,
		logical_keys = lkeys,
	})
	if aerr != nil {
		delete(path_keys, s.allocator)
		delete(lkeys)
		delete(cloned, s.allocator)
		return aerr
	}
	return nil
}

sync_result_destroy :: proc(r: ^Sync_Result) {
	if r == nil {
		return
	}
	vmem.arena_check_temp(&r.arena)
	delete(r.deltas)
	vmem.arena_destroy(&r.arena)
	r^ = {}
}

@(private)
_mix64 :: #force_inline proc "contextless" (x: u64) -> u64 {
	z := x + 0x9e3779b97f4a7c15
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

@(private)
_hash_bytes64 :: proc "contextless" (seed: u64, b: []u8) -> u64 {
	h := seed ~ u64(len(b)) * 0x9e3779b97f4a7c15
	i := 0
	for i + 8 <= len(b) {
		v, _ := endian.get_u64(b[i:i + 8], .Little)
		h = _mix64(h ~ v)
		i += 8
	}
	for i < len(b) {
		h = _mix64(h ~ u64(b[i]) ~ u64(i))
		i += 1
	}
	return _mix64(h)
}

@(private)
_Fp_Frame :: struct {
	is_map:     bool,
	it:         xitdb.Cursor_Iterator,
	acc1:       u64,
	acc2:       u64,
	count:      u64,
	pending_kh: u64,
}

@(private)
_fold_fp_into_frame :: #force_inline proc(parent: ^_Fp_Frame, child_fp: u64) {
	if !parent.is_map {
		parent.acc1 = _mix64(parent.acc1 ~ child_fp)
		return
	}
	eh := _mix64(parent.pending_kh ~ child_fp)
	parent.acc1 ~= eh
	parent.acc2 += eh
	parent.count += 1
}

// Computes an offset-independent 64-bit structural fingerprint of a xitdb value/collection
// so identical records produce identical hashes before and after compaction.
// Uses an explicit scratch-allocated stack so deep nested structures never overflow OS thread stacks.
@(private)
_cursor_content_fingerprint :: proc(
	root_cur: xitdb.Read_Cursor,
	scratch: mem.Allocator,
	frames: ^[dynamic]_Fp_Frame,
) -> (fp: u64, err: Store_Error) {
	clear(frames)

	stack_buf: [258]u8 = ---
	key_buf: [256]u8 = ---

	eval_node :: proc(
		cur: xitdb.Read_Cursor,
		depth: int,
		scratch: mem.Allocator,
		stack_buf: []u8,
	) -> (leaf_fp: u64, frame: _Fp_Frame, is_container: bool, err: Store_Error) {
		if depth > 64 {
			return 0, {}, false, xitdb.Xitdb_Error.Key_Offset_Exceeded
		}
		sp, sp_err := xitdb.cursor_resolved(cur)
		if sp_err != nil {
			return 0, {}, false, xitdb_to_store_err(sp_err)
		}
		#partial switch sp.slot.tag {
		case .None:
			return 0x1000000000000001, {}, false, nil
		case .Int, .Uint, .Float, .Short_Bytes:
			return _mix64(u64(sp.slot.tag) * 0x517cc1b727220a95 ~ u64(sp.slot.value) ~ (u64(1) if sp.slot.full else 0)), {}, false, nil
		case .Bytes:
			b_obj, b_err := xitdb.cursor_read_bytes_buf(cur, stack_buf)
			if b_err == nil {
				h := _hash_bytes64(0x2000000000000002, b_obj.value)
				if b_obj.format_tag != nil {
					h = _hash_bytes64(h, b_obj.format_tag)
				}
				return h, {}, false, nil
			}
			if b_err != .Stream_Too_Long {
				return 0, {}, false, xitdb_to_store_err(b_err)
			}
			obj, o_err := xitdb.cursor_read_bytes_object(cur, 0, scratch)
			if o_err != nil {
				return 0, {}, false, xitdb_to_store_err(o_err)
			}
			h := _hash_bytes64(0x2000000000000002, obj.value)
			if obj.format_tag != nil {
				h = _hash_bytes64(h, obj.format_tag)
			}
			return h, {}, false, nil
		case .Array_List, .Linked_Array_List:
			it, it_err := xitdb.cursor_iterator(cur)
			if it_err != nil {
				return 0, {}, false, xitdb_to_store_err(it_err)
			}
			return 0, _Fp_Frame{is_map = false, it = it, acc1 = _mix64(u64(sp.slot.tag))}, true, nil
		case .Hash_Map, .Counted_Hash_Map, .Hash_Set, .Counted_Hash_Set, .Sorted_Map, .Sorted_Set:
			it, it_err := xitdb.cursor_iterator(cur)
			if it_err != nil {
				return 0, {}, false, xitdb_to_store_err(it_err)
			}
			return 0, _Fp_Frame{is_map = true, it = it, acc1 = _mix64(u64(sp.slot.tag))}, true, nil
		}
		return _mix64(u64(sp.slot.tag)), {}, false, nil
	}

	root_leaf, root_frame, root_is_container := eval_node(root_cur, 0, scratch, stack_buf[:]) or_return
	if !root_is_container {
		return root_leaf, nil
	}
	if _, a_err := append(frames, root_frame); a_err != nil {
		return 0, a_err
	}

	for len(frames^) > 0 {
		top_idx := len(frames^) - 1
		m, n_err := xitdb.cursor_iterator_next(&frames^[top_idx].it)
		if n_err != nil {
			return 0, xitdb_to_store_err(n_err)
		}
		entry, ok := m.?
		if !ok {
			done := frames^[top_idx]
			pop(frames)
			res := _mix64(done.acc1 ~ done.acc2 ~ done.count) if done.is_map else done.acc1
			if len(frames^) == 0 {
				return res, nil
			}
			_fold_fp_into_frame(&frames^[len(frames^) - 1], res)
			continue
		}

		child_cur: xitdb.Read_Cursor
		if !frames^[top_idx].is_map {
			child_cur = entry
		} else {
			kc, vc, kv_err := xitdb.cursor_read_kv_pair_slots(entry)
			if kv_err != nil {
				return 0, xitdb_to_store_err(kv_err)
			}
			kbytes := _read_cursor_key_temp(kc, key_buf[:], scratch) or_return
			frames^[top_idx].pending_kh = _hash_bytes64(0x3000000000000003, kbytes)
			child_cur = vc
		}

		child_leaf, child_frame, child_is_container := eval_node(child_cur, len(frames^), scratch, stack_buf[:]) or_return
		if !child_is_container {
			_fold_fp_into_frame(&frames^[top_idx], child_leaf)
			continue
		}
		if _, a_err := append(frames, child_frame); a_err != nil {
			return 0, a_err
		}
	}
	return 0, nil
}

@(private)
_read_cursor_key_temp :: proc(
	kc: xitdb.Read_Cursor,
	stack_buf: []u8,
	scratch: mem.Allocator,
) -> (key: []u8, err: Store_Error) {
	kb, k_err := xitdb.cursor_read_bytes_buf(kc, stack_buf)
	if k_err == nil {
		return kb.value, nil
	}
	if k_err == .Stream_Too_Long {
		raw, r_err := xitdb.cursor_read_bytes(kc, 0, scratch)
		if r_err != nil {
			return nil, xitdb_to_store_err(r_err)
		}
		return raw, nil
	}
	return nil, xitdb_to_store_err(k_err)
}

@(private)
_update_logical_key_fp :: proc(
	s: ^Delta_Syncer,
	wc: ^Watched_Collection,
	key: string,
	fp: u64,
) -> Store_Error {
	if _, existed := wc.logical_keys[key]; existed {
		wc.logical_keys[key] = fp
		return nil
	}
	if r_err := reserve(&wc.logical_keys, len(wc.logical_keys) + 1); r_err != nil {
		return r_err
	}
	owned, c_err := strings.clone(key, vmem.arena_allocator(&s.key_arena))
	if c_err != nil {
		return c_err
	}
	wc.logical_keys[owned] = fp
	return nil
}

@(private)
_delete_logical_key :: proc(s: ^Delta_Syncer, wc: ^Watched_Collection, key: string) {
	_ = s
	delete_key(&wc.logical_keys, key)
}

@(private)
_emit_delta :: proc(
	out: ^Sync_Result,
	collection: string,
	key: string,
	kind: Fact_Delta_Kind,
	old_value: xitdb.Read_Cursor,
	new_value: xitdb.Read_Cursor,
) -> Store_Error {
	out_alloc := vmem.arena_allocator(&out.arena)
	cloned_key, c_err := strings.clone(key, out_alloc)
	if c_err != nil {
		return c_err
	}
	_, a_err := append(&out.deltas, Fact_Delta{
		collection = collection,
		key        = cloned_key,
		kind       = kind,
		old_value  = old_value,
		new_value  = new_value,
	})
	if a_err != nil {
		return a_err
	}
	return nil
}

@(private)
_Pending_Key_Op :: struct {
	wc:     ^Watched_Collection,
	key:    string,
	fp:     u64,
	delete: bool,
}

@(private)
_Pending_Wc_State :: struct {
	wc:                   ^Watched_Collection,
	set_has_prev:         bool,
	has_prev:             bool,
	set_prev_slot:        bool,
	prev_collection_slot: xitdb.Slot,
}

@(private)
_try_build_file_snapshot :: proc(
	bridge: ^Store_Bridge,
	snap_arena: ^vmem.Arena,
	snap_core: ^xitdb.Core,
	snap_db: ^xitdb.Database,
) -> bool {
	if bridge == nil || bridge.db == nil || bridge.db.core == nil || !_core_has_disk_backing(bridge.db.core) {
		return false
	}
	file_len, l_err := xitdb.core_length(bridge.db.core)
	if l_err != nil || file_len <= 0 || file_len > MAX_HYDRATE_SNAPSHOT_BYTES {
		return false
	}
	raw_bytes, a_err := make([]u8, int(file_len), vmem.arena_allocator(snap_arena))
	if a_err != nil {
		return false
	}
	if r_err := xitdb.core_read_exact_at(bridge.db.core, 0, raw_bytes); r_err != nil {
		return false
	}
	raw_arr := runtime.Raw_Dynamic_Array{
		data      = raw_data(raw_bytes),
		len       = len(raw_bytes),
		cap       = len(raw_bytes),
		allocator = runtime.nil_allocator(),
	}
	snap_core^ = xitdb.Core_Memory{
		buf       = transmute([dynamic]u8)raw_arr,
		pos       = 0,
		allocator = runtime.nil_allocator(),
	}
	snap_db^ = xitdb.Database{
		core   = snap_core,
		hasher = bridge.db.hasher,
		header = bridge.db.header,
	}
	return true
}

@(private)
_sync_full_scan :: proc(
	wc: ^Watched_Collection,
	col_path: string,
	col_cur: xitdb.Read_Cursor,
	has_col: bool,
	is_resync: bool,
	live_db: ^xitdb.Database,
	out: ^Sync_Result,
	pending_ops: ^[dynamic]_Pending_Key_Op,
	scratch: mem.Allocator,
	fp_frames: ^[dynamic]_Fp_Frame,
) -> Store_Error {
	need_seen := is_resync && len(wc.logical_keys) > 0
	seen: map[string]struct{}
	if need_seen {
		seen = make(map[string]struct{}, max(len(wc.logical_keys) * 2, 16), scratch)
	}
	if has_col {
		sp, sp_err := xitdb.cursor_resolved(col_cur)
		if sp_err != nil {
			return xitdb_to_store_err(sp_err)
		}
		if sp.slot.tag != .None {
			it, it_err := xitdb.cursor_iterator(col_cur)
			if it_err != nil {
				return xitdb_to_store_err(it_err)
			}
			key_buf: [256]u8 = ---
			for {
				item_maybe, n_err := xitdb.cursor_iterator_next(&it)
				if n_err != nil {
					return xitdb_to_store_err(n_err)
				}
				entry, ok := item_maybe.?
				if !ok {
					break
				}
				kc, vc, kv_err := xitdb.cursor_read_kv_pair_slots(entry)
				if kv_err != nil {
					return xitdb_to_store_err(kv_err)
				}
				kbytes := _read_cursor_key_temp(kc, key_buf[:], scratch) or_return
				out.keys_decoded += 1
				k_str := string(kbytes)
				fp := _cursor_content_fingerprint(vc, scratch, fp_frames) or_return
				vc_live := vc
				vc_live.db = live_db

				k_scratch: string
				if need_seen {
					ks, ks_err := strings.clone(k_str, scratch)
					if ks_err != nil {
						return ks_err
					}
					k_scratch = ks
					seen[k_scratch] = {}
				}

				if is_resync {
					if old_fp, existed := wc.logical_keys[k_str]; existed {
						if old_fp != fp {
							if k_scratch == "" && len(k_str) > 0 {
								ks, ks_err := strings.clone(k_str, scratch)
								if ks_err != nil {
									return ks_err
								}
								k_scratch = ks
							}
							if _, a_err := append(pending_ops, _Pending_Key_Op{wc = wc, key = k_scratch, fp = fp}); a_err != nil {
								return a_err
							}
							_emit_delta(out, col_path, k_str, .Changed_Old, {}, vc_live) or_return
							_emit_delta(out, col_path, k_str, .Changed_New, {}, vc_live) or_return
						}
						continue
					}
				}
				if k_scratch == "" && len(k_str) > 0 {
					ks, ks_err := strings.clone(k_str, scratch)
					if ks_err != nil {
						return ks_err
					}
					k_scratch = ks
				}
				if _, a_err := append(pending_ops, _Pending_Key_Op{wc = wc, key = k_scratch, fp = fp}); a_err != nil {
					return a_err
				}
				_emit_delta(out, col_path, k_str, .Added, {}, vc_live) or_return
			}
		}
	}

	if is_resync && len(wc.logical_keys) > 0 {
		removed := make([dynamic]string, 0, len(wc.logical_keys), scratch)
		for k in wc.logical_keys {
			if !(k in seen) {
				if _, a_err := append(&removed, k); a_err != nil {
					return a_err
				}
			}
		}
		for rk in removed {
			_emit_delta(out, col_path, rk, .Removed, {}, {}) or_return
			if _, a_err := append(pending_ops, _Pending_Key_Op{wc = wc, key = rk, delete = true}); a_err != nil {
				return a_err
			}
		}
	}
	return nil
}

// Synchronizes all watched collections from the previous synced moment to the latest committed moment,
// emitting Z-set Fact_Delta events and updating Telemetry_Sink counters cleanly.
delta_syncer_sync :: proc(
	s: ^Delta_Syncer,
	bridge: ^Store_Bridge,
	out: ^Sync_Result,
) -> (err: Store_Error) {
	return _delta_syncer_sync_impl(s, bridge, out, nil)
}

@(private)
_delta_syncer_sync_impl :: proc(
	s: ^Delta_Syncer,
	bridge: ^Store_Bridge,
	out: ^Sync_Result,
	snap_db: ^xitdb.Database = nil,
) -> (err: Store_Error) {
	if s == nil || bridge == nil || bridge.db == nil || out == nil {
		return .Invalid_Config
	}

	span := telemetry_span_begin(s.telemetry, .Sync, "delta_sync")
	defer telemetry_span_end(s.telemetry, span)

	vmem.arena_free_all(&s.scratch_arena)
	defer vmem.arena_free_all(&s.scratch_arena)
	scratch := vmem.arena_allocator(&s.scratch_arena)
	fp_frames: [dynamic]_Fp_Frame
	fp_frames.allocator = scratch

	out^ = {}
	vmem.arena_init_growing(&out.arena) or_return
	defer if err != nil {
		sync_result_destroy(out)
	}
	out.deltas = make([dynamic]Fact_Delta, 0, 16, s.allocator) or_return

	read_bridge := bridge^
	if snap_db != nil {
		read_bridge.db = snap_db
	}

	out_alloc := vmem.arena_allocator(&out.arena)
	moment_count := store_bridge_moment_count(&read_bridge) or_return
	if moment_count == 0 {
		if !s.has_synced {
			return nil
		}
		out.was_compacted = true
		for &wc in s.watched {
			if len(wc.logical_keys) == 0 {
				continue
			}
			col_path, cp_err := strings.clone(wc.path, out_alloc)
			if cp_err != nil {
				return cp_err
			}
			for k in wc.logical_keys {
				_emit_delta(out, col_path, k, .Removed, {}, {}) or_return
			}
		}
		for &wc in s.watched {
			clear(&wc.logical_keys)
			wc.has_prev = false
			wc.prev_collection_slot = {}
		}
		vmem.arena_free_all(&s.key_arena)
		s.has_synced = false
		s.last_file_id = 0
		s.last_moment_index = 0
		s.last_moment_slot = {}
		return nil
	}
	cur_moment_idx := moment_count - 1
	cur_m_cur, cur_m_ok, cur_m_err := store_bridge_moment_cursor(&read_bridge, cur_moment_idx)
	if cur_m_err != nil {
		return cur_m_err
	}
	if !cur_m_ok {
		return .Moment_Missing
	}
	cur_m_slot, cms_err := xitdb.cursor_slot(cur_m_cur)
	if cms_err != nil {
		return xitdb_to_store_err(cms_err)
	}
	cur_file_id := bridge.db.header.file_id

	compacted := false
	prev_m_cur: xitdb.Read_Cursor
	if s.has_synced {
		if cur_file_id != s.last_file_id || moment_count <= s.last_moment_index {
			compacted = true
		} else {
			pm, pm_ok, pm_err := store_bridge_moment_cursor(&read_bridge, s.last_moment_index)
			if pm_err != nil || !pm_ok {
				compacted = true
			} else {
				pm_slot, pms_err := xitdb.cursor_slot(pm)
				if pms_err != nil || pm_slot != s.last_moment_slot {
					compacted = true
				} else {
					prev_m_cur = pm
				}
			}
		}
	}
	out.was_compacted = compacted

	pending_ops := make([dynamic]_Pending_Key_Op, 0, max(len(s.watched) * 16, 16), scratch)
	pending_wc := make([dynamic]_Pending_Wc_State, 0, len(s.watched), scratch)

	for &wc in s.watched {
		col_path := strings.clone(wc.path, out_alloc) or_return
		cur_col_cur, cur_ok, cc_err := store_resolve_path_prehashed(cur_m_cur, wc.path_keys)
		if cc_err != nil {
			return cc_err
		}
		cur_col_slot := xitdb.Slot{}
		if cur_ok {
			ccs, ccs_err := xitdb.cursor_slot(cur_col_cur)
			if ccs_err != nil {
				return xitdb_to_store_err(ccs_err)
			}
			cur_col_slot = ccs
		}

		if !s.has_synced || !wc.has_prev || compacted {
			_sync_full_scan(&wc, col_path, cur_col_cur, cur_ok, s.has_synced && wc.has_prev, bridge.db, out, &pending_ops, scratch, &fp_frames) or_return
			if _, a_err := append(&pending_wc, _Pending_Wc_State{
				wc                   = &wc,
				set_has_prev         = true,
				has_prev             = true,
				set_prev_slot        = true,
				prev_collection_slot = cur_col_slot,
			}); a_err != nil {
				return a_err
			}
			continue
		}

		if cur_moment_idx == s.last_moment_index && cur_col_slot == wc.prev_collection_slot {
			out.slots_skipped += 1
			continue
		}

		prev_col_cur, prev_ok, pc_err := store_resolve_path_prehashed(prev_m_cur, wc.path_keys)
		if pc_err != nil {
			return pc_err
		}
		if !prev_ok && !cur_ok {
			out.slots_skipped += 1
			if _, a_err := append(&pending_wc, _Pending_Wc_State{
				wc                   = &wc,
				set_prev_slot        = true,
				prev_collection_slot = {},
			}); a_err != nil {
				return a_err
			}
			continue
		}
		if !prev_ok && cur_ok {
			_sync_full_scan(&wc, col_path, cur_col_cur, true, false, bridge.db, out, &pending_ops, scratch, &fp_frames) or_return
			if _, a_err := append(&pending_wc, _Pending_Wc_State{
				wc                   = &wc,
				set_prev_slot        = true,
				prev_collection_slot = cur_col_slot,
			}); a_err != nil {
				return a_err
			}
			continue
		}
		if prev_ok && !cur_ok {
			_sync_full_scan(&wc, col_path, {}, false, true, bridge.db, out, &pending_ops, scratch, &fp_frames) or_return
			if _, a_err := append(&pending_wc, _Pending_Wc_State{
				wc                   = &wc,
				set_prev_slot        = true,
				prev_collection_slot = {},
			}); a_err != nil {
				return a_err
			}
			continue
		}

		stats: xitdb.Diff_Stats
		changes, d_err := xitdb.diff_collection_with_stats(prev_col_cur, cur_col_cur, &stats, scratch, scratch)
		if d_err != nil {
			return xitdb_to_store_err(d_err)
		}
		out.slots_skipped += stats.slots_skipped
		out.blocks_compared += stats.blocks_compared
		out.keys_decoded += stats.keys_decoded

		for ch in changes {
			k_str := string(ch.key)
			old_live := ch.old_value
			old_live.db = bridge.db
			new_live := ch.new_value
			new_live.db = bridge.db
			switch ch.op {
			case .Added:
				fp := _cursor_content_fingerprint(ch.new_value, scratch, &fp_frames) or_return
				if _, a_err := append(&pending_ops, _Pending_Key_Op{wc = &wc, key = k_str, fp = fp}); a_err != nil {
					return a_err
				}
				_emit_delta(out, col_path, k_str, .Added, {}, new_live) or_return
			case .Removed:
				if _, a_err := append(&pending_ops, _Pending_Key_Op{wc = &wc, key = k_str, delete = true}); a_err != nil {
					return a_err
				}
				_emit_delta(out, col_path, k_str, .Removed, old_live, {}) or_return
			case .Changed:
				fp := _cursor_content_fingerprint(ch.new_value, scratch, &fp_frames) or_return
				if _, a_err := append(&pending_ops, _Pending_Key_Op{wc = &wc, key = k_str, fp = fp}); a_err != nil {
					return a_err
				}
				_emit_delta(out, col_path, k_str, .Changed_Old, old_live, new_live) or_return
				_emit_delta(out, col_path, k_str, .Changed_New, old_live, new_live) or_return
			}
		}
		if _, a_err := append(&pending_wc, _Pending_Wc_State{
			wc                   = &wc,
			set_prev_slot        = true,
			prev_collection_slot = cur_col_slot,
		}); a_err != nil {
			return a_err
		}
	}

	for &wc in s.watched {
		add_cnt := 0
		for op in pending_ops {
			if op.wc == &wc && !op.delete && !(op.key in wc.logical_keys) {
				add_cnt += 1
			}
		}
		if add_cnt > 0 {
			reserve(&wc.logical_keys, len(wc.logical_keys) + add_cnt) or_return
		}
	}
	key_alloc := vmem.arena_allocator(&s.key_arena)
	staged_keys := make([]string, len(pending_ops), scratch)
	for op, oi in pending_ops {
		if !op.delete && !(op.key in op.wc.logical_keys) {
			staged_keys[oi] = strings.clone(op.key, key_alloc) or_return
		}
	}

	for op, oi in pending_ops {
		if op.delete {
			_delete_logical_key(s, op.wc, op.key)
		} else if op.key in op.wc.logical_keys {
			op.wc.logical_keys[op.key] = op.fp
		} else {
			op.wc.logical_keys[staged_keys[oi]] = op.fp
		}
	}
	for pwc in pending_wc {
		if pwc.set_has_prev {
			pwc.wc.has_prev = pwc.has_prev
		}
		if pwc.set_prev_slot {
			pwc.wc.prev_collection_slot = pwc.prev_collection_slot
		}
	}

	s.has_synced = true
	s.last_file_id = cur_file_id
	s.last_moment_index = cur_moment_idx
	s.last_moment_slot = cur_m_slot

	telemetry_count_add(s.telemetry, .Slots_Skipped, out.slots_skipped)
	telemetry_count_add(s.telemetry, .Keys_Decoded, out.keys_decoded)
	return nil
}

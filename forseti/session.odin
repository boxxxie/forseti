package forseti

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import xitdb "xitdb:."

Fact_Id :: distinct u32
INVALID_FACT :: Fact_Id(0)

Fact_Origin :: enum u8 {
	External,
	Logical,
	Unconditional,
}

Fact :: struct {
	id:              Fact_Id,
	binding_idx:     u16,
	key:             String_Id,
	fields:          []Value,
	cursor:          xitdb.Read_Cursor,
	has_cursor:      bool,
	recency:         u64,
	alive:           bool,
	support_count:   i32,
	proof_height:    u32,
	content_hash:    u64,
	best_derivation: Derivation_Id,
	next_logical:    Fact_Id,
	origin:          Fact_Origin,
}

Fact_Alpha_Edge :: struct {
	alpha_id: u32,
	next:     i32,
}

Beta_Bucket_Node :: struct {
	fid:  Fact_Id,
	hash: u64,
	prev: i32,
	next: i32,
}

Beta_Bucket_Index :: struct {
	heads:     map[u64]i32,
	fact_node: map[Fact_Id]i32,
	nodes:     [dynamic]Beta_Bucket_Node,
	free_list: [dynamic]i32,
}

Fact_Lookup_Key :: struct {
	binding_idx: u16,
	key:         String_Id,
}

MAX_ALPHA_DELTA_LOG :: 64

Alpha_Memory :: struct {
	id:              u32,
	fact_ids:        [dynamic]Fact_Id,
	fact_pos:        map[Fact_Id]int,
	version:         u64,
	insert_epoch:    u64,
	retract_epoch:   u64,
	recent_inserts:  [MAX_ALPHA_DELTA_LOG]Fact_Id,
	recent_retracts: [MAX_ALPHA_DELTA_LOG]Fact_Id,
}

Segment_Memory :: struct {
	seg_id:                u32,
	linked_mask:           u64,
	was_linked:            bool,
	dirty:                 bool,
	subnetwork_dirty:      bool,
	last_lia_epoch:        u64,
	last_lia_insert_epoch: u64,
	last_lia_len:          int,
}

Beta_Memory :: struct {
	node_id:             u32,
	right_alpha_version: u64,
	right_retract_epoch: u64,
	right_insert_epoch:  u64,
	indexed_count:       int,
	right_facts:         [dynamic]Fact_Id,
	right_fact_pos:      map[Fact_Id]int,
	right_idx:           Beta_Bucket_Index,
	left_initialized:    bool,
	left_alpha_version:  u64,
	left_retract_epoch:  u64,
	left_insert_epoch:   u64,
	left_indexed_count:  int,
	left_idx:            Beta_Bucket_Index,
}

Session_Config :: struct {
	max_activations: u64,
	initial_phases:  []string,
	provenance_mode: Provenance_Mode, // Defaults to .Audit_Full
}

Session_Error :: enum u8 {
	None = 0,
	Invalid_Arg,
	Unknown_Binding,
	Unknown_Query,
	Max_Activations_Exceeded,
	Vm_Eval_Failed,
	Alloc_Failed,
}

// Session maintains sparse lazy PHREAK working/beta memories over an immutable shared Rulebase.
// Pinned handle: initialize in-place or heap-allocate via new(Session) and never copy by value.
Session :: struct {
	rb:                     ^Rulebase,
	arena:                  vmem.Arena,
	interner:               String_Interner,
	telemetry:              ^Telemetry_Sink,
	facts:                  [dynamic]Fact,
	facts_by_key:           map[Fact_Lookup_Key]Fact_Id,
	logical_buckets:        map[u64]Fact_Id,
	free_logical_facts:     map[u16][dynamic]Fact_Id,
	fact_alpha_head:        [dynamic]i32,
	fact_alpha_edges:       [dynamic]Fact_Alpha_Edge,
	free_fact_alpha_edges:  [dynamic]i32,
	alpha_mems:             map[u32]^Alpha_Memory,
	seg_mems:               map[u32]^Segment_Memory,
	dirty_segs:             [dynamic]u32,
	dirty_segs_rem:         [dynamic]u32,
	dirty_segs_work:        [dynamic]u32,
	zero_input_seeded:      bool,
	beta_mems:              map[u32]^Beta_Memory,
	sub_beta_mems:          map[u64]^Beta_Memory,
	neg_mems:               map[u32]^Not_Exists_Memory,
	accum_mems:             map[u32]^Accum_Memory,
	eval_stack:             [dynamic]Eval_Frame,
	eval_buf_pool:          [dynamic][dynamic]Beta_Token,
	eval_decide_pool:       [dynamic]Decision_Result,
	firing_decide_buf:      [dynamic]Decision_Result,
	reconcile_live_hashes:  map[u64]bool,
	reconcile_to_revoke:    [dynamic]Firing_Key,
	partial_reconcile_fids: [dynamic]Fact_Id,
	partial_reconcile_seen: map[Fact_Id]bool,
	agenda:                 Agenda,
	fired_trace:            [dynamic]String_Id,
	derived_seq_by_bind:    map[u16]u64,
	jtms:                   Jtms_State,
	provenance:             Provenance_Store,
	pending_effects:        [dynamic]Effect_Job,
	inflight_effects:       map[u64]Effect_Inflight,
	next_effect_job_id:     u64,
	committed_bridge_db:    ^xitdb.Database,
	committed_derived:      map[Fact_Lookup_Key]bool,
	dirty_derived_fids:     [dynamic]Fact_Id,
	retracted_derived_keys: [dynamic]Fact_Lookup_Key,
	stratum_changed:        bool,
	earliest_dirty_strat:   u32,
	max_activations:        u64,
	next_recency:           u64,
	live_memories_count:    u64,
	allocator:              mem.Allocator,
}

@(require_results)
session_init :: proc(
	s: ^Session,
	rb: ^Rulebase,
	cfg := Session_Config{},
	telemetry: ^Telemetry_Sink = nil,
	allocator := context.allocator,
) -> (err: Session_Error) {
	if s == nil || rb == nil {
		return .Invalid_Arg
	}
	s^ = {}
	if vmem.arena_init_growing(&s.arena) != nil {
		return .Alloc_Failed
	}
	defer if err != .None {
		session_destroy(s)
	}
	if interner_init(&s.interner, allocator) != nil {
		return .Alloc_Failed
	}

	s.rb = rb
	s.telemetry = telemetry if telemetry != nil else rb.telemetry
	s.allocator = allocator
	s.max_activations = cfg.max_activations if cfg.max_activations > 0 else 100_000
	s.next_recency = 1

	// Allocate tiny fixed initial buckets (O(1) regardless of Rulebase size: works for 1M rules!).
	s.facts = make([dynamic]Fact, 1, 16, allocator) // slot 0 = sentinel
	s.facts_by_key = make(map[Fact_Lookup_Key]Fact_Id, 16, allocator)
	s.logical_buckets = make(map[u64]Fact_Id, 16, allocator)
	s.free_logical_facts = make(map[u16][dynamic]Fact_Id, 8, allocator)
	s.fact_alpha_head = make([dynamic]i32, 1, 16, allocator)
	s.fact_alpha_head[0] = -1
	s.fact_alpha_edges = make([dynamic]Fact_Alpha_Edge, 0, 16, allocator)
	s.free_fact_alpha_edges = make([dynamic]i32, 0, 16, allocator)
	s.alpha_mems = make(map[u32]^Alpha_Memory, 16, allocator)
	s.seg_mems = make(map[u32]^Segment_Memory, 16, allocator)
	s.dirty_segs = make([dynamic]u32, 0, 16, allocator)
	s.dirty_segs_rem = make([dynamic]u32, 0, 16, allocator)
	s.dirty_segs_work = make([dynamic]u32, 0, 16, allocator)
	s.beta_mems = make(map[u32]^Beta_Memory, 16, allocator)
	s.sub_beta_mems = make(map[u64]^Beta_Memory, 8, allocator)
	s.neg_mems = make(map[u32]^Not_Exists_Memory, 8, allocator)
	s.accum_mems = make(map[u32]^Accum_Memory, 8, allocator)
	s.eval_stack = make([dynamic]Eval_Frame, 0, 16, allocator)
	s.eval_buf_pool = make([dynamic][dynamic]Beta_Token, 0, 8, allocator)
	s.eval_decide_pool = make([dynamic]Decision_Result, 0, 8, allocator)
	s.firing_decide_buf = make([dynamic]Decision_Result, 0, 4, allocator)
	s.reconcile_live_hashes = make(map[u64]bool, 16, allocator)
	s.reconcile_to_revoke = make([dynamic]Firing_Key, 0, 8, allocator)
	s.partial_reconcile_fids = make([dynamic]Fact_Id, 0, 16, allocator)
	s.partial_reconcile_seen = make(map[Fact_Id]bool, 16, allocator)
	s.fired_trace = make([dynamic]String_Id, 0, 16, allocator)
	s.derived_seq_by_bind = make(map[u16]u64, 8, allocator)
	s.pending_effects = make([dynamic]Effect_Job, 0, 8, allocator)
	s.inflight_effects = make(map[u64]Effect_Inflight, 8, allocator)
	s.next_effect_job_id = 1
	s.committed_derived = make(map[Fact_Lookup_Key]bool, 8, allocator)
	s.dirty_derived_fids = make([dynamic]Fact_Id, 0, 16, allocator)
	s.retracted_derived_keys = make([dynamic]Fact_Lookup_Key, 0, 8, allocator)
	s.earliest_dirty_strat = max(u32)
	agenda_init(&s.agenda, allocator)
	jtms_init(&s.jtms, allocator)
	provenance_init(&s.provenance, cfg.provenance_mode, allocator)

	if len(cfg.initial_phases) > 0 {
		session_set_phases(s, cfg.initial_phases) or_return
	}
	return .None
}

session_destroy :: proc(s: ^Session) {
	if s == nil {
		return
	}
	vmem.arena_check_temp(&s.arena)
	provenance_destroy(&s.provenance)
	jtms_destroy(&s.jtms)
	effects_destroy(s)
	delete(s.retracted_derived_keys)
	delete(s.dirty_derived_fids)
	delete(s.committed_derived)
	agenda_destroy(&s.agenda)
	delete(s.fired_trace)
	delete(s.derived_seq_by_bind)
	delete(s.partial_reconcile_seen)
	delete(s.partial_reconcile_fids)
	delete(s.reconcile_to_revoke)
	delete(s.reconcile_live_hashes)
	for buf in s.eval_buf_pool {
		delete(buf)
	}
	delete(s.eval_buf_pool)
	delete(s.eval_decide_pool)
	delete(s.firing_decide_buf)
	for &ef in s.eval_stack {
		delete(ef.tokens)
		delete(ef.sub_tokens)
		delete(ef.pass_tokens)
	}
	delete(s.eval_stack)
	delete(s.dirty_segs_work)
	delete(s.dirty_segs_rem)
	delete(s.dirty_segs)

	for _, nm in s.neg_mems {
		delete(nm.blocker_counts)
		free(nm, s.allocator)
	}
	delete(s.neg_mems)

	for _, am_acc in s.accum_mems {
		for _, &st in am_acc.groups {
			accum_destroy(&st)
		}
		delete(am_acc.groups)
		delete(am_acc.dirty_groups)
		delete(am_acc.tracked_facts)
		delete(am_acc.outer_by_group)
		delete(am_acc.outer_fact_node)
		delete(am_acc.outer_nodes)
		delete(am_acc.free_outer_nodes)
		free(am_acc, s.allocator)
	}
	delete(s.accum_mems)

	for _, bm in s.beta_mems {
		_beta_mem_destroy(bm)
		free(bm, s.allocator)
	}
	delete(s.beta_mems)
	for _, bm in s.sub_beta_mems {
		_beta_mem_destroy(bm)
		free(bm, s.allocator)
	}
	delete(s.sub_beta_mems)

	for _, sm in s.seg_mems {
		free(sm, s.allocator)
	}
	delete(s.seg_mems)

	for _, am in s.alpha_mems {
		delete(am.fact_pos)
		delete(am.fact_ids)
		free(am, s.allocator)
	}
	delete(s.alpha_mems)

	delete(s.free_fact_alpha_edges)
	delete(s.fact_alpha_edges)
	delete(s.fact_alpha_head)

	for _, flist in s.free_logical_facts {
		delete(flist)
	}
	delete(s.free_logical_facts)

	delete(s.logical_buckets)

	delete(s.facts_by_key)
	delete(s.facts)
	interner_destroy(&s.interner)
	vmem.arena_destroy(&s.arena)
	s^ = {}
}

session_string :: proc "contextless" (s: ^Session, sid: String_Id) -> string {
	if s == nil || s.rb == nil {
		return ""
	}
	return resolve_runtime_string(&s.rb.interner, &s.interner, sid)
}

session_find_binding :: proc(s: ^Session, name: string) -> (u16, bool) {
	if s == nil || s.rb == nil {
		return 0, false
	}
	if sid, ok := s.rb.interner.lookup[name]; ok {
		return s.rb.binding_by_name[sid]
	}
	return 0, false
}

@(private)
_record_live_memory_watermark :: proc(s: ^Session) {
	if s.telemetry != nil {
		when FORSETI_TELEMETRY {
			if s.live_memories_count > s.telemetry.watermarks.live_session_memories {
				s.telemetry.watermarks.live_session_memories = s.live_memories_count
			}
		}
	}
}

@(private)
_validate_fact_fields_range :: proc(schema: Schema_Def, fields: []Value) -> Session_Error {
	n := min(len(schema.fields), len(fields))
	for i := 0; i < n; i += 1 {
		if schema.fields[i].type.kind == .I32 {
			if iv, is_i64 := fields[i].(i64); is_i64 {
				if iv < i64(min(i32)) || iv > i64(max(i32)) {
					return .Invalid_Arg
				}
			}
		}
	}
	return .None
}

// Normalizes incoming Values into Session string space (using immutable Rulebase IDs when matched).
@(private)
_normalize_fact_fields_into :: proc(s: ^Session, schema: Schema_Def, fields: []Value, out: []Value) {
	for i := 0; i < len(fields); i += 1 {
		v := fields[i]
		if sid, is_s := v.(String_Id); is_s {
			txt := resolve_runtime_string(&s.rb.interner, &s.interner, sid)
			mapped, _ := intern_session_string(&s.rb.interner, &s.interner, txt)
			v = mapped
		}
		if i < len(schema.fields) && schema.fields[i].type.kind == .I32 {
			if iv, is_i64 := v.(i64); is_i64 {
				v = i32(iv)
			}
		}
		out[i] = v
	}
}

@(private)
_normalize_fact_fields :: proc(s: ^Session, schema: Schema_Def, fields: []Value) -> []Value {
	n := max(len(schema.fields), len(fields))
	out := make([]Value, n, vmem.arena_allocator(&s.arena))
	_normalize_fact_fields_into(s, schema, fields, out)
	return out
}

@(private)
_lookup_interned_string_id :: proc "contextless" (
	rb_int: ^String_Interner,
	sess_int: ^String_Interner,
	txt: string,
) -> (String_Id, bool) {
	if len(txt) == 0 {
		return EMPTY_STRING, true
	}
	if rb_int != nil {
		if id, ok := rb_int.lookup[txt]; ok {
			return id, true
		}
	}
	if sess_int != nil {
		if id, ok := sess_int.lookup[txt]; ok {
			return String_Id(u32(id) | RUNTIME_STRING_BIT), true
		}
	}
	return EMPTY_STRING, false
}

@(private)
_record_dirty_derived_fact :: #force_inline proc(s: ^Session, fid: Fact_Id, binding_idx: u16) {
	if s.committed_bridge_db != nil && int(binding_idx) < len(s.rb.bindings) && s.rb.bindings[binding_idx].kind == .Derived {
		append(&s.dirty_derived_fids, fid)
	}
}

@(private)
_record_retracted_derived_key :: #force_inline proc(s: ^Session, f: ^Fact) {
	if s.committed_bridge_db != nil && int(f.binding_idx) < len(s.rb.bindings) && s.rb.bindings[f.binding_idx].kind == .Derived {
		lk := Fact_Lookup_Key{binding_idx = f.binding_idx, key = f.key}
		if lk in s.committed_derived {
			append(&s.retracted_derived_keys, lk)
		}
	}
}

session_insert_fact :: proc(
	s: ^Session,
	binding_name: string,
	key: string,
	fields: []Value,
	origin: Fact_Origin = .External,
) -> (fid: Fact_Id, err: Session_Error) {
	bidx, ok := session_find_binding(s, binding_name)
	if !ok {
		return INVALID_FACT, .Unknown_Binding
	}
	return session_insert_fact_by_idx(s, bidx, key, fields, origin)
}

session_insert_fact_by_idx :: proc(
	s: ^Session,
	binding_idx: u16,
	key: string,
	fields: []Value,
	origin: Fact_Origin = .External,
) -> (fid: Fact_Id, err: Session_Error) {
	if s == nil || s.rb == nil || int(binding_idx) >= len(s.rb.bindings) {
		return INVALID_FACT, .Unknown_Binding
	}
	bdef := s.rb.bindings[binding_idx]
	schema := s.rb.schemas[bdef.schema_id]
	if r_err := _validate_fact_fields_range(schema, fields); r_err != .None {
		return INVALID_FACT, r_err
	}
	key_id, k_err := intern_session_string(&s.rb.interner, &s.interner, key)
	if k_err != nil {
		return INVALID_FACT, .Alloc_Failed
	}

	lk := Fact_Lookup_Key{binding_idx = binding_idx, key = key_id}
	if prev_id, had := s.facts_by_key[lk]; had && s.facts[prev_id].alive {
		_ = session_retract_fact(s, prev_id)
	}

	norm_fields := _normalize_fact_fields(s, schema, fields)

	fid = Fact_Id(len(s.facts))
	recency := s.next_recency
	s.next_recency += 1
	append(&s.facts, Fact{
		id            = fid,
		binding_idx   = binding_idx,
		key           = key_id,
		fields        = norm_fields,
		recency       = recency,
		alive         = true,
		support_count = 1,
		origin        = origin,
	})
	for len(s.fact_alpha_head) <= int(fid) {
		append(&s.fact_alpha_head, -1)
	}
	s.facts_by_key[lk] = fid
	_record_dirty_derived_fact(s, fid, binding_idx)

	alpha_eval_insert_fact(s, fid)
	return fid, .None
}

session_insert_cursor_fact :: proc(
	s: ^Session,
	binding_idx: u16,
	key: string,
	cursor: xitdb.Read_Cursor,
) -> (fid: Fact_Id, err: Session_Error) {
	return _session_insert_cursor_fact_hydrated(s, binding_idx, key, cursor, nil)
}

@(private)
_session_insert_cursor_fact_hydrated :: proc(
	s: ^Session,
	binding_idx: u16,
	key: string,
	cursor: xitdb.Read_Cursor,
	snap_db: ^xitdb.Database,
) -> (fid: Fact_Id, err: Session_Error) {
	if s == nil || s.rb == nil || int(binding_idx) >= len(s.rb.bindings) {
		return INVALID_FACT, .Unknown_Binding
	}
	key_id, k_err := intern_session_string(&s.rb.interner, &s.interner, key)
	if k_err != nil {
		return INVALID_FACT, .Alloc_Failed
	}
	lk := Fact_Lookup_Key{binding_idx = binding_idx, key = key_id}
	if prev_id, had := s.facts_by_key[lk]; had && s.facts[prev_id].alive {
		_ = session_retract_fact(s, prev_id)
	}

	bdef := s.rb.bindings[binding_idx]
	schema := s.rb.schemas[bdef.schema_id]
	fields := make([]Value, len(schema.fields), vmem.arena_allocator(&s.arena)) // nil entries populated lazily or from snapshot
	if snap_db != nil {
		snap_cur := cursor
		snap_cur.db = snap_db
		fhashes := s.rb.schema_field_hashes[bdef.schema_id]
		for sf, fi in schema.fields {
			path := [1]Prehashed_Key{fhashes[fi]}
			val, found, f_err := cursor_read_field_path_prehashed(snap_cur, path[:], &s.interner, sf.type.kind)
			if f_err == nil && found {
				if sid, is_s := val.(String_Id); is_s {
					txt := interner_get(&s.interner, sid)
					if mapped, m_err := intern_session_string(&s.rb.interner, &s.interner, txt); m_err == nil {
						val = mapped
					}
				}
				fields[fi] = val
			}
		}
	}

	fid = Fact_Id(len(s.facts))
	recency := s.next_recency
	s.next_recency += 1
	append(&s.facts, Fact{
		id            = fid,
		binding_idx   = binding_idx,
		key           = key_id,
		fields        = fields,
		cursor        = cursor,
		has_cursor    = true,
		recency       = recency,
		alive         = true,
		support_count = 1,
		origin        = .External,
	})
	for len(s.fact_alpha_head) <= int(fid) {
		append(&s.fact_alpha_head, -1)
	}
	s.facts_by_key[lk] = fid
	_record_dirty_derived_fact(s, fid, binding_idx)

	alpha_eval_insert_fact(s, fid)
	return fid, .None
}

session_retract_fact_by_key :: proc(
	s: ^Session,
	binding_name: string,
	key: string,
) -> Session_Error {
	bidx, ok := session_find_binding(s, binding_name)
	if !ok {
		return .Unknown_Binding
	}
	key_id, has_key := _lookup_interned_string_id(&s.rb.interner, &s.interner, key)
	if !has_key {
		return .None
	}
	lk := Fact_Lookup_Key{binding_idx = bidx, key = key_id}
	fid, found := s.facts_by_key[lk]
	if !found {
		return .None
	}
	return session_retract_fact(s, fid)
}

session_modify_fact_by_key :: proc(
	s: ^Session,
	binding_name: string,
	key: string,
	new_fields: []Value,
) -> Session_Error {
	if s == nil || s.rb == nil {
		return .Unknown_Binding
	}
	bidx, ok := session_find_binding(s, binding_name)
	if !ok {
		return .Unknown_Binding
	}
	bdef := s.rb.bindings[bidx]
	schema := s.rb.schemas[bdef.schema_id]
	if r_err := _validate_fact_fields_range(schema, new_fields); r_err != .None {
		return r_err
	}
	if s.provenance.mode == .Fast {
		if key_id, k_ok := _lookup_interned_string_id(&s.rb.interner, &s.interner, key); k_ok {
			lk := Fact_Lookup_Key{binding_idx = bidx, key = key_id}
			if fid, found := s.facts_by_key[lk]; found {
				f := &s.facts[fid]
				if f.alive && f.origin == .External {
					f.alive = false
					alpha_eval_retract_fact(s, fid)
					agenda_remove_fact(&s.agenda, fid)
					jtms_retract_cascades_for_fact(s, fid)
					f = &s.facts[fid]

					need_len := max(len(schema.fields), len(new_fields))
					if len(f.fields) != need_len {
						f.fields = make([]Value, need_len, vmem.arena_allocator(&s.arena))
					} else {
						for &fv in f.fields {
							fv = nil
						}
					}
					_normalize_fact_fields_into(s, schema, new_fields, f.fields)
					f.has_cursor = false
					f.cursor = {}
					f.recency = s.next_recency
					s.next_recency += 1
					f.alive = true
					f.support_count = 1
					f.proof_height = 0
					f.best_derivation = INVALID_DERIVATION

					_record_dirty_derived_fact(s, fid, bidx)
					alpha_eval_insert_fact(s, fid)
					return .None
				}
			}
		}
	}
	_, err := session_insert_fact_by_idx(s, bidx, key, new_fields)
	return err
}

session_retract_fact :: proc(s: ^Session, fid: Fact_Id) -> Session_Error {
	if s == nil || fid == INVALID_FACT || int(fid) >= len(s.facts) {
		return .None
	}
	f := &s.facts[fid]
	if !f.alive {
		return .None
	}
	f.alive = false
	_record_retracted_derived_key(s, f)
	lk := Fact_Lookup_Key{binding_idx = f.binding_idx, key = f.key}
	if cur, has := s.facts_by_key[lk]; has && cur == fid {
		delete_key(&s.facts_by_key, lk)
	}
	if f.origin == .Logical {
		jtms_remove_logical_bucket_entry(s, fid)
	}
	alpha_eval_retract_fact(s, fid)
	agenda_remove_fact(&s.agenda, fid)
	jtms_retract_cascades_for_fact(s, fid)
	return .None
}

@(private)
_next_derived_key :: proc(s: ^Session, binding_idx: u16) -> string {
	seq := s.derived_seq_by_bind[binding_idx] + 1
	s.derived_seq_by_bind[binding_idx] = seq
	bname := interner_get(&s.rb.interner, s.rb.bindings[binding_idx].name)
	return fmt.tprintf("%s:%d", bname, seq)
}

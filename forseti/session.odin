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
	id:            Fact_Id,
	binding_idx:   u16,
	key:           String_Id,
	fields:        []Value,
	cursor:        xitdb.Read_Cursor,
	has_cursor:    bool,
	recency:       u64,
	alive:         bool,
	support_count: i32,
	origin:        Fact_Origin,
}

Fact_Lookup_Key :: struct {
	binding_idx: u16,
	key:         String_Id,
}

Alpha_Memory :: struct {
	id:       u32,
	fact_ids: [dynamic]Fact_Id,
	fact_pos: map[Fact_Id]int,
	version:  u64,
}

Segment_Memory :: struct {
	seg_id:      u32,
	linked_mask: u64,
	was_linked:  bool,
	dirty:       bool,
}

Beta_Memory :: struct {
	node_id:             u32,
	right_alpha_version: u64,
	right_facts:         [dynamic]Fact_Id,
	right_buckets:       map[u64][dynamic]Fact_Id,
}

Session_Config :: struct {
	max_activations: u64,
	initial_phases:  []string,
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
	rb:                  ^Rulebase,
	arena:               vmem.Arena,
	interner:            String_Interner,
	telemetry:           ^Telemetry_Sink,
	facts:               [dynamic]Fact,
	facts_by_key:        map[Fact_Lookup_Key]Fact_Id,
	fact_alpha_mems:     map[Fact_Id][dynamic]u32,
	alpha_mems:          map[u32]^Alpha_Memory,
	seg_mems:            map[u32]^Segment_Memory,
	dirty_segs:          [dynamic]u32,
	beta_mems:           map[u32]^Beta_Memory,
	eval_stack:          [dynamic]Eval_Frame,
	agenda:              Agenda,
	fired_trace:         [dynamic]String_Id,
	derived_seq_by_bind: map[u16]u64,
	max_activations:     u64,
	next_recency:        u64,
	live_memories_count: u64,
	allocator:           mem.Allocator,
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
	s.fact_alpha_mems = make(map[Fact_Id][dynamic]u32, 16, allocator)
	s.alpha_mems = make(map[u32]^Alpha_Memory, 16, allocator)
	s.seg_mems = make(map[u32]^Segment_Memory, 16, allocator)
	s.dirty_segs = make([dynamic]u32, 0, 16, allocator)
	s.beta_mems = make(map[u32]^Beta_Memory, 16, allocator)
	s.eval_stack = make([dynamic]Eval_Frame, 0, 16, allocator)
	s.fired_trace = make([dynamic]String_Id, 0, 16, allocator)
	s.derived_seq_by_bind = make(map[u16]u64, 8, allocator)
	agenda_init(&s.agenda, allocator)

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
	agenda_destroy(&s.agenda)
	delete(s.fired_trace)
	delete(s.derived_seq_by_bind)
	delete(s.eval_stack)
	delete(s.dirty_segs)

	for _, bm in s.beta_mems {
		for _, bucket in bm.right_buckets {
			delete(bucket)
		}
		delete(bm.right_buckets)
		delete(bm.right_facts)
		free(bm, s.allocator)
	}
	delete(s.beta_mems)

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

	for _, list in s.fact_alpha_mems {
		delete(list)
	}
	delete(s.fact_alpha_mems)

	delete(s.facts_by_key)
	for &f in s.facts {
		if f.fields != nil {
			delete(f.fields, s.allocator)
		}
	}
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

// Normalizes incoming Values into Session string space (using immutable Rulebase IDs when matched).
@(private)
_normalize_fact_fields :: proc(s: ^Session, schema: Schema_Def, fields: []Value) -> []Value {
	n := max(len(schema.fields), len(fields))
	out := make([]Value, n, s.allocator)
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
	return out
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
	s.facts_by_key[lk] = fid

	alpha_eval_insert_fact(s, fid)
	return fid, .None
}

session_insert_cursor_fact :: proc(
	s: ^Session,
	binding_idx: u16,
	key: string,
	cursor: xitdb.Read_Cursor,
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
	fields := make([]Value, len(schema.fields), s.allocator) // nil entries populated lazily on first touch

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
	s.facts_by_key[lk] = fid

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
	key_id, _ := intern_session_string(&s.rb.interner, &s.interner, key)
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
	session_retract_fact_by_key(s, binding_name, key) or_return
	_, err := session_insert_fact(s, binding_name, key, new_fields)
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
	lk := Fact_Lookup_Key{binding_idx = f.binding_idx, key = f.key}
	if cur, has := s.facts_by_key[lk]; has && cur == fid {
		delete_key(&s.facts_by_key, lk)
	}
	alpha_eval_retract_fact(s, fid)
	agenda_remove_fact(&s.agenda, fid)
	return .None
}

@(private)
_next_derived_key :: proc(s: ^Session, binding_idx: u16) -> string {
	seq := s.derived_seq_by_bind[binding_idx] + 1
	s.derived_seq_by_bind[binding_idx] = seq
	bname := interner_get(&s.rb.interner, s.rb.bindings[binding_idx].name)
	return fmt.tprintf("%s:%d", bname, seq)
}

package forseti

import "core:mem"

Provenance_Mode :: enum u8 {
	Audit_Full,
	Support_Only,
	Fast,
}

Derivation_Id :: distinct u32
INVALID_DERIVATION :: Derivation_Id(0)

// Compact 32-byte derivation record stored in #soa[dynamic]Derivation with zero hot-path crypto hashing.
Derivation :: struct {
	derived_fact: Fact_Id,
	rule_id:      u32,
	parent_start: u32,
	proof_height: u32,
	tx_seq:       u32,
	rule_ver:     u16,
	table_row_id: u16,
	parent_count: u16,
	table_idx:    u16, // 0xffff if no table involved
	origin_kind:  Fact_Origin,
	weight:       i8,
	alive:        bool,
	_pad:         u8,
}
#assert(size_of(Derivation) == 32)

INVALID_TABLE_IDX :: max(u16)
INVALID_ROW_ID    :: max(u16)

Provenance_Store :: struct {
	mode:              Provenance_Mode,
	derivs:            #soa[dynamic]Derivation,
	parent_facts:      [dynamic]Fact_Id,
	fact_derivs:       map[Fact_Id][dynamic]Derivation_Id,
	rule_derivs:       map[u32][dynamic]Derivation_Id,
	last_tx_derivs:    [dynamic]Derivation_Id,
	tx_seq:            u32,
	hot_crypto_hashes: u64, // Always 0: invariant check against hot-path SHA-1/SHA-256
	allocator:         mem.Allocator,
}

@(private)
provenance_init :: proc(p: ^Provenance_Store, mode: Provenance_Mode, allocator: mem.Allocator) {
	p^ = {}
	p.mode = mode
	p.allocator = allocator
	if mode == .Fast {
		return
	}
	p.derivs = make(#soa[dynamic]Derivation, 1, 16, allocator) // slot 0 = INVALID_DERIVATION sentinel
	p.parent_facts = make([dynamic]Fact_Id, 0, 32, allocator)
	p.fact_derivs = make(map[Fact_Id][dynamic]Derivation_Id, 16, allocator)
	p.rule_derivs = make(map[u32][dynamic]Derivation_Id, 16, allocator)
	p.last_tx_derivs = make([dynamic]Derivation_Id, 0, 16, allocator)
	p.tx_seq = 1
}

@(private)
provenance_destroy :: proc(p: ^Provenance_Store) {
	if p == nil || p.allocator.procedure == nil {
		return
	}
	for _, list in p.fact_derivs {
		delete(list)
	}
	delete(p.fact_derivs)
	for _, list in p.rule_derivs {
		delete(list)
	}
	delete(p.rule_derivs)
	delete(p.last_tx_derivs)
	delete(p.parent_facts)
	delete(p.derivs)
	p^ = {}
}

@(private)
provenance_begin_tx :: proc(p: ^Provenance_Store) {
	if p == nil || p.mode != .Audit_Full {
		return
	}
	p.tx_seq += 1
	clear(&p.last_tx_derivs)
}

@(private)
provenance_record :: proc(
	p: ^Provenance_Store,
	telemetry: ^Telemetry_Sink,
	derived_fact: Fact_Id,
	rule_id: u32,
	rule_ver: u16,
	parents: []Fact_Id,
	proof_height: u32,
	origin_kind: Fact_Origin,
	table_idx: u16 = INVALID_TABLE_IDX,
	table_row_id: u16 = INVALID_ROW_ID,
) -> Derivation_Id {
	if p == nil || p.mode != .Audit_Full {
		return INVALID_DERIVATION
	}

	p_start := u32(len(p.parent_facts))
	for pf in parents {
		append(&p.parent_facts, pf)
	}

	did := Derivation_Id(len(p.derivs))
	append(&p.derivs, Derivation{
		derived_fact = derived_fact,
		rule_id      = rule_id,
		parent_start = p_start,
		proof_height = proof_height,
		tx_seq       = p.tx_seq,
		rule_ver     = rule_ver,
		table_row_id = table_row_id,
		parent_count = u16(min(len(parents), int(max(u16)))),
		table_idx    = table_idx,
		origin_kind  = origin_kind,
		weight       = 1,
		alive        = true,
	})

	flist, has_f := &p.fact_derivs[derived_fact]
	if !has_f {
		p.fact_derivs[derived_fact] = make([dynamic]Derivation_Id, 0, 2, p.allocator)
		flist = &p.fact_derivs[derived_fact]
	}
	append(flist, did)

	rlist, has_r := &p.rule_derivs[rule_id]
	if !has_r {
		p.rule_derivs[rule_id] = make([dynamic]Derivation_Id, 0, 4, p.allocator)
		rlist = &p.rule_derivs[rule_id]
	}
	append(rlist, did)
	append(&p.last_tx_derivs, did)

	telemetry_count_add(telemetry, .Derivations_Recorded, 1)
	return did
}

@(private)
provenance_mark_retracted :: proc(p: ^Provenance_Store, did: Derivation_Id) {
	if p == nil || p.mode != .Audit_Full || did == INVALID_DERIVATION || int(did) >= len(p.derivs) {
		return
	}
	p.derivs[did].alive = false
	p.derivs[did].weight = -1
}

@(private)
provenance_parents :: proc(p: ^Provenance_Store, did: Derivation_Id) -> []Fact_Id {
	if p == nil || p.mode != .Audit_Full || did == INVALID_DERIVATION || int(did) >= len(p.derivs) {
		return nil
	}
	d := p.derivs[did]
	start := int(d.parent_start)
	end := start + int(d.parent_count)
	if start < 0 || end > len(p.parent_facts) {
		return nil
	}
	return p.parent_facts[start:end]
}

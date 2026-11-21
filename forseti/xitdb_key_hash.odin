package forseti

import "core:encoding/endian"
import "core:sync"
import xitdb "xitdb:."

// Opt-in 128-bit non-cryptographic hasher ("fh16") kept in Forseti for trusted
// ephemeral in-memory stores (`Xitdb_Config{mode = .Fast_Memory}`).
FAST_HASH_ID   :: u32(0x66683136) // "fh16"
FAST_HASH_SIZE :: u16(16)

@(private)
_wymix64 :: #force_inline proc "contextless" (a, b: u64) -> u64 {
	r := u128(a) * u128(b)
	return u64(r) ~ u64(r >> 64)
}

@(private)
_read_u64_le_padded :: #force_inline proc "contextless" (p: []u8) -> u64 #no_bounds_check {
	n := len(p)
	if n >= 8 {
		v, _ := endian.get_u64(p[:8], .Little)
		return v
	}
	v: u64 = 0
	for i := 0; i < n; i += 1 {
		v |= u64(p[i]) << u64(i * 8)
	}
	return v
}

fast_hash128_sum_into :: proc "contextless" (data: []u8, out: []u8) #no_bounds_check {
	s0 :: u64(0xa0761d6478bd642f)
	s1 :: u64(0xe7037ed1a0b428db)
	s2 :: u64(0x8ebc6af09c88c6e3)
	s3 :: u64(0x589965cc75374cc3)

	seed_a := s0 ~ _wymix64(u64(len(data)) ~ s1, s2)
	seed_b := s1 ~ _wymix64(u64(len(data)) ~ s3, s0)

	i := 0
	for i + 16 <= len(data) {
		v0, _ := endian.get_u64(data[i:i + 8], .Little)
		v1, _ := endian.get_u64(data[i + 8:i + 16], .Little)
		seed_a = _wymix64(v0 ~ s1, v1 ~ seed_a) ~ seed_b
		seed_b = _wymix64(v1 ~ s2, v0 ~ seed_b) ~ s3
		i += 16
	}

	rem := data[i:]
	a := _read_u64_le_padded(rem)
	b: u64 = 0
	if len(rem) > 8 {
		b = _read_u64_le_padded(rem[8:])
	}

	h0 := _wymix64(seed_a ~ a ~ s1, seed_b ~ u64(len(data)) ~ s2)
	h1 := _wymix64(seed_b ~ b ~ s3, seed_a ~ u64(len(data)) ~ s0)
	h0 = _wymix64(h0 ~ s0, h1 ~ s3)
	h1 = _wymix64(h1 ~ s2, h0 ~ s1)

	if len(out) >= 8 {
		endian.unchecked_put_u64be(out[0:8], h0)
	}
	if len(out) >= 16 {
		endian.unchecked_put_u64be(out[8:16], h1)
	}
}

fast_hasher :: proc(id: u32 = FAST_HASH_ID, file_id: u64 = 0) -> xitdb.Hasher {
	effective_id := id if id != 0 else FAST_HASH_ID
	return xitdb.Hasher{
		hash_proc = proc(data: []u8, out_hash: []u8, _: rawptr) {
			fast_hash128_sum_into(data, out_hash)
		},
		hash_size = FAST_HASH_SIZE,
		id        = effective_id,
		file_id   = file_id,
	}
}

// Prehashed_Key stores wire-compatible SHA-1 (Safe_V2) and fast128 digests for a static key.
// `key` must outlive this struct (e.g. owned by Rulebase.interner, Watched_Collection, or rodata).
Prehashed_Key :: struct {
	key:     string,
	sha1:    [20]u8,
	fast128: [16]u8,
}

@(require_results)
prehashed_key_make :: proc(key: string) -> Prehashed_Key {
	pk := Prehashed_Key{key = key}
	raw := transmute([]u8)key
	xitdb.sha1_sum_into(raw, pk.sha1[:])
	fast_hash128_sum_into(raw, pk.fast128[:])
	return pk
}

prehashed_key_digest :: #force_inline proc(db: ^xitdb.Database, pk: ^Prehashed_Key, fallback_buf: []u8) -> []u8 {
	if db.hasher.id == 0 && db.hasher.hash_size == 20 {
		return pk.sha1[:]
	}
	if db.hasher.id == FAST_HASH_ID && db.hasher.hash_size == FAST_HASH_SIZE {
		return pk.fast128[:]
	}
	return xitdb.database_digest_string_buf(db, pk.key, fallback_buf)
}

hash_map_get_slot_prehashed :: #force_inline proc(m: xitdb.Read_Hash_Map, pk: ^Prehashed_Key) -> (Maybe(xitdb.Slot), xitdb.Error) {
	buf: [64]u8 = ---
	return xitdb.hash_map_get_slot_by_hash(m, prehashed_key_digest(m.cursor.db, pk, buf[:]))
}

hash_map_get_cursor_prehashed :: #force_inline proc(m: xitdb.Read_Hash_Map, pk: ^Prehashed_Key) -> (Maybe(xitdb.Read_Cursor), xitdb.Error) {
	buf: [64]u8 = ---
	return xitdb.hash_map_get_cursor_by_hash(m, prehashed_key_digest(m.cursor.db, pk, buf[:]))
}

hash_set_get_slot_prehashed :: #force_inline proc(s: xitdb.Read_Hash_Set, pk: ^Prehashed_Key) -> (Maybe(xitdb.Slot), xitdb.Error) {
	buf: [64]u8 = ---
	return xitdb.hash_set_get_slot_by_hash(s, prehashed_key_digest(s.cursor.db, pk, buf[:]))
}

hash_set_get_cursor_prehashed :: #force_inline proc(s: xitdb.Read_Hash_Set, pk: ^Prehashed_Key) -> (Maybe(xitdb.Read_Cursor), xitdb.Error) {
	buf: [64]u8 = ---
	return xitdb.hash_set_get_cursor_by_hash(s, prehashed_key_digest(s.cursor.db, pk, buf[:]))
}

hash_map_put_prehashed :: #force_inline proc(m: ^xitdb.Write_Hash_Map, pk: ^Prehashed_Key, data: xitdb.Writeable_Data) -> xitdb.Error {
	buf: [64]u8 = ---
	h := prehashed_key_digest(m.cursor.db, pk, buf[:])
	return xitdb.hash_map_put_key_and_value(m, h, pk.key, data)
}

hash_map_put_cursor_prehashed :: #force_inline proc(m: ^xitdb.Write_Hash_Map, pk: ^Prehashed_Key) -> (res: xitdb.Write_Cursor, err: xitdb.Error) {
	buf: [64]u8 = ---
	h := prehashed_key_digest(m.cursor.db, pk, buf[:])
	xitdb.hash_map_put_key_by_hash(m, h, pk.key) or_return
	return xitdb.hash_map_put_cursor_by_hash(m, h)
}

hash_map_remove_prehashed :: #force_inline proc(m: ^xitdb.Write_Hash_Map, pk: ^Prehashed_Key) -> (res: bool, err: xitdb.Error) {
	buf: [64]u8 = ---
	h := prehashed_key_digest(m.cursor.db, pk, buf[:])
	return xitdb.hash_map_remove_by_hash(m, h)
}

hash_set_put_prehashed :: #force_inline proc(s: ^xitdb.Write_Hash_Set, pk: ^Prehashed_Key) -> xitdb.Error {
	buf: [64]u8 = ---
	h := prehashed_key_digest(s.cursor.db, pk, buf[:])
	return xitdb.hash_set_put_by_hash(s, h, pk.key)
}

@(private)
Audit_Static_Keys :: struct {
	decisions:           Prehashed_Key,
	idx:                 Prehashed_Key,
	decisions_by_entity: Prehashed_Key,
	decisions_by_rule:   Prehashed_Key,
	tx_root:             Prehashed_Key,
	tx_seq:              Prehashed_Key,
	module:              Prehashed_Key,
	decision_ids:        Prehashed_Key,
	rule_versions:       Prehashed_Key,
	rule:                Prehashed_Key,
	rule_version:        Prehashed_Key,
	proof_height:        Prehashed_Key,
	weight:              Prehashed_Key,
	derived_fact_id:     Prehashed_Key,
	alive:               Prehashed_Key,
	derived_binding:     Prehashed_Key,
	derived_key:         Prehashed_Key,
	table:               Prehashed_Key,
	table_row:           Prehashed_Key,
	parents:             Prehashed_Key,
}

@(private = "file")
_audit_keys_once: sync.Once

@(private = "file")
_audit_keys_storage: Audit_Static_Keys

@(private = "file")
_init_audit_keys_fn :: proc() {
	_audit_keys_storage = Audit_Static_Keys{
		decisions           = prehashed_key_make("decisions"),
		idx                 = prehashed_key_make("idx"),
		decisions_by_entity = prehashed_key_make("decisions_by_entity"),
		decisions_by_rule   = prehashed_key_make("decisions_by_rule"),
		tx_root             = prehashed_key_make("__tx"),
		tx_seq              = prehashed_key_make("tx_seq"),
		module              = prehashed_key_make("module"),
		decision_ids        = prehashed_key_make("decision_ids"),
		rule_versions       = prehashed_key_make("rule_versions"),
		rule                = prehashed_key_make("rule"),
		rule_version        = prehashed_key_make("rule_version"),
		proof_height        = prehashed_key_make("proof_height"),
		weight              = prehashed_key_make("weight"),
		derived_fact_id     = prehashed_key_make("derived_fact_id"),
		alive               = prehashed_key_make("alive"),
		derived_binding     = prehashed_key_make("derived_binding"),
		derived_key         = prehashed_key_make("derived_key"),
		table               = prehashed_key_make("table"),
		table_row           = prehashed_key_make("table_row"),
		parents             = prehashed_key_make("parents"),
	}
}

@(private)
audit_static_keys :: #force_inline proc() -> ^Audit_Static_Keys {
	sync.once_do(&_audit_keys_once, _init_audit_keys_fn)
	return &_audit_keys_storage
}

package forseti

import "core:sync"
import xitdb "xitdb:."

// Prehashed_Key stores wire-compatible SHA-1 digest for a static key.
// `key` must outlive this struct (e.g. owned by Rulebase.interner, Watched_Collection, or rodata).
Prehashed_Key :: struct {
	key:  string,
	sha1: [20]u8,
}

@(require_results)
prehashed_key_make :: proc(key: string) -> Prehashed_Key {
	pk := Prehashed_Key{key = key}
	raw := transmute([]u8)key
	xitdb.sha1_sum_into(raw, pk.sha1[:])
	return pk
}

prehashed_key_digest :: #force_inline proc(db: ^xitdb.Database, pk: ^Prehashed_Key, fallback_buf: []u8) -> []u8 {
	if db.hasher.hash_proc == xitdb.sha1_hasher().hash_proc && db.hasher.hash_size == 20 && db.hasher.user_data == nil {
		return pk.sha1[:]
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
	unknown:             Prehashed_Key,
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
		unknown             = prehashed_key_make("unknown"),
	}
}

@(private)
audit_static_keys :: #force_inline proc() -> ^Audit_Static_Keys {
	sync.once_do(&_audit_keys_once, _init_audit_keys_fn)
	return &_audit_keys_storage
}

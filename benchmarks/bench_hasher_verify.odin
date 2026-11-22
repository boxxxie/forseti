package main

import "core:bytes"
import "core:crypto/legacy/sha1"
import "core:encoding/endian"
import "core:fmt"
import hugi "hugi:."
import xitdb "xitdb:."
import forseti "../forseti"

@(private = "file")
_HASH_RING_LEN :: 64

@(private = "file")
_HASH_VERIFY_COUNT :: 1_000

@(private = "file")
_Hash_Seed_Ctx :: struct {
	keys: []string,
}

@(private = "file")
_sw_sha1_proc :: proc(data: []u8, out_hash: []u8, _: rawptr) {
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, data)
	sha1.final(&ctx, out_hash)
}

@(private = "file")
_sw_sha1_hasher :: proc() -> xitdb.Hasher {
	return xitdb.Hasher{
		hash_proc = _sw_sha1_proc,
		hash_size = sha1.DIGEST_SIZE,
	}
}

@(private = "file")
_make_ring_keys :: proc(key_len: int, allocator := context.temp_allocator) -> [][]u8 {
	buf := make([]u8, _HASH_RING_LEN * key_len, allocator)
	keys := make([][]u8, _HASH_RING_LEN, allocator)
	for k := 0; k < _HASH_RING_LEN; k += 1 {
		off := k * key_len
		for j := 0; j < key_len; j += 1 {
			buf[off + j] = u8(((k * 31) + (j * 17) + 7) & 0xff)
		}
		keys[k] = buf[off:off + key_len]
	}
	return keys
}

@(private = "file")
_make_sized_string_keys :: proc(count: int, key_len: int, allocator := context.temp_allocator) -> []string {
	klen := max(key_len, 10)
	buf := make([]u8, count * klen, allocator)
	keys := make([]string, count, allocator)
	for i := 0; i < count; i += 1 {
		off := i * klen
		slice := buf[off:off + klen]
		_ = fmt.bprintf(slice[:10], "org:%06d", i)
		for j := 10; j < klen; j += 1 {
			slice[j] = u8('a' + ((i + j) % 26))
		}
		keys[i] = string(slice)
	}
	return keys
}

@(private = "file")
_bench_hash_seed_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ctx := (^_Hash_Seed_Ctx)(user_data)
	m, err := forseti.store_write_path_ensure_map(moment_wc, ".orgs.raw")
	if err != nil {
		return .Write_Failed
	}
	for k, idx in ctx.keys {
		xitdb.hash_map_put(&m, k, i64(idx)) or_return
	}
	return nil
}

@(private = "file")
_run_raw_hasher :: proc(b: ^hugi.Bencher, h: xitdb.Hasher) {
	key_len := max(hugi.param(b), 10)
	defer free_all(context.temp_allocator)

	keys := _make_ring_keys(key_len, context.temp_allocator)
	if h.hash_size == sha1.DIGEST_SIZE {
		hw_digest: [sha1.DIGEST_SIZE]u8 = ---
		sw_digest: [sha1.DIGEST_SIZE]u8 = ---
		xitdb.sha1_sum_into(keys[0], hw_digest[:])
		_sw_sha1_proc(keys[0], sw_digest[:], nil)
		assert(bytes.equal(hw_digest[:], sw_digest[:]))
	}

	out_buf: [64]u8
	out := out_buf[:int(h.hash_size)]
	h_proc := hugi.black_box(h.hash_proc)

	hugi.set_items(b, 1)
	hugi.set_bytes(b, u64(key_len))
	hugi.expect_zero_allocs(b)

	idx := 0
	acc: u64 = 0
	for hugi.step(b) {
		key := keys[idx & (_HASH_RING_LEN - 1)]
		idx += 1
		h_proc(key, out, h.user_data)
		lo, _ := endian.get_u64(out[0:8], .Little)
		hi, _ := endian.get_u64(out[len(out) - 8:len(out)], .Little)
		acc ~= lo + hi
	}
	_ = hugi.black_box(acc)
}

@(private = "file")
_run_xitdb_lookup_sized :: proc(b: ^hugi.Bencher, cfg: forseti.Xitdb_Config, prehashed: bool) {
	key_len := max(hugi.param(b), 10)
	defer free_all(context.temp_allocator)

	sb := new(forseti.Store_Bridge)
	assert(forseti.store_bridge_init_standalone(sb, cfg) == nil)
	defer {
		forseti.store_bridge_destroy(sb)
		free(sb)
	}

	keys := _make_sized_string_keys(_HASH_VERIFY_COUNT, key_len, context.temp_allocator)
	seed_ctx := _Hash_Seed_Ctx{keys = keys}
	_, _ = forseti.store_bridge_commit_moment(sb, _bench_hash_seed_cb, &seed_ctx)

	m_cur, _, _ := forseti.store_bridge_moment_cursor(sb, -1)
	col_cur, _, _ := forseti.store_resolve_path(m_cur, ".orgs.raw")
	rm, _ := xitdb.read_hash_map_init(col_cur)

	pkeys: []forseti.Prehashed_Key
	if prehashed {
		pkeys = make([]forseti.Prehashed_Key, len(keys), context.temp_allocator)
		for k, idx in keys {
			pkeys[idx] = forseti.prehashed_key_make(k)
		}
	}

	hugi.set_items(b, u64(len(keys)))
	hugi.set_bytes(b, u64(len(keys) * key_len))
	hugi.expect_zero_allocs(b)

	sum: i64 = 0
	for hugi.step(b) {
		iter_sum: i64 = 0
		if prehashed {
			for &pk in pkeys {
				ms, _ := forseti.hash_map_get_slot_prehashed(rm, &pk)
				if slot, ok := ms.?; ok {
					v, _, _ := forseti.decode_slot_to_value(sb.db, slot, nil)
					if iv, is_i := v.(i64); is_i {
						iter_sum += iv
					}
				}
			}
		} else {
			for k in keys {
				ms, _ := xitdb.hash_map_get_slot(rm, k)
				if slot, ok := ms.?; ok {
					v, _, _ := forseti.decode_slot_to_value(sb.db, slot, nil)
					if iv, is_i := v.(i64); is_i {
						iter_sum += iv
					}
				}
			}
		}
		assert(iter_sum > 0)
		sum += iter_sum
	}
	_ = hugi.black_box(sum)
}

@(private = "file")
_run_xitdb_insert_sized :: proc(b: ^hugi.Bencher, cfg: forseti.Xitdb_Config) {
	key_len := max(hugi.param(b), 10)
	defer free_all(context.temp_allocator)

	keys := _make_sized_string_keys(_HASH_VERIFY_COUNT, key_len, context.temp_allocator)
	seed_ctx := _Hash_Seed_Ctx{keys = keys}

	hugi.set_items(b, u64(len(keys)))
	hugi.set_bytes(b, u64(len(keys) * key_len))

	for hugi.step(b) {
		sb := new(forseti.Store_Bridge)
		assert(forseti.store_bridge_init_standalone(sb, cfg) == nil)
		_, _ = forseti.store_bridge_commit_moment(sb, _bench_hash_seed_cb, &seed_ctx)
		_ = hugi.black_box(sb.db.header.file_id)
		forseti.store_bridge_destroy(sb)
		free(sb)
	}
}

@(private = "file")
_bench_raw_xitdb_sha1_hw :: proc(b: ^hugi.Bencher) {
	_run_raw_hasher(b, xitdb.sha1_hasher())
}

@(private = "file")
_bench_raw_xitdb_sha256_hw :: proc(b: ^hugi.Bencher) {
	_run_raw_hasher(b, xitdb.sha256_hasher())
}

@(private = "file")
_bench_raw_core_crypto_sha1_sw :: proc(b: ^hugi.Bencher) {
	_run_raw_hasher(b, _sw_sha1_hasher())
}

@(private = "file")
_bench_xitdb_lookup_sha1_hw :: proc(b: ^hugi.Bencher) {
	_run_xitdb_lookup_sized(b, forseti.Xitdb_Config{}, prehashed = false)
}

@(private = "file")
_bench_xitdb_lookup_sha256_hw :: proc(b: ^hugi.Bencher) {
	_run_xitdb_lookup_sized(b, forseti.Xitdb_Config{custom_hasher = xitdb.sha256_hasher()}, prehashed = false)
}

@(private = "file")
_bench_xitdb_lookup_sha1_prehashed :: proc(b: ^hugi.Bencher) {
	_run_xitdb_lookup_sized(b, forseti.Xitdb_Config{}, prehashed = true)
}

@(private = "file")
_bench_xitdb_insert_sha1_hw :: proc(b: ^hugi.Bencher) {
	_run_xitdb_insert_sized(b, forseti.Xitdb_Config{})
}

@(private = "file")
_bench_xitdb_insert_sha256_hw :: proc(b: ^hugi.Bencher) {
	_run_xitdb_insert_sized(b, forseti.Xitdb_Config{custom_hasher = xitdb.sha256_hasher()})
}

register_hasher_verify_benchmarks :: proc(suite: ^hugi.Suite) {
	g_raw := hugi.group_add(suite, "hasher_raw_verify")
	hugi.group_params(g_raw, []int{10, 32, 64, 256, 1_024, 4_096})
	hugi.group_bench(g_raw, "xitdb_sha1_hw", _bench_raw_xitdb_sha1_hw, zero_alloc = true)
	hugi.group_bench(g_raw, "xitdb_sha256_hw", _bench_raw_xitdb_sha256_hw, zero_alloc = true)
	hugi.group_bench(g_raw, "core_crypto_sha1_sw", _bench_raw_core_crypto_sha1_sw, zero_alloc = true)

	g_xit := hugi.group_add(suite, "hasher_xitdb_verify")
	hugi.group_params(g_xit, []int{10, 64, 256, 1_024})
	hugi.group_bench(g_xit, "lookup_1k_safe_v2_sha1_hw", _bench_xitdb_lookup_sha1_hw, zero_alloc = true)
	hugi.group_bench(g_xit, "lookup_1k_safe_v2_sha256_hw", _bench_xitdb_lookup_sha256_hw, zero_alloc = true)
	hugi.group_bench(g_xit, "lookup_1k_safe_v2_prehashed", _bench_xitdb_lookup_sha1_prehashed, zero_alloc = true)
	hugi.group_bench(g_xit, "insert_1k_safe_v2_sha1_hw", _bench_xitdb_insert_sha1_hw)
	hugi.group_bench(g_xit, "insert_1k_safe_v2_sha256_hw", _bench_xitdb_insert_sha256_hw)
}

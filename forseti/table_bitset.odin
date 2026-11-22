package forseti

import "base:intrinsics"
import "core:mem"
import "core:slice"

@(private, require_results)
build_bitset_matrix :: proc(ct: ^Compiled_Table, alloc: mem.Allocator) -> (err: mem.Allocator_Error) {
	word_count := max((ct.row_count + 63) / 64, 1)
	ct.bitset.word_count = word_count

	ct.bitset.col_eval_order = make([]int, ct.col_count, alloc) or_return
	for ci in 0 ..< ct.col_count {
		ct.bitset.col_eval_order[ci] = ci
	}
	Sort_Col :: struct {
		col_idx: int,
		cost:    u32,
	}
	sc := make([]Sort_Col, ct.col_count, context.temp_allocator)
	for ci in 0 ..< ct.col_count {
		sc[ci] = Sort_Col{col_idx = ci, cost = ct.col_costs[ci]}
	}
	slice.sort_by(sc, proc(a, b: Sort_Col) -> bool {
		if a.cost != b.cost {
			return a.cost < b.cost
		}
		return a.col_idx < b.col_idx
	})
	for s, i in sc {
		ct.bitset.col_eval_order[i] = s.col_idx
	}

	ct.bitset.col_nonwild_masks = make([][]u64, ct.col_count, alloc) or_return
	ct.bitset.col_atom_masks = make([][][]u64, ct.col_count, alloc) or_return

	for ci in 0 ..< ct.col_count {
		atom_cnt := len(ct.col_domains[ci].atoms)
		nw := make([]u64, word_count, alloc) or_return
		ct.bitset.col_nonwild_masks[ci] = nw

		am := make([][]u64, atom_cnt, alloc) or_return
		ct.bitset.col_atom_masks[ci] = am
		for ai in 0 ..< atom_cnt {
			am[ai] = make([]u64, word_count, alloc) or_return
		}

		for ri in 0 ..< ct.row_count {
			rmask := ct.row_masks[ri][ci]
			if !mask_is_full(rmask, atom_cnt) {
				nw[ri / 64] |= u64(1) << u64(ri % 64)
			}
			for ai in 0 ..< atom_cnt {
				if (rmask[ai / 64] & (u64(1) << u64(ai % 64))) != 0 {
					am[ai][ri / 64] |= u64(1) << u64(ri % 64)
				}
			}
		}
	}
	return nil
}

@(private)
CHUNK_WORDS :: 16

@(private)
eval_bitset_matrix :: proc(ct: ^Compiled_Table, input: Table_Input, res: ^Decision_Result, extra_hits: []u32) {
	fetched_mask: u64 = 0
	cached_vals: [64]Value
	cached_atoms: [64]int

	total_words := ct.bitset.word_count
	total_hits: u32 = 0
	last_hit_row: u32 = 0

	// Aggregator state for Collect_*
	has_num := false
	is_float := false
	sum_i: i64 = 0
	sum_f: f64 = 0
	min_i: i64 = 0
	min_f: f64 = 0
	max_i: i64 = 0
	max_f: f64 = 0

	for chunk_start := 0; chunk_start < total_words; chunk_start += CHUNK_WORDS {
		chunk_end := min(chunk_start + CHUNK_WORDS, total_words)
		chunk_len := chunk_end - chunk_start

		live: [CHUNK_WORDS]u64
		for cw in 0 ..< chunk_len {
			w := chunk_start + cw
			rem_rows := ct.row_count - w * 64
			if rem_rows >= 64 {
				live[cw] = ~u64(0)
			} else if rem_rows > 0 {
				live[cw] = (u64(1) << u64(rem_rows)) - 1
			}
		}

		for ci in ct.bitset.col_eval_order {
			// Skip column lazily if NO live row in this chunk restricts column `ci`
			need_col := false
			nw := ct.bitset.col_nonwild_masks[ci]
			for cw in 0 ..< chunk_len {
				if (live[cw] & nw[chunk_start + cw]) != 0 {
					need_col = true
					break
				}
			}
			if !need_col {
				continue
			}

			atom_idx := fetch_input_col(ct, input, ci, &fetched_mask, &cached_vals, &cached_atoms)
			if atom_idx < 0 || atom_idx >= len(ct.bitset.col_atom_masks[ci]) {
				any_live := false
				for cw in 0 ..< chunk_len {
					live[cw] &= ~nw[chunk_start + cw]
					if live[cw] != 0 {
						any_live = true
					}
				}
				if !any_live {
					break
				}
				continue
			}

			amask := ct.bitset.col_atom_masks[ci][atom_idx]
			any_live := false
			for cw in 0 ..< chunk_len {
				live[cw] &= amask[chunk_start + cw]
				if live[cw] != 0 {
					any_live = true
				}
			}
			if !any_live {
				break
			}
		}

		for cw in 0 ..< chunk_len {
			word_idx := chunk_start + cw
			bits := live[cw]
			for bits != 0 {
				tz := int(intrinsics.count_trailing_zeros(bits))
				row_idx := u32(word_idx * 64 + tz)
				bits &= bits - 1

				if int(total_hits) < MAX_INLINE_HITS {
					res.matched_rows[total_hits] = row_idx
				}
				if extra_hits != nil && int(total_hits) < len(extra_hits) {
					extra_hits[total_hits] = row_idx
				}
				total_hits += 1
				last_hit_row = row_idx

				#partial switch ct.hit_policy {
				case .Collect:
					if total_hits == 1 {
						res.trace.winning_row_idx = i32(row_idx)
						for oi in 0 ..< int(res.output_count) {
							if ct.row_output_set[row_idx][oi] {
								res.outputs[oi] = ct.row_outputs[row_idx][oi]
								res.output_set[oi] = true
							}
						}
					}
				case .Merge:
					if res.trace.winning_row_idx < 0 {
						res.trace.winning_row_idx = i32(row_idx)
					}
					for oi in 0 ..< int(res.output_count) {
						if !res.output_set[oi] && ct.row_output_set[row_idx][oi] {
							res.outputs[oi] = ct.row_outputs[row_idx][oi]
							res.output_set[oi] = true
						}
					}
				case .Reverse_Merge:
					res.trace.winning_row_idx = i32(row_idx)
					for oi in 0 ..< int(res.output_count) {
						if ct.row_output_set[row_idx][oi] {
							res.outputs[oi] = ct.row_outputs[row_idx][oi]
							res.output_set[oi] = true
						}
					}
				case .Collect_Sum, .Collect_Min, .Collect_Max:
					if total_hits == 1 {
						res.trace.winning_row_idx = i32(row_idx)
					}
					if int(res.output_count) > 0 && ct.row_output_set[row_idx][0] {
						ov := ct.row_outputs[row_idx][0]
						if iv, iok := value_to_i64(ov); iok && !is_float {
							if !has_num {
								has_num = true
								sum_i = iv
								min_i = iv
								max_i = iv
							} else {
								sum_i += iv
								min_i = min(min_i, iv)
								max_i = max(max_i, iv)
							}
						} else if fv, fok := value_to_f64(ov); fok {
							if !has_num {
								has_num = true
								is_float = true
								sum_f = fv
								min_f = fv
								max_f = fv
							} else {
								if !is_float {
									is_float = true
									sum_f = f64(sum_i)
									min_f = f64(min_i)
									max_f = f64(max_i)
								}
								sum_f += fv
								min_f = min(min_f, fv)
								max_f = max(max_f, fv)
							}
						}
					}
				case .Collect_Count:
					if total_hits == 1 {
						res.trace.winning_row_idx = i32(row_idx)
					}
				}
			}
		}
	}

	res.matched_row_count = total_hits
	res.trace.matched_count = total_hits
	res.trace.evaluated_col_mask = fetched_mask
	res.matched = total_hits > 0

	#partial switch ct.hit_policy {
	case .Collect_Count:
		res.outputs[0] = i64(total_hits)
		res.output_set[0] = true
	case .Collect_Sum:
		if has_num {
			res.outputs[0] = sum_f if is_float else sum_i
			res.output_set[0] = true
		}
	case .Collect_Min:
		if has_num {
			res.outputs[0] = min_f if is_float else min_i
			res.output_set[0] = true
		}
	case .Collect_Max:
		if has_num {
			res.outputs[0] = max_f if is_float else max_i
			res.output_set[0] = true
		}
	case .Reverse_Merge:
		if total_hits > 0 {
			res.trace.winning_row_idx = i32(last_hit_row)
		}
	}
}

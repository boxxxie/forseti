package forseti_tests

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:testing"
import "core:time"
import "../forseti"

@(test)
prop_retractable_accumulators_match_bruteforce :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	rng_state := rand.create(t.seed)
	rng := rand.default_random_generator(&rng_state)

	ops := []forseti.Accum_Op{.Count, .Sum, .Avg, .Min, .Max, .Distinct, .Collect}
	for op in ops {
		st: forseti.Accum_State
		forseti.accum_init(&st, op)
		defer forseti.accum_destroy(&st)

		si: forseti.String_Interner
		testing.expect_value(t, forseti.interner_init(&si), nil)
		defer forseti.interner_destroy(&si)

		active := make([dynamic]i64, 0, 64)
		defer delete(active)

		for step := 0; step < 500; step += 1 {
			if len(active) == 0 || rand.int_max(10, rng) < 6 {
				v := i64(rand.int_max(15, rng) - 3) // Deliberate duplicates/ties and negatives
				append(&active, v)
				forseti.accum_insert(&st, v, nil, &si)
			} else {
				idx := rand.int_max(len(active), rng)
				v := active[idx]
				unordered_remove(&active, idx)
				forseti.accum_retract(&st, v, nil, &si)
			}

			got_val, got_ok := forseti.accum_finalize(&st, nil, &si)

			// Brute-force ground truth over `active`:
			#partial switch op {
			case .Count:
				testing.expect(t, got_ok)
				testing.expect_value(t, got_val.(i64), i64(len(active)))
			case .Sum:
				testing.expect(t, got_ok)
				exp := i64(0)
				for x in active {
					exp += x
				}
				testing.expect_value(t, got_val.(i64), exp)
			case .Avg:
				if len(active) == 0 {
					testing.expect(t, !got_ok)
				} else {
					testing.expect(t, got_ok)
					exp := i64(0)
					for x in active {
						exp += x
					}
					exp_avg := f64(exp) / f64(len(active))
					testing.expect(t, math.abs(got_val.(f64) - exp_avg) < 1e-9)
				}
			case .Min:
				if len(active) == 0 {
					testing.expect(t, !got_ok)
				} else {
					testing.expect(t, got_ok)
					exp := active[0]
					for x in active[1:] {
						if x < exp {
							exp = x
						}
					}
					testing.expect_value(t, got_val.(i64), exp)
				}
			case .Max:
				if len(active) == 0 {
					testing.expect(t, !got_ok)
				} else {
					testing.expect(t, got_ok)
					exp := active[0]
					for x in active[1:] {
						if x > exp {
							exp = x
						}
					}
					testing.expect_value(t, got_val.(i64), exp)
				}
			case .Distinct:
				testing.expect(t, got_ok)
				seen := make(map[i64]bool, 16, context.temp_allocator)
				for x in active {
					seen[x] = true
				}
				testing.expect_value(t, got_val.(i64), i64(len(seen)))
			}
			free_all(context.temp_allocator)
		}
	}
}

@(private = "file")
_collect_canonical_derived_set :: proc(
	s: ^forseti.Session,
	rb: ^forseti.Rulebase,
) -> map[string]bool {
	out := make(map[string]bool, 32, context.temp_allocator)
	for &f in s.facts {
		if !f.alive {
			continue
		}
		bdef := rb.bindings[f.binding_idx]
		if bdef.kind != .Derived {
			continue
		}
		bname := forseti.interner_get(&rb.interner, bdef.name)
		// Format canonical `(binding, fields...)` signature (excluding internal fact key / insertion sequence).
		sig := ""
		switch len(f.fields) {
		case 1:
			sig = fmt.tprintf("%s(%v)", bname, f.fields[0])
		case 2:
			sig = fmt.tprintf("%s(%v,%v)", bname, f.fields[0], f.fields[1])
		case 3:
			sig = fmt.tprintf("%s(%v,%v,%v)", bname, f.fields[0], f.fields[1], f.fields[2])
		case:
			sig = fmt.tprintf("%s(?)", bname)
		}
		out[sig] = true
	}
	return out
}

@(test)
prop_jtms_stratified_differential_oracle_10k_ops :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)

	src := `module oracle_10k version "1.0"

schema NodeVal { n: i64, val: i64 }
schema EdgeRec { a: i64, b: i64 }
schema NodeOnly { n: i64 }
schema SummaryRec { n: i64, cnt: i64, mx: i64 }

source RawItem : NodeVal at .raw_item[?id]
source AltSeed : NodeVal at .alt_seed[?id]
source Edge : EdgeRec at .edge[?id]
source Blocker : NodeOnly at .blocker[?id]
source Witness : NodeOnly at .witness[?id]

derived BaseActive : NodeVal at .base_active[?id]
derived Reach : EdgeRec at .reach[?id]
derived NodeStats : SummaryRec at .node_stats[?id]
derived FinalOK : NodeOnly at .final_ok[?id]

// Diamond supports + Negation + Existence:
rule active_from_raw {
  when {
    ?_r := RawItem(n: ?node, val: ?v)
    exists Witness(n: ?node)
    not Blocker(n: ?node)
  }
  then { assert BaseActive(n: ?node, val: ?v) }
}

rule active_from_alt {
  when {
    ?_a := AltSeed(n: ?node, val: ?v)
    not Blocker(n: ?node)
  }
  then { assert BaseActive(n: ?node, val: ?v) }
}

// Positive cyclic recursion over edges:
rule reach_base {
  when { ?_e := Edge(a: ?x, b: ?y) }
  then { assert Reach(a: ?x, b: ?y) }
}

rule reach_trans {
  when {
    ?_r := Reach(a: ?x, b: ?y)
    ?_e := Edge(a: ?y, b: ?z)
  }
  then { assert Reach(a: ?x, b: ?z) }
}

// Stratified accumulators (count & max ties) over BaseActive:
rule summarize_node {
  when {
    ?_w := Witness(n: ?node)
    ?c := count(?v) from BaseActive(n: ?node, val: ?v)
    ?mx := max(?v) from BaseActive(n: ?node, val: ?v)
  }
  then {
    assert NodeStats(n: ?node, cnt: ?c, mx: ?mx)
  }
}

// Stratified downstream rule depending negatively on Reach & positively on NodeStats:
rule final_gate {
  when {
    ?_st := NodeStats(n: ?node, cnt: ?cnt, mx: ?_mx)
    where ?cnt >= 1
    not Reach(a: ?node, b: ?node)
  }
  then {
    assert FinalOK(n: ?node)
  }
}`

	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)
	ir, ir_err := forseti.compile_source(src, "oracle10k.forseti", &diags)
	testing.expect_value(t, ir_err, nil)
	defer forseti.ir_destroy(&ir)
	testing.expect_value(t, diags.error_count, 0)

	rb, rb_err := forseti.rulebase_compile(&ir)
	testing.expect_value(t, rb_err, forseti.Compile_Error.None)
	defer forseti.rulebase_destroy(&rb)

	inc_sess := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(inc_sess, &rb), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(inc_sess)
		free(inc_sess)
	}

	Ext_Fact :: struct {
		binding: string,
		key:     string,
		f0:      i64,
		f1:      i64,
		arity:   int,
	}
	ext_facts := make([dynamic]Ext_Fact, 0, 128)
	defer delete(ext_facts)

	rng_state := rand.create(t.seed)
	rng := rand.default_random_generator(&rng_state)

	TOTAL_OPS :: 2_500 when .Address in ODIN_SANITIZER_FLAGS else 10_000
	mismatches := 0
	seq := 0

	oracle_compare :: proc(t: ^testing.T, inc_sess: ^forseti.Session, rb: ^forseti.Rulebase, ext_facts: []Ext_Fact, mismatches: ^int) {
		oracle := new(forseti.Session)
		testing.expect_value(t, forseti.session_init(oracle, rb, forseti.Session_Config{provenance_mode = .Support_Only}), forseti.Session_Error.None)
		defer {
			forseti.session_destroy(oracle)
			free(oracle)
		}
		for ef in ext_facts {
			if ef.arity == 1 {
				_, _ = forseti.session_insert_fact(oracle, ef.binding, ef.key, {ef.f0})
			} else {
				_, _ = forseti.session_insert_fact(oracle, ef.binding, ef.key, {ef.f0, ef.f1})
			}
		}
		_, f_err := forseti.session_fire(oracle)
		testing.expect_value(t, f_err, forseti.Session_Error.None)

		actual := _collect_canonical_derived_set(inc_sess, rb)
		expected := _collect_canonical_derived_set(oracle, rb)
		if len(actual) != len(expected) {
			mismatches^ += 1
			testing.expectf(t, false, "size mismatch: inc=%d oracle=%d\nactual=%v\nexpected=%v", len(actual), len(expected), actual, expected)
		} else {
			for k in actual {
				if !(k in expected) {
					mismatches^ += 1
					testing.expectf(t, false, "extra incremental fact %q", k)
				}
			}
		}
		free_all(context.temp_allocator)
	}

	key_counter := 0
	for step := 0; step < TOTAL_OPS; step += 1 {
		op := rand.int_max(12, rng)
		switch op {
		case 0, 1: // insert RawItem
			key_counter += 1
			k := fmt.aprintf("r:%d", key_counter)
			n := i64(rand.int_max(3, rng))
			v := i64(rand.int_max(4, rng) * 10)
			_, _ = forseti.session_insert_fact(inc_sess, "RawItem", k, {n, v})
			append(&ext_facts, Ext_Fact{binding = "RawItem", key = k, f0 = n, f1 = v, arity = 2})
		case 2: // insert AltSeed
			key_counter += 1
			k := fmt.aprintf("a:%d", key_counter)
			n := i64(rand.int_max(3, rng))
			v := i64(rand.int_max(4, rng) * 10)
			_, _ = forseti.session_insert_fact(inc_sess, "AltSeed", k, {n, v})
			append(&ext_facts, Ext_Fact{binding = "AltSeed", key = k, f0 = n, f1 = v, arity = 2})
		case 3: // insert Edge (can create cycles!)
			key_counter += 1
			k := fmt.aprintf("e:%d", key_counter)
			a := i64(rand.int_max(3, rng))
			b := i64(rand.int_max(3, rng))
			_, _ = forseti.session_insert_fact(inc_sess, "Edge", k, {a, b})
			append(&ext_facts, Ext_Fact{binding = "Edge", key = k, f0 = a, f1 = b, arity = 2})
		case 4: // toggle Blocker
			n := i64(rand.int_max(3, rng))
			k := fmt.aprintf("blk:%d", n)
			found_idx := -1
			for ef, i in ext_facts {
				if ef.binding == "Blocker" && ef.key == k {
					found_idx = i
					break
				}
			}
			if found_idx >= 0 {
				_ = forseti.session_retract_fact_by_key(inc_sess, "Blocker", k)
				delete(ext_facts[found_idx].key)
				unordered_remove(&ext_facts, found_idx)
				delete(k)
			} else {
				_, _ = forseti.session_insert_fact(inc_sess, "Blocker", k, {n})
				append(&ext_facts, Ext_Fact{binding = "Blocker", key = k, f0 = n, arity = 1})
			}
		case 5: // insert Witness
			key_counter += 1
			k := fmt.aprintf("w:%d", key_counter)
			n := i64(rand.int_max(3, rng))
			_, _ = forseti.session_insert_fact(inc_sess, "Witness", k, {n})
			append(&ext_facts, Ext_Fact{binding = "Witness", key = k, f0 = n, arity = 1})
		case 6, 7: // retract random external fact
			if len(ext_facts) > 0 {
				idx := rand.int_max(len(ext_facts), rng)
				ef := ext_facts[idx]
				_ = forseti.session_retract_fact_by_key(inc_sess, ef.binding, ef.key)
				delete(ef.key)
				unordered_remove(&ext_facts, idx)
			}
		case 8: // update existing RawItem or AltSeed
			updated := false
			for &ef in ext_facts {
				if ef.binding == "RawItem" || ef.binding == "AltSeed" {
					new_v := i64(rand.int_max(4, rng) * 10)
					_ = forseti.session_modify_fact_by_key(inc_sess, ef.binding, ef.key, {ef.f0, new_v})
					ef.f1 = new_v
					updated = true
					break
				}
			}
			_ = updated
		case 9, 10, 11: // fire + verify differential parity
			_, fe := forseti.session_fire(inc_sess)
			testing.expect_value(t, fe, forseti.Session_Error.None)
			seq += 1
			// Verify against fresh oracle frequently (every fire when < 200 or periodically up to 10k ops to keep runtime fast).
			stride := 1 if seq <= 100 else 10
			if step == TOTAL_OPS - 1 || seq % stride == 0 {
				oracle_compare(t, inc_sess, &rb, ext_facts[:], &mismatches)
				if mismatches > 0 {
					break
				}
			}
		}

		// Cap live external facts around ~24 so graph stays rich with churn without exploding edge powerset.
		if len(ext_facts) > 24 {
			idx := rand.int_max(len(ext_facts), rng)
			ef := ext_facts[idx]
			_ = forseti.session_retract_fact_by_key(inc_sess, ef.binding, ef.key)
			delete(ef.key)
			unordered_remove(&ext_facts, idx)
		}
	}

	// Final fire + final exact oracle check at 10k!
	_, fe := forseti.session_fire(inc_sess)
	testing.expect_value(t, fe, forseti.Session_Error.None)
	oracle_compare(t, inc_sess, &rb, ext_facts[:], &mismatches)
	testing.expect_value(t, mismatches, 0)

	for ef in ext_facts {
		delete(ef.key)
	}
}

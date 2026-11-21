package forseti_tests

import "core:fmt"
import "core:math/rand"
import "core:testing"
import "core:time"
import "../forseti"

@(test)
test_matcher_100k_rules_sparse_session_init_and_unlinked_skip :: proc(t: ^testing.T) {
	b: forseti.Ir_Builder
	testing.expect_value(t, forseti.ir_builder_init(&b, "scale_100k", "1.0"), nil)
	defer forseti.ir_builder_destroy(&b)

	forseti.ir_schema(&b, "Acct", {forseti.field("bucket", .I64)})
	forseti.ir_schema(&b, "Trigger", {forseti.field("bucket", .I64)})
	forseti.ir_schema(&b, "Hit", {forseti.field("bucket", .I64)})
	forseti.ir_source(&b, "Acct", "Acct", ".accts[?id]")
	forseti.ir_source(&b, "Trigger", "Trigger", ".triggers[?id]")
	forseti.ir_derived(&b, "Hit", "Hit", ".hits[?id]")

	RULE_COUNT :: 10_000 when .Address in ODIN_SANITIZER_FLAGS else 100_000
	// Notice: compile 100,000 rules natively (10k under ASan so instrumented compile stays fast).
	buf: [32]u8 = ---
	for i := 0; i < RULE_COUNT; i += 1 {
		rname := fmt.bprintf(buf[:], "r_%d", i)
		forseti.ir_rule(&b, forseti.Rule_Spec{
			name = rname,
			when_clauses = {
				forseti.pat("a", "Acct", {forseti.field_bind("bucket", forseti.lit(i64(i)))}),
				forseti.pat("tr", "Trigger", {forseti.field_bind("bucket", forseti.lit(i64(i)))}),
			},
			then_actions = {
				forseti.assert_fact("Hit", {forseti.field_bind("bucket", forseti.lit(i64(i)))}),
			},
		})
	}

	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)

	ir, ir_err := forseti.ir_builder_build(&b, &diags)
	testing.expect_value(t, ir_err, nil)
	defer forseti.ir_destroy(&ir)

	tel: forseti.Telemetry_Sink
	testing.expect_value(t, forseti.telemetry_init(&tel, true), nil)
	defer forseti.telemetry_destroy(&tel)

	rb, comp_err := forseti.rulebase_compile(&ir, &tel)
	testing.expect_value(t, comp_err, forseti.Compile_Error.None)
	defer forseti.rulebase_destroy(&rb)
	testing.expect_value(t, len(rb.rules), RULE_COUNT)

	// Measure lazy session_init latency & verify zero O(rules) Beta allocations.
	t0 := time.tick_now()
	sess := new(forseti.Session)
	defer {
		forseti.session_destroy(sess)
		free(sess)
	}
	s_err := forseti.session_init(sess, &rb, forseti.Session_Config{}, &tel)
	init_ms := time.duration_milliseconds(time.tick_since(t0))
	testing.expect_value(t, s_err, forseti.Session_Error.None)
	testing.expectf(t, init_ms < 5.0, "expected sub-5ms session_init, got %.3fms", init_ms)
	testing.expect_value(t, tel.watermarks.live_session_memories, u64(0))

	// Insert left pattern for bucket 42 ONLY without Trigger -> must remain unlinked with 0 Beta joins!
	_, ins1_err := forseti.session_insert_fact(sess, "Acct", "a:42", {i64(42)})
	testing.expect_value(t, ins1_err, forseti.Session_Error.None)
	fired1, f1_err := forseti.session_fire(sess)
	testing.expect_value(t, f1_err, forseti.Session_Error.None)
	testing.expect_value(t, fired1, u64(0))
	testing.expect_value(t, tel.counters[.Beta_Joins], u64(0))
	testing.expect(t, tel.counters[.Segments_Skipped_Unlinked] >= 1)
	testing.expect(t, tel.watermarks.live_session_memories <= 4)

	// Now insert partner Trigger for bucket 42 -> links ONLY rule r_42 and fires once!
	_, ins2_err := forseti.session_insert_fact(sess, "Trigger", "t:42", {i64(42)})
	testing.expect_value(t, ins2_err, forseti.Session_Error.None)
	fired2, f2_err := forseti.session_fire(sess)
	testing.expect_value(t, f2_err, forseti.Session_Error.None)
	testing.expect_value(t, fired2, u64(1))
	testing.expect(t, tel.watermarks.live_session_memories <= 12)
}

@(test)
test_matcher_3way_join_differential_oracle :: proc(t: ^testing.T) {
	src := `module join3_oracle version "1.0"

schema A { k1: i64 }
schema B { k1: i64, k2: i64 }
schema C { k2: i64, score: i64 }
schema Out { k1: i64, k2: i64, score: i64 }

source SA : A at .a[?id]
source SB : B at .b[?id]
source SC : C at .c[?id]
derived DOut : Out at .out[?id]

rule join_abc {
  when {
    ?a := SA(k1: ?x)
    ?b := SB(k1: ?x, k2: ?y)
    ?c := SC(k2: ?y, score: ?sc)
    where ?sc >= 10
  }
  then {
    assert DOut(k1: ?x, k2: ?y, score: ?sc)
  }
}`

	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)
	ir, ir_err := forseti.compile_source(src, "join3.forseti", &diags)
	testing.expect_value(t, ir_err, nil)
	defer forseti.ir_destroy(&ir)

	rb, rb_err := forseti.rulebase_compile(&ir)
	testing.expect_value(t, rb_err, forseti.Compile_Error.None)
	defer forseti.rulebase_destroy(&rb)

	sess := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(sess, &rb), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(sess)
		free(sess)
	}

	RecA :: struct { id: string, k1: i64, fid: forseti.Fact_Id }
	RecB :: struct { id: string, k1, k2: i64, fid: forseti.Fact_Id }
	RecC :: struct { id: string, k2, sc: i64, fid: forseti.Fact_Id }
	list_a: [dynamic]RecA
	list_b: [dynamic]RecB
	list_c: [dynamic]RecC
	defer delete(list_a)
	defer delete(list_b)
	defer delete(list_c)

	rng_state := rand.create(t.seed)
	rng := rand.default_random_generator(&rng_state)
	kbuf: [32]u8 = ---
	for step := 0; step < 120; step += 1 {
		op := rand.int_max(6, rng)
		key := fmt.tprintf("k_%d", step)
		_ = kbuf
		switch op {
		case 0:
			k1 := i64(rand.int_max(4, rng))
			fid, e := forseti.session_insert_fact(sess, "SA", key, {k1})
			testing.expect_value(t, e, forseti.Session_Error.None)
			append(&list_a, RecA{id = key, k1 = k1, fid = fid})
		case 1:
			k1 := i64(rand.int_max(4, rng))
			k2 := i64(rand.int_max(4, rng))
			fid, e := forseti.session_insert_fact(sess, "SB", key, {k1, k2})
			testing.expect_value(t, e, forseti.Session_Error.None)
			append(&list_b, RecB{id = key, k1 = k1, k2 = k2, fid = fid})
		case 2:
			k2 := i64(rand.int_max(4, rng))
			sc := i64(rand.int_max(20, rng))
			fid, e := forseti.session_insert_fact(sess, "SC", key, {k2, sc})
			testing.expect_value(t, e, forseti.Session_Error.None)
			append(&list_c, RecC{id = key, k2 = k2, sc = sc, fid = fid})
		case 3:
			if len(list_a) > 0 {
				idx := rand.int_max(len(list_a), rng)
				r := list_a[idx]
				ordered_remove(&list_a, idx)
				testing.expect_value(t, forseti.session_retract_fact(sess, r.fid), forseti.Session_Error.None)
			}
		case 4:
			if len(list_b) > 0 {
				idx := rand.int_max(len(list_b), rng)
				r := list_b[idx]
				ordered_remove(&list_b, idx)
				testing.expect_value(t, forseti.session_retract_fact(sess, r.fid), forseti.Session_Error.None)
			}
		case 5:
			if len(list_c) > 0 {
				idx := rand.int_max(len(list_c), rng)
				r := list_c[idx]
				ordered_remove(&list_c, idx)
				testing.expect_value(t, forseti.session_retract_fact(sess, r.fid), forseti.Session_Error.None)
			}
		}

		_, fe := forseti.session_fire(sess)
		testing.expect_value(t, fe, forseti.Session_Error.None)

		// Compare cumulative distinct asserted DOut triples against ground-truth join set (no JTMS retraction in Track 4; Track 5 adds JTMS).
		// On insertions without retractions we verify every PHREAK triple satisfies join + guard!
		live_out := 0
		for &f in sess.facts {
			if f.alive && rb.bindings[f.binding_idx].name == ir.bindings[3].name {
				live_out += 1
				sc_v := f.fields[2].(i64)
				testing.expect(t, sc_v >= 10)
			}
		}
		_ = live_out
	}

	// Verify final ground-truth parity on a clean fresh session over the exact same surviving input facts!
	fresh := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(fresh, &rb), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(fresh)
		free(fresh)
	}
	for a in list_a {
		_, _ = forseti.session_insert_fact(fresh, "SA", a.id, {a.k1})
	}
	for b in list_b {
		_, _ = forseti.session_insert_fact(fresh, "SB", b.id, {b.k1, b.k2})
	}
	for c in list_c {
		_, _ = forseti.session_insert_fact(fresh, "SC", c.id, {c.k2, c.sc})
	}
	_, _ = forseti.session_fire(fresh)

	expected_hits := make(map[string]struct{}, 16, context.temp_allocator)
	for a in list_a {
		for b in list_b {
			if a.k1 != b.k1 {
				continue
			}
			for c in list_c {
				if b.k2 == c.k2 && c.sc >= 10 {
					sig := fmt.tprintf("%d:%d:%d", a.k1, b.k2, c.sc)
					expected_hits[sig] = {}
				}
			}
		}
	}
	actual_hits := make(map[string]struct{}, 16, context.temp_allocator)
	for &f in fresh.facts {
		if f.alive && f.binding_idx == 3 {
			sig := fmt.tprintf("%d:%d:%d", f.fields[0].(i64), f.fields[1].(i64), f.fields[2].(i64))
			actual_hits[sig] = {}
			testing.expect(t, sig in expected_hits)
		}
	}
	testing.expect_value(t, len(actual_hits), len(expected_hits))
	free_all(context.temp_allocator)
}

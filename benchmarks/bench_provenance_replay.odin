package main

import "core:fmt"
import "core:thread"
import hugi "hugi:."
import xitdb "xitdb:."
import "../forseti"

@(private = "file")
_BENCH_PROV_SRC :: `module bench_prov version "1.0"
schema SeedA { k: string }
schema SeedB { k: string }
schema Mid { k: string }
schema Leaf { k: string }

source SeedA : SeedA at .a[?k]
source SeedB : SeedB at .b[?k]
derived Mid : Mid at .mid[?k]
derived Leaf : Leaf at .leaf[?k]

rule r_mid_a {
  when { ?_a := SeedA(k: ?k) }
  then { assert Mid(k: ?k) }
}
rule r_mid_b {
  when { ?_b := SeedB(k: ?k) }
  then { assert Mid(k: ?k) }
}
rule r_leaf {
  when {
    ?_a := SeedA(k: ?k)
    ?_m := Mid(k: ?k)
  }
  then { assert Leaf(k: ?k) }
}`

@(private = "file")
_BENCH_REPLAY_V1_SRC :: `module bench_replay version "1.0"
schema RawOrg { id: string, employees: i64 }
schema EntFlag { id: string }
source RawOrg : RawOrg at .raw[?id]
derived EntFlag : EntFlag at .ent[?id]
rule mark_ent {
  when { ?_r := RawOrg(id: ?id, employees: ?emp); where ?emp >= 50 }
  then { assert EntFlag(id: ?id) }
}`

@(private = "file")
_BENCH_REPLAY_V2_SRC :: `module bench_replay version "2.0"
schema RawOrg { id: string, employees: i64 }
schema EntFlag { id: string }
source RawOrg : RawOrg at .raw[?id]
derived EntFlag : EntFlag at .ent[?id]
rule mark_ent {
  when { ?_r := RawOrg(id: ?id, employees: ?emp); where ?emp >= 150 }
  then { assert EntFlag(id: ?id) }
}`

@(private = "file")
_BENCH_EFFECTS_SRC :: `module bench_effects version "1.0"
schema Req { id: string }
schema Done { id: string, status: string }
source Req : Req at .req[?id]
derived Done : Done at .done[?id]

rule emit_work {
  when { ?_r := Req(id: ?id) }
  effect "verify_req" { req_id: ?id }
}`

@(private = "file")
_seed_provenance_session :: proc(n: int) -> (rb: ^forseti.Rulebase, s: ^forseti.Session, sample_leaf: forseti.Fact_Id) {
	sample_leaf = forseti.INVALID_FACT
	ok: bool
	rb, ok = compile_benchmark_source(_BENCH_PROV_SRC, "bench_prov.forseti")
	if !ok {
		return nil, nil, forseti.INVALID_FACT
	}
	s = new(forseti.Session)
	_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = .Audit_Full})

	for i := 0; i < n; i += 1 {
		k := fmt.tprintf("k:%05d", i)
		ksid := bench_intern(s, k)
		vals := [1]forseti.Value{ksid}
		_, _ = forseti.session_insert_fact(s, "SeedA", k, vals[:])
		if i % 2 == 0 {
			_, _ = forseti.session_insert_fact(s, "SeedB", k, vals[:])
		}
	}
	_, _ = forseti.session_fire(s)
	free_all(context.temp_allocator)

	leaf_bidx, has_b := forseti.session_find_binding(s, "Leaf")
	if has_b {
		for &f in s.facts {
			if f.alive && f.binding_idx == leaf_bidx {
				sample_leaf = f.id
				break
			}
		}
	}
	return rb, s, sample_leaf
}

@(private = "file")
_bench_explain_dag_leaf :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb, s, leaf_fid := _seed_provenance_session(n)
	if rb == nil || s == nil {
		return
	}
	defer {
		forseti.session_destroy(s)
		free(s)
		forseti.rulebase_destroy(rb)
		free(rb)
	}
	if leaf_fid == forseti.INVALID_FACT {
		return
	}

	hugi.set_items(b, 1)
	for hugi.step(b) {
		tree := forseti.explain(s, leaf_fid)
		_ = hugi.black_box(len(tree.root.children))
		forseti.explain_tree_destroy(&tree)
	}
}

@(private = "file")
_bench_impact_rule_blast_radius :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb, s, _ := _seed_provenance_session(n)
	if rb == nil || s == nil {
		return
	}
	defer {
		forseti.session_destroy(s)
		free(s)
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	hugi.set_items(b, u64(n))
	for hugi.step(b) {
		rep := forseti.impact(s, 0)
		_ = hugi.black_box(len(rep.direct_facts) + len(rep.transitive_facts))
		forseti.impact_report_destroy(&rep)
	}
}

@(private = "file")
_bench_semiring_why_provenance :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb, s, leaf_fid := _seed_provenance_session(n)
	if rb == nil || s == nil {
		return
	}
	defer {
		forseti.session_destroy(s)
		free(s)
		forseti.rulebase_destroy(rb)
		free(rb)
	}
	if leaf_fid == forseti.INVALID_FACT {
		return
	}

	hugi.set_items(b, 1)
	for hugi.step(b) {
		res := forseti.evaluate_semiring(s, leaf_fid, .Why)
		_ = hugi.black_box(len(res.why_sets))
		forseti.semiring_result_destroy(&res)
	}
}

@(private = "file")
_bench_semiring_how_viterbi :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb, s, leaf_fid := _seed_provenance_session(n)
	if rb == nil || s == nil {
		return
	}
	defer {
		forseti.session_destroy(s)
		free(s)
		forseti.rulebase_destroy(rb)
		free(rb)
	}
	if leaf_fid == forseti.INVALID_FACT {
		return
	}

	hugi.set_items(b, 2)
	for hugi.step(b) {
		how := forseti.evaluate_semiring(s, leaf_fid, .How)
		vit := forseti.evaluate_semiring(s, leaf_fid, .Viterbi)
		_ = hugi.black_box(len(how.how_expr) + int(vit.viterbi_score * 1000))
		forseti.semiring_result_destroy(&how)
		forseti.semiring_result_destroy(&vit)
	}
}

@(private = "file")
_Replay_Seed_Ctx :: struct {
	n: int,
}

@(private = "file")
_replay_seed_cb :: proc(wc: ^xitdb.Write_Cursor, ud: rawptr) -> xitdb.Error {
	ctx := (^_Replay_Seed_Ctx)(ud)
	m, err := forseti.store_write_path_ensure_map(wc, ".raw")
	if err != nil {
		return .Write_Failed
	}
	k_id := forseti.prehashed_key_make("id")
	k_emp := forseti.prehashed_key_make("employees")
	kbuf: [32]u8 = ---
	for i := 0; i < ctx.n; i += 1 {
		key := fmt.bprintf(kbuf[:], "o:%05d", i)
		rwc := xitdb.hash_map_put_cursor(&m, key) or_return
		rm := xitdb.write_hash_map_init(rwc) or_return
		forseti.hash_map_put_prehashed(&rm, &k_id, key) or_return
		forseti.hash_map_put_prehashed(&rm, &k_emp, i64(50 + (i % 200))) or_return
	}
	return nil
}

@(private = "file")
_bench_overlay_diff_replay :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb1, ok1 := compile_benchmark_source(_BENCH_REPLAY_V1_SRC, "replay_v1.forseti")
	rb2, ok2 := compile_benchmark_source(_BENCH_REPLAY_V2_SRC, "replay_v2.forseti")
	if !ok1 || !ok2 {
		if rb1 != nil {
			forseti.rulebase_destroy(rb1)
			free(rb1)
		}
		if rb2 != nil {
			forseti.rulebase_destroy(rb2)
			free(rb2)
		}
		return
	}
	defer {
		forseti.rulebase_destroy(rb1)
		free(rb1)
		forseti.rulebase_destroy(rb2)
		free(rb2)
	}

	sb := new(forseti.Store_Bridge)
	_ = forseti.store_bridge_init_standalone(sb, forseti.Xitdb_Config{})
	defer {
		forseti.store_bridge_destroy(sb)
		free(sb)
	}

	seed_ctx := _Replay_Seed_Ctx{n = n}
	_, _ = forseti.store_bridge_commit_moment(sb, _replay_seed_cb, &seed_ctx)

	syncer := new(forseti.Delta_Syncer)
	_ = forseti.delta_syncer_init(syncer)
	_ = forseti.delta_syncer_watch(syncer, ".raw")
	defer {
		forseti.delta_syncer_destroy(syncer)
		free(syncer)
	}

	s := new(forseti.Session)
	_ = forseti.session_init(s, rb1, forseti.Session_Config{provenance_mode = .Audit_Full})
	defer {
		forseti.session_destroy(s)
		free(s)
	}
	_, _ = forseti.session_sync_and_fire(s, sb, syncer, commit_derived = false)

	hugi.set_items(b, u64(n))
	for hugi.step(b) {
		rep, dr_err := forseti.session_diff_replay(s, sb, rb2, {".raw"})
		if dr_err == nil {
			_ = hugi.black_box(len(rep.removed) + rep.unchanged_count)
			forseti.diff_replay_report_destroy(&rep)
		}
	}
}

@(private = "file")
_Effect_Worker_Slice :: struct {
	jobs:    []forseti.Effect_Job,
	results: []forseti.Effect_Result,
	facts:   []forseti.Effect_Result_Fact,
}

@(private = "file")
_effect_worker_batch_proc :: proc(data: rawptr) {
	w := (^_Effect_Worker_Slice)(data)
	for j, idx in w.jobs {
		req_str := ""
		for f in j.fields {
			if f.name == "req_id" {
				req_str = f.str
				break
			}
		}
		w.facts[idx] = forseti.Effect_Result_Fact{
			binding_name = "Done",
			key          = req_str,
			fields       = nil,
		}
		w.results[idx] = forseti.Effect_Result{
			job_id = j.job_id,
			facts  = w.facts[idx:idx + 1],
		}
	}
}

@(private = "file")
_bench_async_effects_3phase :: proc(b: ^hugi.Bencher) {
	n := min(max(hugi.param(b), 10), 500)
	rb, ok := compile_benchmark_source(_BENCH_EFFECTS_SRC, "bench_effects.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	keys := make([]string, n, context.temp_allocator)
	for i := 0; i < n; i += 1 {
		keys[i] = fmt.tprintf("req:%04d", i)
	}
	defer free_all(context.temp_allocator)

	WORKERS :: 4
	hugi.set_items(b, u64(n))
	for hugi.step(b) {
		s := new(forseti.Session)
		_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = .Audit_Full})

		ok_sid := bench_intern(s, "done")
		for k in keys {
			ksid := bench_intern(s, k)
			vals := [1]forseti.Value{ksid}
			_, _ = forseti.session_insert_fact(s, "Req", k, vals[:])
		}
		_, _ = forseti.session_fire(s)

		jobs := forseti.session_prepare_effects(s)
		results := make([]forseti.Effect_Result, len(jobs))
		facts := make([]forseti.Effect_Result_Fact, len(jobs))
		pair_buf := make([][2]forseti.Value, len(jobs))

		// Pre-bind field slices on owner thread so workers remain race-free on Session interner.
		for j, ji in jobs {
			ksid := bench_intern(s, j.fields[0].str)
			pair_buf[ji] = [2]forseti.Value{ksid, ok_sid}
		}

		slices: [WORKERS]_Effect_Worker_Slice
		threads: [WORKERS]^thread.Thread
		chunk := (len(jobs) + WORKERS - 1) / WORKERS
		active_workers := 0
		for w := 0; w < WORKERS; w += 1 {
			start := w * chunk
			if start >= len(jobs) {
				break
			}
			end := min(start + chunk, len(jobs))
			slices[w] = _Effect_Worker_Slice{
				jobs    = jobs[start:end],
				results = results[start:end],
				facts   = facts[start:end],
			}
			threads[w] = thread.create_and_start_with_data(&slices[w], _effect_worker_batch_proc)
			active_workers += 1
		}
		for w := 0; w < active_workers; w += 1 {
			if threads[w] != nil {
				thread.join(threads[w])
				thread.destroy(threads[w])
			}
		}
		for i := 0; i < len(facts); i += 1 {
			facts[i].fields = pair_buf[i][:]
		}

		applied, _ := forseti.session_apply_effects(s, results)
		_ = hugi.black_box(len(applied))
		delete(applied)
		delete(pair_buf)
		delete(facts)
		delete(results)
		forseti.effects_jobs_destroy(jobs)
		forseti.session_destroy(s)
		free(s)
	}
}

register_provenance_replay_benchmarks :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "provenance_and_replay")
	hugi.group_params(g, []int{10, 100, 1_000, 5_000})
	hugi.group_bench(g, "explain_dag_leaf", _bench_explain_dag_leaf)
	hugi.group_bench(g, "impact_rule_blast_radius", _bench_impact_rule_blast_radius)
	hugi.group_bench(g, "semiring_why_provenance", _bench_semiring_why_provenance)
	hugi.group_bench(g, "semiring_how_viterbi", _bench_semiring_how_viterbi)
	hugi.group_bench(g, "overlay_diff_replay", _bench_overlay_diff_replay)
	hugi.group_bench(g, "async_effects_3phase", _bench_async_effects_3phase)
}

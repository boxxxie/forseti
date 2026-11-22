package forseti

import "core:fmt"
import "core:mem"
import "core:strings"

Diff_Fact_Change :: struct {
	binding_name: string,
	summary:      string,
}

Diff_Replay_Report :: struct {
	added:                 []Diff_Fact_Change,
	removed:               []Diff_Fact_Change,
	unchanged_count:       int,
	baseline_decisions:    int,
	candidate_decisions:   int,
	overlay_owned_bytes:   i64,
	parent_moments_before: i64,
	parent_moments_after:  i64,
	allocator:             mem.Allocator,
}

diff_replay_report_destroy :: proc(rep: ^Diff_Replay_Report) {
	if rep == nil || rep.allocator.procedure == nil {
		return
	}
	a := rep.allocator
	for c in rep.added {
		delete(c.binding_name, a)
		delete(c.summary, a)
	}
	delete(rep.added, a)
	for c in rep.removed {
		delete(c.binding_name, a)
		delete(c.summary, a)
	}
	delete(rep.removed, a)
	rep^ = {}
}

@(private)
_collect_derived_signatures :: proc(
	s: ^Session,
	alloc: mem.Allocator,
) -> map[string]Diff_Fact_Change {
	out := make(map[string]Diff_Fact_Change, 16, alloc)
	for &f in s.facts {
		if !f.alive {
			continue
		}
		bdef := s.rb.bindings[f.binding_idx]
		if bdef.kind != .Derived {
			continue
		}
		summary := _format_fact_summary(s, f.id, alloc)
		bname := interner_get(&s.rb.interner, bdef.name)
		if summary in out {
			delete(summary, alloc)
			continue
		}
		out[summary] = Diff_Fact_Change{
			binding_name = strings.clone(bname, alloc),
			summary      = summary,
		}
	}
	return out
}

@(private)
_count_alive_derivations :: proc(s: ^Session) -> int {
	if s.provenance.mode != .Audit_Full {
		return 0
	}
	cnt := 0
	for i := 1; i < len(s.provenance.derivs); i += 1 {
		if s.provenance.derivs[i].alive {
			cnt += 1
		}
	}
	return cnt
}

// Replays `candidate_rb` against a frozen snapshot of `parent_bridge` inside a zero-copy xitdb.Core_Overlay
// fork, returning added/removed derived facts relative to `baseline_sess` without mutating `parent_bridge`.
session_diff_replay :: proc(
	baseline_sess: ^Session,
	parent_bridge: ^Store_Bridge,
	candidate_rb: ^Rulebase,
	watched_paths: []string,
	allocator := context.allocator,
) -> (rep: Diff_Replay_Report, err: Store_Error) {
	if baseline_sess == nil || baseline_sess.rb == nil || parent_bridge == nil || candidate_rb == nil {
		return {}, .Invalid_Config
	}

	moments_before := store_bridge_moment_count(parent_bridge) or_return

	fh: Fork_Handle
	fork_create(&fh, parent_bridge, allocator) or_return
	defer fork_destroy(&fh)

	cand_sess := new(Session, allocator)
	defer {
		session_destroy(cand_sess)
		free(cand_sess, allocator)
	}
	cfg := Session_Config{
		max_activations = baseline_sess.max_activations,
		provenance_mode = .Audit_Full,
	}
	if s_err := session_init(cand_sess, candidate_rb, cfg, baseline_sess.telemetry, allocator); s_err != .None {
		return {}, .Invalid_Config
	}

	syncer: Delta_Syncer
	delta_syncer_init(&syncer, baseline_sess.telemetry, allocator) or_return
	defer delta_syncer_destroy(&syncer)

	for wp in watched_paths {
		delta_syncer_watch(&syncer, wp) or_return
	}

	_, f_err := session_sync_and_fire(cand_sess, &fh.bridge, &syncer, commit_derived = true)
	if f_err != nil {
		return {}, f_err
	}

	base_sigs := _collect_derived_signatures(baseline_sess, context.temp_allocator)
	cand_sigs := _collect_derived_signatures(cand_sess, context.temp_allocator)
	moments_after := store_bridge_moment_count(parent_bridge) or_return

	added := make([dynamic]Diff_Fact_Change, 0, 8, allocator)
	removed := make([dynamic]Diff_Fact_Change, 0, 8, allocator)
	unchanged := 0

	for sig, ch in cand_sigs {
		if sig in base_sigs {
			unchanged += 1
		} else {
			append(&added, Diff_Fact_Change{
				binding_name = strings.clone(ch.binding_name, allocator),
				summary      = strings.clone(ch.summary, allocator),
			})
		}
	}
	for sig, ch in base_sigs {
		if !(sig in cand_sigs) {
			append(&removed, Diff_Fact_Change{
				binding_name = strings.clone(ch.binding_name, allocator),
				summary      = strings.clone(ch.summary, allocator),
			})
		}
	}

	rep = Diff_Replay_Report{
		added                 = added[:],
		removed               = removed[:],
		unchanged_count       = unchanged,
		baseline_decisions    = _count_alive_derivations(baseline_sess),
		candidate_decisions   = _count_alive_derivations(cand_sess),
		overlay_owned_bytes   = fork_owned_bytes(&fh),
		parent_moments_before = moments_before,
		parent_moments_after  = moments_after,
		allocator             = allocator,
	}
	_ = fmt.tprintf
	return rep, nil
}

// Replays both `baseline_rb` and `candidate_rb` against `parent_bridge` using isolated overlay forks.
diff_replay :: proc(
	parent_bridge: ^Store_Bridge,
	baseline_rb: ^Rulebase,
	candidate_rb: ^Rulebase,
	watched_paths: []string,
	telemetry: ^Telemetry_Sink = nil,
	allocator := context.allocator,
) -> (rep: Diff_Replay_Report, err: Store_Error) {
	if parent_bridge == nil || baseline_rb == nil || candidate_rb == nil {
		return {}, .Invalid_Config
	}

	base_fh: Fork_Handle
	fork_create(&base_fh, parent_bridge, allocator) or_return
	defer fork_destroy(&base_fh)

	base_sess := new(Session, allocator)
	defer {
		session_destroy(base_sess)
		free(base_sess, allocator)
	}
	if s_err := session_init(base_sess, baseline_rb, Session_Config{provenance_mode = .Audit_Full}, telemetry, allocator); s_err != .None {
		return {}, .Invalid_Config
	}

	base_sync: Delta_Syncer
	delta_syncer_init(&base_sync, telemetry, allocator) or_return
	defer delta_syncer_destroy(&base_sync)
	for wp in watched_paths {
		delta_syncer_watch(&base_sync, wp) or_return
	}
	_, f_err := session_sync_and_fire(base_sess, &base_fh.bridge, &base_sync, commit_derived = false)
	if f_err != nil {
		return {}, f_err
	}

	return session_diff_replay(base_sess, parent_bridge, candidate_rb, watched_paths, allocator)
}

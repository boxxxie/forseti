package forseti_actors_specs

import "core:testing"
import "core:time"

@(test)
spec_tenant_rule_runtime_isolation_crash_recovery_and_idle_eviction :: proc(t: ^testing.T) {
	w: Actor_World
	actor_world_init(&w, t, num_workers = 4)
	defer actor_world_destroy(&w)

	policy := `module tenant_mdm version "1.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string, tier: string }

source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]

rule classify {
  when {
    Raw(org_id: ?oid, employees: ?emp)
    where ?emp >= 100
  }
  then { assert Canon(org_id: ?oid, tier: "enterprise") }
}

query canon_orgs() {
  Canon(org_id: ?oid, tier: ?tier)
}`

	given_actor_policy(&w, "tenant_p", policy)
	given_frozen_snapshot_store(&w, "snap", {
		{org_id = "org:base", employees = 200},
	})
	given_tenant_rule_runtime(&w, "rt", "tenant_p", "snap", {".orgs.raw"}, idle_timeout = 30 * time.Second, panic_first_fire_for_tenant = "tenant:alpha")

	// Normal tenant beta works on generation 1
	upon_tenant_inserting_and_firing(&w, "rt", "tenant:beta", "Raw", "org:b1", {"org:b1", i64(300)}, expect_crash = false)
	then_tenant_query_returns_count(&w, "rt", "tenant:beta", "canon_orgs", 2)
	then_tenant_generation_is(&w, "rt", "tenant:beta", 1)

	// Tenant alpha's first fire panics (trapped by Sleipnir .One_For_One); try_call reports .Call_Target_Crashed
	upon_tenant_inserting_and_firing(&w, "rt", "tenant:alpha", "Raw", "org:a1", {"org:a1", i64(400)}, expect_crash = true)

	// Alpha restarts cleanly to generation >= 2 and re-hydrates from snap (.orgs.raw -> org:base), while beta stays untouched!
	upon_waiting_for_tenant_recovery(&w, "rt", "tenant:alpha", min_gen = 2)
	then_tenant_generation_is(&w, "rt", "tenant:beta", 1)
	then_tenant_query_returns_count(&w, "rt", "tenant:alpha", "canon_orgs", 1)

	// Advance deterministic clock past idle_timeout and sweep idle tenants
	upon_advancing_tenant_clock(&w, "rt", 45 * time.Second)
	upon_sweeping_idle_tenants(&w, "rt", expected_evicted = 2)
	then_tenant_runtime_active_count_is(&w, "rt", 0)
}

@(test)
spec_effect_dispatcher_routes_parallel_jobs_and_isolates_worker_crashes :: proc(t: ^testing.T) {
	w: Actor_World
	actor_world_init(&w, t, num_workers = 4)
	defer actor_world_destroy(&w)

	policy := `module eff_mdm version "1.0"
schema RawOrg { org_id: string }
schema EnrichedOrg { org_id: string, country: string }

source Raw : RawOrg at .orgs.raw[?id]
derived Enriched : EnrichedOrg at .orgs.enriched[?id]

rule request_enrichment {
  when { Raw(org_id: ?oid) }
  effect "enrich" { org_id: ?oid }
}

query all_enriched() {
  Enriched(org_id: ?oid, country: ?c)
}`

	given_actor_policy(&w, "eff_p", policy)
	given_session_actor(&w, "sa_eff", "eff_p")
	given_effect_dispatcher(&w, "disp", crash_on_bad_org = true, use_distinct_track_alloc = true)

	upon_sending_fact_batch(&w, "sa_eff", {
		{binding_name = "Raw", key = "org:1", fields = {"org:1"}},
		{binding_name = "Raw", key = "org:2", fields = {"org:2"}},
		{binding_name = "Raw", key = "org:bad", fields = {"org:bad"}},
	})
	upon_firing_session_actor(&w, "sa_eff")

	upon_dispatching_and_applying_effects(&w, "disp", "sa_eff", expected_jobs = 3, expected_applied = 2, expected_failed = 1)
	then_session_actor_query_returns_count(&w, "sa_eff", "all_enriched", {}, 2)
}

@(test)
spec_parallel_diff_replay_evaluates_candidates_without_parent_mutation :: proc(t: ^testing.T) {
	w: Actor_World
	actor_world_init(&w, t, num_workers = 4)
	defer actor_world_destroy(&w)

	base_policy := `module diff_base version "1.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string }
source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]
rule keep {
  when { Raw(org_id: ?oid, employees: ?emp); where ?emp >= 100 }
  then { assert Canon(org_id: ?oid) }
}`

	cand_strict := `module diff_strict version "2.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string }
source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]
rule keep {
  when { Raw(org_id: ?oid, employees: ?emp); where ?emp >= 300 }
  then { assert Canon(org_id: ?oid) }
}`

	cand_relaxed := `module diff_relaxed version "2.1"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string }
source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]
rule keep {
  when { Raw(org_id: ?oid, employees: ?emp); where ?emp >= 50 }
  then { assert Canon(org_id: ?oid) }
}`

	given_actor_policy(&w, "p_base", base_policy)
	given_actor_policy(&w, "p_strict", cand_strict)
	given_actor_policy(&w, "p_relaxed", cand_relaxed)
	given_frozen_snapshot_store(&w, "parent_db", {
		{org_id = "org:1", employees = 60},
		{org_id = "org:2", employees = 150},
		{org_id = "org:3", employees = 400},
	})

	upon_running_parallel_diff_replay(&w, "replay_run", "parent_db", "p_base", {
		{name = "strict", policy_label = "p_strict"},
		{name = "relaxed", policy_label = "p_relaxed"},
		{name = "same", policy_label = "p_base"},
	}, {".orgs.raw"})

	then_parallel_diff_candidate_matches(&w, "replay_run", "strict", expected_added = 0, expected_removed = 1, expected_unchanged = 1, expected_moments = 1)
	then_parallel_diff_candidate_matches(&w, "replay_run", "relaxed", expected_added = 1, expected_removed = 0, expected_unchanged = 2, expected_moments = 1)
	then_parallel_diff_candidate_matches(&w, "replay_run", "same", expected_added = 0, expected_removed = 0, expected_unchanged = 2, expected_moments = 1)
}

@(test)
spec_tenant_panic_single_worker_preserves_temp_allocator_across_eviction :: proc(t: ^testing.T) {
	w: Actor_World
	actor_world_init(&w, t, num_workers = 1)
	defer actor_world_destroy(&w)

	policy := `module tenant_single_worker version "1.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string, tier: string }

source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]

rule classify {
  when {
    Raw(org_id: ?oid, employees: ?emp)
    where ?emp >= 100
  }
  then { assert Canon(org_id: ?oid, tier: "enterprise") }
}

query canon_orgs() {
  Canon(org_id: ?oid, tier: ?tier)
}`

	given_actor_policy(&w, "tenant_p", policy)
	given_frozen_snapshot_store(&w, "snap", {
		{org_id = "org:base", employees = 200},
	})
	given_tenant_rule_runtime(&w, "rt", "tenant_p", "snap", {".orgs.raw"}, idle_timeout = 30 * time.Second, panic_first_fire_for_tenant = "tenant:alpha")

	// Panic on the single worker thread, recover, then evict tenant:alpha (freeing its Session_Actor_Handle)
	upon_tenant_inserting_and_firing(&w, "rt", "tenant:alpha", "Raw", "org:a1", {"org:a1", i64(400)}, expect_crash = true)
	upon_waiting_for_tenant_recovery(&w, "rt", "tenant:alpha", min_gen = 2)
	upon_advancing_tenant_clock(&w, "rt", 45 * time.Second)
	upon_sweeping_idle_tenants(&w, "rt", expected_evicted = 1)

	// Subsequent tenant execution on the same single worker must not touch the freed temp_arena
	upon_tenant_inserting_and_firing(&w, "rt", "tenant:gamma", "Raw", "org:g1", {"org:g1", i64(350)}, expect_crash = false)
	then_tenant_query_returns_count(&w, "rt", "tenant:gamma", "canon_orgs", 2)
}

@(test)
spec_parallel_diff_replay_reclaims_actors_across_repeated_runs :: proc(t: ^testing.T) {
	w: Actor_World
	actor_world_init(&w, t, num_workers = 4)
	defer actor_world_destroy(&w)

	base_policy := `module diff_loop_base version "1.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string }
source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]
rule keep {
  when { Raw(org_id: ?oid, employees: ?emp); where ?emp >= 100 }
  then { assert Canon(org_id: ?oid) }
}`

	cand_policy := `module diff_loop_cand version "2.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string }
source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]
rule keep {
  when { Raw(org_id: ?oid, employees: ?emp); where ?emp >= 300 }
  then { assert Canon(org_id: ?oid) }
}`

	given_actor_policy(&w, "p_base", base_policy)
	given_actor_policy(&w, "p_cand", cand_policy)
	given_frozen_snapshot_store(&w, "parent_db", {
		{org_id = "org:1", employees = 150},
		{org_id = "org:2", employees = 400},
	})

	upon_capturing_scheduler_actor_baseline(&w)
	for _ in 0 ..< 4 {
		upon_running_parallel_diff_replay(&w, "loop_run", "parent_db", "p_base", {
			{name = "cand", policy_label = "p_cand"},
			{name = "same", policy_label = "p_base"},
		}, {".orgs.raw"})
		then_parallel_diff_candidate_matches(&w, "loop_run", "cand", expected_added = 0, expected_removed = 1, expected_unchanged = 1, expected_moments = 1)
		then_scheduler_actor_count_matches_baseline(&w)
	}
}

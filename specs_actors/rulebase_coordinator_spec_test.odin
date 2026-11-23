package forseti_actors_specs

import "core:testing"

@(test)
spec_rulebase_coordinator_hot_reload_rejection_and_grace_reclamation :: proc(t: ^testing.T) {
	w: Actor_World
	actor_world_init(&w, t, num_workers = 4)
	defer actor_world_destroy(&w)

	v1_policy := `module reload_mdm version "1.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string, tier: string }

source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]

table tier_gate version "1.0" hit First {
  inputs { employees: i64 }
  outputs { tier: string }
  rows {
    r_ent: >= 100 || "enterprise";
    r_smb: -      || "smb";
  }
}

rule classify {
  when {
    ?_r := Raw(org_id: ?oid, employees: ?emp)
    ?g := decide tier_gate(employees: ?emp)
  }
  then { assert Canon(org_id: ?oid, tier: ?g.tier) }
}

query ent_orgs() {
  Canon(org_id: ?oid, tier: "enterprise")
}`

	invalid_policy := `module reload_mdm version "1.5"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string, tier: string }

source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]

table broken_gate version "1.5" hit Unique {
  inputs { employees: i64 }
  outputs { tier: string }
  rows {
    r1: >= 100 || "enterprise";
    r2: >= 200 || "vip";
  }
}

rule classify {
  when {
    ?_r := Raw(org_id: ?oid, employees: ?emp)
    ?g := decide broken_gate(employees: ?emp)
  }
  then { assert Canon(org_id: ?oid, tier: ?g.tier) }
}`

	v2_policy := `module reload_mdm version "2.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string, tier: string }

source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]

table tier_gate version "2.0" hit First {
  inputs { employees: i64 }
  outputs { tier: string }
  rows {
    r_ent: >= 300 || "enterprise";
    r_smb: -      || "smb";
  }
}

rule classify {
  when {
    ?_r := Raw(org_id: ?oid, employees: ?emp)
    ?g := decide tier_gate(employees: ?emp)
  }
  then { assert Canon(org_id: ?oid, tier: ?g.tier) }
}

query ent_orgs() {
  Canon(org_id: ?oid, tier: "enterprise")
}`

	given_frozen_snapshot_store(&w, "rehyd_db", {
		{org_id = "org:1", employees = 150},
		{org_id = "org:2", employees = 400},
	})
	given_rulebase_coordinator(&w, "coord", v1_policy, "rehyd_db", {".orgs.raw"})
	given_coordinated_session_actor(&w, "coord", "s_a")
	given_coordinated_session_actor(&w, "coord", "s_b")

	// Under v1 (>= 100), both org:1 and org:2 are enterprise -> 2 rows
	then_session_actor_query_returns_count(&w, "s_a", "ent_orgs", {}, 2)
	then_session_actor_query_returns_count(&w, "s_b", "ent_orgs", {}, 2)

	// Invalid policy (Unique overlap) is rejected cleanly without disrupting active sessions
	upon_reloading_coordinator_policy(&w, "coord", invalid_policy, expect_ok = false)
	then_coordinator_version_is(&w, "coord", 1)
	then_session_actor_query_returns_count(&w, "s_a", "ent_orgs", {}, 2)

	// Valid v2 policy (>= 300) swaps cleanly and re-hydrates both sessions -> only org:2 is enterprise
	upon_reloading_coordinator_policy(&w, "coord", v2_policy, expect_ok = true)
	then_coordinator_version_is(&w, "coord", 2)
	then_coordinator_retired_count_is(&w, "coord", 1)
	then_session_actor_query_returns_count(&w, "s_a", "ent_orgs", {}, 1)
	then_session_actor_query_returns_count(&w, "s_b", "ent_orgs", {}, 1)
}

@(test)
spec_rulebase_coordinator_prunes_stopped_and_swaps_uninitialized_sessions :: proc(t: ^testing.T) {
	w: Actor_World
	actor_world_init(&w, t, num_workers = 2)
	defer actor_world_destroy(&w)

	v1_policy := `module reload_prune version "1.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string, tier: string }

source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]

rule classify {
  when { Raw(org_id: ?oid, employees: ?emp); where ?emp >= 100 }
  then { assert Canon(org_id: ?oid, tier: "enterprise") }
}

query ent_orgs() {
  Canon(org_id: ?oid, tier: "enterprise")
}`

	v2_policy := `module reload_prune version "2.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string, tier: string }

source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]

rule classify {
  when { Raw(org_id: ?oid, employees: ?emp); where ?emp >= 300 }
  then { assert Canon(org_id: ?oid, tier: "enterprise") }
}

query ent_orgs() {
  Canon(org_id: ?oid, tier: "enterprise")
}`

	given_frozen_snapshot_store(&w, "rehyd_db", {
		{org_id = "org:1", employees = 150},
		{org_id = "org:2", employees = 400},
	})
	given_rulebase_coordinator(&w, "coord", v1_policy, "rehyd_db", {".orgs.raw"})
	given_coordinated_session_actor(&w, "coord", "s_stopped")
	given_coordinated_session_actor(&w, "coord", "s_idle")

	// Stop s_stopped before reload; leave s_idle uninitialized (no messages sent yet)
	upon_stopping_session_actor(&w, "s_stopped")

	upon_reloading_coordinator_policy(&w, "coord", v2_policy, expect_ok = true)
	then_coordinator_version_is(&w, "coord", 2)
	then_coordinator_subscriber_count_is(&w, "coord", 1)
	then_coordinator_retired_count_is(&w, "coord", 1)
	then_session_actor_query_returns_count(&w, "s_idle", "ent_orgs", {}, 1)
}

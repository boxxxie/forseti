package forseti_actors_specs

import "core:testing"
import "../actors"

@(test)
spec_session_actor_lifecycle_batch_insert_query_and_explain :: proc(t: ^testing.T) {
	w: Actor_World
	actor_world_init(&w, t, num_workers = 4)
	defer actor_world_destroy(&w)

	policy := `module actor_mdm version "1.0"
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

rule canonicalize {
  when {
    ?_r := Raw(org_id: ?oid, employees: ?emp)
    ?g := decide tier_gate(employees: ?emp)
  }
  then { assert Canon(org_id: ?oid, tier: ?g.tier) }
}

query canon_by_tier(tier: string) {
  Canon(org_id: ?oid, tier: ?tier)
}`

	given_actor_policy(&w, "mdm", policy)
	given_session_actor(&w, "s1", "mdm")

	// Chain=K batch send followed by synchronous fire, query, and explain via actor.call
	upon_sending_fact_batch(&w, "s1", {
		{binding_name = "Raw", key = "org:1", fields = {"org:1", i64(250)}},
		{binding_name = "Raw", key = "org:2", fields = {"org:2", i64(40)}},
		{binding_name = "Raw", key = "org:3", fields = {"org:3", i64(180)}},
	})
	upon_firing_session_actor(&w, "s1")

	then_session_actor_query_returns_count(&w, "s1", "canon_by_tier", {{name = "tier", value = "enterprise"}}, 2)
	then_session_actor_query_returns_count(&w, "s1", "canon_by_tier", {{name = "tier", value = "smb"}}, 1)
	then_session_actor_explain_contains(&w, "s1", "Canon", {"org:1"}, {"canonicalize", "tier_gate", "r_ent"})

	// Retract org:3 via actor.call and verify JTMS cascade removes its derived Canon fact
	upon_retracting_fact_on_actor(&w, "s1", "Raw", "org:3")
	upon_firing_session_actor(&w, "s1")
	then_session_actor_query_returns_count(&w, "s1", "canon_by_tier", {{name = "tier", value = "enterprise"}}, 1)
}

@(test)
spec_session_actor_sharded_spsc_fast_ingest :: proc(t: ^testing.T) {
	w: Actor_World
	actor_world_init(&w, t, num_workers = 4)
	defer actor_world_destroy(&w)

	policy := `module spsc_ingest version "1.0"
schema RawOrg { org_id: string, employees: i64 }
schema AlertOrg { org_id: string }

source Raw : RawOrg at .orgs.raw[?id]
derived Alert : AlertOrg at .orgs.alert[?id]

rule alert_large {
  when {
    Raw(org_id: ?oid, employees: ?emp)
    where ?emp >= 500
  }
  then { assert Alert(org_id: ?oid) }
}

query all_alerts() {
  Alert(org_id: ?oid)
}`

	given_actor_policy(&w, "alerts", policy)
	given_spsc_ingest_mailbox(&w, "spsc_in", num_producers = 2)
	given_session_actor(&w, "s_spsc", "alerts")

	upon_pushing_spsc_fact(&w, "spsc_in", producer_id = 0, fact = actors.Actor_Fact_Input{
		binding_name = "Raw",
		key          = "org:10",
		fields       = {"org:10", i64(700)},
	})
	upon_pushing_spsc_fact(&w, "spsc_in", producer_id = 1, fact = actors.Actor_Fact_Input{
		binding_name = "Raw",
		key          = "org:11",
		fields       = {"org:11", i64(120)},
	})
	upon_pushing_spsc_fact(&w, "spsc_in", producer_id = 1, fact = actors.Actor_Fact_Input{
		binding_name = "Raw",
		key          = "org:12",
		fields       = {"org:12", i64(900)},
	})

	upon_draining_spsc_on_actor(&w, "s_spsc", "spsc_in", auto_fire = true)
	then_session_actor_query_returns_count(&w, "s_spsc", "all_alerts", {}, 2)
}

@(test)
spec_xitdb_commit_actor_serializes_multi_session_commits_and_notifications :: proc(t: ^testing.T) {
	w: Actor_World
	actor_world_init(&w, t, num_workers = 4)
	defer actor_world_destroy(&w)

	policy := `module commit_demo version "1.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string, tier: string }

source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]

rule make_canon {
  when {
    Raw(org_id: ?oid, employees: ?emp)
    where ?emp >= 100
  }
  then { assert Canon(org_id: ?oid, tier: "enterprise") }
}`

	given_actor_policy(&w, "p", policy)
	given_commit_actor(&w, "writer")
	given_session_actor(&w, "sa", "p")
	given_session_actor(&w, "sb", "p")
	upon_subscribing_session_to_commits(&w, "sa", "writer")
	upon_subscribing_session_to_commits(&w, "sb", "writer")

	upon_sending_fact(&w, "sa", "Raw", "org:a1", {"org:a1", i64(250)})
	upon_sending_fact(&w, "sb", "Raw", "org:b1", {"org:b1", i64(350)})
	upon_firing_session_actor(&w, "sa")
	upon_firing_session_actor(&w, "sb")

	upon_committing_session_derived_to_writer(&w, "sa", "writer")
	upon_committing_session_derived_to_writer(&w, "sb", "writer")
	upon_waiting_actor_scheduler_idle(&w)

	then_commit_actor_moment_count_is(&w, "writer", 2)
	then_commit_actor_has_derived_record(&w, "writer", ".orgs.canon", "org_id", "org:a1", "tier", "enterprise")
	then_commit_actor_has_derived_record(&w, "writer", ".orgs.canon", "org_id", "org:b1", "tier", "enterprise")
	then_session_actor_received_commit_notifications(&w, "sa", expected_count = 2, last_moment = 1)
	then_session_actor_received_commit_notifications(&w, "sb", expected_count = 2, last_moment = 1)
}

@(test)
spec_session_actor_honors_fast_mode_and_stopped_writer_commit :: proc(t: ^testing.T) {
	w: Actor_World
	actor_world_init(&w, t, num_workers = 2)
	defer actor_world_destroy(&w)

	policy := `module fast_commit version "1.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string, tier: string }

source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]

rule make_canon {
  when {
    Raw(org_id: ?oid, employees: ?emp)
    where ?emp >= 100
  }
  then { assert Canon(org_id: ?oid, tier: "enterprise") }
}

query all_canon() {
  Canon(org_id: ?oid, tier: ?tier)
}`

	given_actor_policy(&w, "p_fast", policy)
	given_session_actor_with_mode(&w, "s_fast", "p_fast", .Fast)
	given_commit_actor(&w, "stopped_writer")

	upon_sending_fact(&w, "s_fast", "Raw", "org:1", {"org:1", i64(250)})
	upon_firing_session_actor(&w, "s_fast")

	// .Fast mode evaluates rules without recording .Audit_Full explain lineage
	then_session_actor_query_returns_count(&w, "s_fast", "all_canon", {}, 1)
	then_session_actor_explain_lacks(&w, "s_fast", "Canon", {"org:1"}, {"via rule=", "make_canon"})

	// Stopping the writer causes Commit_Derived_To_Writer to fail cleanly without leaking the batch
	upon_stopping_commit_actor(&w, "stopped_writer")
	upon_committing_session_derived_to_writer_expect(&w, "s_fast", "stopped_writer", .Invalid_Config)
}

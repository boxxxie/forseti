package forseti_specs

import "core:testing"

@(test)
spec_typed_struct_mdm_ingestion_and_query_unmarshal :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	policy := `module typed_mdm version "1.0"
schema RawOrg { org_id: string, employees: i64, active: bool }
schema TieredOrg { org_id: string, tier: string, employees: i64 }

source raw_orgs: RawOrg at .orgs.raw[?id]
derived tiered_orgs: TieredOrg at .orgs.tiered[?id]

rule classify_enterprise {
  when {
    raw_orgs(org_id: ?oid, employees: ?emp, active: true)
    where ?emp >= 100
  }
  then {
    assert tiered_orgs(org_id: ?oid, tier: "enterprise", employees: ?emp)
  }
}

query list_tiered(tier: string) {
  tiered_orgs(org_id: ?oid, tier: ?tier, employees: ?emp)
}
`
	given_external_policy(&w, "p1", policy, "typed_mdm.forseti")
	upon_compiling_policy(&w, "p1")
	upon_compiling_rulebase(&w, "p1", "rb1")
	given_session(&w, "rb1", "s1")

	upon_inserting_typed_org(&w, "s1", "raw_orgs", "org:acme", "org:acme", employees = 250, active = true)
	upon_inserting_typed_org(&w, "s1", "raw_orgs", "org:small", "org:small", employees = 20, active = true)
	upon_firing_session(&w, "s1", "fire_1")
	then_typed_error_is(&w, .None)

	upon_running_query(&w, "s1", "list_tiered", "q1", {"tier"}, {"enterprise"})
	then_typed_query_returns_orgs(&w, "q1", "s1", {
		{oid = "org:acme", tier = "enterprise", employees = 250},
	})

	// Modify typed struct below threshold -> JTMS retracts derived TieredOrg.
	upon_modifying_typed_org(&w, "s1", "raw_orgs", "org:acme", "org:acme", employees = 40, active = true)
	upon_firing_session(&w, "s1", "fire_2")
	upon_running_query(&w, "s1", "list_tiered", "q2", {"tier"}, {"enterprise"})
	then_typed_query_returns_orgs(&w, "q2", "s1", {})
}

@(test)
spec_typed_decide_struct_and_validation_errors :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	policy := `module typed_table version "1.0"
schema Dummy { id: string }
source dummy: Dummy at .dummy[?id]

table tier_gate version "1.0" hit First verify(complete) {
  inputs { employees: i64, active: bool }
  outputs { tier: string, limit: i64 }
  rows {
    r_ent: >= 100 | true || "enterprise" | 10000;
    r_std: -      | -    || "standard"   | 1000;
  }
}
`
	given_external_policy(&w, "p1", policy, "typed_table.forseti")
	upon_compiling_policy(&w, "p1")
	upon_compiling_rulebase(&w, "p1", "rb1")
	given_session(&w, "rb1", "s1")

	upon_deciding_typed_tier(&w, "rb1", "tier_gate", employees = 250, active = true)
	then_typed_error_is(&w, .None)
	then_typed_decide_result_is(&w, matched = true, tier = "enterprise", limit = 10000)

	upon_deciding_typed_tier(&w, "rb1", "tier_gate", employees = 10, active = false)
	then_typed_error_is(&w, .None)
	then_typed_decide_result_is(&w, matched = true, tier = "standard", limit = 1000)

	// Error paths: unknown table, unknown binding, missing field, type mismatch.
	upon_deciding_typed_tier(&w, "rb1", "missing_tbl", employees = 10, active = true)
	then_typed_error_is(&w, .Unknown_Table)

	upon_inserting_typed_org(&w, "s1", "missing_binding", "k1", "k1", employees = 10, active = true)
	then_typed_error_is(&w, .Unknown_Binding)

	upon_inserting_typed_org_missing_field(&w, "s1", "dummy", "d1")
	then_typed_error_is(&w, .Missing_Field)

	upon_deciding_typed_tier_mismatched(&w, "rb1", "tier_gate")
	then_typed_error_is(&w, .Type_Mismatch)
}

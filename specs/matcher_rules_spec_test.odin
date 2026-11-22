package forseti_specs

import "core:testing"
import "../forseti"

@(test)
spec_multi_fact_mdm_joins_and_decide_integration :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := `module mdm_match version "1.0"

schema Org {
  name: string,
  domain: string,
  employees: i64,
  active: bool
}

schema StewardPref {
  domain: string,
  preferred_name: string
}

source RawOrg : Org at .orgs.raw[?id]
source Steward : StewardPref at .orgs.steward[?id]
derived CanonOrg : Org at .orgs.canon[?id]

table survivorship_gate version "1.0" hit First {
  inputs {
    employees: i64 cost 1,
    active: bool cost 1
  }
  outputs {
    action: string
  }
  rows {
    r1: >= 100 | true || "merge";
    r2: -      | -    || "review";
  }
}

rule apply_steward_survivorship phase "survive" salience 50 {
  when {
    ?_raw := RawOrg(domain: ?dom, employees: ?emp, active: ?act)
    ?_st := Steward(domain: ?dom, preferred_name: ?pname)
    ?gate := decide survivorship_gate(employees: ?emp, active: ?act)
    where ?gate.action == "merge" and ?emp >= 100
  }
  then {
    assert CanonOrg(name: ?pname, domain: ?dom, employees: ?emp, active: ?act)
  }
}`

	given_external_policy(&w, "mdm", src, "mdm_match.forseti")
	upon_compiling_policy(&w, "mdm")
	then_compilation_has_zero_diagnostics(&w, "mdm")
	upon_compiling_rulebase(&w, "mdm", "rb")
	given_session(&w, "rb", "s")

	upon_asserting_fact(&w, "s", "RawOrg", "raw:1", {"ACME Inc", "acme.com", i64(250), true})
	upon_asserting_fact(&w, "s", "RawOrg", "raw:2", {"Tiny Inc", "tiny.io", i64(5), true})
	upon_asserting_fact(&w, "s", "Steward", "st:1", {"acme.com", "ACME Global GmbH"})
	upon_asserting_fact(&w, "s", "Steward", "st:2", {"tiny.io", "Tiny Canonical"})

	upon_firing_session(&w, "s", "f1")
	then_rules_fired_count_is(&w, "f1", 1)
	then_session_has_derived_fact(&w, "s", "CanonOrg", {"ACME Global GmbH", "acme.com", i64(250), true})
}

@(test)
spec_phase_focus_stack_salience_and_refraction :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := `module agenda_seq version "1.0"

schema Item { flag: i64 }
source In : Item at .items_in[?id]
derived Out : Item at .items_out[?id]

rule low_salience_clean phase "clean" salience 10 {
  when { ?_x := In(flag: 1) }
  then { assert Out(flag: 1) }
}

rule high_salience_clean phase "clean" salience 100 {
  when { ?_x := In(flag: 1) }
  then { assert Out(flag: 2) }
}

rule survive_step phase "survive" salience 50 {
  when { ?_x := In(flag: 1) }
  then { assert Out(flag: 3) }
}

rule match_step phase "match" salience 5 {
  when { ?_x := In(flag: 1) }
  then { assert Out(flag: 4) }
}`

	given_external_policy(&w, "ag", src, "agenda.forseti")
	upon_compiling_policy(&w, "ag")
	then_compilation_has_zero_diagnostics(&w, "ag")
	upon_compiling_rulebase(&w, "ag", "rb")
	given_session(&w, "rb", "s")
	given_session_phases(&w, "s", {"clean", "match", "survive"})

	upon_asserting_fact(&w, "s", "In", "item:1", {i64(1)})
	upon_firing_session(&w, "s", "run1")
	then_rules_fired_count_is(&w, "run1", 4)
	then_fired_rule_sequence_is(&w, "s", {
		"high_salience_clean",
		"low_salience_clean",
		"match_step",
		"survive_step",
	})

	// Refraction: re-firing without modifying facts fires 0 rules!
	upon_firing_session(&w, "s", "run2")
	then_rules_fired_count_is(&w, "run2", 0)

	// Modifying the participating fact refreshes recency and clears refraction!
	given_session_phases(&w, "s", {"clean", "match", "survive"})
	upon_modifying_fact(&w, "s", "In", "item:1", {i64(1)})
	upon_firing_session(&w, "s", "run3")
	then_rules_fired_count_is(&w, "run3", 4)
}

@(test)
spec_unlinked_segments_skip_beta_joins :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := `module unlinked_test version "1.0"

schema Left { bucket: i64, join_id: i64 }
schema Right { join_id: i64 }
schema Hit { join_id: i64 }

source L : Left at .left[?id]
source R : Right at .right[?id]
derived H : Hit at .hits[?id]

rule j1 { when { ?_l := L(bucket: 1, join_id: ?k); ?_r := R(join_id: ?k) } then { assert H(join_id: ?k) } }
rule j2 { when { ?_l := L(bucket: 2, join_id: ?k); ?_r := R(join_id: ?k) } then { assert H(join_id: ?k) } }
rule j3 { when { ?_l := L(bucket: 3, join_id: ?k); ?_r := R(join_id: ?k) } then { assert H(join_id: ?k) } }
rule j4 { when { ?_l := L(bucket: 4, join_id: ?k); ?_r := R(join_id: ?k) } then { assert H(join_id: ?k) } }`

	given_external_policy(&w, "ul", src, "unlinked.forseti")
	upon_compiling_policy(&w, "ul")
	then_compilation_has_zero_diagnostics(&w, "ul")
	upon_compiling_rulebase(&w, "ul", "rb")
	given_session(&w, "rb", "s")

	upon_asserting_fact(&w, "s", "L", "l1", {i64(1), i64(101)})
	upon_asserting_fact(&w, "s", "L", "l2", {i64(2), i64(102)})
	upon_asserting_fact(&w, "s", "L", "l3", {i64(3), i64(103)})
	upon_asserting_fact(&w, "s", "L", "l4", {i64(4), i64(104)})

	upon_firing_session(&w, "s", "no_right")
	then_rules_fired_count_is(&w, "no_right", 0)
	then_session_telemetry_bounds(&w, min_live_mem = 1, max_live_mem = 16, max_beta_joins = 0, min_unlinked_skipped = 4)

	upon_asserting_fact(&w, "s", "R", "r2", {i64(102)})
	upon_firing_session(&w, "s", "one_right")
	then_rules_fired_count_is(&w, "one_right", 1)
	then_session_has_derived_fact(&w, "s", "H", {i64(102)})
}

@(test)
spec_parameterized_query_and_xitdb_sync_and_fire :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := `module sync_and_query version "1.0"

schema Organization {
  name: string,
  domain: string,
  employees: i64,
  active: bool
}

source RawOrg : Organization at .orgs.raw[?id]
derived CanonOrg : Organization at .orgs.canon[?id]

rule canonicalize {
  when {
    ?_raw := RawOrg(name: ?nm, domain: ?dom, employees: ?emp, active: true)
    where ?emp >= 100
  }
  then {
    assert CanonOrg(name: ?nm, domain: ?dom, employees: ?emp, active: true)
  }
}

query orgs_by_domain(dom: string) {
  ?_c := CanonOrg(domain: ?dom, name: ?cname, employees: ?_cemp)
}`

	given_external_policy(&w, "sq", src, "sync_query.forseti")
	upon_compiling_policy(&w, "sq")
	then_compilation_has_zero_diagnostics(&w, "sq")
	upon_compiling_rulebase(&w, "sq", "rb")

	given_standalone_store(&w, "db", forseti.Xitdb_Config{mode = .Fast_Memory})
	given_watched_collection(&w, "db", ".orgs.raw")
	upon_committing_mdm_orgs(&w, "db", {
		{id = "org:1", name = "ACME HQ", country = "DE", domain = "acme.com", employees = 250, active = true},
		{id = "org:2", name = "ACME West", country = "US", domain = "acme.com", employees = 120, active = true},
		{id = "org:3", name = "Small Co", country = "FR", domain = "small.fr", employees = 15, active = true},
	})

	given_session(&w, "rb", "s")
	upon_syncing_store_and_firing(&w, "db", "s", "sync1", commit_derived = true)
	then_rules_fired_count_is(&w, "sync1", 2)

	// Derived CanonOrg facts were committed atomically back into .orgs.canon in xitdb!
	then_store_collection_has_record_count_and_field(&w, "db", ".orgs.canon", 2, "name", "ACME HQ")
	then_store_collection_has_record_count_and_field(&w, "db", ".orgs.canon", 2, "name", "ACME West")

	// Parameterized query over live working memory returns both matching canonical orgs!
	upon_running_query(&w, "s", "orgs_by_domain", "q1", {"dom"}, {"acme.com"})
	then_query_matches_are(&w, "q1", 2, "?cname", {"ACME HQ", "ACME West"})
}

@(test)
spec_incremental_grouped_accumulators_and_empty_revocation :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := `module inc_grouped_accum version "1.0"

schema Bucket { grp: string }
schema Item { grp: string, amt: i64, tag: string }
schema GrpI64 { grp: string, val: i64 }
schema GrpF64 { grp: string, val: f64 }
schema GrpStr { grp: string, val: string }

source Bucket : Bucket at .buckets[?id]
source Item : Item at .items[?id]
derived GrpSum : GrpI64 at .grp_sum[?id]
derived GrpCnt : GrpI64 at .grp_cnt[?id]
derived GrpDist : GrpI64 at .grp_dist[?id]
derived GrpCol : GrpStr at .grp_col[?id]
derived GrpMin : GrpI64 at .grp_min[?id]
derived GrpMax : GrpI64 at .grp_max[?id]
derived GrpAvg : GrpF64 at .grp_avg[?id]

rule grp_sum {
  when {
    ?_b := Bucket(grp: ?g)
    ?s := sum(?a) from Item(grp: ?g, amt: ?a)
  }
  then { assert GrpSum(grp: ?g, val: ?s) }
}
rule grp_cnt {
  when {
    ?_b := Bucket(grp: ?g)
    ?c := count(?a) from Item(grp: ?g, amt: ?a)
  }
  then { assert GrpCnt(grp: ?g, val: ?c) }
}
rule grp_distinct {
  when {
    ?_b := Bucket(grp: ?g)
    ?d := distinct(?t) from Item(grp: ?g, tag: ?t)
  }
  then { assert GrpDist(grp: ?g, val: ?d) }
}
rule grp_collect {
  when {
    ?_b := Bucket(grp: ?g)
    ?cs := collect(?t) from Item(grp: ?g, tag: ?t)
  }
  then { assert GrpCol(grp: ?g, val: ?cs) }
}
rule grp_min {
  when {
    ?_b := Bucket(grp: ?g)
    ?mn := min(?a) from Item(grp: ?g, amt: ?a)
  }
  then { assert GrpMin(grp: ?g, val: ?mn) }
}
rule grp_max {
  when {
    ?_b := Bucket(grp: ?g)
    ?mx := max(?a) from Item(grp: ?g, amt: ?a)
  }
  then { assert GrpMax(grp: ?g, val: ?mx) }
}
rule grp_avg {
  when {
    ?_b := Bucket(grp: ?g)
    ?av := avg(?a) from Item(grp: ?g, amt: ?a)
  }
  then { assert GrpAvg(grp: ?g, val: ?av) }
}`

	given_external_policy(&w, "acc", src, "inc_grouped_accum.forseti")
	upon_compiling_policy(&w, "acc")
	then_compilation_has_zero_diagnostics(&w, "acc")
	upon_compiling_rulebase(&w, "acc", "rb")
	given_session(&w, "rb", "s")

	upon_asserting_fact(&w, "s", "Bucket", "b:east", {"east"})
	upon_asserting_fact(&w, "s", "Bucket", "b:west", {"west"})
	upon_asserting_fact(&w, "s", "Item", "e1", {"east", i64(10), "alpha"})
	upon_asserting_fact(&w, "s", "Item", "e2", {"east", i64(30), "alpha"})
	upon_asserting_fact(&w, "s", "Item", "e3", {"east", i64(30), "beta"})
	upon_asserting_fact(&w, "s", "Item", "w1", {"west", i64(50), "west_tag"})

	upon_firing_session(&w, "s", "f1")
	then_rules_fired_count_is(&w, "f1", 14)
	then_session_has_derived_fact(&w, "s", "GrpSum", {"east", i64(70)})
	then_session_has_derived_fact(&w, "s", "GrpCnt", {"east", i64(3)})
	then_session_has_derived_fact(&w, "s", "GrpDist", {"east", i64(2)})
	then_session_has_derived_fact(&w, "s", "GrpCol", {"east", "alpha,alpha,beta"})
	then_session_has_derived_fact(&w, "s", "GrpMin", {"east", i64(10)})
	then_session_has_derived_fact(&w, "s", "GrpMax", {"east", i64(30)})
	then_session_has_derived_fact(&w, "s", "GrpSum", {"west", i64(50)})

	// Edit e2 (east, 30->5, beta->gamma): ONLY east rules fire (max stays 30 via e3, sum 70->45, dist 2->3)!
	upon_modifying_fact(&w, "s", "Item", "e2", {"east", i64(5), "gamma"})
	upon_firing_session(&w, "s", "f2")
	then_session_has_derived_fact(&w, "s", "GrpSum", {"east", i64(45)})
	then_session_has_derived_fact(&w, "s", "GrpMin", {"east", i64(5)})
	then_session_has_derived_fact(&w, "s", "GrpMax", {"east", i64(30)})
	then_session_has_derived_fact(&w, "s", "GrpDist", {"east", i64(3)})
	then_session_has_derived_fact(&w, "s", "GrpAvg", {"east", f64(15.0)})
	then_session_has_derived_fact(&w, "s", "GrpSum", {"west", i64(50)})

	// Retract all east items -> empty-group total=0/cnt=0/distinct=0/collect="" while min/max/avg revoke for east ONLY!
	upon_retracting_fact(&w, "s", "Item", "e1")
	upon_retracting_fact(&w, "s", "Item", "e2")
	upon_retracting_fact(&w, "s", "Item", "e3")
	upon_firing_session(&w, "s", "f3")
	then_session_has_derived_fact(&w, "s", "GrpSum", {"east", i64(0)})
	then_session_has_derived_fact(&w, "s", "GrpCnt", {"east", i64(0)})
	then_session_has_derived_fact(&w, "s", "GrpDist", {"east", i64(0)})
	then_session_has_derived_fact(&w, "s", "GrpCol", {"east", ""})
	then_session_binding_count_is(&w, "s", "GrpMin", 1)
	then_session_binding_count_is(&w, "s", "GrpMax", 1)
	then_session_binding_count_is(&w, "s", "GrpAvg", 1)
	then_session_has_derived_fact(&w, "s", "GrpMin", {"west", i64(50)})

	// Re-insert into east -> GrpMin/GrpMax/GrpAvg revive cleanly!
	upon_asserting_fact(&w, "s", "Item", "e4", {"east", i64(25), "delta"})
	upon_firing_session(&w, "s", "f4")
	then_session_binding_count_is(&w, "s", "GrpMin", 2)
	then_session_has_derived_fact(&w, "s", "GrpMin", {"east", i64(25)})
	then_session_has_derived_fact(&w, "s", "GrpAvg", {"east", f64(25.0)})
}

@(test)
spec_incremental_multi_way_star_and_chain_joins :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := `module multi_join_test version "1.0"

schema Org { oid: string, dom: string }
schema Dept { dom: string, code: string }
schema Contract { dom: string, tier: string }
schema Block { dom: string }
schema StarMatch { oid: string, code: string, tier: string }

schema Lead { lid: string, acct: string }
schema Acct { acct: string, parent: string }
schema RegionPol { parent: string, region: string }
schema ChainMatch { lid: string, parent: string, region: string }

source Org : Org at .orgs[?id]
source Dept : Dept at .depts[?id]
source Contract : Contract at .contracts[?id]
source Block : Block at .blocks[?id]
derived StarMatch : StarMatch at .star[?id]

source Lead : Lead at .leads[?id]
source Acct : Acct at .accts[?id]
source RegionPol : RegionPol at .pols[?id]
derived ChainMatch : ChainMatch at .chain[?id]

// 3-way star join: Org -> Dept and Org -> Contract
rule star_join {
  when {
    ?_o := Org(oid: ?oid, dom: ?dom)
    ?_d := Dept(dom: ?dom, code: ?code)
    ?_c := Contract(dom: ?dom, tier: ?tier)
  }
  then {
    assert StarMatch(oid: ?oid, code: ?code, tier: ?tier)
  }
}

// 3-way chain join: Lead -> Acct -> RegionPol
rule chain_join {
  when {
    ?_l := Lead(lid: ?lid, acct: ?acct)
    ?_a := Acct(acct: ?acct, parent: ?parent)
    ?_p := RegionPol(parent: ?parent, region: ?reg)
  }
  then {
    assert ChainMatch(lid: ?lid, parent: ?parent, region: ?reg)
  }
}

// Hash-indexed Not subnetwork paired with StarMatch
derived CleanDom : Block at .clean_dom[?id]
rule unblocked_dept {
  when {
    ?_d := Dept(dom: ?dom, code: ?_c)
    not Block(dom: ?dom)
  }
  then {
    assert CleanDom(dom: ?dom)
  }
}`

	given_external_policy(&w, "mj", src, "multi_join.forseti")
	upon_compiling_policy(&w, "mj")
	then_compilation_has_zero_diagnostics(&w, "mj")
	upon_compiling_rulebase(&w, "mj", "rb")
	given_session(&w, "rb", "s")

	upon_asserting_fact(&w, "s", "Org", "o1", {"org:1", "d1.io"})
	upon_asserting_fact(&w, "s", "Dept", "d1", {"d1.io", "eng"})
	upon_asserting_fact(&w, "s", "Contract", "c1", {"d1.io", "gold"})
	upon_asserting_fact(&w, "s", "Lead", "l1", {"lead:1", "acct:A"})
	upon_asserting_fact(&w, "s", "Acct", "a1", {"acct:A", "corp:X"})
	upon_asserting_fact(&w, "s", "RegionPol", "p1", {"corp:X", "EU"})

	upon_firing_session(&w, "s", "cold_run")
	then_rules_fired_count_is(&w, "cold_run", 3)
	then_session_has_derived_fact(&w, "s", "StarMatch", {"org:1", "eng", "gold"})
	then_session_has_derived_fact(&w, "s", "ChainMatch", {"lead:1", "corp:X", "EU"})
	then_session_has_derived_fact(&w, "s", "CleanDom", {"d1.io"})

	// Incremental leaf Contract insert for a second domain (plus partial Org+Dept) fires ONCE without duplicate firings!
	upon_asserting_fact(&w, "s", "Org", "o2", {"org:2", "d2.io"})
	upon_asserting_fact(&w, "s", "Dept", "d2", {"d2.io", "sales"})
	upon_firing_session(&w, "s", "partial_d2")
	then_rules_fired_count_is(&w, "partial_d2", 1) // unblocked_dept on d2.io
	then_session_binding_count_is(&w, "s", "StarMatch", 1)

	upon_asserting_fact(&w, "s", "Contract", "c2", {"d2.io", "platinum"})
	upon_firing_session(&w, "s", "leaf_c2")
	then_rules_fired_count_is(&w, "leaf_c2", 1)
	then_session_has_derived_fact(&w, "s", "StarMatch", {"org:2", "sales", "platinum"})

	// Middle chain pattern modify Acct(a1 -> parent corp:Y) + RegionPol(corp:Y -> US):
	upon_asserting_fact(&w, "s", "RegionPol", "p2", {"corp:Y", "US"})
	upon_modifying_fact(&w, "s", "Acct", "a1", {"acct:A", "corp:Y"})
	upon_firing_session(&w, "s", "mid_chain_mod")
	then_session_lacks_derived_fact(&w, "s", "ChainMatch", {"lead:1", "corp:X", "EU"})
	then_session_has_derived_fact(&w, "s", "ChainMatch", {"lead:1", "corp:Y", "US"})

	// Retract middle Dept d2 -> StarMatch(org:2) & CleanDom(d2.io) retract; Block d1.io retracts CleanDom(d1.io).
	upon_retracting_fact(&w, "s", "Dept", "d2")
	upon_asserting_fact(&w, "s", "Block", "blk1", {"d1.io"})
	upon_firing_session(&w, "s", "retract_step")
	then_session_lacks_derived_fact(&w, "s", "StarMatch", {"org:2", "sales", "platinum"})
	then_session_binding_count_is(&w, "s", "CleanDom", 0)

	// Re-insert Dept d2 and unblock d1.io -> clean recovery!
	upon_asserting_fact(&w, "s", "Dept", "d2b", {"d2.io", "ops"})
	upon_retracting_fact(&w, "s", "Block", "blk1")
	upon_firing_session(&w, "s", "recover_step")
	then_session_has_derived_fact(&w, "s", "StarMatch", {"org:2", "ops", "platinum"})
	then_session_has_derived_fact(&w, "s", "CleanDom", {"d1.io"})
	then_session_has_derived_fact(&w, "s", "CleanDom", {"d2.io"})
}

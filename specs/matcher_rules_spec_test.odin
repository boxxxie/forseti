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

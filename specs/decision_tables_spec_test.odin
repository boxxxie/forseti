package forseti_specs

import "base:runtime"
import "core:testing"

Table_Eval_Case :: struct {
	name:           string,
	table_name:     string,
	args:           []Table_Test_Arg,
	expected_match: bool,
	expected_out0:  string,
	expected_row:   string,
	loc:            runtime.Source_Code_Location,
}

table_eval_case :: proc(
	name: string,
	table_name: string,
	args: []Table_Test_Arg,
	expected_match: bool,
	expected_out0: string,
	expected_row: string,
	loc := #caller_location,
) -> Table_Eval_Case {
	return Table_Eval_Case{
		name           = name,
		table_name     = table_name,
		args           = args,
		expected_match = expected_match,
		expected_out0  = expected_out0,
		expected_row   = expected_row,
		loc            = loc,
	}
}

@(test)
spec_static_table_verifier_detects_overlaps_gaps_shadowed_and_unused_outputs :: proc(t: ^testing.T) {
	// 1. Unique overlap emits E3001 with witness tuple
	{
		w: World
		world_init(&w, t)
		defer world_destroy(&w)

		src := `module overlap_mdm version "1.0"
table survivorship_gate version "1.0" hit Unique {
  inputs { priority: i64, locked: bool }
  outputs { winner: string }
  rows {
    r1: >= 80 | true || "steward";
    r2: >= 90 | -    || "system";
  }
}
rule use_gate { when { ?_g := decide survivorship_gate(priority: 90, locked: true) } }`

		given_external_policy(&w, "p", src, "overlap.forseti")
		upon_compiling_policy(&w, "p")
		then_policy_emits_diagnostic(&w, "p", .E3001, .Error, 7, 5, "priority=")
	}

	// 2. Any policy allows agreeing overlap, rejects conflicting overlap (E3001)
	{
		w: World
		world_init(&w, t)
		defer world_destroy(&w)

		agree_src := `module any_ok version "1.0"
table identity_routing version "1.0" hit Any {
  inputs { verified: bool, score: i64 }
  outputs { route: string }
  rows {
    r1: true | -    || "auto";
    r2: -    | >= 0 || "auto";
    r3: false | < 0 || "manual";
  }
}
rule use_route { when { ?_r := decide identity_routing(verified: true, score: 5) } }`

		conflict_src := `module any_bad version "1.0"
table identity_routing version "1.0" hit Any {
  inputs { verified: bool, score: i64 }
  outputs { route: string }
  rows {
    r1: true | -     || "auto";
    r2: -    | >= 50 || "manual";
  }
}
rule use_route { when { ?_r := decide identity_routing(verified: true, score: 80) } }`

		given_external_policy(&w, "ok", agree_src, "any_ok.forseti")
		given_external_policy(&w, "bad", conflict_src, "any_bad.forseti")
		upon_compiling_policy(&w, "ok")
		upon_compiling_policy(&w, "bad")
		then_compilation_has_zero_diagnostics(&w, "ok")
		then_policy_emits_diagnostic(&w, "bad", .E3001, .Error, 7, 5)
	}

	// 3. Unsatisfiable cell (E3002), completeness gap (W3001), dead/shadowed rule (W3002),
	// mergeable rules (W3003), redundant full-domain cell (W3004), unused enum variant (W3005)
	{
		w: World
		world_init(&w, t)
		defer world_destroy(&w)

		src := `module career_mdm version "1.0"
table career_consolidation version "1.0" hit First verify(complete, no_dead_rules) {
  inputs {
    years: i64,
    active: bool,
    region: string
  }
  outputs {
    action: enum("keep", "merge", "archive")
  }
  rows {
    r1: > 10 and < 5 | -              | -      || "keep";
    r2: -            | true or false  | "US"   || "keep";
    r3: -            | -              | "CA"   || "keep";
    r4: >= 0         | -              | "US"   || "merge";
  }
}
rule use_cc { when { ?_c := decide career_consolidation(years: 1, active: true, region: "US") } }`

		given_external_policy(&w, "cc", src, "career.forseti")
		upon_compiling_policy(&w, "cc")
		then_policy_emits_diagnostic(&w, "cc", .E3002, .Error, 12, 9)
		then_policy_emits_diagnostic(&w, "cc", .W3004, .Warning, 13, 24)
		then_policy_emits_diagnostic(&w, "cc", .W3003, .Warning, 14, 5)
		then_policy_emits_diagnostic(&w, "cc", .W3002, .Warning, 15, 5, "r2")
		then_policy_emits_diagnostic(&w, "cc", .W3001, .Warning, 2, 1)
		then_policy_emits_diagnostic(&w, "cc", .W3005, .Warning, 2, 1, "archive")
	}

	// 4. Budget exhaustion emits W3006 cleanly
	{
		w: World
		world_init(&w, t)
		defer world_destroy(&w)

		src := `module big_mdm version "1.0"
table event_lifecycle version "1.0" hit First {
  inputs { a: i64, b: i64, c: i64, d: i64 }
  outputs { state: string }
  rows {
    r1: 1..10 | 1..10 | 1..10 | 1..10 || "active";
    r2: 20..30 | 20..30 | 20..30 | 20..30 || "closed";
  }
}`
		given_external_policy(&w, "el", src, "event.forseti")
		upon_verifying_table_with_budget(&w, "el", table_idx = 0, max_budget = 2)
		then_policy_emits_diagnostic(&w, "el", .W3006, .Warning, 2, 1)
	}
}

@(test)
spec_decision_table_single_hit_policies_matrix :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	policy_src := `module mdm_tables version "1.0"

table survivorship_gate version "2.0" hit First {
  inputs { priority: i64 cost 1, locked: bool cost 1, conf: f64 cost 5 }
  outputs { winner: string, reason: string }
  rows {
    r_locked: -     | true  | -       || "steward"   | "locked";
    r_high:   >= 80 | false | >= 0.85 || "authority" | "high_conf";
    r_low:    -     | -     | -       || "defer"     | "fallback";
  }
}

table identity_routing version "1.0" hit Unique {
  inputs { exact_email: bool, score: f64 }
  outputs { route: string }
  rows {
    r_auto:   true  | >= 0.90 || "auto_merge";
    r_review: true  | < 0.90  || "steward_review";
    r_split:  false | -       || "keep_separate";
  }
}

table career_consolidation version "1.0" hit Priority {
  inputs { same_org: bool, tenure_overlap: bool }
  outputs { resolution: enum("escalate", "merge_role", "ignore") }
  rows {
    r_ignore:   false | -     || "ignore";
    r_merge:    true  | true  || "merge_role";
    r_escalate: true  | -     || "escalate";
  }
}

query eval_mdm_tables() {
  ?_a := decide survivorship_gate(priority: 1, locked: false, conf: 0.5)
  ?_b := decide identity_routing(exact_email: false, score: 0.5)
  ?_c := decide career_consolidation(same_org: false, tenure_overlap: false)
}`

	given_external_policy(&w, "mdm", policy_src, "mdm_tables.forseti")
	upon_compiling_policy(&w, "mdm")
	then_compilation_has_zero_diagnostics(&w, "mdm")

	cases := []Table_Eval_Case{
		table_eval_case("survivorship locked wins over low score", "survivorship_gate", {i64(10), true, 0.2}, true, "steward", "r_locked"),
		table_eval_case("survivorship authority high conf", "survivorship_gate", {i64(90), false, 0.92}, true, "authority", "r_high"),
		table_eval_case("survivorship fallback", "survivorship_gate", {i64(40), false, 0.50}, true, "defer", "r_low"),
		table_eval_case("identity unique auto merge", "identity_routing", {true, 0.95}, true, "auto_merge", "r_auto"),
		table_eval_case("identity unique steward review", "identity_routing", {true, 0.65}, true, "steward_review", "r_review"),
		table_eval_case("identity unique split", "identity_routing", {false, 0.99}, true, "keep_separate", "r_split"),
		table_eval_case("career priority picks escalate over merge_role", "career_consolidation", {true, true}, true, "escalate", "r_escalate"),
		table_eval_case("career priority picks ignore when false/false", "career_consolidation", {false, false}, true, "ignore", "r_ignore"),
	}

	for tc in cases {
		upon_deciding_table(&w, "mdm", tc.table_name, "res", tc.args, loc = tc.loc)
		then_decision_result_is(&w, "res", tc.expected_match, tc.expected_out0, tc.expected_row, loc = tc.loc)
	}
}

@(test)
spec_lazy_cost_tree_skips_expensive_columns :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := `module lazy_mdm version "1.0"
table cost_gate version "1.0" hit First {
  inputs {
    exact_match: bool cost 1,
    domain_blocked: bool cost 1,
    llm_arbitration: f64 cost 100
  }
  outputs { decision: string }
  rows {
    r_exact:   true  | false | -      || "auto_merge";
    r_blocked: -     | true  | -      || "reject";
    r_llm_hi:  false | false | >= 0.8 || "llm_merge";
    r_default: -     | -     | -      || "review";
  }
}
query eval_cost_gate() {
  ?_d := decide cost_gate(exact_match: true, domain_blocked: false, llm_arbitration: 0.0)
}`

	given_external_policy(&w, "lazy", src, "lazy.forseti")
	upon_compiling_policy(&w, "lazy")
	then_compilation_has_zero_diagnostics(&w, "lazy")

	// Case 1: exact_match=true, domain_blocked=false decides immediately -> llm_arbitration (col 2, cost 100) skipped!
	upon_deciding_table_lazily(&w, "lazy", "cost_gate", "cheap_res", {true, false, 0.95})
	then_decision_result_is(&w, "cheap_res", true, "auto_merge", "r_exact")
	then_decision_column_eval_counts(&w, "cheap_res", col = 2, expected_calls = 0, expect_skipped_bit = true)
	then_decision_allocated_zero_bytes(&w, "cheap_res")

	// Case 2: exact_match=false, domain_blocked=false must invoke llm_arbitration exactly once
	upon_deciding_table_lazily(&w, "lazy", "cost_gate", "exp_res", {false, false, 0.88})
	then_decision_result_is(&w, "exp_res", true, "llm_merge", "r_llm_hi")
	then_decision_column_eval_counts(&w, "exp_res", col = 2, expected_calls = 1, expect_skipped_bit = false)
	then_decision_allocated_zero_bytes(&w, "exp_res")
}

@(test)
spec_multi_hit_collect_merge_and_reverse_merge_tables :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := `module multi_mdm version "1.0"

table collect_scores version "1.0" hit Collect_Sum {
  inputs { flag_a: bool, flag_b: bool }
  outputs { points: i64 }
  rows {
    r1: true | -    || 10;
    r2: -    | true || 25;
    r3: true | true || 5;
  }
}

table collect_min version "1.0" hit Collect_Min {
  inputs { tier: i64 }
  outputs { fee: i64 }
  rows {
    r1: >= 1 || 30;
    r2: >= 2 || 12;
    r3: >= 3 || 20;
  }
}

table collect_max version "1.0" hit Collect_Max {
  inputs { tier: i64 }
  outputs { fee: i64 }
  rows {
    r1: >= 1 || 30;
    r2: >= 2 || 12;
    r3: >= 3 || 45;
  }
}

table collect_count version "1.0" hit Collect_Count {
  inputs { active: bool }
  outputs { tag: string }
  rows {
    r1: true || "a";
    r2: -    || "b";
    r3: true || "c";
  }
}

table field_merge version "1.0" hit Merge {
  inputs { has_crm: bool, has_billing: bool }
  outputs { primary_name: string, billing_tier: string }
  rows {
    r1: true | -    || "Acme CRM" | -;
    r2: -    | true || "Acme Bill" | "enterprise";
  }
}

table field_rev_merge version "1.0" hit Reverse_Merge {
  inputs { has_crm: bool, has_billing: bool }
  outputs { primary_name: string, billing_tier: string }
  rows {
    r1: true | -    || "Acme CRM" | "starter";
    r2: -    | true || "Acme Bill" | -;
  }
}`

	given_external_policy(&w, "multi", src, "multi.forseti")
	upon_compiling_policy(&w, "multi")

	upon_deciding_table(&w, "multi", "collect_scores", "sum_res", {true, true})
	then_decision_int_output_is(&w, "sum_res", col = 0, expected = 40, expected_hits = 3)

	upon_deciding_table(&w, "multi", "collect_min", "min_res", {i64(2)})
	then_decision_int_output_is(&w, "min_res", col = 0, expected = 12, expected_hits = 2)

	upon_deciding_table(&w, "multi", "collect_max", "max_res", {i64(3)})
	then_decision_int_output_is(&w, "max_res", col = 0, expected = 45, expected_hits = 3)

	upon_deciding_table(&w, "multi", "collect_count", "cnt_res", {true})
	then_decision_int_output_is(&w, "cnt_res", col = 0, expected = 3, expected_hits = 3)

	// Merge: r1 sets primary_name="Acme CRM", r2 fills billing_tier="enterprise"
	upon_deciding_table(&w, "multi", "field_merge", "merge_res", {true, true})
	then_decision_outputs_are(&w, "merge_res", {"Acme CRM", "enterprise"}, expected_hits = 2)

	// Reverse_Merge: r2 overrides primary_name="Acme Bill", r1 fills billing_tier="starter"
	upon_deciding_table(&w, "multi", "field_rev_merge", "rev_res", {true, true})
	then_decision_outputs_are(&w, "rev_res", {"Acme Bill", "starter"}, expected_hits = 2)
}

@(test)
spec_aot_codegen_passes_strict_vet_and_matches_runtime :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	policy_src := `module aot_mdm version "1.0"

table gate_first version "1.0" hit First {
  inputs { score: i64, locked: bool, tag: string }
  outputs { action: string }
  rows {
    r1: -     | true  | -      || "locked";
    r2: >= 80 | false | "vip"  || "fast_track";
    r3: -     | -     | -      || "standard";
  }
}

table score_sum version "1.0" hit Collect_Sum {
  inputs { a: bool, b: bool }
  outputs { pts: i64 }
  rows {
    r1: true  | -     || 10;
    r2: -     | true  || 25;
    r3: false | false || 0;
  }
}

table row_merge version "1.0" hit Merge {
  inputs { a: bool, b: bool }
  outputs { name: string, tier: string }
  rows {
    r1: true  | -     || "Primary" | -;
    r2: -     | true  || "Secondary" | "gold";
    r3: false | false || - | -;
  }
}

table row_rev_merge version "1.0" hit Reverse_Merge {
  inputs { a: bool, b: bool }
  outputs { name: string, tier: string }
  rows {
    r1: true  | -     || "Primary" | "silver";
    r2: -     | true  || "Override" | -;
    r3: false | false || - | -;
  }
}

query q() {
  ?_1 := decide gate_first(score: 10, locked: false, tag: "std")
  ?_2 := decide score_sum(a: true, b: true)
  ?_3 := decide row_merge(a: true, b: true)
  ?_4 := decide row_rev_merge(a: true, b: true)
}`

	given_external_policy(&w, "aot", policy_src, "aot.forseti")
	upon_compiling_policy(&w, "aot")
	then_compilation_has_zero_diagnostics(&w, "aot")

	harness_test := `package generated_tables

import "core:testing"

@(test)
test_aot_generated_parity :: proc(t: ^testing.T) {
	r1 := decide_gate_first(Gate_First_Input{score = 10, locked = true, tag = "x"})
	testing.expect(t, r1.matched)
	testing.expect_value(t, r1.action, "locked")
	testing.expect_value(t, r1.row_id, "r1")

	r2 := decide_gate_first(Gate_First_Input{score = 95, locked = false, tag = "vip"})
	testing.expect(t, r2.matched)
	testing.expect_value(t, r2.action, "fast_track")

	rs := decide_score_sum(Score_Sum_Input{a = true, b = true})
	testing.expect(t, rs.matched)
	testing.expect_value(t, rs.pts, i64(35))
	testing.expect_value(t, rs.matched_count, u32(2))

	rm := decide_row_merge(Row_Merge_Input{a = true, b = true})
	testing.expect(t, rm.matched)
	testing.expect_value(t, rm.name, "Primary")
	testing.expect_value(t, rm.tier, "gold")

	rr := decide_row_rev_merge(Row_Rev_Merge_Input{a = true, b = true})
	testing.expect(t, rr.matched)
	testing.expect_value(t, rr.name, "Override")
	testing.expect_value(t, rr.tier, "silver")
}`

	upon_generating_and_verifying_aot_odin(&w, "aot", "generated_tables", harness_test)
	then_aot_odin_checks_and_passes_tests(&w)
}

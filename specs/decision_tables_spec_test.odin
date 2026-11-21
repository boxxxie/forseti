package forseti_specs

import "core:testing"

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

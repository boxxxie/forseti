package forseti_specs

import "core:strings"
import "core:testing"
import forseti "../forseti"

@(private = "file")
_build_scaled_alpha_policy :: proc(n: int) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, `module bench_sanity version "1.0"
schema Org { id: string, kind: string, bucket: i64 }
schema Flag { id: string, bucket: i64 }
source Org : Org at .orgs.raw[?id]
derived Flag : Flag at .orgs.flags[?id]
`)
	for i := 0; i < n; i += 1 {
		strings.write_string(&b, "rule r_")
		strings.write_int(&b, i)
		strings.write_string(&b, ` { when { ?_o := Org(kind: "saas", bucket: `)
		strings.write_int(&b, i)
		strings.write_string(&b, `, id: ?id) } then { assert Flag(id: ?id, bucket: `)
		strings.write_int(&b, i)
		strings.write_string(&b, ") } }\n")
	}
	return strings.to_string(b)
}

// Sanity spec: 1,000-rule selective fan-out compiles cleanly, allocates O(active) lazy memories,
// and triggers only matching rule derivations without leaks.
@(test)
spec_benchmark_scale_1k_alpha_fanout_and_sparse_memory :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := _build_scaled_alpha_policy(1_000)
	given_external_policy(&w, "scale1k", src, "scale1k.forseti")
	upon_compiling_policy(&w, "scale1k")
	then_compilation_has_zero_diagnostics(&w, "scale1k")
	upon_compiling_rulebase(&w, "scale1k", "rb")

	given_session(&w, "rb", "s", forseti.Session_Config{provenance_mode = .Fast})
	upon_asserting_fact(&w, "s", "Org", "org:777", {"org:777", "saas", i64(777)})
	upon_firing_session(&w, "s", "f1")

	then_rules_fired_count_is(&w, "f1", 1)
	then_session_has_derived_fact(&w, "s", "Flag", {"org:777", i64(777)})
	then_session_binding_count_is(&w, "s", "Flag", 1)
	then_session_telemetry_bounds(&w, min_live_mem = 1, max_live_mem = 16, max_beta_joins = 0, min_unlinked_skipped = 0)
	then_telemetry_counter_at_least(&w, .Alpha_Nodes_Shared, 900)
}

// Sanity spec: Safe_V2 xitdb store with pre-hashed paths/fields executes end-to-end MDM survivorship,
// decision table gating, negation, and count accumulators with atomic Audit_Full provenance commit.
@(test)
spec_benchmark_mdm_e2e_safe_v2_prehashed_parity :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := `module bench_mdm_sanity version "1.0"
schema RawOrg {
  name: string,
  country: string,
  domain: string,
  employees: i64,
  active: bool
}
schema Suppress { domain: string }
schema CanonOrg {
  name: string,
  domain: string,
  employees: i64,
  active: bool
}
schema DomainStats {
  domain: string,
  cnt: i64
}
source RawOrg : RawOrg at .orgs.raw[?id]
source Suppress : Suppress at .orgs.suppress[?domain]
derived CanonOrg : CanonOrg at .orgs.canon[?id]
derived DomainStats : DomainStats at .orgs.stats[?domain]

table survivorship_tier version "1.0" hit First {
  inputs { employees: i64 cost 1, active: bool cost 1 }
  outputs { action: string }
  rows {
    r1: >= 100 | true || "canon";
    r2: -      | -    || "ignore";
  }
}

rule canonicalize phase "survive" salience 10 {
  when {
    ?_r := RawOrg(name: ?nm, domain: ?dom, employees: ?emp, active: ?act)
    ?g := decide survivorship_tier(employees: ?emp, active: ?act)
    not Suppress(domain: ?dom)
    where ?g.action == "canon"
  }
  then { assert CanonOrg(name: ?nm, domain: ?dom, employees: ?emp, active: true) }
}

rule count_domain_canon phase "stats" salience 5 {
  when {
    ?_c := CanonOrg(domain: ?dom, name: ?_nm)
    ?cnt := count(?nm) from CanonOrg(domain: ?dom, name: ?nm)
  }
  then { assert DomainStats(domain: ?dom, cnt: ?cnt) }
}`

	given_external_policy(&w, "mdm", src, "mdm_sanity.forseti")
	upon_compiling_policy(&w, "mdm")
	then_compilation_has_zero_diagnostics(&w, "mdm")
	upon_compiling_rulebase(&w, "mdm", "rb")

	given_standalone_store(&w, "db")
	given_watched_collection(&w, "db", ".orgs.raw")
	upon_committing_mdm_orgs(&w, "db", {
		{id = "org:1", name = "Acme One", country = "US", domain = "acme.com", employees = 250, active = true},
		{id = "org:2", name = "Acme Two", country = "US", domain = "acme.com", employees = 150, active = true},
		{id = "org:3", name = "Tiny Co", country = "DE", domain = "tiny.de", employees = 25, active = true},
	})

	given_session(&w, "rb", "s")
	upon_syncing_store_and_firing(&w, "db", "s", "sync1", commit_derived = true)

	then_rules_fired_count_is(&w, "sync1", 4)
	then_session_binding_count_is(&w, "s", "CanonOrg", 2)
	then_session_has_derived_fact(&w, "s", "DomainStats", {"acme.com", i64(2)})
	then_store_collection_has_record_count_and_field(&w, "db", ".orgs.canon", 2, "name", "Acme One")
	then_store_audit_trail_is_complete(&w, "db", "bench_mdm_sanity", 4, "canonicalize")
}

// Sanity spec: Recursive reachability + negative stratification and JTMS retraction parity
// for benchmark graph and chain workloads.
@(test)
spec_benchmark_recursive_and_jtms_sanity :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := `module bench_rec_sanity version "1.0"
schema Edge { src: string, dst: string }
schema Node { id: string }
schema Reach { src: string, dst: string }
schema Isolated { id: string }

source Edge : Edge at .graph.edges[?k]
source Node : Node at .graph.nodes[?id]
derived Reach : Reach at .graph.reach[?k]
derived Isolated : Isolated at .graph.isolated[?id]

rule base_reach {
  when { ?_e := Edge(src: ?x, dst: ?y) }
  then { assert Reach(src: ?x, dst: ?y) }
}
rule step_reach {
  when { ?_r1 := Reach(src: ?x, dst: ?y); ?_r2 := Reach(src: ?y, dst: ?z) }
  then { assert Reach(src: ?x, dst: ?z) }
}
rule find_isolated {
  when { ?_n := Node(id: ?u); not Reach(src: "root", dst: ?u) }
  then { assert Isolated(id: ?u) }
}`

	given_external_policy(&w, "rec", src, "rec.forseti")
	upon_compiling_policy(&w, "rec")
	then_compilation_has_zero_diagnostics(&w, "rec")
	upon_compiling_rulebase(&w, "rec", "rb")

	given_session(&w, "rb", "s")
	upon_asserting_fact(&w, "s", "Node", "n1", {"n1"})
	upon_asserting_fact(&w, "s", "Node", "n2", {"n2"})
	upon_asserting_fact(&w, "s", "Node", "n3", {"n3"})
	upon_asserting_fact(&w, "s", "Edge", "e1", {"root", "n1"})
	upon_asserting_fact(&w, "s", "Edge", "e2", {"n1", "n2"})
	upon_firing_session(&w, "s", "f1")

	then_session_has_derived_fact(&w, "s", "Reach", {"root", "n2"})
	then_session_has_derived_fact(&w, "s", "Isolated", {"n3"})
	then_session_lacks_derived_fact(&w, "s", "Isolated", {"n2"})

	// Retracting edge e2 retracts transitive Reach("root", "n2") and revives Isolated("n2").
	upon_retracting_fact(&w, "s", "Edge", "e2")
	upon_firing_session(&w, "s", "f2")
	then_session_lacks_derived_fact(&w, "s", "Reach", {"root", "n2"})
	then_session_has_derived_fact(&w, "s", "Isolated", {"n2"})
}

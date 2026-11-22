package forseti_specs

import "core:testing"

@(test)
spec_e2e_mdm_full_lifecycle_tables_xitdb_jtms_recursion_effects_and_audit :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := `module e2e_mdm version "2.0"

schema RawOrg {
  name: string,
  domain: string,
  employees: i64,
  active: bool
}
schema Link { a: string, b: string }
schema OrgPair { a: string, b: string }
schema Suppress { domain: string }
schema CanonOrg {
  name: string,
  domain: string,
  tier: string
}
schema DomainSummary { domain: string, cnt: i64 }
schema EnrichOut { org_id: string, score: i64, country: string }
schema AuditLog { domain: string }

source RawOrg : RawOrg at .orgs.raw[?id]
source Link : Link at .orgs.links[?id]
source Suppress : Suppress at .orgs.suppress[?id]
derived CanonOrg : CanonOrg at .orgs.canon[?id]
derived OrgCluster : OrgPair at .orgs.cluster[?id]
derived DomainSummary : DomainSummary at .orgs.summary[?id]
derived EnrichOut : EnrichOut at .orgs.enrich[?id]
derived AuditLog : AuditLog at .orgs.audit[?id]

table survivorship_gate version "1.0" hit First verify(complete, no_overlap) {
  inputs { employees: i64 cost 1, active: bool cost 1 }
  outputs { tier: string }
  rows {
    r_ent: >= 100 | true  || "enterprise";
    r_smb: < 100  | true  || "smb";
    r_off: -      | false || "inactive";
  }
}

rule canonicalize phase "survive" salience 50 {
  when {
    ?_r := RawOrg(name: ?nm, domain: ?dom, employees: ?emp, active: ?act)
    ?g := decide survivorship_gate(employees: ?emp, active: ?act)
    not Suppress(domain: ?dom)
    where ?g.tier != "inactive"
  }
  then {
    assert CanonOrg(name: ?nm, domain: ?dom, tier: ?g.tier)
    assert! AuditLog(domain: ?dom) unconditional
  }
}

rule enrich_enterprise phase "enrich" salience 30 {
  when { ?_c := CanonOrg(name: ?nm, domain: ?_dom, tier: "enterprise") }
  effect "enrich" { org_id: ?nm }
}

rule summarize_domain phase "stats" salience 20 {
  when {
    ?_c := CanonOrg(domain: ?dom)
    ?cnt := count(?nm) from CanonOrg(domain: ?dom, name: ?nm)
  }
  then {
    assert DomainSummary(domain: ?dom, cnt: ?cnt)
  }
}

rule cluster_base phase "recurse" salience 10 {
  when { ?_l := Link(a: ?x, b: ?y) }
  then { assert OrgCluster(a: ?x, b: ?y) }
}

rule cluster_trans phase "recurse" salience 10 {
  when {
    ?_p1 := OrgCluster(a: ?x, b: ?y)
    ?_p2 := OrgCluster(a: ?y, b: ?z)
  }
  then { assert OrgCluster(a: ?x, b: ?z) }
}`

	given_external_policy(&w, "e2e", src, "e2e_mdm.forseti")
	upon_compiling_policy(&w, "e2e")
	then_compilation_has_zero_diagnostics(&w, "e2e")
	upon_compiling_rulebase(&w, "e2e", "rb")

	given_attached_file_store(&w, "db", "e2e_mdm.xit")
	given_watched_collection(&w, "db", ".orgs.raw")
	upon_committing_mdm_orgs(&w, "db", {
		{id = "org:1", name = "org:1", country = "US", domain = "acme.com", employees = 250, active = true},
		{id = "org:2", name = "Acme Two", country = "US", domain = "acme.com", employees = 40, active = true},
		{id = "org:3", name = "Dormant", country = "DE", domain = "dead.de", employees = 500, active = false},
	})

	given_session(&w, "rb", "s")
	upon_asserting_fact(&w, "s", "Link", "lnk:12", {"acme.com", "subsidiary.com"})
	upon_asserting_fact(&w, "s", "Link", "lnk:21", {"subsidiary.com", "acme.com"})

	upon_syncing_store_and_firing(&w, "db", "s", "sync1", commit_derived = false)
	then_session_binding_count_is(&w, "s", "CanonOrg", 2)
	then_session_has_derived_fact(&w, "s", "DomainSummary", {"acme.com", i64(2)})
	then_session_has_derived_fact(&w, "s", "OrgCluster", {"acme.com", "acme.com"})

	upon_executing_effects_in_parallel(&w, "s", "EnrichOut", "eff1")
	then_effect_batch_applied(&w, "eff1", 1)
	then_session_has_derived_fact(&w, "s", "EnrichOut", {"org:1", i64(90), "DE"})

	upon_committing_session_audit(&w, "s", "db")
	then_provenance_has_zero_hot_crypto(&w, "s", min_derivs = 5)
	then_store_collection_has_record_count_and_field(&w, "db", ".orgs.canon", 2, "tier", "enterprise")

	{
		ent_view := viewing_entity_audit(&w, "s", "db", "CanonOrg", {"org:1", "acme.com", "enterprise"}, "org:1")
		view_has_proof_support(ent_view, .Logical, expected_support = 1, expected_height = 1)
		view_explanation_mentions(ent_view, "canonicalize", table_name = "survivorship_gate", table_row = "r_ent")
		view_semiring_how_contains(ent_view, "canonicalize")
		view_semiring_why_count_is(ent_view, 1)
		view_store_audit_indexes_entity(ent_view, "e2e_mdm", "canonicalize", 4)
	}

	// Steward suppression of acme.com triggers JTMS cascade over CanonOrg, DomainSummary, and EnrichOut,
	// while unconditional AuditLog persists!
	upon_asserting_fact(&w, "s", "Suppress", "sup:acme", {"acme.com"})
	upon_firing_session(&w, "s", "sup_fire")
	then_session_binding_count_is(&w, "s", "CanonOrg", 0)
	then_session_binding_count_is(&w, "s", "EnrichOut", 0)
	then_session_binding_count_is(&w, "s", "AuditLog", 2)
	{
		retracted_canon := viewing_entity_audit(&w, "s", "db", "CanonOrg", {"org:1", "acme.com", "enterprise"}, "org:1")
		view_is_retracted(retracted_canon)
	}
}

@(test)
spec_e2e_mdm_counterfactual_policy_upgrade_and_visual_export :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	base_src := `module upgrade_mdm version "1.0"
schema RawOrg { name: string, domain: string, employees: i64, active: bool }
schema CanonOrg { name: string, domain: string, tier: string }
source RawOrg : RawOrg at .orgs.raw[?id]
derived CanonOrg : CanonOrg at .orgs.canon[?id]
table tier_tbl version "1.0" hit First {
  inputs { employees: i64, active: bool }
  outputs { tier: string }
  rows {
    r_ent: >= 100 | true || "enterprise";
    r_smb: >= 20  | true || "smb";
    r_no:  -      | -    || "drop";
  }
}
rule promote {
  when {
    ?_r := RawOrg(name: ?nm, domain: ?dom, employees: ?emp, active: ?act)
    ?g := decide tier_tbl(employees: ?emp, active: ?act)
    where ?g.tier != "drop"
  }
  then { assert CanonOrg(name: ?nm, domain: ?dom, tier: ?g.tier) }
}`

	cand_src := `module upgrade_mdm version "2.0"
schema RawOrg { name: string, domain: string, employees: i64, active: bool }
schema CanonOrg { name: string, domain: string, tier: string }
source RawOrg : RawOrg at .orgs.raw[?id]
derived CanonOrg : CanonOrg at .orgs.canon[?id]
table tier_tbl version "2.0" hit First {
  inputs { employees: i64, active: bool }
  outputs { tier: string }
  rows {
    r_ent: >= 100 | true || "enterprise";
    r_no:  -      | -    || "drop";
  }
}
rule promote {
  when {
    ?_r := RawOrg(name: ?nm, domain: ?dom, employees: ?emp, active: ?act)
    ?g := decide tier_tbl(employees: ?emp, active: ?act)
    where ?g.tier != "drop"
  }
  then { assert CanonOrg(name: ?nm, domain: ?dom, tier: ?g.tier) }
}`

	given_external_policy(&w, "base", base_src, "base.forseti")
	given_external_policy(&w, "cand", cand_src, "cand.forseti")
	upon_compiling_policy(&w, "base")
	upon_compiling_policy(&w, "cand")
	then_compilation_has_zero_diagnostics(&w, "base")
	then_compilation_has_zero_diagnostics(&w, "cand")

	upon_compiling_rulebase(&w, "base", "rb_base")
	upon_compiling_rulebase(&w, "cand", "rb_cand")

	given_standalone_store(&w, "db")
	given_watched_collection(&w, "db", ".orgs.raw")
	upon_committing_mdm_orgs(&w, "db", {
		{id = "org:1", name = "Acme One", country = "US", domain = "acme.com", employees = 250, active = true},
		{id = "org:2", name = "Mid Co", country = "US", domain = "mid.com", employees = 50, active = true},
	})

	given_session(&w, "rb_base", "s_base")
	upon_syncing_store_and_firing(&w, "db", "s_base", "sync_base", commit_derived = false)

	upon_running_diff_replay(&w, "s_base", "db", "rb_cand", {".orgs.raw"}, "rep1")
	then_diff_replay_reports(&w, "rep1", expected_added = 0, expected_removed = 1, expected_unchanged = 1)

	upon_exporting_rulebase_graph(&w, "rb_base", .Dot, "rb_dot")
	then_graph_export_contains(&w, "rb_dot", {"digraph forseti_rulebase", "promote", "tier_tbl", `style=dashed,label="decide"`})

	upon_exporting_rulebase_graph(&w, "rb_base", .Mermaid, "rb_mmd")
	then_graph_export_contains(&w, "rb_mmd", {"flowchart LR", "promote", "tier_tbl", "-. decide .->"})

	upon_exporting_derivation_graph(&w, "s_base", .Dot, "deriv_dot", "CanonOrg", {"Acme One", "acme.com", "enterprise"})
	then_graph_export_contains(&w, "deriv_dot", {"digraph forseti_derivations", "promote", "tier_tbl:r_ent", "Acme One"})

	upon_exporting_derivation_graph(&w, "s_base", .Mermaid, "deriv_mmd")
	then_graph_export_contains(&w, "deriv_mmd", {"flowchart TD", "promote", "Mid Co"})
}

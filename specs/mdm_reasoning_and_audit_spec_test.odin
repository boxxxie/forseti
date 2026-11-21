package forseti_specs

import "core:testing"
import "../forseti"

@(test)
spec_jtms_steward_override_cascades_diamond_survival_and_unconditional :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := `module mdm_jtms version "1.0"

schema RawInput { org_id: string, employees: i64 }
schema AltTrigger { org_id: string }
schema Survived { org_id: string }
schema Escalated { org_id: string, tier: string }
schema PermAudit { org_id: string }

source RawOrg : RawInput at .orgs.raw[?id]
source Alt : AltTrigger at .orgs.alt[?id]
derived Surv : Survived at .orgs.surv[?id]
derived Esc : Escalated at .orgs.esc[?id]
derived AuditLog : PermAudit at .orgs.audit[?id]

rule survive_from_raw {
  when { ?_r := RawOrg(org_id: ?oid, employees: ?emp); where ?emp >= 50 }
  then {
    assert Surv(org_id: ?oid)
    assert! AuditLog(org_id: ?oid) unconditional
  }
}

rule diamond_from_alt {
  when { ?_a := Alt(org_id: ?oid) }
  then { assert Surv(org_id: ?oid) }
}

rule escalate_survived {
  when { ?_s := Surv(org_id: ?oid) }
  then { assert Esc(org_id: ?oid, tier: "high") }
}`

	given_external_policy(&w, "jtms", src, "jtms.forseti")
	upon_compiling_policy(&w, "jtms")
	then_compilation_has_zero_diagnostics(&w, "jtms")
	upon_compiling_rulebase(&w, "jtms", "rb")
	given_session(&w, "rb", "s")

	// Assert both diamond paths + unconditional audit trigger for org:1; only RawOrg for org:2.
	upon_asserting_fact(&w, "s", "RawOrg", "raw:1", {"org:1", i64(200)})
	upon_asserting_fact(&w, "s", "Alt", "alt:1", {"org:1"})
	upon_asserting_fact(&w, "s", "RawOrg", "raw:2", {"org:2", i64(120)})
	upon_firing_session(&w, "s", "f1")

	// Diamond deduplicates Surv(org:1) -> 1 alive Surv for org:1 (support_count=2), 1 for org:2 -> 2 Surv total, 2 Esc, 2 AuditLog.
	then_session_binding_count_is(&w, "s", "Surv", 2)
	then_session_binding_count_is(&w, "s", "Esc", 2)
	then_session_binding_count_is(&w, "s", "AuditLog", 2)
	then_derived_fact_proof_and_support(&w, "s", "Surv", {"org:1"}, .Logical, expected_support = 2, expected_height = 1)
	then_derived_fact_proof_and_support(&w, "s", "Esc", {"org:1", "high"}, .Logical, expected_support = 1, expected_height = 2)

	// Retract RawOrg(raw:2) -> transitive cascade removes Surv(org:2) & Esc(org:2); AuditLog(org:2) is assert! so it SURVIVES!
	upon_retracting_fact(&w, "s", "RawOrg", "raw:2")
	then_session_lacks_derived_fact(&w, "s", "Surv", {"org:2"})
	then_session_lacks_derived_fact(&w, "s", "Esc", {"org:2", "high"})
	then_session_has_derived_fact(&w, "s", "AuditLog", {"org:2"})
	then_telemetry_counter_at_least(&w, .Jtms_Retractions, 2)

	// Retract RawOrg(raw:1) -> Surv(org:1) drops support 2 -> 1 (survives via diamond Alt!), so Esc(org:1) ALSO stays alive!
	upon_retracting_fact(&w, "s", "RawOrg", "raw:1")
	then_derived_fact_proof_and_support(&w, "s", "Surv", {"org:1"}, .Logical, expected_support = 1, expected_height = 1)
	then_session_has_derived_fact(&w, "s", "Esc", {"org:1", "high"})
	then_session_has_derived_fact(&w, "s", "AuditLog", {"org:1"})

	// Retract Alt(alt:1) -> Surv(org:1) & Esc(org:1) now cascade out completely, while AuditLog(org:1) survives!
	upon_retracting_fact(&w, "s", "Alt", "alt:1")
	then_session_lacks_derived_fact(&w, "s", "Surv", {"org:1"})
	then_session_lacks_derived_fact(&w, "s", "Esc", {"org:1", "high"})
	then_session_binding_count_is(&w, "s", "AuditLog", 2)
}

@(test)
spec_negation_exists_and_retractable_accumulators :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := `module neg_exists_accum version "1.0"

schema Org { org_id: string }
schema Contact { org_id: string, email: string }
schema Frozen { org_id: string }
schema Invoice { org_id: string, amt: i64 }
schema ActiveSummary { org_id: string, cnt: i64, total: i64, min_amt: i64, max_amt: i64 }

source OrgSrc : Org at .orgs[?id]
source ContactSrc : Contact at .contacts[?id]
source FrozenSrc : Frozen at .frozen[?id]
source InvSrc : Invoice at .invoices[?id]
derived Summary : ActiveSummary at .summary[?id]

rule summarize_active_org {
  when {
    ?_o := OrgSrc(org_id: ?oid)
    exists ContactSrc(org_id: ?oid)
    not FrozenSrc(org_id: ?oid)
    ?c := count(?a) from InvSrc(org_id: ?oid, amt: ?a)
    ?s := sum(?a) from InvSrc(org_id: ?oid, amt: ?a)
    ?mn := min(?a) from InvSrc(org_id: ?oid, amt: ?a)
    ?mx := max(?a) from InvSrc(org_id: ?oid, amt: ?a)
  }
  then {
    assert Summary(org_id: ?oid, cnt: ?c, total: ?s, min_amt: ?mn, max_amt: ?mx)
  }
}`

	given_external_policy(&w, "na", src, "neg_accum.forseti")
	upon_compiling_policy(&w, "na")
	then_compilation_has_zero_diagnostics(&w, "na")
	upon_compiling_rulebase(&w, "na", "rb")
	given_session(&w, "rb", "s")

	// Org + 2 duplicate-min invoices (100, 100) + 250, NO contact yet -> exists blocks emission.
	upon_asserting_fact(&w, "s", "OrgSrc", "o1", {"org:1"})
	upon_asserting_fact(&w, "s", "InvSrc", "i1", {"org:1", i64(100)})
	upon_asserting_fact(&w, "s", "InvSrc", "i2", {"org:1", i64(100)})
	upon_asserting_fact(&w, "s", "InvSrc", "i3", {"org:1", i64(250)})
	upon_firing_session(&w, "s", "no_contact")
	then_rules_fired_count_is(&w, "no_contact", 0)
	then_session_binding_count_is(&w, "s", "Summary", 0)

	// Add 2 contacts -> exists fires ONCE (does not duplicate or re-fire on second contact).
	upon_asserting_fact(&w, "s", "ContactSrc", "c1", {"org:1", "a@acme.com"})
	upon_asserting_fact(&w, "s", "ContactSrc", "c2", {"org:1", "b@acme.com"})
	upon_firing_session(&w, "s", "with_contacts")
	then_rules_fired_count_is(&w, "with_contacts", 1)
	then_session_has_derived_fact(&w, "s", "Summary", {"org:1", i64(3), i64(450), i64(100), i64(250)})

	// Retract one contact (c1): c2 still satisfies exists -> Summary stays alive untouched!
	upon_retracting_fact(&w, "s", "ContactSrc", "c1")
	upon_firing_session(&w, "s", "one_contact_left")
	then_rules_fired_count_is(&w, "one_contact_left", 0)
	then_session_has_derived_fact(&w, "s", "Summary", {"org:1", i64(3), i64(450), i64(100), i64(250)})

	// Retract one tied minimum (i1=100): cnt 3->2, total 450->350, min STAYS 100 via tie i2=100!
	upon_retracting_fact(&w, "s", "InvSrc", "i1")
	upon_firing_session(&w, "s", "tie_min_retract")
	then_session_binding_count_is(&w, "s", "Summary", 1)
	then_session_has_derived_fact(&w, "s", "Summary", {"org:1", i64(2), i64(350), i64(100), i64(250)})

	// Retract second minimum i2=100: min updates 100->250, max stays 250!
	upon_retracting_fact(&w, "s", "InvSrc", "i2")
	upon_firing_session(&w, "s", "min_changes")
	then_session_binding_count_is(&w, "s", "Summary", 1)
	then_session_has_derived_fact(&w, "s", "Summary", {"org:1", i64(1), i64(250), i64(250), i64(250)})

	// Freeze org -> not blocker retracts Summary!
	upon_asserting_fact(&w, "s", "FrozenSrc", "fz:1", {"org:1"})
	upon_firing_session(&w, "s", "frozen")
	then_session_binding_count_is(&w, "s", "Summary", 0)

	// Unfreeze org -> Summary cleanly restored!
	upon_retracting_fact(&w, "s", "FrozenSrc", "fz:1")
	upon_firing_session(&w, "s", "unfrozen")
	then_session_has_derived_fact(&w, "s", "Summary", {"org:1", i64(1), i64(250), i64(250), i64(250)})
}

@(test)
spec_tarjan_scc_stratification_rejects_unstratified_cycles_with_e4001 :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	// 1. Direct & mutual negation cycle: A -[not]-> B -> A
	bad_mutual_neg := `module bad_strat version "1.0"
schema Flag { id: string }
source Seed : Flag at .seed[?id]
derived A : Flag at .a[?id]
derived B : Flag at .b[?id]

rule make_a {
  when {
    ?_s := Seed(id: ?id)
    not B(id: ?id)
  }
  then { assert A(id: ?id) }
}

rule make_b {
  when { ?_a := A(id: ?id) }
  then { assert B(id: ?id) }
}`

	given_external_policy(&w, "bad_neg", bad_mutual_neg, "bad_neg.forseti")
	upon_compiling_policy(&w, "bad_neg")
	then_policy_emits_diagnostic(&w, "bad_neg", .E4001, .Error, 10, 9, "make_a")
	upon_attempting_rulebase_compile(&w, "bad_neg")
	then_rulebase_compile_failed_with(&w, .Unstratified_Negation)

	// 2. Unstratified aggregation cycle: Total -[accum]-> Item -> Total
	bad_accum_cycle := `module bad_agg version "1.0"
schema Val { x: i64 }
source Seed : Val at .seed[?id]
derived Total : Val at .total[?id]
derived Item : Val at .item[?id]

rule sum_items {
  when { ?t := count(?v) from Item(x: ?v) }
  then { assert Total(x: ?t) }
}

rule total_feeds_item {
  when { ?_s := Seed(x: ?_x); ?_t := Total(x: ?tv) }
  then { assert Item(x: ?tv) }
}`

	given_external_policy(&w, "bad_agg", bad_accum_cycle, "bad_agg.forseti")
	upon_compiling_policy(&w, "bad_agg")
	then_policy_emits_diagnostic(&w, "bad_agg", .E4001, .Error, 8, 31, "sum_items")
	upon_attempting_rulebase_compile(&w, "bad_agg")
	then_rulebase_compile_failed_with(&w, .Unstratified_Negation)
}

@(test)
spec_cyclic_org_hierarchy_and_person_merge_semi_naive_recursion :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := `module cyclic_datalog version "1.0"

schema OrgEdge { child_id: string, parent_id: string }
schema OrgRef { org_id: string }
schema Link { a: string, b: string }
schema ActiveAlert { org_id: string }

source SeedFreeze : OrgRef at .seed_freeze[?id]
source OrgParent : OrgEdge at .org_parent[?id]
source RawLink : Link at .raw_link[?id]
source MergeSeed : OrgRef at .merge_seed[?id]

derived FrozenOrg : OrgRef at .frozen_org[?id]
derived SamePerson : Link at .same_person[?id]
derived MergedPerson : OrgRef at .merged_person[?id]
derived CleanOrgAlert : ActiveAlert at .clean_alert[?id]

rule seed_freeze {
  when { ?_s := SeedFreeze(org_id: ?oid) }
  then { assert FrozenOrg(org_id: ?oid) }
}

// Positive cyclic recursion: must terminate with minimal finite proof_height!
rule prop_freeze {
  when {
    ?_f := FrozenOrg(org_id: ?p)
    ?_e := OrgParent(child_id: ?c, parent_id: ?p)
  }
  then {
    assert FrozenOrg(org_id: ?c)
  }
}

// Stratified negation on top of recursive FrozenOrg (Stratum 1 after Stratum 0 saturates):
rule clean_alert {
  when {
    ?_e := OrgParent(child_id: ?cid, parent_id: ?_p)
    not FrozenOrg(org_id: ?cid)
  }
  then {
    assert CleanOrgAlert(org_id: ?cid)
  }
}

// Cyclic person merge transitive closure:
rule seed_same_fwd {
  when { ?_l := RawLink(a: ?x, b: ?y) }
  then { assert SamePerson(a: ?x, b: ?y) }
}
rule seed_same_rev {
  when { ?_l := RawLink(a: ?x, b: ?y) }
  then { assert SamePerson(a: ?y, b: ?x) }
}
rule trans_same {
  when {
    ?_m1 := SamePerson(a: ?x, b: ?y)
    ?_m2 := SamePerson(a: ?y, b: ?z)
  }
  then {
    assert SamePerson(a: ?x, b: ?z)
  }
}
rule merge_seed {
  when { ?_s := MergeSeed(org_id: ?p) }
  then { assert MergedPerson(org_id: ?p) }
}
rule prop_merge {
  when {
    ?_m := MergedPerson(org_id: ?p)
    ?_e := SamePerson(a: ?p, b: ?q)
  }
  then {
    assert MergedPerson(org_id: ?q)
  }
}`

	given_external_policy(&w, "cyc", src, "cyclic_datalog.forseti")
	upon_compiling_policy(&w, "cyc")
	then_compilation_has_zero_diagnostics(&w, "cyc")
	upon_compiling_rulebase(&w, "cyc", "rb")
	given_session(&w, "rb", "s")

	// Build 3-node cycle A -> B -> C -> A plus untouched node D -> E.
	upon_asserting_fact(&w, "s", "OrgParent", "e1", {"org:B", "org:A"})
	upon_asserting_fact(&w, "s", "OrgParent", "e2", {"org:C", "org:B"})
	upon_asserting_fact(&w, "s", "OrgParent", "e3", {"org:A", "org:C"})
	upon_asserting_fact(&w, "s", "OrgParent", "e4", {"org:E", "org:D"})
	upon_asserting_fact(&w, "s", "SeedFreeze", "sf:A", {"org:A"})

	// Person cycle: p1 <-> p2 <-> p3 -> p1
	upon_asserting_fact(&w, "s", "RawLink", "l1", {"p1", "p2"})
	upon_asserting_fact(&w, "s", "RawLink", "l2", {"p2", "p3"})
	upon_asserting_fact(&w, "s", "RawLink", "l3", {"p3", "p1"})
	upon_asserting_fact(&w, "s", "MergeSeed", "ms:1", {"p1"})

	upon_firing_session(&w, "s", "sat")

	// Minimal finite proof heights along cycle: A=1, B=2, C=3!
	then_session_binding_count_is(&w, "s", "FrozenOrg", 3)
	then_derived_fact_proof_and_support(&w, "s", "FrozenOrg", {"org:A"}, .Logical, expected_support = 2, expected_height = 1)
	then_derived_fact_proof_and_support(&w, "s", "FrozenOrg", {"org:B"}, .Logical, expected_support = 1, expected_height = 2)
	then_derived_fact_proof_and_support(&w, "s", "FrozenOrg", {"org:C"}, .Logical, expected_support = 1, expected_height = 3)
	then_session_binding_count_is(&w, "s", "MergedPerson", 3)

	// Only org:E gets CleanOrgAlert because FrozenOrg(A, B, C) saturated in Stratum 0 before clean_alert ran in Stratum 1!
	then_session_binding_count_is(&w, "s", "CleanOrgAlert", 1)
	then_session_has_derived_fact(&w, "s", "CleanOrgAlert", {"org:E"})

	// Now retract SeedFreeze(A) -> groundedness JTMS breaks the self-supporting A->B->C->A ghost cycle completely!
	upon_retracting_fact(&w, "s", "SeedFreeze", "sf:A")
	then_session_binding_count_is(&w, "s", "FrozenOrg", 0)
	upon_firing_session(&w, "s", "after_unfreeze")
	// Now A, B, C, E all get CleanOrgAlert (4 alerts)!
	then_session_binding_count_is(&w, "s", "CleanOrgAlert", 4)
}

@(test)
spec_provenance_xitdb_audit_semirings_explain_impact_and_diff_replay :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	policy_v1 := `module mdm_audit version "1.0"

schema Org {
  name: string,
  domain: string,
  employees: i64,
  active: bool
}
schema Flag { domain: string, reason: string }

source RawOrg : Org at .orgs.raw[?id]
derived CanonOrg : Org at .orgs.canon[?id]
derived RiskFlag : Flag at .orgs.flags[?id]

table size_gate version "1.0" hit First {
  inputs { employees: i64 cost 1, active: bool cost 1 }
  outputs { action: string }
  rows {
    r1: >= 100 | true || "canon";
    r2: -      | -    || "skip";
  }
}

rule canonicalize_org phase "survive" salience 50 {
  when {
    ?_raw := RawOrg(name: ?nm, domain: ?dom, employees: ?emp, active: ?act)
    ?g := decide size_gate(employees: ?emp, active: ?act)
    where ?g.action == "canon"
  }
  then {
    assert CanonOrg(name: ?nm, domain: ?dom, employees: ?emp, active: true)
  }
}

rule flag_canon_org phase "audit" salience 10 {
  when { ?_c := CanonOrg(name: ?_nm, domain: ?dom, employees: ?_emp, active: true) }
  then { assert RiskFlag(domain: ?dom, reason: "large_canon") }
}`

	// Candidate v2 tightens threshold from >= 100 to >= 200 -> ACME West (120) dropped!
	policy_v2 := `module mdm_audit version "2.0"

schema Org {
  name: string,
  domain: string,
  employees: i64,
  active: bool
}
schema Flag { domain: string, reason: string }

source RawOrg : Org at .orgs.raw[?id]
derived CanonOrg : Org at .orgs.canon[?id]
derived RiskFlag : Flag at .orgs.flags[?id]

table size_gate version "2.0" hit First {
  inputs { employees: i64 cost 1, active: bool cost 1 }
  outputs { action: string }
  rows {
    r1: >= 200 | true || "canon";
    r2: -      | -    || "skip";
  }
}

rule canonicalize_org phase "survive" salience 50 {
  when {
    ?_raw := RawOrg(name: ?nm, domain: ?dom, employees: ?emp, active: ?act)
    ?g := decide size_gate(employees: ?emp, active: ?act)
    where ?g.action == "canon"
  }
  then {
    assert CanonOrg(name: ?nm, domain: ?dom, employees: ?emp, active: true)
  }
}

rule flag_canon_org phase "audit" salience 10 {
  when { ?_c := CanonOrg(name: ?_nm, domain: ?dom, employees: ?_emp, active: true) }
  then { assert RiskFlag(domain: ?dom, reason: "large_canon") }
}`

	given_external_policy(&w, "v1", policy_v1, "v1.forseti")
	given_external_policy(&w, "v2", policy_v2, "v2.forseti")
	upon_compiling_policy(&w, "v1")
	upon_compiling_policy(&w, "v2")
	then_compilation_has_zero_diagnostics(&w, "v1")
	then_compilation_has_zero_diagnostics(&w, "v2")
	upon_compiling_rulebase(&w, "v1", "rb1")
	upon_compiling_rulebase(&w, "v2", "rb2")

	given_standalone_store(&w, "db", forseti.Xitdb_Config{mode = .Fast_Memory})
	given_watched_collection(&w, "db", ".orgs.raw")
	upon_committing_mdm_orgs(&w, "db", {
		{id = "org:1", name = "ACME HQ", country = "DE", domain = "acme.com", employees = 250, active = true},
		{id = "org:2", name = "NorthCo", country = "US", domain = "north.io", employees = 120, active = true},
	})

	// Default Session_Config enables .Audit_Full automatically!
	given_session(&w, "rb1", "s1")
	upon_syncing_store_and_firing(&w, "db", "s1", "sync1", commit_derived = true)
	then_rules_fired_count_is(&w, "sync1", 4)
	then_provenance_has_zero_hot_crypto(&w, "s1", min_derivs = 4)
	then_telemetry_counter_at_least(&w, .Derivations_Recorded, 4)

	// Atomic xitdb moment committed derived.* + decisions + idx.decisions_by_* + __tx!
	then_store_audit_trail_is_complete(&w, "db", "mdm_audit", 4, "canonicalize_org", "org:1")

	// Explain, Impact, Semiring views (Boolean, Why, How, Viterbi):
	upon_explaining_derived_fact(&w, "s1", "RiskFlag", {"acme.com", "large_canon"}, "exp_risk")
	then_explanation_contains(&w, "exp_risk", {"flag_canon_org", "canonicalize_org", "table=size_gate", "row=r1", "ACME HQ"})

	upon_computing_rule_impact(&w, "s1", "canonicalize_org", "imp_canon")
	then_impact_counts_at_least(&w, "imp_canon", min_direct = 2, min_transitive = 4, min_derivs = 4)

	upon_evaluating_semiring(&w, "s1", "RiskFlag", {"acme.com", "large_canon"}, .Boolean, "semi_b")
	then_semiring_result_satisfies(&w, "semi_b", expect_bool = true)

	upon_evaluating_semiring(&w, "s1", "RiskFlag", {"acme.com", "large_canon"}, .Why, "semi_w")
	then_semiring_result_satisfies(&w, "semi_w", min_why_sets = 1)

	upon_evaluating_semiring(&w, "s1", "RiskFlag", {"acme.com", "large_canon"}, .How, "semi_h")
	then_semiring_result_satisfies(&w, "semi_h", how_substr = "flag_canon_org(canonicalize_org(RawOrg[org:1]))")

	upon_evaluating_semiring(&w, "s1", "RiskFlag", {"acme.com", "large_canon"}, .Viterbi, "semi_v")
	then_semiring_result_satisfies(&w, "semi_v", min_viterbi_score = 0.5)

	// Counterfactual diff_replay of rb2 over Core_Overlay fork drops NorthCo (120 < 200): 2 removed (CanonOrg+RiskFlag), 2 unchanged, 0 added!
	upon_running_diff_replay(&w, "s1", "db", "rb2", {".orgs.raw"}, "dr")
	then_diff_replay_reports(&w, "dr", expected_added = 0, expected_removed = 2, expected_unchanged = 2)

	// Opt-out .Fast mode allocates 0 derivation records cleanly!
	given_session(&w, "rb1", "s_fast", forseti.Session_Config{provenance_mode = .Fast})
	upon_asserting_fact(&w, "s_fast", "RawOrg", "org:1", {"ACME HQ", "acme.com", i64(250), true})
	upon_firing_session(&w, "s_fast", "fast_run")
	then_provenance_has_zero_hot_crypto(&w, "s_fast", min_derivs = 0)
}

@(test)
spec_three_phase_async_effects_parallel_execution_and_lineage :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	src := `module mdm_effects version "1.0"

schema Org { org_id: string, domain: string }
schema EnrichRec { org_id: string, score: i64, country: string }
schema ApprovedOrg { org_id: string, score: i64 }

source RawOrg : Org at .orgs.raw[?id]
source Enriched : EnrichRec at .orgs.enriched[?id]
derived Approved : ApprovedOrg at .orgs.approved[?id]

rule request_enrichment {
  when { ?_r := RawOrg(org_id: ?oid, domain: ?dom) }
  effect "enrich_registry" { org_id: ?oid, domain: ?dom }
}

rule approve_high_score {
  when { ?_e := Enriched(org_id: ?oid, score: ?sc, country: ?_c); where ?sc >= 80 }
  then { assert Approved(org_id: ?oid, score: ?sc) }
}`

	given_external_policy(&w, "eff", src, "effects.forseti")
	upon_compiling_policy(&w, "eff")
	then_compilation_has_zero_diagnostics(&w, "eff")
	upon_compiling_rulebase(&w, "eff", "rb")
	given_session(&w, "rb", "s")

	upon_asserting_fact(&w, "s", "RawOrg", "org:1", {"org:1", "acme.de"})
	upon_asserting_fact(&w, "s", "RawOrg", "org:2", {"org:2", "beta.us"})
	upon_firing_session(&w, "s", "phase1_prepare")
	then_rules_fired_count_is(&w, "phase1_prepare", 2)

	// Phase 2 & 3: execute 2 Effect_Jobs concurrently across real core:thread workers and apply returned facts!
	upon_executing_effects_in_parallel(&w, "s", "Enriched", "batch1")
	then_effect_batch_applied(&w, "batch1", expected_count = 2)

	upon_firing_session(&w, "s", "phase3_react")
	then_rules_fired_count_is(&w, "phase3_react", 2)
	then_session_binding_count_is(&w, "s", "Approved", 2)

	// Provenance explain traces Approved -> Enriched -> request_enrichment -> RawOrg!
	upon_explaining_derived_fact(&w, "s", "Approved", {"org:1", i64(90)}, "exp_eff")
	then_explanation_contains(&w, "exp_eff", {"approve_high_score", "request_enrichment", "RawOrg", "org:1"})
}

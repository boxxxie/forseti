package forseti_specs

import "core:testing"

@(test)
spec_lsp_stdio_diagnostics_utf16_and_incomplete_buffers :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_cli_binary(&w)
	given_lsp_session(&w, "lsp")

	// Line 5 has UTF-8 prefix before ?missing so UTF-16 character offset counts surrogate pair (😀 = 2 units)
	policy := `module lsp_diag version "1.0"
schema Org { org_id: string }
source Raw : Org at .raw[?id]
derived Out : Org at .out[?id]
rule bad_rule {
  when { /* 😀 */ Raw(org_id: ?unused) }
  then { assert Out(org_id: ?missing) }
}`

	uri := "file:///policy.forseti"
	upon_lsp_opening_document(&w, "lsp", uri, policy, version = 1)
	then_lsp_diagnostics_count_is(&w, "lsp", uri, 2)
	// Line 5: "  when { /* 😀 */ Raw(org_id: ?unused) }" -> ?unused at UTF-16 col 30..37
	then_lsp_has_diagnostic(&w, "lsp", uri, "W2001", 5, 30, 5, 37)
	// Line 6: "  then { assert Out(org_id: ?missing) }" -> ?missing at col 28..36
	then_lsp_has_diagnostic(&w, "lsp", uri, "E2003", 6, 28, 6, 36)

	// Incomplete buffer during typing reports syntax error without crashing
	upon_lsp_changing_document(&w, "lsp", uri, "module lsp_diag version \"1.0\"\nrule partial { when { Raw(", version = 2)
	then_lsp_has_diagnostic(&w, "lsp", uri, "E1002", 1, 26, 1, 26)

	// Clean policy clears diagnostics, then incremental edit injects an error and closing clears diagnostics
	clean := `module lsp_diag version "1.0"
schema Org { org_id: string }
source Raw : Org at .raw[?id]
derived Out : Org at .out[?id]
rule ok_rule {
  when { Raw(org_id: ?oid) }
  then { assert Out(org_id: ?oid) }
}`
	upon_lsp_changing_document(&w, "lsp", uri, clean, version = 3)
	then_lsp_diagnostics_count_is(&w, "lsp", uri, 0)

	// Incremental edit changing ?oid -> ?bad in then-action triggers E2003
	upon_lsp_changing_document_range(&w, "lsp", uri, 6, 28, 6, 32, "?bad", version = 4)
	then_lsp_has_diagnostic(&w, "lsp", uri, "E2003", 6, 28, 6, 32)

	upon_lsp_closing_document(&w, "lsp", uri)
	then_lsp_diagnostics_count_is(&w, "lsp", uri, 0)
	upon_lsp_shutting_down(&w, "lsp", expected_exit = 0)
}

@(test)
spec_lsp_hover_definition_symbols_completion_formatting_and_code_actions :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_cli_binary(&w)
	given_lsp_session(&w, "lsp")

	policy := `module lsp_full version "1.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string, tier: string }

source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]

table tier_gate version "1.0" hit First {
  inputs { employees: i64 cost 1 }
  outputs { tier: string }
  rows {
    r_ent: >= 100 || "enterprise";
  }
}

rule classify phase "main" salience 10 {
  when {
    Raw(org_id: ?oid, employees: ?emp)
    ?g := decide tier_gate(employees: ?emp)
    Raw(org_id: ?unused)
  }
  then { assert Canon(org_id: ?oid, tier: ?g.tier) }
}

query ent_orgs(tier: string) {
  Canon(org_id: ?oid, tier: ?tier)
}`

	uri := "file:///full.forseti"
	upon_lsp_opening_document(&w, "lsp", uri, policy, version = 1)

	// PublishDiagnostics emits W2001 (unused ?unused) and W3001 (non-exhaustive tier_gate)
	then_lsp_has_diagnostic(&w, "lsp", uri, "W2001", 19, 16, 19, 23)
	then_lsp_has_diagnostic(&w, "lsp", uri, "W3001", 7, 0, 13, 1)

	// Hover on binding Raw (line 17 col 5), table tier_gate (line 18 col 18), ?emp (line 18 col 38), rule classify (line 15 col 6)
	then_lsp_hover_contains(&w, "lsp", uri, 17, 5, {"source Raw", "RawOrg", ".orgs.raw[?id]"})
	then_lsp_hover_contains(&w, "lsp", uri, 18, 18, {"table tier_gate", "First", "employees: i64"})
	then_lsp_hover_contains(&w, "lsp", uri, 18, 38, {"?emp", "i64"})
	then_lsp_hover_contains(&w, "lsp", uri, 15, 6, {"rule classify", "phase", "main", "salience 10", "stratum 0"})

	// Go-to-definition from Raw usage -> line 4, tier_gate -> line 7, ?oid in then (col 30) -> line 17 col 16
	then_lsp_definition_is(&w, "lsp", uri, 17, 5, 4, 0)
	then_lsp_definition_is(&w, "lsp", uri, 18, 18, 7, 0)
	then_lsp_definition_is(&w, "lsp", uri, 21, 30, 17, 16)

	// Document symbols outline
	then_lsp_document_symbols_include(&w, "lsp", uri, {"RawOrg", "CanonOrg", "Raw", "Canon", "tier_gate", "classify", "ent_orgs"})

	// Completion inside rule body / decide, inside Raw(...), and dot-access after ?g.
	then_lsp_completion_includes(&w, "lsp", uri, 18, 18, {"tier_gate", "Raw", "Canon"})
	then_lsp_completion_includes(&w, "lsp", uri, 17, 10, {"org_id", "employees"})
	then_lsp_completion_includes(&w, "lsp", uri, 21, 45, {"tier"})

	// Code actions: W2001 -> prefix ?_unused, W3001 -> append fallback row
	then_lsp_code_action_fixes_to(&w, "lsp", uri, "W2001", 19, 16, 19, 23, "Prefix", "?_unused")
	then_lsp_code_action_fixes_to(&w, "lsp", uri, "W3001", 7, 0, 13, 1, "fallback", "r_fallback: -")

	// Formatting via LSP
	expected_fmt := `module lsp_full version "1.0"

schema RawOrg { org_id: string, employees: i64 }

schema CanonOrg { org_id: string, tier: string }

source Raw : RawOrg at .orgs.raw[?id]

derived Canon : CanonOrg at .orgs.canon[?id]

table tier_gate version "1.0" hit First {
  inputs { employees: i64 cost 1 }
  outputs { tier: string }
  rows {
    r_ent: >= 100 || "enterprise";
  }
}

rule classify phase "main" salience 10 {
  when {
    Raw(org_id: ?oid, employees: ?emp)
    ?g := decide tier_gate(employees: ?emp)
    Raw(org_id: ?unused)
  }
  then { assert Canon(org_id: ?oid, tier: ?g.tier) }
}

query ent_orgs(tier: string) {
  Canon(org_id: ?oid, tier: ?tier)
}
`
	then_lsp_formatting_produces(&w, "lsp", uri, expected_fmt)

	upon_lsp_shutting_down(&w, "lsp", expected_exit = 0)
}

package forseti_specs

import "core:testing"

@(test)
spec_dsl_v1_1_imports_diamond_dedup_and_cycles :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_cli_binary(&w)

	// Shared schema imported both directly by main.forseti and transitively by tables.forseti (diamond dedup).
	given_workspace_file(&w, "inc/schemas.forseti", `schema RawOrg { id: string, name: string }
schema CanonOrg { id: string, norm: string }
source raw_orgs: RawOrg at .orgs.raw[?id]
derived canon_orgs: CanonOrg at .orgs.canon[?id]
`)
	given_workspace_file(&w, "inc/tables.forseti", `import "schemas.forseti"
table tier_gate version "1.0" hit First verify(complete) {
  inputs { name: string }
  outputs { label: string }
  rows {
    r_any: - || "ok";
  }
}
`)
	given_workspace_file(&w, "main.forseti", `module multi_file version "1.1"
import "schemas.forseti"
import "tables.forseti"

rule canon {
  when {
    raw_orgs(id: ?id, name: ?nm)
    ?t := decide tier_gate(name: ?nm)
    where len(?t.label) > 0
  }
  then {
    assert canon_orgs(id: ?id, norm: lower(?nm))
  }
}
`)

	// Compile via library compile_file with include search path ("inc").
	upon_compiling_workspace_file(&w, "p_ok", "main.forseti", {"inc"})
	then_compilation_has_zero_diagnostics(&w, "p_ok")

	// Also verify CLI `forseti check --include inc main.forseti` and `forseti run --include inc` succeed.
	upon_running_cli(&w, "cli_inc_ok", {"check", "--include", "inc", "main.forseti"})
	then_cli_exits_with(&w, "cli_inc_ok", 0)

	given_workspace_file(&w, "facts.json", `{"facts":[{"binding":"raw_orgs","key":"o1","fields":{"id":"o1","name":"ACME"}}]}`)
	upon_running_cli(&w, "cli_run_inc", {"run", "--include", "inc", "--facts", "facts.json", "--format=json", "main.forseti"})
	then_cli_exits_with(&w, "cli_run_inc", 0)
	then_cli_output_contains(&w, "cli_run_inc", `"fired":1`)

	// Circular import a.forseti -> b.forseti -> a.forseti triggers E2006 with trace.
	given_workspace_file(&w, "cycle/a.forseti", `module cyc version "1.0"
import "b.forseti"
`)
	given_workspace_file(&w, "cycle/b.forseti", `import "a.forseti"
`)
	upon_compiling_workspace_file(&w, "p_cyc", "cycle/a.forseti", {})
	then_policy_emits_diagnostic(&w, "p_cyc", .E2006, .Error, 1, 1, substr = "circular import")
	then_policy_emits_diagnostic(&w, "p_cyc", .E2006, .Error, 1, 1, substr = "a.forseti")

	// Multi-file diagnostic span reporting: E2002 inside imported child reports child filename.
	given_workspace_file(&w, "bad/child.forseti", `schema Item { id: string, qty: i64 }
source items: Item at .items[?id]
rule bad_type {
  when {
    items(id: ?id, qty: ?q)
    where lower(?q) == "x"
  }
  then {
    assert items(id: ?id, qty: 1)
  }
}
`)
	given_workspace_file(&w, "bad/root.forseti", `module bad_root version "1.0"
import "child.forseti"
`)
	upon_compiling_workspace_file(&w, "p_bad", "bad/root.forseti", {})
	then_diagnostic_file_contains(&w, "p_bad", .E2002, "child.forseti")
}

@(test)
spec_dsl_v1_1_pure_builtin_scalar_functions :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	policy := `module builtins_v1_1 version "1.1"
schema Lead { id: string, name: string, delta: i64, score: i64 }
schema ScoredLead { id: string, canon_name: string, upper_name: string, name_len: i64, abs_delta: i64, bounded: i64 }

source leads: Lead at .leads[?id]
derived scored: ScoredLead at .scored[?id]

rule normalize_and_score {
  when {
    leads(id: ?id, name: ?nm, delta: ?d, score: ?sc)
    ?low := lower(?nm)
    ?up := upper(?nm)
    ?nlen := len(?nm)
    ?ad := abs(?d)
    ?bounded := min(max(?sc, 0), 100)
    where starts_with(?low, "acme") and contains(?low, "corp") and ?nlen >= 4
  }
  then {
    assert scored(id: ?id, canon_name: ?low, upper_name: ?up, name_len: ?nlen, abs_delta: ?ad, bounded: ?bounded)
  }
}
`
	given_external_policy(&w, "p_ok", policy, "builtins.forseti")
	upon_compiling_policy(&w, "p_ok")
	then_compilation_has_zero_diagnostics(&w, "p_ok")
	upon_compiling_rulebase(&w, "p_ok", "rb")
	given_session(&w, "rb", "s")

	upon_asserting_fact(&w, "s", "leads", "l1", {"l1", "AcMe Corp", i64(-42), i64(150)})
	upon_asserting_fact(&w, "s", "leads", "l2", {"l2", "Beta Inc", i64(10), i64(50)})
	upon_firing_session(&w, "s", "f1")

	then_session_binding_count_is(&w, "s", "scored", 1)
	then_session_has_derived_fact(&w, "s", "scored", {"l1", "acme corp", "ACME CORP", i64(9), i64(42), i64(100)})

	// Type errors on built-in arguments emit E2002.
	bad_policy := `module bad_builtins version "1.1"
schema Lead { id: string, qty: i64 }
source leads: Lead at .leads[?id]
derived out: Lead at .out[?id]
rule bad {
  when {
    leads(id: ?id, qty: ?q)
    where starts_with(?q, "a") and abs(?id) > 0
  }
  then {
    assert out(id: ?id, qty: ?q)
  }
}
`
	given_external_policy(&w, "p_bad", bad_policy, "bad_builtins.forseti")
	upon_compiling_policy(&w, "p_bad")
	then_policy_emits_diagnostic(&w, "p_bad", .E2002, .Error, 8, 11, substr = "starts_with")
	then_policy_emits_diagnostic(&w, "p_bad", .E2002, .Error, 8, 36, substr = "abs")
}

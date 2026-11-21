package forseti_specs

import "core:testing"

@(test)
spec_cli_check_exit_codes_and_warnings_as_errors :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_cli_binary(&w)

	clean_policy := `module clean version "1.0"
schema Org { name: string }
source RawOrg : Org at .orgs[?id]
derived CanonOrg : Org at .canon[?id]
rule copy_org {
  when { RawOrg(name: ?n) }
  then { assert CanonOrg(name: ?n) }
}`

	warn_policy := `module warn_only version "1.0"
schema Org { name: string }
source RawOrg : Org at .orgs[?id]
rule r {
  when { RawOrg(name: ?unused) }
}`

	err_policy := `module bad version "1.0"
schema Org { name: string }
source RawOrg : Org at .orgs[?id]
derived CanonOrg : Org at .canon[?id]
rule r {
  when { RawOrg(name: ?_n) }
  then { assert CanonOrg(name: ?unbound) }
}`

	given_workspace_file(&w, "clean.forseti", clean_policy)
	given_workspace_file(&w, "warn.forseti", warn_policy)
	given_workspace_file(&w, "err.forseti", err_policy)

	upon_running_cli(&w, "clean_check", {"check", "clean.forseti"})
	then_cli_exits_with(&w, "clean_check", 0)

	upon_running_cli(&w, "err_check", {"check", "err.forseti"})
	then_cli_exits_with(&w, "err_check", 1)
	then_cli_output_contains(&w, "err_check", "E2003")

	upon_running_cli(&w, "warn_normal", {"check", "warn.forseti"})
	then_cli_exits_with(&w, "warn_normal", 0)
	then_cli_output_contains(&w, "warn_normal", "W2001")

	upon_running_cli(&w, "warn_strict", {"check", "--warnings-as-errors", "warn.forseti"})
	then_cli_exits_with(&w, "warn_strict", 1)
}

@(test)
spec_cli_check_json_and_telemetry_export :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_cli_binary(&w)

	err_policy := `module json_test version "1.0"
schema Org { name: string }
source RawOrg : Org at .orgs[?id]
derived CanonOrg : Org at .canon[?id]
rule r {
  when { RawOrg(name: ?_n) }
  then { assert CanonOrg(name: ?missing) }
}`

	given_workspace_file(&w, "bad.forseti", err_policy)
	upon_running_cli(&w, "json_run", {"check", "--format=json", "--telemetry", "trace.json", "bad.forseti"})
	then_cli_exits_with(&w, "json_run", 1)
	then_cli_json_reports_diagnostic(&w, "json_run", code = "E2003", line = 7, col = 32)
	then_workspace_telemetry_trace_has_phases(&w, "trace.json", {"lex", "parse", "ir_lower", "analyze"})
}

@(test)
spec_cli_ast_and_ir_commands :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_cli_binary(&w)

	policy := `module inspect_demo version "1.0"
schema Org { name: string }
source RawOrg : Org at .orgs[?id]
derived CanonOrg : Org at .canon[?id]
table gate version "1" hit First {
  inputs { name: string }
  outputs { ok: bool }
  rows { r1: "Acme" || true; }
}
rule r1 {
  when {
    RawOrg(name: ?n)
    ?g := decide gate(name: ?n)
    where ?g.ok == true
  }
  then { assert CanonOrg(name: ?n) }
}
query q1(name: string) { CanonOrg(name: ?name) }`

	given_workspace_file(&w, "demo.forseti", policy)

	upon_running_cli(&w, "ast_run", {"ast", "demo.forseti"})
	then_cli_exits_with(&w, "ast_run", 0)
	then_cli_output_contains(&w, "ast_run", "(module inspect_demo")
	then_cli_output_contains(&w, "ast_run", "(rule r1")

	upon_running_cli(&w, "ir_run", {"ir", "demo.forseti"})
	then_cli_exits_with(&w, "ir_run", 0)
	then_cli_output_contains(&w, "ir_run", "module inspect_demo")
	then_cli_output_contains(&w, "ir_run", "table gate")
	then_cli_output_contains(&w, "ir_run", "query q1")
}

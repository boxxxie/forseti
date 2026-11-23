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

@(test)
spec_cli_verify_tables_and_gen_commands :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_cli_binary(&w)

	clean_tbl := `module tbl_ok version "1.0"
table route version "1.0" hit Unique {
  inputs { score: i64 }
  outputs { tier: string }
  rows {
    r1: >= 90 || "gold";
    r2: < 90  || "std";
  }
}
query q() { ?_r := decide route(score: 95) }`

	overlap_tbl := `module tbl_bad version "1.0"
table route version "1.0" hit Unique {
  inputs { score: i64 }
  outputs { tier: string }
  rows {
    r1: >= 80 || "gold";
    r2: >= 90 || "vip";
  }
}
query q() { ?_r := decide route(score: 95) }`

	given_workspace_file(&w, "ok.forseti", clean_tbl)
	given_workspace_file(&w, "bad.forseti", overlap_tbl)

	upon_running_cli(&w, "vt_ok", {"verify-tables", "ok.forseti"})
	then_cli_exits_with(&w, "vt_ok", 0)

	upon_running_cli(&w, "vt_bad", {"verify-tables", "bad.forseti"})
	then_cli_exits_with(&w, "vt_bad", 1)
	then_cli_output_contains(&w, "vt_bad", "E3001")

	upon_running_cli(&w, "gen_ok", {"gen", "--package", "route_gen", "--out", "route.odin", "ok.forseti"})
	then_cli_exits_with(&w, "gen_ok", 0)
	then_workspace_odin_file_passes_strict_check(&w, "route.odin")
}

@(test)
spec_cli_run_explain_and_impact_human_and_json :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_cli_binary(&w)

	policy := `module mdm_cli version "2.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string, tier: string }
schema AlertOrg { org_id: string }

source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]
derived Alert : AlertOrg at .orgs.alert[?id]

table tier_gate version "1.0" hit First {
  inputs { employees: i64 }
  outputs { tier: string }
  rows {
    r_ent: >= 100 || "enterprise";
    r_smb: -      || "smb";
  }
}

rule canonicalize {
  when {
    ?_r := Raw(org_id: ?oid, employees: ?emp)
    ?g := decide tier_gate(employees: ?emp)
  }
  then { assert Canon(org_id: ?oid, tier: ?g.tier) }
}

rule flag_enterprise {
  when { ?_c := Canon(org_id: ?oid, tier: "enterprise") }
  then { assert Alert(org_id: ?oid) }
}`

	facts_json := `{
  "facts": [
    {"binding": "Raw", "key": "org:1", "fields": {"org_id": "org:1", "employees": 250}},
    {"binding": "Raw", "key": "org:2", "fields": {"org_id": "org:2", "employees": 25}}
  ]
}`

	given_workspace_file(&w, "mdm.forseti", policy)
	given_workspace_file(&w, "facts.json", facts_json)

	upon_running_cli(&w, "run_json", {"run", "--facts", "facts.json", "--store", "mdm.xit", "--format=json", "mdm.forseti"})
	then_cli_exits_with(&w, "run_json", 0)
	then_cli_json_stdout_parses(&w, "run_json", {"fired", "derived_count", "derived", "committed_moment"})
	then_cli_json_int_field_equals(&w, "run_json", "fired", 3)
	then_cli_json_int_field_equals(&w, "run_json", "derived_count", 3)
	then_cli_json_int_field_equals(&w, "run_json", "committed_moment", 1)
	then_cli_output_contains(&w, "run_json", "enterprise")

	upon_running_cli(&w, "explain_store", {"explain", "--store", "mdm.xit", "--binding", "Alert", "mdm.forseti"})
	then_cli_exits_with(&w, "explain_store", 0)
	then_cli_output_contains(&w, "explain_store", "via rule=flag_enterprise")

	extra_facts_json := `[
  {"binding": "Raw", "key": "org:3", "fields": {"org_id": "org:3", "employees": 500}}
]`
	cand_policy := `module mdm_cli version "2.1"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string, tier: string }
schema AlertOrg { org_id: string }

source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]
derived Alert : AlertOrg at .orgs.alert[?id]

table tier_gate version "1.0" hit First {
  inputs { employees: i64 }
  outputs { tier: string }
  rows {
    r_ent: >= 300 || "enterprise";
    r_smb: -      || "smb";
  }
}

rule canonicalize {
  when {
    ?_r := Raw(org_id: ?oid, employees: ?emp)
    ?g := decide tier_gate(employees: ?emp)
  }
  then { assert Canon(org_id: ?oid, tier: ?g.tier) }
}

rule flag_enterprise {
  when { ?_c := Canon(org_id: ?oid, tier: "enterprise") }
  then { assert Alert(org_id: ?oid) }
}`
	given_workspace_file(&w, "extra_facts.json", extra_facts_json)
	given_workspace_file(&w, "cand_mdm.forseti", cand_policy)

	upon_running_cli(&w, "explain_store_facts", {"explain", "--store", "mdm.xit", "--facts", "extra_facts.json", "--binding", "Alert", "mdm.forseti"})
	then_cli_exits_with(&w, "explain_store_facts", 0)
	then_cli_output_contains(&w, "explain_store_facts", "org:3")

	upon_running_cli(&w, "diff_store_ro", {"diff-replay", "--candidate", "cand_mdm.forseti", "--store", "mdm.xit", "--format=json", "mdm.forseti"})
	then_cli_exits_with(&w, "diff_store_ro", 0)
	then_cli_json_stdout_parses(&w, "diff_store_ro", {"parent_moments_before", "parent_moments_after", "removed_count"})
	then_cli_json_int_field_equals(&w, "diff_store_ro", "parent_moments_before", 2)
	then_cli_json_int_field_equals(&w, "diff_store_ro", "parent_moments_after", 2)
	then_cli_json_int_field_equals(&w, "diff_store_ro", "removed_count", 2)

	upon_running_cli(&w, "diff_store_facts_ro", {"diff-replay", "--candidate", "cand_mdm.forseti", "--store", "mdm.xit", "--facts", "extra_facts.json", "--format=json", "mdm.forseti"})
	then_cli_exits_with(&w, "diff_store_facts_ro", 0)
	then_cli_json_int_field_equals(&w, "diff_store_facts_ro", "parent_moments_before", 3)
	then_cli_json_int_field_equals(&w, "diff_store_facts_ro", "parent_moments_after", 3)

	upon_running_cli(&w, "diff_store_verify_ro", {"diff-replay", "--candidate", "cand_mdm.forseti", "--store", "mdm.xit", "--format=json", "mdm.forseti"})
	then_cli_exits_with(&w, "diff_store_verify_ro", 0)
	then_cli_json_int_field_equals(&w, "diff_store_verify_ro", "parent_moments_before", 2)
	then_cli_json_int_field_equals(&w, "diff_store_verify_ro", "parent_moments_after", 2)

	score_policy := `module score_f64 version "1.0"
schema ScoreIn { id: string, weight: f64 }
schema ScoreOut { id: string, weight: f64 }
source ScoreSrc : ScoreIn at .scores.raw[?id]
derived ScorePass : ScoreOut at .scores.out[?id]
rule pass {
  when { ?_s := ScoreSrc(id: ?id, weight: ?w); where ?w >= 50.0 }
  then { assert ScorePass(id: ?id, weight: ?w) }
}`
	score_facts := `[{"binding": "ScoreSrc", "key": "s1", "fields": {"id": "s1", "weight": 100}}]`
	given_workspace_file(&w, "score.forseti", score_policy)
	given_workspace_file(&w, "score_facts.json", score_facts)

	upon_running_cli(&w, "run_f64_store", {"run", "--facts", "score_facts.json", "--store", "score.xit", "--format=json", "score.forseti"})
	then_cli_exits_with(&w, "run_f64_store", 0)
	then_cli_json_int_field_equals(&w, "run_f64_store", "derived_count", 1)

	upon_running_cli(&w, "bad_fmt_run", {"run", "--format=jsonl", "mdm.forseti"})
	then_cli_exits_with(&w, "bad_fmt_run", 2)
	upon_running_cli(&w, "bad_fmt_ast", {"ast", "--format=json", "mdm.forseti"})
	then_cli_exits_with(&w, "bad_fmt_ast", 2)

	upon_running_cli(&w, "explain_human", {"explain", "--facts", "facts.json", "--binding", "Alert", "mdm.forseti"})
	then_cli_exits_with(&w, "explain_human", 0)
	then_cli_output_contains(&w, "explain_human", "via rule=flag_enterprise")
	then_cli_output_contains(&w, "explain_human", "via rule=canonicalize")
	then_cli_output_contains(&w, "explain_human", "table=tier_gate row=r_ent")

	upon_running_cli(&w, "explain_json", {"explain", "--facts", "facts.json", "--binding", "Canon", "--format=json", "mdm.forseti"})
	then_cli_exits_with(&w, "explain_json", 0)
	then_cli_json_stdout_parses(&w, "explain_json", {"explanations"})
	then_cli_output_contains(&w, "explain_json", "canonicalize")

	upon_running_cli(&w, "impact_human", {"impact", "--facts", "facts.json", "--rule", "canonicalize", "mdm.forseti"})
	then_cli_exits_with(&w, "impact_human", 0)
	then_cli_output_contains(&w, "impact_human", "Impact rule=canonicalize")
	then_cli_output_contains(&w, "impact_human", "direct=2")
	then_cli_output_contains(&w, "impact_human", "transitive=3")

	upon_running_cli(&w, "impact_json", {"impact", "--facts", "facts.json", "--rule", "canonicalize", "--format=json", "mdm.forseti"})
	then_cli_exits_with(&w, "impact_json", 0)
	then_cli_json_stdout_parses(&w, "impact_json", {"rule_name", "direct_count", "transitive_count", "derivation_count"})
	then_cli_json_int_field_equals(&w, "impact_json", "direct_count", 2)
	then_cli_json_int_field_equals(&w, "impact_json", "transitive_count", 3)
}

@(test)
spec_cli_diff_replay_telemetry_and_graph_exports :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_cli_binary(&w)

	base_policy := `module diff_demo version "1.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string }
source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]
rule keep_org {
  when { ?_r := Raw(org_id: ?oid, employees: ?emp); where ?emp >= 50 }
  then { assert Canon(org_id: ?oid) }
}`

	cand_policy := `module diff_demo version "2.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string }
source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]
rule keep_org {
  when { ?_r := Raw(org_id: ?oid, employees: ?emp); where ?emp >= 200 }
  then { assert Canon(org_id: ?oid) }
}`

	facts_json := `[
  {"binding": "Raw", "key": "org:1", "fields": {"org_id": "org:1", "employees": 250}},
  {"binding": "Raw", "key": "org:2", "fields": {"org_id": "org:2", "employees": 75}}
]`

	given_workspace_file(&w, "base.forseti", base_policy)
	given_workspace_file(&w, "cand.forseti", cand_policy)
	given_workspace_file(&w, "facts.json", facts_json)

	upon_running_cli(&w, "diff_json", {"diff-replay", "--candidate", "cand.forseti", "--facts", "facts.json", "--format=json", "base.forseti"})
	then_cli_exits_with(&w, "diff_json", 0)
	then_cli_json_stdout_parses(&w, "diff_json", {"added", "removed", "unchanged_count", "parent_moments_before", "parent_moments_after"})
	then_cli_json_int_field_equals(&w, "diff_json", "added_count", 0)
	then_cli_json_int_field_equals(&w, "diff_json", "removed_count", 1)
	then_cli_json_int_field_equals(&w, "diff_json", "unchanged_count", 1)
	then_cli_output_contains(&w, "diff_json", "org:2")

	upon_running_cli(&w, "tel_human", {"telemetry", "--facts", "facts.json", "base.forseti"})
	then_cli_exits_with(&w, "tel_human", 0)
	then_cli_output_contains(&w, "tel_human", "rules_fired")

	upon_running_cli(&w, "tel_jsonl", {"telemetry", "--facts", "facts.json", "--format=jsonl", "--out", "tel.jsonl", "base.forseti"})
	then_cli_exits_with(&w, "tel_jsonl", 0)
	then_workspace_file_contains(&w, "tel.jsonl", {`"type":"span"`, `"type":"summary"`, `"rules_fired":2`})

	upon_running_cli(&w, "dot_rb", {"export-dot", "--graph=rulebase", "base.forseti"})
	then_cli_exits_with(&w, "dot_rb", 0)
	then_cli_output_contains(&w, "dot_rb", "digraph forseti_rulebase")
	then_cli_output_contains(&w, "dot_rb", "keep_org")

	upon_running_cli(&w, "mmd_deriv", {"export-mermaid", "--graph=derivations", "--facts", "facts.json", "--out", "derivs.mmd", "base.forseti"})
	then_cli_exits_with(&w, "mmd_deriv", 0)
	then_workspace_file_contains(&w, "derivs.mmd", {"flowchart TD", "keep_org", "org:1", "org:2"})
}

@(test)
spec_cli_fmt_check_write_and_table_alignment :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	given_cli_binary(&w)

	unformatted := `// Keep comment
module  fmt_cli  version  "1.0"
schema Raw{id:string,emp:i64}
source S : Raw at .raw[?id]
table tier version "1.0" hit First {
inputs { emp : i64 }
outputs { out : string }
rows {
r_large : >= 100 || "ent" ; // top
r_small : - || "smb" ;
}
}
`

	expected := `// Keep comment
module fmt_cli version "1.0"

schema Raw { id: string, emp: i64 }

source S : Raw at .raw[?id]

table tier version "1.0" hit First {
  inputs { emp: i64 }
  outputs { out: string }
  rows {
    r_large: >= 100 || "ent"; // top
    r_small: -      || "smb";
  }
}
`

	given_workspace_file(&w, "messy.forseti", unformatted)

	upon_running_cli(&w, "fmt_stdout", {"fmt", "messy.forseti"})
	then_cli_exits_with(&w, "fmt_stdout", 0)
	then_cli_output_contains(&w, "fmt_stdout", `r_large: >= 100 || "ent"; // top`)

	upon_running_cli(&w, "fmt_check_fail", {"fmt", "--check", "messy.forseti"})
	then_cli_exits_with(&w, "fmt_check_fail", 1)

	upon_running_cli(&w, "fmt_write", {"fmt", "--write", "messy.forseti"})
	then_cli_exits_with(&w, "fmt_write", 0)
	then_workspace_file_equals(&w, "messy.forseti", expected)

	upon_running_cli(&w, "fmt_check_pass", {"fmt", "--check", "messy.forseti"})
	then_cli_exits_with(&w, "fmt_check_pass", 0)

	given_workspace_file(&w, "extra.forseti", expected)
	upon_running_cli(&w, "fmt_bad_flag_after_positional", {"fmt", "messy.forseti", "extra.forseti", "--graph=bogus"})
	then_cli_exits_with(&w, "fmt_bad_flag_after_positional", 2)
}

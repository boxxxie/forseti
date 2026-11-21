package forseti_specs

import "base:runtime"
import "core:strings"
import "core:testing"
import "../forseti"

Diag_Case :: struct {
	name:           string,
	source:         string,
	expected_code:  forseti.Diag_Code,
	expected_sev:   forseti.Diagnostic_Severity,
	expected_line:  u32,
	expected_col:   u32,
	expect_clean:   bool,
	loc:            runtime.Source_Code_Location,
}

diag_case :: proc(
	name: string,
	source: string,
	expected_code: forseti.Diag_Code,
	expected_sev: forseti.Diagnostic_Severity,
	expected_line: u32,
	expected_col: u32,
	loc := #caller_location,
) -> Diag_Case {
	return Diag_Case{
		name          = name,
		source        = source,
		expected_code = expected_code,
		expected_sev  = expected_sev,
		expected_line = expected_line,
		expected_col  = expected_col,
		loc           = loc,
	}
}

diag_clean_case :: proc(
	name: string,
	source: string,
	loc := #caller_location,
) -> Diag_Case {
	return Diag_Case{
		name         = name,
		source       = source,
		expect_clean = true,
		loc          = loc,
	}
}

@(test)
spec_external_dsl_and_internal_odin_dsl_produce_equivalent_ir :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	external_src := `module mdm_parity version "1.0"

schema Organization {
  name: string,
  domain: string,
  employees: i64,
  active: bool
}

source RawOrg : Organization at .orgs.raw[?id]
derived CanonOrg : Organization at .orgs.canon[?id]

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
    r2: - | - || "review";
  }
}

rule apply_survivorship phase "survive" salience 50 {
  when {
    ?raw := RawOrg(domain: ?dom, employees: ?emp, active: ?act)
    ?gate := decide survivorship_gate(employees: ?emp, active: ?act)
    where ?gate.action == "merge" and ?emp >= 100
  }
  then {
    assert CanonOrg(name: ?raw.name, domain: ?dom, employees: ?emp, active: ?act)
  }
}

query orgs_by_domain(dom: string) {
  ?c := CanonOrg(domain: ?dom)
}`

	given_external_policy(&w, "ext", external_src, "mdm_parity.forseti")

	b: forseti.Ir_Builder
	testing.expect_value(t, forseti.ir_builder_init(&b, "mdm_parity", "1.0"), nil)
	defer forseti.ir_builder_destroy(&b)

	forseti.ir_schema(&b, "Organization", {
		forseti.field("name", .String),
		forseti.field("domain", .String),
		forseti.field("employees", .I64),
		forseti.field("active", .Bool),
	})
	forseti.ir_source(&b, "RawOrg", "Organization", ".orgs.raw[?id]")
	forseti.ir_derived(&b, "CanonOrg", "Organization", ".orgs.canon[?id]")
	forseti.ir_table(&b, forseti.Table_Spec{
		name       = "survivorship_gate",
		version    = "1.0",
		hit_policy = .First,
		inputs = {
			{name = "employees", type = .I64, cost = 1},
			{name = "active", type = .Bool, cost = 1},
		},
		outputs = {
			{name = "action", type = .String},
		},
		rows = {
			{id = "r1", cells = {forseti.cond(.Gte, i64(100)), forseti.lit(true)}, outputs = {forseti.lit("merge")}},
			{id = "r2", cells = {forseti.wildcard(), forseti.wildcard()}, outputs = {forseti.lit("review")}},
		},
	})
	forseti.ir_rule(&b, forseti.Rule_Spec{
		name         = "apply_survivorship",
		phase        = "survive",
		salience     = 50,
		has_salience = true,
		when_clauses = {
			forseti.pat("?raw", "RawOrg", {
				forseti.field_bind("domain", forseti.vref("?dom")),
				forseti.field_bind("employees", forseti.vref("?emp")),
				forseti.field_bind("active", forseti.vref("?act")),
			}),
			forseti.decide_clause("?gate", "survivorship_gate", {
				forseti.field_bind("employees", forseti.vref("?emp")),
				forseti.field_bind("active", forseti.vref("?act")),
			}),
			forseti.where_clause(
				forseti.cond(.And,
					forseti.cond(.Eq, forseti.fget("?gate", "action"), forseti.lit("merge")),
					forseti.cond(.Gte, forseti.vref("?emp"), forseti.lit(i64(100))),
				),
			),
		},
		then_actions = {
			forseti.assert_fact("CanonOrg", {
				forseti.field_bind("name", forseti.fget("?raw", "name")),
				forseti.field_bind("domain", forseti.vref("?dom")),
				forseti.field_bind("employees", forseti.vref("?emp")),
				forseti.field_bind("active", forseti.vref("?act")),
			}),
		},
	})
	forseti.ir_query(&b, forseti.Query_Spec{
		name   = "orgs_by_domain",
		params = {{name = "dom", type = .String}},
		when_clauses = {
			forseti.pat("?c", "CanonOrg", {
				forseti.field_bind("domain", forseti.vref("?dom")),
			}),
		},
	})

	given_internal_policy(&w, "int", &b)

	upon_compiling_policy(&w, "ext")
	upon_compiling_policy(&w, "int")

	then_compilation_has_zero_diagnostics(&w, "ext")
	then_compilation_has_zero_diagnostics(&w, "int")
	then_external_and_internal_ir_match(&w, "ext", "int")
}

@(test)
spec_compiler_diagnostics_and_lints_matrix :: proc(t: ^testing.T) {
	cases := []Diag_Case{
		diag_case(
			"E1001 unterminated string",
			"module m\nrule r { when { where \"open } }",
			.E1001, .Error, 2, 23,
		),
		diag_case(
			"E1002 syntax error",
			"module m\nrule r { when { where 1 + * 2 } }",
			.E1002, .Error, 2, 27,
		),
		diag_case(
			"E1005 missing table row id",
			"table t version \"1\" hit First {\n  inputs { x: i64 }\n  outputs { y: bool }\n  rows {\n    >= 1 || true;\n  }\n}\nrule r { when { ?d := decide t(x: 1) } }",
			.E1005, .Error, 5, 5,
		),
		diag_case(
			"E2001 unknown schema in binding",
			"source S : MissingSchema at .s[?id]",
			.E2001, .Error, 1, 1,
		),
		diag_case(
			"E2001 unknown binding in pattern",
			"schema Org { name: string }\nrule r {\n  when {\n    MissingOrg(name: ?_n)\n  }\n}",
			.E2001, .Error, 4, 5,
		),
		diag_case(
			"E2001 unknown field in where",
			"schema Org { name: string }\nsource RawOrg : Org at .orgs[?id]\nderived Out : Org at .out[?id]\nrule r {\n  when {\n    ?o := RawOrg(name: ?n)\n    where ?o.missing_field == \"x\"\n  }\n  then { assert Out(name: ?n) }\n}",
			.E2001, .Error, 7, 11,
		),
		diag_case(
			"E2001 unknown table in decide",
			"schema Org { name: string }\nsource RawOrg : Org at .orgs[?id]\nrule r {\n  when {\n    RawOrg(name: ?_n)\n    ?_d := decide no_such_table(x: 1)\n  }\n}",
			.E2001, .Error, 6, 5,
		),
		diag_case(
			"E2002 type mismatch in where comparison",
			"schema Org { name: string }\nsource RawOrg : Org at .orgs[?id]\nderived Out : Org at .out[?id]\nrule r {\n  when {\n    RawOrg(name: ?n)\n    where ?n == 42\n  }\n  then { assert Out(name: ?n) }\n}",
			.E2002, .Error, 7, 11,
		),
		diag_case(
			"E2002 non-bool where predicate",
			"schema Org { employees: i64 }\nsource RawOrg : Org at .orgs[?id]\nderived Out : Org at .out[?id]\nrule r {\n  when {\n    RawOrg(employees: ?e)\n    where ?e + 1\n  }\n  then { assert Out(employees: ?e) }\n}",
			.E2002, .Error, 7, 11,
		),
		diag_case(
			"E2002 decide argument type mismatch",
			"schema Org { name: string }\nsource RawOrg : Org at .orgs[?id]\ntable gate version \"1\" hit First {\n  inputs { score: i64 }\n  outputs { ok: bool }\n  rows { r1: >= 1 || true; }\n}\nrule r {\n  when {\n    RawOrg(name: ?n)\n    ?_g := decide gate(score: ?n)\n  }\n}",
			.E2002, .Error, 11, 24,
		),
		diag_case(
			"E2002 sum on non-numeric field",
			"schema Org { name: string }\nsource RawOrg : Org at .orgs[?id]\nderived Out : Org at .out[?id]\nrule r {\n  when {\n    ?_total := sum(?n) from RawOrg(name: ?n)\n  }\n}",
			.E2002, .Error, 6, 5,
		),
		diag_case(
			"E2002 table cell type mismatch",
			"table gate version \"1\" hit First {\n  inputs { score: i64 }\n  outputs { ok: bool }\n  rows {\n    r1: \"bad\" || true;\n  }\n}\nrule r { when { ?_g := decide gate(score: 1) } }",
			.E2002, .Error, 5, 9,
		),
		diag_case(
			"E2003 unbound var in assert",
			"schema Org { name: string }\nsource RawOrg : Org at .orgs[?id]\nderived Out : Org at .out[?id]\nrule r {\n  when { RawOrg(name: ?_n) }\n  then {\n    assert Out(name: ?missing)\n  }\n}",
			.E2003, .Error, 7, 22,
		),
		diag_case(
			"E2003 unbound var in where",
			"schema Org { name: string }\nsource RawOrg : Org at .orgs[?id]\nrule r {\n  when {\n    RawOrg(name: ?_n)\n    where ?ghost == \"x\"\n  }\n}",
			.E2003, .Error, 6, 11,
		),
		diag_case(
			"E2003 var bound only inside not leaks to assert",
			"schema Org { name: string }\nsource RawOrg : Org at .orgs[?id]\nderived Out : Org at .out[?id]\nrule r {\n  when {\n    RawOrg(name: ?_a)\n    not RawOrg(name: ?hidden)\n  }\n  then {\n    assert Out(name: ?hidden)\n  }\n}",
			.E2003, .Error, 10, 22,
		),
		diag_case(
			"E2003 unbound var in effect",
			"schema Org { name: string }\nsource RawOrg : Org at .orgs[?id]\nrule r {\n  when { RawOrg(name: ?_a) }\n  effect \"audit\" { who: ?missing }\n}",
			.E2003, .Error, 5, 25,
		),
		diag_case(
			"E2004 duplicate schema",
			"schema Org { name: string }\nschema Org { name: string }",
			.E2004, .Error, 2, 1,
		),
		diag_case(
			"E2004 duplicate table",
			"table t version \"1\" hit First { inputs { x: i64 } outputs { y: bool } rows { r1: 1 || true; } }\ntable t version \"1\" hit First { inputs { x: i64 } outputs { y: bool } rows { r1: 1 || true; } }\nrule r { when { ?_g := decide t(x: 1) } }",
			.E2004, .Error, 2, 1,
		),
		diag_case(
			"E2004 duplicate rule",
			"schema Org { name: string }\nsource RawOrg : Org at .orgs[?id]\nrule r { when { RawOrg(name: ?_n) } }\nrule r { when { RawOrg(name: ?_n) } }",
			.E2004, .Error, 4, 1,
		),
		diag_case(
			"E2004 duplicate table row id",
			"table t version \"1\" hit First {\n  inputs { x: i64 }\n  outputs { y: bool }\n  rows {\n    r1: 1 || true;\n    r1: 2 || false;\n  }\n}\nrule r { when { ?_g := decide t(x: 1) } }",
			.E2004, .Error, 6, 5,
		),
		diag_case(
			"E2005 wrong decide argument name",
			"table t version \"1\" hit First { inputs { x: i64 } outputs { y: bool } rows { r1: 1 || true; } }\nrule r {\n  when {\n    ?_g := decide t(wrong_col: 1)\n  }\n}",
			.E2005, .Error, 4, 21,
		),
		diag_case(
			"E2005 missing required decide input",
			"table t version \"1\" hit First { inputs { x: i64, y: string } outputs { ok: bool } rows { r1: 1 | \"a\" || true; } }\nrule r {\n  when {\n    ?_g := decide t(x: 1)\n  }\n}",
			.E2005, .Error, 4, 5,
		),
		diag_case(
			"E2005 missing required field on assert",
			"schema Org { name: string, domain: string }\nsource RawOrg : Org at .orgs[?id]\nderived Out : Org at .out[?id]\nrule r {\n  when { RawOrg(name: ?n) }\n  then {\n    assert Out(name: ?n)\n  }\n}",
			.E2005, .Error, 7, 5,
		),
		diag_case(
			"W2001 unused variable",
			"schema Org { name: string }\nsource RawOrg : Org at .orgs[?id]\nrule r {\n  when {\n    RawOrg(name: ?unused_name)\n  }\n}",
			.W2001, .Warning, 5, 18,
		),
		diag_clean_case(
			"W2001 suppressed by ?_ prefix",
			"schema Org { name: string }\nsource RawOrg : Org at .orgs[?id]\nrule r {\n  when {\n    RawOrg(name: ?_ignored)\n  }\n}",
		),
		diag_case(
			"W2002 unreferenced table",
			"table unused_tbl version \"1\" hit First { inputs { x: i64 } outputs { y: bool } rows { r1: 1 || true; } }",
			.W2002, .Warning, 1, 1,
		),
		diag_case(
			"W2003 Cartesian join",
			"schema Org { name: string, domain: string }\nsource RawOrg : Org at .orgs[?id]\nderived Out : Org at .out[?id]\nrule r {\n  when {\n    RawOrg(name: ?n)\n    RawOrg(domain: ?d)\n  }\n  then { assert Out(name: ?n, domain: ?d) }\n}",
			.W2003, .Warning, 7, 5,
		),
		diag_clean_case(
			"joined patterns do not emit W2003",
			"schema Org { name: string, domain: string }\nsource RawOrg : Org at .orgs[?id]\nderived Out : Org at .out[?id]\nrule r {\n  when {\n    RawOrg(domain: ?d, name: ?n)\n    RawOrg(domain: ?d)\n  }\n  then { assert Out(name: ?n, domain: ?d) }\n}",
		),
		diag_case(
			"W2004 self-triggering rule",
			"schema Org { name: string }\nsource RawOrg : Org at .orgs[?id]\nrule self_loop {\n  when { RawOrg(name: ?n) }\n  then {\n    assert RawOrg(name: ?n)\n  }\n}",
			.W2004, .Warning, 3, 1,
		),
		diag_clean_case(
			"not-guarded self recursion suppresses W2004",
			"schema Org { name: string }\nsource RawOrg : Org at .orgs[?id]\nsource StopFlag : Org at .stop[?id]\nrule safe_loop {\n  when {\n    RawOrg(name: ?n)\n    not StopFlag(name: \"stop\")\n  }\n  then {\n    assert RawOrg(name: ?n)\n  }\n}",
		),
		diag_case(
			"W2005 shadowed variable in nested not scope",
			"schema Org { name: string }\nsource RawOrg : Org at .orgs[?id]\nderived Out : Org at .out[?id]\nrule r {\n  when {\n    ?o := RawOrg(name: ?_n)\n    not { ?o := RawOrg(name: \"blocked\") }\n  }\n  then { assert Out(name: ?o.name) }\n}",
			.W2005, .Warning, 7, 11,
		),
	}

	for tc in cases {
		w: World
		world_init(&w, t, loc = tc.loc)
		given_external_policy(&w, "p", tc.source, strings.concatenate({tc.name, ".forseti"}, context.temp_allocator), loc = tc.loc)
		upon_compiling_policy(&w, "p", loc = tc.loc)
		if tc.expect_clean {
			then_compilation_has_zero_diagnostics(&w, "p", loc = tc.loc)
		} else {
			then_policy_emits_diagnostic(&w, "p", tc.expected_code, tc.expected_sev, tc.expected_line, tc.expected_col, loc = tc.loc)
		}
		world_destroy(&w)
	}
}

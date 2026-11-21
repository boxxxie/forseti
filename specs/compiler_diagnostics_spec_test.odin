package forseti_specs

import "core:testing"
import "../forseti"

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
    ?raw := RawOrg(name: ?name, domain: ?dom, employees: ?emp, active: ?act)
    ?gate := decide survivorship_gate(employees: ?emp, active: ?act)
    where ?gate.action == "merge" and ?emp >= 100
  }
  then {
    assert CanonOrg(name: ?name, domain: ?dom, employees: ?emp, active: ?act)
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
		name     = "apply_survivorship",
		phase    = "survive",
		salience     = 50,
		has_salience = true,
		when_clauses = {
			forseti.pat("?raw", "RawOrg", {
				forseti.field_bind("name", forseti.vref("?name")),
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
				forseti.field_bind("name", forseti.vref("?name")),
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

package forseti_tests

import "core:encoding/json"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "core:time"
import "../forseti"

@(test)
test_ast_pool_size_and_nested_children_non_interleaving :: proc(t: ^testing.T) {
	#assert(size_of(forseti.Ast_Node) <= 32)
	testing.expect_value(t, forseti.INVALID_NODE, forseti.Node_Id(0))

	pool: forseti.Ast_Pool
	err := forseti.ast_pool_init(&pool)
	testing.expect_value(t, err, nil)
	defer forseti.ast_pool_destroy(&pool)

	interner: forseti.String_Interner
	testing.expect_value(t, forseti.interner_init(&interner), nil)
	defer forseti.interner_destroy(&interner)

	// Build f(a, g(b, c), d) staging children first so nested g(b, c) does not interleave f's args
	id_f, _ := forseti.intern(&interner, "f")
	id_g, _ := forseti.intern(&interner, "g")
	id_a, _ := forseti.intern(&interner, "a")
	id_b, _ := forseti.intern(&interner, "b")
	id_c, _ := forseti.intern(&interner, "c")
	id_d, _ := forseti.intern(&interner, "d")

	na, _ := forseti.ast_add_node(&pool, forseti.Ast_Node{payload = forseti.Ast_Ident{name = id_a}})
	nb, _ := forseti.ast_add_node(&pool, forseti.Ast_Node{payload = forseti.Ast_Ident{name = id_b}})
	nc, _ := forseti.ast_add_node(&pool, forseti.Ast_Node{payload = forseti.Ast_Ident{name = id_c}})
	nd, _ := forseti.ast_add_node(&pool, forseti.Ast_Node{payload = forseti.Ast_Ident{name = id_d}})

	g_args := []forseti.Node_Id{nb, nc}
	g_span, _ := forseti.ast_add_children(&pool, g_args)
	ng, _ := forseti.ast_add_node(&pool, forseti.Ast_Node{payload = forseti.Ast_Call{callee = id_g, args = g_span}})

	f_args := []forseti.Node_Id{na, ng, nd}
	f_span, _ := forseti.ast_add_children(&pool, f_args)
	nf, _ := forseti.ast_add_node(&pool, forseti.Ast_Node{payload = forseti.Ast_Call{callee = id_f, args = f_span}})

	sexp, s_err := forseti.ast_expr_to_sexp(&pool, &interner, nf, context.temp_allocator)
	testing.expect_value(t, s_err, nil)
	testing.expect_value(t, sexp, "(call f a (call g b c) d)")
}

@(test)
test_pratt_precedence_and_associativity :: proc(t: ^testing.T) {
	cases := [][2]string{
		{"1 + 2 * 3", "(+ 1 (* 2 3))"},
		{"10 - 3 - 2", "(- (- 10 3) 2)"},
		{"-5 + 2", "(+ (- 5) 2)"},
		{"?a == 1 and ?b == 2 or ?c == 3", "(or (and (== ?a 1) (== ?b 2)) (== ?c 3))"},
		{"not ?a and ?b", "(and (not ?a) ?b)"},
		{"?org.address.country", "(. (. ?org address) country)"},
	}

	for tc in cases {
		defer free_all(context.temp_allocator)
		src := strings.concatenate({"rule t { when { where ", tc[0], " } }"}, context.temp_allocator)

		diags: forseti.Diagnostic_List
		testing.expect_value(t, forseti.diag_list_init(&diags), nil)
		defer forseti.diag_list_destroy(&diags)

		parsed, p_err := forseti.parse_source_to_ast(src, "prec.forseti", &diags)
		testing.expect_value(t, p_err, nil)
		defer forseti.parsed_ast_destroy(&parsed)

		testing.expectf(t, diags.error_count == 0, "expr %q produced errors", tc[0])
		sexp, s_err := forseti.ast_print_sexp(&parsed.pool, &parsed.interner, context.temp_allocator)
		testing.expect_value(t, s_err, nil)
		expected_rule := strings.concatenate({"(module (rule t (when (where ", tc[1], "))))"}, context.temp_allocator)
		testing.expect_value(t, sexp, expected_rule)
	}
}

@(test)
test_parser_max_depth_and_error_recovery :: proc(t: ^testing.T) {
	// 1. Deep nesting exceeds MAX_PARSE_DEPTH cleanly without stack overflow
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, "rule deep { when { where ")
	for _ in 0 ..< forseti.MAX_PARSE_DEPTH + 10 {
		strings.write_byte(&b, '(')
	}
	strings.write_string(&b, "true")
	for _ in 0 ..< forseti.MAX_PARSE_DEPTH + 10 {
		strings.write_byte(&b, ')')
	}
	strings.write_string(&b, " } }")

	diags_deep: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags_deep), nil)
	defer forseti.diag_list_destroy(&diags_deep)

	parsed_deep, err_deep := forseti.parse_source_to_ast(strings.to_string(b), "deep.forseti", &diags_deep)
	testing.expect_value(t, err_deep, nil)
	defer forseti.parsed_ast_destroy(&parsed_deep)

	has_e1003 := false
	for d in diags_deep.items {
		if d.code == .E1003 {
			has_e1003 = true
		}
	}
	testing.expect(t, has_e1003)

	// 2. Malformed declarations recover to parse subsequent valid rule
	bad_src := `
table broken hit UnknownPolicy {
  inputs { x: i64 }
  outputs { ok: bool }
  rows {
    10 | true;
  }
}
rule broken_expr { when { where 1 + * 2 ) } }
rule valid_after { when { ?x := Org(name: ?n) } then { assert Out(name: ?n) } }`

	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)

	parsed, p_err := forseti.parse_source_to_ast(bad_src, "recover.forseti", &diags)
	testing.expect_value(t, p_err, nil)
	defer forseti.parsed_ast_destroy(&parsed)

	has_e1002 := false
	has_e1004 := false
	has_e1005 := false
	for d in diags.items {
		#partial switch d.code {
		case .E1002:
			has_e1002 = true
		case .E1004:
			has_e1004 = true
		case .E1005:
			has_e1005 = true
		}
	}
	testing.expect(t, has_e1002)
	testing.expect(t, has_e1004)
	testing.expect(t, has_e1005)
	testing.expect_value(t, len(parsed.pool.rules), 2)
}

@(test)
test_parser_full_mdm_module_sexp :: proc(t: ^testing.T) {
	src := `module mdm_core version "2.1"

schema Organization {
  name: string,
  domain: string,
  confidence: f64,
  active: bool,
  tier: enum("enterprise", "smb")
}

source RawOrg : Organization at .orgs.raw[?id]
derived CanonOrg : Organization at .orgs.canon[?id]

table survivorship_gate version "1.0" hit First verify(complete, no_overlap) {
  inputs {
    confidence: f64 cost 5,
    tier: string cost 1
  }
  outputs {
    action: string
  }
  rows {
    r1: >= 0.90 | "enterprise" || "auto_merge";
    r2: 0.50..0.89 | in ("enterprise", "smb") || "steward_review";
    r3: - | - || "reject";
  }
}

rule apply_mdm phase "survive" salience 50 {
  when {
    ?raw := RawOrg(domain: ?dom, confidence: ?conf, tier: ?t)
    [?e, "org/alias", ?dom]
    exists RawOrg(domain: ?dom, active: true)
    not CanonOrg(domain: ?dom)
    ?total := count(?r) from RawOrg(domain: ?dom) where ?r.active == true
    ?res := decide survivorship_gate(confidence: ?conf, tier: ?t)
    where ?res.action != "reject" and ?total > 0
  }
  then {
    assert CanonOrg(name: ?raw.name, domain: ?dom, confidence: ?conf, active: true, tier: ?t)
    assert! CanonOrg(name: "root", domain: "root.org", confidence: 1.0, active: true, tier: "enterprise") unconditional
    retract ?raw
  }
  effect "audit_emit" { entity: ?e, decision: ?res.action }
}

query find_canon(dom: string) {
  ?c := CanonOrg(domain: ?dom)
}`

	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)

	parsed, p_err := forseti.parse_source_to_ast(src, "mdm.forseti", &diags)
	testing.expect_value(t, p_err, nil)
	defer forseti.parsed_ast_destroy(&parsed)

	testing.expect_value(t, diags.error_count, 0)
	testing.expect_value(t, len(parsed.pool.schemas), 1)
	testing.expect_value(t, len(parsed.pool.bindings), 2)
	testing.expect_value(t, len(parsed.pool.tables), 1)
	testing.expect_value(t, len(parsed.pool.rules), 1)
	testing.expect_value(t, len(parsed.pool.queries), 1)

	sexp, s_err := forseti.ast_print_sexp(&parsed.pool, &parsed.interner, context.temp_allocator)
	testing.expect_value(t, s_err, nil)
	testing.expect(t, strings.contains(sexp, "(module mdm_core \"2.1\""))
	testing.expect(t, strings.contains(sexp, "(table survivorship_gate"))
	testing.expect(t, strings.contains(sexp, "(rule apply_mdm"))
	testing.expect(t, strings.contains(sexp, "(query find_canon"))
}

@(test)
prop_parser_fuzz_recovery_terminates_without_leaks :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)
	rng_state := rand.create(t.seed)
	context.random_generator = rand.default_random_generator(&rng_state)

	fragments := []string{
		"module ", "schema ", "source ", "derived ", "table ", "rule ", "query ",
		"when ", "then ", "effect ", "where ", "decide ", "assert ", "assert! ",
		"not ", "exists ", "from ", "count", "sum", "hit ", "First", "rows ",
		"inputs ", "outputs ", "{", "}", "(", ")", "[", "]", "|", "||", "-",
		":=", ":", ";", ",", ".", "..", "..=", "==", "!=", ">=", "<=", "+", "*",
		"?v", "?a", `"x"`, "42", "3.14", "true", " and ", " or ", "\n", " ",
	}

	for iter in 0 ..< 300 {
		defer free_all(context.temp_allocator)

		b: strings.Builder
		strings.builder_init(&b, context.temp_allocator)
		count := 5 + rand.int_max(40)
		for _ in 0 ..< count {
			strings.write_string(&b, fragments[rand.int_max(len(fragments))])
		}
		sample := strings.to_string(b)

		diags: forseti.Diagnostic_List
		d_err := forseti.diag_list_init(&diags)
		if !testing.expectf(t, d_err == nil, "seed=%d iter=%d diag init err=%v", t.seed, iter, d_err) {
			return
		}
		defer forseti.diag_list_destroy(&diags)

		parsed, p_err := forseti.parse_source_to_ast(sample, "fuzz.forseti", &diags)
		if !testing.expectf(t, p_err == nil, "seed=%d iter=%d parse err=%v", t.seed, iter, p_err) {
			return
		}
		forseti.parsed_ast_destroy(&parsed)
	}
}

@(test)
test_diagnostic_human_and_json_format :: proc(t: ^testing.T) {
	src := "module demo\nrule r1 {\n  when { ?x := UnknownSchema(a: 1) }\n}\n"
	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)

	starts, s_err := forseti.compute_line_starts(src)
	testing.expect_value(t, s_err, nil)
	defer delete(starts)

	idx := strings.index(src, "UnknownSchema")
	testing.expect(t, idx > 0)
	add_err := forseti.diag_add(
		&diags,
		starts[:],
		.E2001,
		.Error,
		forseti.Span{offset = u32(idx), len = u32(len("UnknownSchema"))},
		`unknown schema "UnknownSchema"`,
		"declare schema UnknownSchema first",
	)
	testing.expect_value(t, add_err, nil)

	human, h_err := forseti.format_diagnostic_human(diags.items[0], src, "demo.forseti", context.allocator)
	testing.expect_value(t, h_err, nil)
	defer delete(human)
	testing.expect(t, strings.contains(human, "demo.forseti:3:16: error[E2001]:"))
	testing.expect(t, strings.contains(human, "^^^^^^^^^^^^^"))
	testing.expect(t, strings.contains(human, "hint: declare schema UnknownSchema first"))

	json_str, j_err := forseti.format_diagnostics_json(&diags, "demo.forseti", context.allocator)
	testing.expect_value(t, j_err, nil)
	defer delete(json_str)

	val, p_err := json.parse_string(json_str, parse_integers = true)
	testing.expect_value(t, p_err, nil)
	defer json.destroy_value(val)
	obj := val.(json.Object)
	testing.expect_value(t, obj["error_count"].(json.Integer), i64(1))
	arr := obj["diagnostics"].(json.Array)
	testing.expect_value(t, len(arr), 1)
	d0 := arr[0].(json.Object)
	testing.expect_value(t, d0["code"].(json.String), "E2001")
	testing.expect_value(t, d0["line"].(json.Integer), i64(3))
	testing.expect_value(t, d0["col"].(json.Integer), i64(16))
}

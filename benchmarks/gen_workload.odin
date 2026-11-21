package main

import "core:fmt"
import vmem "core:mem/virtual"
import forseti "../forseti"

bench_intern :: #force_inline proc(s: ^forseti.Session, txt: string) -> forseti.String_Id {
	sid, _ := forseti.intern_session_string(&s.rb.interner, &s.interner, txt)
	return sid
}

// Builds a compact, arena-backed Rulebase_IR with `rule_count` selective rules
// sharing a root `Org(kind: "saas")` alpha test and branching into O(1)-hashed `bucket` buckets.
gen_scaled_rule_ir :: proc(
	rule_count: int,
	telemetry: ^forseti.Telemetry_Sink = nil,
) -> forseti.Rulebase_IR {
	ir: forseti.Rulebase_IR
	_ = vmem.arena_init_growing(&ir.arena)
	_ = forseti.interner_init(&ir.interner)
	a := vmem.arena_allocator(&ir.arena)

	ir.module_name, _ = forseti.intern(&ir.interner, "scale_bench")
	ir.module_version, _ = forseti.intern(&ir.interner, "1.0")

	sid_org, _ := forseti.intern(&ir.interner, "Org")
	sid_flag, _ := forseti.intern(&ir.interner, "Flag")
	sid_id, _ := forseti.intern(&ir.interner, "id")
	sid_kind, _ := forseti.intern(&ir.interner, "kind")
	sid_bucket, _ := forseti.intern(&ir.interner, "bucket")
	sid_tag, _ := forseti.intern(&ir.interner, "tag")
	sid_orgs_seg, _ := forseti.intern(&ir.interner, "orgs")
	sid_raw_seg, _ := forseti.intern(&ir.interner, "raw")
	sid_flags_seg, _ := forseti.intern(&ir.interner, "flags")
	sid_key_var, _ := forseti.intern(&ir.interner, "?id")
	sid_bind_o, _ := forseti.intern(&ir.interner, "?_o")
	sid_saas, _ := forseti.intern(&ir.interner, "saas")
	sid_matched, _ := forseti.intern(&ir.interner, "matched")

	ir.schemas = make([]forseti.Schema_Def, 2, a)
	org_fields := make([]forseti.Field_Def, 3, a)
	org_fields[0] = forseti.Field_Def{name = sid_id, type = {kind = .String}}
	org_fields[1] = forseti.Field_Def{name = sid_kind, type = {kind = .String}}
	org_fields[2] = forseti.Field_Def{name = sid_bucket, type = {kind = .I64}}
	ir.schemas[0] = forseti.Schema_Def{name = sid_org, fields = org_fields}

	flag_fields := make([]forseti.Field_Def, 2, a)
	flag_fields[0] = forseti.Field_Def{name = sid_id, type = {kind = .String}}
	flag_fields[1] = forseti.Field_Def{name = sid_tag, type = {kind = .String}}
	ir.schemas[1] = forseti.Schema_Def{name = sid_flag, fields = flag_fields}

	ir.bindings = make([]forseti.Binding_Def, 2, a)
	src_segs := make([]forseti.Selector_Segment, 3, a)
	src_segs[0] = forseti.Selector_Segment{kind = .Field, text = sid_orgs_seg}
	src_segs[1] = forseti.Selector_Segment{kind = .Field, text = sid_raw_seg}
	src_segs[2] = forseti.Selector_Segment{kind = .Var_Key, text = sid_key_var}
	ir.bindings[0] = forseti.Binding_Def{
		kind        = .Source,
		name        = sid_org,
		schema_name = sid_org,
		schema_id   = forseti.Schema_Id(forseti.INVALID_ID),
		segments    = src_segs,
	}

	drv_segs := make([]forseti.Selector_Segment, 3, a)
	drv_segs[0] = forseti.Selector_Segment{kind = .Field, text = sid_orgs_seg}
	drv_segs[1] = forseti.Selector_Segment{kind = .Field, text = sid_flags_seg}
	drv_segs[2] = forseti.Selector_Segment{kind = .Var_Key, text = sid_key_var}
	ir.bindings[1] = forseti.Binding_Def{
		kind        = .Derived,
		name        = sid_flag,
		schema_name = sid_flag,
		schema_id   = forseti.Schema_Id(forseti.INVALID_ID),
		segments    = drv_segs,
	}

	// Expr pool: [0]=Invalid, [1]="saas", [2]=?id, [3]="matched", [4+i]=Lit_Int(i)
	ir.exprs = make([]forseti.Expr_IR, 4 + rule_count, a)
	ir.exprs[0] = forseti.Expr_IR{kind = .Invalid}
	ir.exprs[1] = forseti.Expr_IR{kind = .Lit_String, str_id = sid_saas}
	ir.exprs[2] = forseti.Expr_IR{kind = .Var, str_id = sid_key_var}
	ir.exprs[3] = forseti.Expr_IR{kind = .Lit_String, str_id = sid_matched}
	for i := 0; i < rule_count; i += 1 {
		ir.exprs[4 + i] = forseti.Expr_IR{kind = .Lit_Int, int_val = i64(i)}
	}

	// Shared action template across all generated rules (assert Flag(id: ?id, tag: "matched")).
	shared_then_fbs := make([]forseti.Field_Binding_IR, 2, a)
	shared_then_fbs[0] = forseti.Field_Binding_IR{name = sid_id, expr = forseti.Expr_Id(2)}
	shared_then_fbs[1] = forseti.Field_Binding_IR{name = sid_tag, expr = forseti.Expr_Id(3)}
	shared_actions := make([]forseti.Action_IR, 1, a)
	shared_actions[0] = forseti.Action_IR{
		kind   = .Assert,
		target = sid_flag,
		fields = shared_then_fbs,
	}

	// Bulk-allocate per-rule Clause_IR + Field_Binding_IR slabs cleanly on ir.arena.
	all_when_fbs := make([]forseti.Field_Binding_IR, rule_count * 3, a)
	all_clauses := make([]forseti.Clause_IR, rule_count, a)
	ir.rules = make([]forseti.Rule_Def, rule_count, a)

	name_buf: [32]u8 = ---
	for i := 0; i < rule_count; i += 1 {
		fb_off := i * 3
		all_when_fbs[fb_off + 0] = forseti.Field_Binding_IR{name = sid_kind, expr = forseti.Expr_Id(1)}
		all_when_fbs[fb_off + 1] = forseti.Field_Binding_IR{name = sid_bucket, expr = forseti.Expr_Id(4 + i)}
		all_when_fbs[fb_off + 2] = forseti.Field_Binding_IR{name = sid_id, expr = forseti.Expr_Id(2)}

		all_clauses[i] = forseti.Clause_IR{
			kind     = .Pattern,
			bind_var = sid_bind_o,
			target   = sid_org,
			fields   = all_when_fbs[fb_off:fb_off + 3],
		}

		rname := fmt.bprintf(name_buf[:], "r%d", i)
		rname_id, _ := forseti.intern(&ir.interner, rname)
		ir.rules[i] = forseti.Rule_Def{
			name         = rname_id,
			when_clauses = all_clauses[i:i + 1],
			then_actions = shared_actions,
		}
	}

	_ = forseti.analyze_ir(&ir, nil, telemetry)
	return ir
}

compile_benchmark_source :: proc(
	src: string,
	name: string,
	telemetry: ^forseti.Telemetry_Sink = nil,
) -> (rb: ^forseti.Rulebase, ok: bool) {
	diags: forseti.Diagnostic_List
	_ = forseti.diag_list_init(&diags)
	defer forseti.diag_list_destroy(&diags)

	ir, c_err := forseti.compile_source(src, name, &diags, telemetry)
	if c_err != nil || diags.error_count > 0 {
		forseti.ir_destroy(&ir)
		return nil, false
	}
	defer forseti.ir_destroy(&ir)

	compiled, rb_err := forseti.rulebase_compile(&ir, telemetry)
	if rb_err != .None {
		return nil, false
	}
	rb = new(forseti.Rulebase)
	rb^ = compiled
	return rb, true
}

BENCH_JOIN_POLICY_SRC :: `module bench_joins version "1.0"

schema Org {
  id: string,
  domain: string,
  employees: i64
}

schema Pair {
  id: string,
  domain: string,
  employees: i64
}

source Org : Org at .orgs.raw[?id]
derived Pair : Pair at .orgs.pairs[?id]

rule dedup_domain_pair {
  when {
    ?_a := Org(id: ?ida, domain: ?dom, employees: ?ea)
    ?_b := Org(id: ?_idb, domain: ?dom, employees: ?eb)
    where ?ea > ?eb
  }
  then {
    assert Pair(id: ?ida, domain: ?dom, employees: ?ea)
  }
}

query orgs_in_domain(d: string) {
  ?_o := Org(domain: ?d, id: ?oid, employees: ?emp)
}`

BENCH_JTMS_POLICY_SRC :: `module bench_jtms version "1.0"

schema Root { org_id: string, employees: i64 }
schema Mid { org_id: string, tier: string }
schema Leaf { org_id: string, tier: string }
schema InvItem { org_id: string, amt: i64 }
schema InvSum { org_id: string, total: i64, cnt: i64 }

source Root : Root at .jtms.root[?org_id]
source InvItem : InvItem at .jtms.items[?id]
derived Mid : Mid at .jtms.mid[?org_id]
derived Leaf : Leaf at .jtms.leaf[?org_id]
derived InvSum : InvSum at .jtms.sum[?org_id]

rule root_to_mid {
  when { ?_r := Root(org_id: ?oid, employees: ?emp); where ?emp >= 50 }
  then { assert Mid(org_id: ?oid, tier: "eligible") }
}

rule mid_to_leaf {
  when { ?_m := Mid(org_id: ?oid, tier: ?t) }
  then { assert Leaf(org_id: ?oid, tier: ?t) }
}

rule accum_invoices {
  when {
    ?_r := Root(org_id: ?oid, employees: ?_emp)
    ?s := sum(?a) from InvItem(org_id: ?oid, amt: ?a)
    ?c := count(?a2) from InvItem(org_id: ?oid, amt: ?a2)
  }
  then {
    assert InvSum(org_id: ?oid, total: ?s, cnt: ?c)
  }
}`

BENCH_RECURSIVE_POLICY_SRC :: `module bench_recursive version "1.0"

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
  when {
    ?_r1 := Reach(src: ?x, dst: ?y)
    ?_r2 := Reach(src: ?y, dst: ?z)
  }
  then {
    assert Reach(src: ?x, dst: ?z)
  }
}

rule find_isolated {
  when {
    ?_n := Node(id: ?u)
    not Reach(src: "root", dst: ?u)
  }
  then {
    assert Isolated(id: ?u)
  }
}`

BENCH_MDM_E2E_POLICY_SRC :: `module bench_mdm_e2e version "1.0"

schema RawOrg {
  name: string,
  country: string,
  domain: string,
  employees: i64,
  active: bool
}

schema Suppress {
  domain: string
}

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
  inputs {
    employees: i64 cost 1,
    active: bool cost 1
  }
  outputs {
    action: string
  }
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
  then {
    assert CanonOrg(name: ?nm, domain: ?dom, employees: ?emp, active: true)
  }
}

rule count_domain_canon phase "stats" salience 5 {
  when {
    ?_c := CanonOrg(domain: ?dom, name: ?_nm)
    ?cnt := count(?nm) from CanonOrg(domain: ?dom, name: ?nm)
  }
  then {
    assert DomainStats(domain: ?dom, cnt: ?cnt)
  }
}`

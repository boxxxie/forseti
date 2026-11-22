package forseti

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"

Query_Arg :: struct {
	name:  string,
	value: Value,
}

Query_Row :: struct {
	fact_ids:    []Fact_Id,
	var_names:   []string,
	var_values:  []Value,
	var_strings: []string,
}

Query_Result :: struct {
	arena: vmem.Arena,
	rows:  [dynamic]Query_Row,
}

query_result_destroy :: proc(res: ^Query_Result) {
	if res == nil {
		return
	}
	vmem.arena_check_temp(&res.arena)
	delete(res.rows)
	vmem.arena_destroy(&res.arena)
	res^ = {}
}

@(private)
_value_format_str :: proc(s: ^Session, v: Value, alloc: mem.Allocator) -> string {
	switch x in v {
	case bool:
		return "true" if x else "false"
	case i32:
		return fmt.aprintf("%d", x, allocator = alloc)
	case i64:
		return fmt.aprintf("%d", x, allocator = alloc)
	case f64:
		return fmt.aprintf("%v", x, allocator = alloc)
	case String_Id:
		c, _ := strings.clone(session_string(s, x), alloc)
		return c
	case Entity_Id:
		return fmt.aprintf("%d", u64(x), allocator = alloc)
	case Time_Ns:
		return fmt.aprintf("%d", i64(x), allocator = alloc)
	case Enum_Val:
		return fmt.aprintf("%d:%d", x.enum_id, x.variant, allocator = alloc)
	}
	return ""
}

// Executes a parameterized compiled Query against live facts currently stored in `s`.
session_query :: proc(
	s: ^Session,
	query_name: string,
	args: []Query_Arg,
	out_res: ^Query_Result,
) -> (err: Session_Error) {
	if s == nil || s.rb == nil || out_res == nil {
		return .Invalid_Arg
	}
	out_res^ = {}
	if vmem.arena_init_growing(&out_res.arena) != nil {
		return .Alloc_Failed
	}
	defer if err != .None {
		query_result_destroy(out_res)
	}
	out_res.rows = make([dynamic]Query_Row, 0, 8, s.allocator)

	qc: Query_Compiled
	found_q := false
	for q in s.rb.queries {
		if interner_get(&s.rb.interner, q.name) == query_name {
			qc = q
			found_q = true
			break
		}
	}
	if !found_q {
		return .Unknown_Query
	}

	init_tok := Beta_Token{fact_sig_hash = 0x51525900}
	for pn, pi in qc.param_names {
		pstr := interner_get(&s.rb.interner, pn)
		for a in args {
			if a.name == pstr {
				v := a.value
				if sid, is_s := v.(String_Id); is_s {
					txt := session_string(s, sid)
					if mapped, m_err := intern_session_string(&s.rb.interner, &s.interner, txt); m_err == nil {
						v = mapped
					}
				}
				if pi < MAX_TOKEN_VARS {
					init_tok.vars[pi] = v
				}
				break
			}
		}
	}

	cur := make([dynamic]Beta_Token, 0, 16, context.temp_allocator)
	nxt := make([dynamic]Beta_Token, 0, 16, context.temp_allocator)
	append(&cur, init_tok)

	fact_slots_buf: [MAX_TOKEN_FACTS]Vm_Fact_Binding
	for step in qc.clauses {
		clear(&nxt)
		if step.guard_prog >= 0 {
			for &tok in cur {
				fslots := _fill_vm_fact_slots(s, &tok, fact_slots_buf[:])
				val, verr := vm_eval(&s.rb.programs[step.guard_prog], tok.vars[:], fslots, s.rb.tables, &s.rb.interner, nil, &s.interner)
				if verr == .None && val == Value(true) {
					append(&nxt, tok)
				}
			}
			cur, nxt = nxt, cur
			continue
		}

		// Match against the populated Alpha_Memory (created lazily on first matching fact).
		am, has_am := s.alpha_mems[step.alpha_mem_id]
		if !has_am || len(am.fact_ids) == 0 {
			clear(&cur)
			break
		}
		for &ltok in cur {
			for fid in am.fact_ids {
				f := &s.facts[fid]
				if !f.alive {
					continue
				}
				eq_ok := true
				for jk in step.join_keys {
					lv := ltok.vars[jk.left_var_slot]
					rv, r_ok := fact_get_field(s, f, jk.right_field_idx)
					if !r_ok || !_join_values_equal(s, lv, rv) {
						eq_ok = false
						break
					}
				}
				if !eq_ok {
					continue
				}
				if ext, eok := _token_extend_fact(s, &ltok, f, step.field_binds); eok {
					append(&nxt, ext)
				}
			}
		}
		cur, nxt = nxt, cur
	}

	a := vmem.arena_allocator(&out_res.arena)
	for &tok in cur {
		vn := len(qc.var_names)
		fids := make([]Fact_Id, tok.fact_count, a)
		copy(fids, tok.fact_ids[:tok.fact_count])

		vnames := make([]string, vn, a)
		vvals := make([]Value, vn, a)
		vstrs := make([]string, vn, a)
		for vi := 0; vi < vn; vi += 1 {
			vnames[vi] = interner_get(&s.rb.interner, qc.var_names[vi])
			vvals[vi] = tok.vars[vi]
			vstrs[vi] = _value_format_str(s, tok.vars[vi], a)
		}
		append(&out_res.rows, Query_Row{
			fact_ids    = fids,
			var_names   = vnames,
			var_values  = vvals,
			var_strings = vstrs,
		})
	}
	return .None
}

package forseti

import "core:fmt"
import "core:mem"
import "core:strings"

Effect_Field :: struct {
	name:  string,
	value: Value,
	str:   string,
}

Effect_Job :: struct {
	job_id:               u64,
	kind:                 string,
	rule_name:            string,
	rule_id:              u32,
	parent_derivation_id: Derivation_Id,
	parent_facts:         []Fact_Id,
	fields:               []Effect_Field,
	allocator:            mem.Allocator,
}

Effect_Inflight :: struct {
	rule_id:              u32,
	parent_derivation_id: Derivation_Id,
	parent_facts:         []Fact_Id,
	allocator:            mem.Allocator,
}

Effect_Result_Fact :: struct {
	binding_name:  string,
	key:           string,
	fields:        []Value,
	unconditional: bool,
}

Effect_Result :: struct {
	job_id: u64,
	facts:  []Effect_Result_Fact,
}

effect_job_destroy :: proc(j: ^Effect_Job) {
	if j == nil || j.allocator.procedure == nil {
		return
	}
	a := j.allocator
	if len(j.kind) > 0 {
		delete(j.kind, a)
	}
	if len(j.rule_name) > 0 {
		delete(j.rule_name, a)
	}
	for f in j.fields {
		if len(f.name) > 0 {
			delete(f.name, a)
		}
		if len(f.str) > 0 {
			delete(f.str, a)
		}
	}
	delete(j.fields, a)
	delete(j.parent_facts, a)
	j^ = {}
}

effects_jobs_destroy :: proc(jobs: []Effect_Job) {
	if len(jobs) == 0 {
		return
	}
	alloc := jobs[0].allocator
	for &j in jobs {
		if alloc.procedure == nil && j.allocator.procedure != nil {
			alloc = j.allocator
		}
		effect_job_destroy(&j)
	}
	if alloc.procedure != nil {
		delete(jobs, alloc)
	}
}

@(private)
effects_destroy :: proc(s: ^Session) {
	if s == nil {
		return
	}
	for &j in s.pending_effects {
		effect_job_destroy(&j)
	}
	delete(s.pending_effects)
	for _, inf in s.inflight_effects {
		delete(inf.parent_facts, inf.allocator)
	}
	delete(s.inflight_effects)
}

@(private)
effects_stage_job :: proc(
	s: ^Session,
	rule: Rule_Compiled,
	act: Compiled_Action,
	tok: ^Beta_Token,
	fslots: []Vm_Fact_Binding,
	parent_deriv_id: Derivation_Id,
) -> Session_Error {
	a := s.allocator
	kind_s := interner_get(&s.rb.interner, act.effect_kind)
	rname_s := interner_get(&s.rb.interner, rule.name)

	fields := make([]Effect_Field, len(act.fields), a)
	for fb, fi in act.fields {
		val: Value
		if fb.expr_prog >= 0 {
			v, verr := vm_eval(
				&s.rb.programs[fb.expr_prog],
				tok.vars[:],
				fslots,
				s.rb.tables,
				&s.rb.interner,
				tok.decide_results[:],
				&s.interner,
			)
			if verr != .None {
				for pj := 0; pj < fi; pj += 1 {
					delete(fields[pj].name, a)
					delete(fields[pj].str, a)
				}
				delete(fields, a)
				return .Vm_Eval_Failed
			}
			val = v
		}
		fn_str := interner_get(&s.rb.interner, fb.field_name)
		fstr: string
		#partial switch v in val {
		case bool:
			fstr, _ = strings.clone("true" if v else "false", a)
		case i32:
			fstr = fmt.aprintf("%d", v, allocator = a)
		case i64:
			fstr = fmt.aprintf("%d", v, allocator = a)
		case f64:
			fstr = fmt.aprintf("%v", v, allocator = a)
		case String_Id:
			fstr, _ = strings.clone(session_string(s, v), a)
		case Entity_Id:
			fstr = fmt.aprintf("%d", u64(v), allocator = a)
		case Time_Ns:
			fstr = fmt.aprintf("%d", i64(v), allocator = a)
		case Enum_Val:
			fstr = fmt.aprintf("%d:%d", v.enum_id, v.variant, allocator = a)
		}
		cloned_fn, _ := strings.clone(fn_str, a)
		fields[fi] = Effect_Field{
			name  = cloned_fn,
			value = val,
			str   = fstr,
		}
	}

	p_cnt := int(tok.fact_count)
	pfacts := make([]Fact_Id, p_cnt, a)
	copy(pfacts, tok.fact_ids[:p_cnt])

	jid := s.next_effect_job_id
	s.next_effect_job_id += 1
	cloned_kind, _ := strings.clone(kind_s, a)
	cloned_rname, _ := strings.clone(rname_s, a)

	append(&s.pending_effects, Effect_Job{
		job_id               = jid,
		kind                 = cloned_kind,
		rule_name            = cloned_rname,
		rule_id              = rule.id,
		parent_derivation_id = parent_deriv_id,
		parent_facts         = pfacts,
		fields               = fields,
		allocator            = a,
	})
	return .None
}

// Phase 1 of 3-phase async effects: drains staged Effect_Jobs to execute concurrently off-engine.
session_prepare_effects :: proc(
	s: ^Session,
	allocator := context.allocator,
) -> []Effect_Job {
	if s == nil || len(s.pending_effects) == 0 {
		return nil
	}
	out := make([]Effect_Job, len(s.pending_effects), allocator)
	for &pj, i in s.pending_effects {
		// Copy inflight ancestry into Session before handing off Effect_Job ownership.
		pf_copy := make([]Fact_Id, len(pj.parent_facts), s.allocator)
		copy(pf_copy, pj.parent_facts)
		s.inflight_effects[pj.job_id] = Effect_Inflight{
			rule_id              = pj.rule_id,
			parent_derivation_id = pj.parent_derivation_id,
			parent_facts         = pf_copy,
			allocator            = s.allocator,
		}

		// Clone into caller's requested allocator if different from s.allocator.
		if allocator.procedure == s.allocator.procedure && allocator.data == s.allocator.data {
			out[i] = pj
		} else {
			out_fields := make([]Effect_Field, len(pj.fields), allocator)
			for f, fi in pj.fields {
				out_fields[fi] = Effect_Field{
					name  = strings.clone(f.name, allocator),
					value = f.value,
					str   = strings.clone(f.str, allocator),
				}
			}
			out_pf := make([]Fact_Id, len(pj.parent_facts), allocator)
			copy(out_pf, pj.parent_facts)
			out[i] = Effect_Job{
				job_id               = pj.job_id,
				kind                 = strings.clone(pj.kind, allocator),
				rule_name            = strings.clone(pj.rule_name, allocator),
				rule_id              = pj.rule_id,
				parent_derivation_id = pj.parent_derivation_id,
				parent_facts         = out_pf,
				fields               = out_fields,
				allocator            = allocator,
			}
			effect_job_destroy(&pj)
		}
	}
	clear(&s.pending_effects)
	return out
}

// Phase 3 of 3-phase async effects: applies off-engine Effect_Results back into Session,
// inserting resulting facts and linking provenance back to the originating rule + parent facts.
session_apply_effects :: proc(
	s: ^Session,
	results: []Effect_Result,
	allocator := context.allocator,
) -> (applied_facts: []Fact_Id, err: Session_Error) {
	if s == nil || s.rb == nil {
		return nil, .Invalid_Arg
	}

	seen_jobs: map[u64]bool
	if len(results) > 1 {
		seen_jobs = make(map[u64]bool, len(results), context.temp_allocator)
	}
	total_facts := 0
	for res in results {
		if !(res.job_id in s.inflight_effects) {
			return nil, .Invalid_Arg
		}
		if len(results) > 1 {
			if res.job_id in seen_jobs {
				return nil, .Invalid_Arg
			}
			seen_jobs[res.job_id] = true
		}
		for rf in res.facts {
			bidx, bok := session_find_binding(s, rf.binding_name)
			if !bok {
				return nil, .Unknown_Binding
			}
			schema := s.rb.schemas[s.rb.bindings[bidx].schema_id]
			if r_err := _validate_fact_fields_range(schema, rf.fields); r_err != .None {
				return nil, r_err
			}
			total_facts += 1
		}
	}

	out := make([dynamic]Fact_Id, 0, total_facts, allocator)
	defer if err != .None {
		delete(out)
	}

	for res in results {
		inf, has_inf := s.inflight_effects[res.job_id]
		if !has_inf {
			return nil, .Invalid_Arg
		}
		for rf in res.facts {
			bidx, bok := session_find_binding(s, rf.binding_name)
			if !bok {
				return nil, .Unknown_Binding
			}
			fkey := Firing_Key{
				rule_id  = inf.rule_id,
				tok_hash = u64(0x45464600) ~ res.job_id,
			}
			if !rf.unconditional {
				fid, _, _, _, j_err := jtms_assert_logical(
					s,
					inf.rule_id,
					fkey,
					bidx,
					rf.fields,
					inf.parent_facts,
				)
				if j_err != .None {
					return nil, j_err
				}
				append(&out, fid)
			} else {
				fid := session_insert_fact_by_idx(s, bidx, rf.key, rf.fields, .Unconditional) or_return
				max_h := u32(0)
				for pf in inf.parent_facts {
					if pf != INVALID_FACT && int(pf) < len(s.facts) && s.facts[pf].alive {
						if s.facts[pf].proof_height > max_h {
							max_h = s.facts[pf].proof_height
						}
					}
				}
				s.facts[fid].proof_height = max_h + 1
				did := provenance_record(
					&s.provenance,
					s.telemetry,
					fid,
					inf.rule_id,
					_rule_ver_u16(s, inf.rule_id),
					inf.parent_facts,
					max_h + 1,
					.Unconditional,
				)
				if did != INVALID_DERIVATION {
					s.facts[fid].best_derivation = did
				}
				append(&out, fid)
			}
		}

		delete(inf.parent_facts, inf.allocator)
		delete_key(&s.inflight_effects, res.job_id)
	}

	return out[:], .None
}

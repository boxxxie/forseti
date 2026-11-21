package forseti

Eval_Frame :: struct {
	seg_id:   u32,
	node_idx: u32,
}

// Evaluates all linked dirty segments using an explicit non-recursive Eval_Stack.
phreak_evaluate_linked_rules :: proc(s: ^Session) -> Session_Error {
	if s == nil || len(s.dirty_segs) == 0 {
		return .None
	}
	scope := telemetry_span_begin(s.telemetry, .Match, "phreak_eval")
	defer telemetry_span_end(s.telemetry, scope)

	clear(&s.eval_stack)
	for seg_id in s.dirty_segs {
		sm, ok := s.seg_mems[seg_id]
		if !ok || !sm.dirty || !sm.was_linked {
			continue
		}
		sm.dirty = false
		append(&s.eval_stack, Eval_Frame{
			seg_id   = seg_id,
			node_idx = 0,
		})
	}
	clear(&s.dirty_segs)

	tokens_a := make([dynamic]Beta_Token, 0, 16, context.temp_allocator)
	tokens_b := make([dynamic]Beta_Token, 0, 16, context.temp_allocator)
	fact_slots_buf: [MAX_TOKEN_FACTS]Vm_Fact_Binding

	for len(s.eval_stack) > 0 {
		frame := pop(&s.eval_stack)
		seg := s.rb.segments[frame.seg_id]

		clear(&tokens_a)
		clear(&tokens_b)
		cur := &tokens_a
		nxt := &tokens_b

		for ni := seg.node_start; ni < seg.node_start + seg.node_count; ni += 1 {
			bn := s.rb.beta_nodes[ni]
			clear(nxt)

			#partial switch bn.kind {
			case .Left_Input_Adapter:
				am, am_ok := s.alpha_mems[bn.alpha_mem_id]
				if !am_ok || len(am.fact_ids) == 0 {
					break
				}
				for fid in am.fact_ids {
					f := &s.facts[fid]
					if !f.alive {
						continue
					}
					if tok, ok := _token_extend_fact(s, Beta_Token{fact_sig_hash = 0x544f4b00}, f, bn.field_binds); ok {
						append(nxt, tok)
					}
				}
				telemetry_count_add(s.telemetry, .Beta_Tuples_Staged, u64(len(nxt^)))

			case .Join:
				if len(cur^) == 0 {
					break
				}
				beta_join_expand(s, bn, cur^[:], nxt)
				telemetry_count_add(s.telemetry, .Beta_Tuples_Staged, u64(len(nxt^)))

			case .Decide:
				for &tok in cur^ {
					fslots := _fill_vm_fact_slots(s, &tok, fact_slots_buf[:])
					val, v_err := vm_eval(
						&s.rb.programs[bn.prog_idx],
						tok.vars[:],
						fslots,
						s.rb.tables,
						&s.rb.interner,
						tok.decide_results[:],
						&s.interner,
					)
					if v_err != .None {
						return .Vm_Eval_Failed
					}
					if val == Value(true) {
						append(nxt, tok)
					}
				}

			case .Filter:
				for &tok in cur^ {
					fslots := _fill_vm_fact_slots(s, &tok, fact_slots_buf[:])
					val, v_err := vm_eval(
						&s.rb.programs[bn.prog_idx],
						tok.vars[:],
						fslots,
						s.rb.tables,
						&s.rb.interner,
						tok.decide_results[:],
						&s.interner,
					)
					if v_err != .None {
						return .Vm_Eval_Failed
					}
					if val == Value(true) {
						append(nxt, tok)
					}
				}

			case .Bind:
				for &tok in cur^ {
					fslots := _fill_vm_fact_slots(s, &tok, fact_slots_buf[:])
					val, v_err := vm_eval(
						&s.rb.programs[bn.prog_idx],
						tok.vars[:],
						fslots,
						s.rb.tables,
						&s.rb.interner,
						tok.decide_results[:],
						&s.interner,
					)
					if v_err != .None {
						return .Vm_Eval_Failed
					}
					if int(bn.var_slot) < MAX_TOKEN_VARS {
						tok.vars[bn.var_slot] = val
					}
					append(nxt, tok)
				}

			case .Rule_Terminal:
				for &tok in cur^ {
					agenda_stage_activation(s, bn.rule_id, tok)
				}
				continue
			}

			cur, nxt = nxt, cur
		}
	}
	return .None
}

package forseti

Eval_Frame_Kind :: enum u8 {
	Segment,
	Subnetwork_Not,
	Subnetwork_Exists,
	Subnetwork_Accum,
}

Eval_Frame :: struct {
	kind:        Eval_Frame_Kind,
	seg_id:      u32,
	node_idx:    u32, // Relative to seg.node_start when Segment
	sub_id:      u32,
	beta_node:   Beta_Node_Def,
	var_slot:    u16,
	accum_op:    Accum_Op,
	tokens:      [dynamic]Beta_Token,
	outer_idx:   int,
	sub_step:    int,
	sub_tokens:  [dynamic]Beta_Token,
	pass_tokens: [dynamic]Beta_Token,
}

@(private)
_reconcile_rule_terminal :: proc(s: ^Session, rule_id: u32, tokens: []Beta_Token) {
	live_hashes := make(map[u64]bool, len(tokens) + 1, context.temp_allocator)
	for tok in tokens {
		live_hashes[tok.fact_sig_hash] = true
	}

	// Revoke previously active firings that are no longer satisfied (e.g. blocked by NOT or Accum value changed).
	if flist, has := s.jtms.rule_firings[rule_id]; has {
		to_revoke := make([dynamic]Firing_Key, 0, 4, context.temp_allocator)
		for fk in flist {
			if af, ok := s.jtms.active_firings[fk]; ok && af.alive {
				if !(fk.tok_hash in live_hashes) {
					append(&to_revoke, fk)
				}
			}
		}
		for fk in to_revoke {
			jtms_revoke_firing(s, fk)
		}
	}

	// Cancel any queued (unfired) agenda activations for this rule that fell out of live_hashes.
	for &act in s.agenda.items {
		if act.alive && act.rule_id == rule_id && !(act.token.fact_sig_hash in live_hashes) {
			act.alive = false
			delete_key(&s.agenda.queued, Activation_Key{rule_id = rule_id, tok_hash = act.token.fact_sig_hash})
		}
	}

	for &tok in tokens {
		agenda_stage_activation(s, rule_id, tok)
	}
}

@(private)
_push_segment_frame :: proc(s: ^Session, seg_id: u32) {
	sdef := s.rb.segments[seg_id]
	tokens := make([dynamic]Beta_Token, 0, 16, s.allocator)
	if len(sdef.inputs) == 0 {
		// 0-positive-input rule (e.g. standalone Not or standalone Accum) starts with a unit token.
		append(&tokens, Beta_Token{fact_sig_hash = 0x5a45524f})
	}
	append(&s.eval_stack, Eval_Frame{
		kind     = .Segment,
		seg_id   = seg_id,
		node_idx = 0,
		tokens   = tokens,
	})
}

@(private)
_destroy_eval_frame_bufs :: proc(f: ^Eval_Frame) {
	delete(f.tokens)
	delete(f.sub_tokens)
	delete(f.pass_tokens)
	f^ = {}
}

// Evaluates all dirty linked segments in `target_stratum` using an explicit iterative Eval_Stack
// with pause/resume for Not, Exists, and Accum subnetworks. Other strata stay queued in `dirty_segs`.
phreak_evaluate_stratum :: proc(s: ^Session, target_stratum: u32, evaluate_all_strata := false) -> Session_Error {
	if s == nil {
		return .Invalid_Arg
	}
	if len(s.dirty_segs) == 0 {
		return .None
	}
	scope := telemetry_span_begin(s.telemetry, .Match, "phreak_eval")
	defer telemetry_span_end(s.telemetry, scope)

	for &ef in s.eval_stack {
		_destroy_eval_frame_bufs(&ef)
	}
	clear(&s.eval_stack)

	remaining := make([dynamic]u32, 0, len(s.dirty_segs), context.temp_allocator)
	for seg_id in s.dirty_segs {
		sm, ok := s.seg_mems[seg_id]
		if !ok || !sm.dirty {
			continue
		}
		sdef := s.rb.segments[seg_id]
		st := s.rb.rules[sdef.rule_id].stratum if int(sdef.rule_id) < len(s.rb.rules) else u32(0)
		if !evaluate_all_strata && st != target_stratum {
			append(&remaining, seg_id)
			continue
		}
		sm.dirty = false
		if !sm.was_linked {
			jtms_revoke_all_rule_firings(s, sdef.rule_id)
			continue
		}
		_push_segment_frame(s, seg_id)
	}
	clear(&s.dirty_segs)
	for seg_id in remaining {
		append(&s.dirty_segs, seg_id)
	}

	fact_slots_buf: [MAX_TOKEN_FACTS]Vm_Fact_Binding

	for len(s.eval_stack) > 0 {
		frame_idx := len(s.eval_stack) - 1
		frame := &s.eval_stack[frame_idx]

		switch frame.kind {
		case .Segment:
			seg := s.rb.segments[frame.seg_id]
			paused := false

			for frame.node_idx < seg.node_count {
				bn := s.rb.beta_nodes[seg.node_start + frame.node_idx]

				#partial switch bn.kind {
				case .Left_Input_Adapter:
					clear(&frame.tokens)
					am, am_ok := s.alpha_mems[bn.alpha_mem_id]
					if am_ok && len(am.fact_ids) > 0 {
						for fid in am.fact_ids {
							f := &s.facts[fid]
							if !f.alive {
								continue
							}
							if tok, ok := _token_extend_fact(s, Beta_Token{fact_sig_hash = 0x544f4b00}, f, bn.field_binds); ok {
								append(&frame.tokens, tok)
							}
						}
					}
					telemetry_count_add(s.telemetry, .Beta_Tuples_Staged, u64(len(frame.tokens)))
					frame.node_idx += 1

				case .Join:
					if len(frame.tokens) > 0 {
						nxt := make([dynamic]Beta_Token, 0, len(frame.tokens), context.temp_allocator)
						beta_join_expand(s, bn, frame.tokens[:], &nxt)
						clear(&frame.tokens)
						for tok in nxt {
							append(&frame.tokens, tok)
						}
						telemetry_count_add(s.telemetry, .Beta_Tuples_Staged, u64(len(frame.tokens)))
					}
					frame.node_idx += 1

				case .Decide, .Filter:
					if len(frame.tokens) > 0 {
						kept := 0
						for wi := 0; wi < len(frame.tokens); wi += 1 {
							tok := frame.tokens[wi]
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
								frame.tokens[kept] = tok
								kept += 1
							}
						}
						resize(&frame.tokens, kept)
					}
					frame.node_idx += 1

				case .Bind:
					if len(frame.tokens) > 0 {
						for &tok in frame.tokens {
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
						}
					}
					frame.node_idx += 1

				case .Not, .Exists, .Accum:
					if len(frame.tokens) == 0 {
						frame.node_idx += 1
						continue
					}
					// Pause outer segment at node_idx + 1 and push child subnetwork frame onto Eval_Stack.
					frame.node_idx += 1
					outer_tokens := frame.tokens
					frame.tokens = nil

					child_kind := Eval_Frame_Kind.Subnetwork_Not
					if bn.kind == .Exists {
						child_kind = .Subnetwork_Exists
					} else if bn.kind == .Accum {
						child_kind = .Subnetwork_Accum
					}
					append(&s.eval_stack, Eval_Frame{
						kind        = child_kind,
						seg_id      = frame.seg_id,
						sub_id      = bn.subnetwork_id,
						beta_node   = bn,
						var_slot    = bn.var_slot,
						accum_op    = bn.accum_op,
						tokens      = outer_tokens,
						outer_idx   = 0,
						sub_step    = 0,
						sub_tokens  = make([dynamic]Beta_Token, 0, 8, s.allocator),
						pass_tokens = make([dynamic]Beta_Token, 0, len(outer_tokens), s.allocator),
					})
					paused = true

				case .Rule_Terminal:
					_reconcile_rule_terminal(s, bn.rule_id, frame.tokens[:])
					frame.node_idx = seg.node_count
				}

				if paused {
					break
				}
			}

			if !paused {
				finished := pop(&s.eval_stack)
				_destroy_eval_frame_bufs(&finished)
			}

		case .Subnetwork_Not, .Subnetwork_Exists:
			sub := s.rb.subnetworks[frame.sub_id]
			nm := _neg_get_or_create_mem(s, frame.beta_node.id)

			for frame.outer_idx < len(frame.tokens) {
				if frame.sub_step == 0 {
					clear(&frame.sub_tokens)
					append(&frame.sub_tokens, frame.tokens[frame.outer_idx])
				}

				if frame.sub_step < len(sub.steps) {
					step := sub.steps[frame.sub_step]
					nxt := make([dynamic]Beta_Token, 0, 8, context.temp_allocator)
					_subnetwork_eval_step(s, step, frame.sub_tokens[:], &nxt) or_return
					clear(&frame.sub_tokens)
					for t in nxt {
						append(&frame.sub_tokens, t)
					}
					frame.sub_step += 1
					if len(frame.sub_tokens) > 0 && frame.sub_step < len(sub.steps) {
						continue // Step iteratively through next subnetwork step
					}
				}

				// Finished all steps (or short-circuited empty) for this outer token!
				otok := frame.tokens[frame.outer_idx]
				blockers := i32(len(frame.sub_tokens))
				nm.blocker_counts[otok.fact_sig_hash] = blockers

				if frame.kind == .Subnetwork_Not {
					if blockers == 0 {
						append(&frame.pass_tokens, otok)
					}
				} else {
					if blockers > 0 {
						append(&frame.pass_tokens, otok)
					}
				}

				frame.outer_idx += 1
				frame.sub_step = 0
			}

			done := pop(&s.eval_stack)
			if len(s.eval_stack) > 0 {
				parent := &s.eval_stack[len(s.eval_stack) - 1]
				delete(parent.tokens)
				parent.tokens = done.pass_tokens
				done.pass_tokens = nil
			}
			_destroy_eval_frame_bufs(&done)

		case .Subnetwork_Accum:
			sub := s.rb.subnetworks[frame.sub_id]
			for frame.outer_idx < len(frame.tokens) {
				otok := frame.tokens[frame.outer_idx]
				out_tok, emit := beta_accum_eval_token(s, frame.beta_node, sub, otok) or_return
				if emit {
					append(&frame.pass_tokens, out_tok)
				}
				frame.outer_idx += 1
			}

			done := pop(&s.eval_stack)
			if len(s.eval_stack) > 0 {
				parent := &s.eval_stack[len(s.eval_stack) - 1]
				delete(parent.tokens)
				parent.tokens = done.pass_tokens
				done.pass_tokens = nil
			}
			_destroy_eval_frame_bufs(&done)
		}
	}
	return .None
}

// Evaluates all linked dirty segments regardless of stratum (compatibility helper).
phreak_evaluate_linked_rules :: proc(s: ^Session) -> Session_Error {
	return phreak_evaluate_stratum(s, 0, evaluate_all_strata = true)
}

package forseti

@(private)
_seed_zero_input_segments_for_stratum :: proc(s: ^Session, stratum: u32) {
	if len(s.rb.zero_input_segs) == 0 {
		return
	}
	for seg_id in s.rb.zero_input_segs {
		sdef := s.rb.segments[seg_id]
		if int(sdef.rule_id) < len(s.rb.rules) && s.rb.rules[sdef.rule_id].stratum != stratum {
			continue
		}
		sm := _seg_get_or_create_mem(s, seg_id)
		if !sm.was_linked {
			sm.was_linked = true
			telemetry_count_add(s.telemetry, .Segments_Linked, 1)
			_mark_segment_dirty(s, sm)
		}
	}
}

@(private)
_session_has_dirty_in_stratum :: proc(s: ^Session, stratum: u32) -> bool {
	for seg_id in s.dirty_segs {
		sm, ok := s.seg_mems[seg_id]
		if !ok || !sm.dirty {
			continue
		}
		sdef := s.rb.segments[seg_id]
		if int(sdef.rule_id) < len(s.rb.rules) && s.rb.rules[sdef.rule_id].stratum == stratum {
			return true
		}
	}
	return false
}

// Evaluates and drains one topological stratum until fixed-point (semi-naive delta saturation for recursive strata).
@(private)
session_fire_stratum :: proc(
	s: ^Session,
	stratum: u32,
	total_fired: ^u64,
) -> Session_Error {
	_seed_zero_input_segments_for_stratum(s, stratum)
	wave_safe := int(stratum) < len(s.rb.stratum_wave_safe) && s.rb.stratum_wave_safe[stratum]

	if wave_safe {
		for {
			s.stratum_changed = false
			phreak_evaluate_stratum(s, stratum) or_return

			fired_any := false
			for {
				act, ok := _agenda_pop_for_stratum(s, stratum)
				if !ok {
					break
				}
				if total_fired^ >= s.max_activations {
					return .Max_Activations_Exceeded
				}
				ak := Activation_Key{rule_id = act.rule_id, tok_hash = act.token.fact_sig_hash}

				all_alive := true
				for i := 0; i < int(act.token.fact_count); i += 1 {
					if !s.facts[act.token.fact_ids[i]].alive {
						all_alive = false
						break
					}
				}
				if !all_alive {
					continue
				}

				fired_any = true
				s.agenda.refracted[ak] = true
				rule := s.rb.rules[act.rule_id]
				total_fired^ += 1
				append(&s.fired_trace, rule.name)
				telemetry_count_add(s.telemetry, .Rules_Fired, 1)

				_execute_rule_actions(s, rule, &act.token) or_return
			}

			if _session_has_dirty_in_stratum(s, stratum) {
				continue
			}
			if !fired_any {
				break
			}
			break
		}
		return .None
	}

	for {
		s.stratum_changed = false
		phreak_evaluate_stratum(s, stratum) or_return

		act, ok := _agenda_pop_for_stratum(s, stratum)
		if !ok {
			if _session_has_dirty_in_stratum(s, stratum) {
				continue
			}
			break
		}
		if total_fired^ >= s.max_activations {
			return .Max_Activations_Exceeded
		}
		ak := Activation_Key{rule_id = act.rule_id, tok_hash = act.token.fact_sig_hash}

		// Verify all participating facts are still alive right before firing.
		all_alive := true
		for i := 0; i < int(act.token.fact_count); i += 1 {
			if !s.facts[act.token.fact_ids[i]].alive {
				all_alive = false
				break
			}
		}
		if !all_alive {
			continue
		}

		s.agenda.refracted[ak] = true
		rule := s.rb.rules[act.rule_id]
		total_fired^ += 1
		append(&s.fired_trace, rule.name)
		telemetry_count_add(s.telemetry, .Rules_Fired, 1)

		_execute_rule_actions(s, rule, &act.token) or_return
	}
	return .None
}

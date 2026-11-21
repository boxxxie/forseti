package forseti_tests

import "core:encoding/json"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "core:time"
import "../forseti"

@(test)
test_string_interner_dedup_and_empty_sentinel :: proc(t: ^testing.T) {
	interner: forseti.String_Interner
	err := forseti.interner_init(&interner)
	testing.expect_value(t, err, nil)
	defer forseti.interner_destroy(&interner)

	testing.expect_value(t, forseti.EMPTY_STRING, forseti.String_Id(0))
	testing.expect_value(t, forseti.interner_get(&interner, forseti.EMPTY_STRING), "")

	empty_id, empty_err := forseti.intern(&interner, "")
	testing.expect_value(t, empty_err, nil)
	testing.expect_value(t, empty_id, forseti.EMPTY_STRING)

	id_a1, err_a1 := forseti.intern(&interner, "Organization")
	testing.expect_value(t, err_a1, nil)
	id_a2, err_a2 := forseti.intern(&interner, "Organization")
	testing.expect_value(t, err_a2, nil)
	testing.expect_value(t, id_a1, id_a2)
	testing.expect(t, id_a1 != forseti.EMPTY_STRING)

	// Non-aliasing copy test: mutate caller slice after interning
	buf := strings.clone("Établissement-東京", context.temp_allocator)
	id_utf8, err_u := forseti.intern(&interner, buf)
	testing.expect_value(t, err_u, nil)
	raw := transmute([]byte)buf
	raw[0] = 'X'

	testing.expect_value(t, forseti.interner_get(&interner, id_a1), "Organization")
	testing.expect_value(t, forseti.interner_get(&interner, id_utf8), "Établissement-東京")
	testing.expect(t, id_utf8 != id_a1)
	testing.expect_value(t, forseti.interner_len(&interner), 3)
}

@(test)
test_resolve_line_col_utf8_boundaries :: proc(t: ^testing.T) {
	src := "module mdm\n// café 😀\r\nrule ok {}"
	starts, err := forseti.compute_line_starts(src)
	testing.expect_value(t, err, nil)
	defer delete(starts)

	l1, c1 := forseti.resolve_line_col(starts[:], 0)
	testing.expect_value(t, l1, u32(1))
	testing.expect_value(t, c1, u32(1))

	// First byte of line 2 after '\n' at index 10
	l2, c2 := forseti.resolve_line_col(starts[:], 11)
	testing.expect_value(t, l2, u32(2))
	testing.expect_value(t, c2, u32(1))

	// Inside line 2 past multi-byte UTF-8 runes ('café 😀' has 2-byte é and 4-byte 😀)
	rule_idx := strings.index(src, "rule")
	testing.expect(t, rule_idx > 0)
	l3, c3 := forseti.resolve_line_col(starts[:], u32(rule_idx))
	testing.expect_value(t, l3, u32(3))
	testing.expect_value(t, c3, u32(1))

	// End of line 3
	l_eof, c_eof := forseti.resolve_line_col(starts[:], u32(len(src)))
	testing.expect_value(t, l_eof, u32(3))
	testing.expect_value(t, c_eof, u32(len("rule ok {}") + 1))

	// Empty line starts slice fallback
	l_empty, c_empty := forseti.resolve_line_col(nil, 4)
	testing.expect_value(t, l_empty, u32(1))
	testing.expect_value(t, c_empty, u32(5))
}

@(test)
test_telemetry_sink_spans_counters_and_exports :: proc(t: ^testing.T) {
	sink: forseti.Telemetry_Sink
	err := forseti.telemetry_init(&sink, enabled = true)
	testing.expect_value(t, err, nil)
	defer forseti.telemetry_destroy(&sink)

	s_lex := forseti.telemetry_span_begin(&sink, .Lex, "lexer")
	forseti.telemetry_count_add(&sink, .Tokens_Lexed, 42)
	s_nested := forseti.telemetry_span_begin(&sink, .Parse, "sub\"quoted\"")
	forseti.telemetry_span_end(&sink, s_nested, 128)
	forseti.telemetry_span_end(&sink, s_lex, 512)

	forseti.telemetry_watermark_heap(&sink, 1024)
	forseti.telemetry_watermark_heap(&sink, 512)
	forseti.telemetry_watermark_arena(&sink, 4096)

	testing.expect_value(t, sink.counters[.Tokens_Lexed], u64(42))
	testing.expect_value(t, sink.watermarks.peak_heap_bytes, u64(1024))
	testing.expect_value(t, sink.watermarks.peak_arena_bytes, u64(4096))
	testing.expect_value(t, len(sink.events), 2)
	testing.expect_value(t, sink.events[0].parent_idx, i32(-1))
	testing.expect_value(t, sink.events[0].depth, u16(0))
	testing.expect_value(t, sink.events[1].parent_idx, i32(0))
	testing.expect_value(t, sink.events[1].depth, u16(1))

	jsonl, j_err := forseti.telemetry_export_jsonl(&sink)
	testing.expect_value(t, j_err, nil)
	defer delete(jsonl)

	lines := strings.split_lines(strings.trim_space(jsonl), context.temp_allocator)
	testing.expect_value(t, len(lines), 3) // 2 span events + 1 summary line
	for line, idx in lines {
		parsed, p_err := json.parse_string(line, parse_integers = true)
		testing.expectf(t, p_err == nil, "line %d err=%v raw=%q", idx, p_err, line)
		json.destroy_value(parsed)
	}

	chrome, c_err := forseti.telemetry_export_chrome_trace(&sink)
	testing.expect_value(t, c_err, nil)
	defer delete(chrome)

	trace_val, t_err := json.parse_string(chrome, parse_integers = true)
	testing.expectf(t, t_err == nil, "chrome err=%v raw=%q", t_err, chrome)
	defer json.destroy_value(trace_val)

	root_obj, is_obj := trace_val.(json.Object)
	testing.expect(t, is_obj)
	events_val, has_events := root_obj["traceEvents"]
	testing.expect(t, has_events)
	events_arr, is_arr := events_val.(json.Array)
	testing.expect(t, is_arr)
	testing.expect_value(t, len(events_arr), 2)

	// Disabled runtime sink records zero events
	disabled: forseti.Telemetry_Sink
	d_err := forseti.telemetry_init(&disabled, enabled = false)
	testing.expect_value(t, d_err, nil)
	defer forseti.telemetry_destroy(&disabled)

	sd := forseti.telemetry_span_begin(&disabled, .Analyze, "noop")
	forseti.telemetry_count_add(&disabled, .Ir_Rules, 9)
	forseti.telemetry_span_end(&disabled, sd)
	testing.expect_value(t, len(disabled.events), 0)
	testing.expect_value(t, disabled.counters[.Ir_Rules], u64(0))
}

@(test)
test_lexer_tokens_keywords_tables_and_escapes :: proc(t: ^testing.T) {
	src := `module mdm version "1.0"
// line comment
schema Org { name: string, active: bool, score: f64, tier: enum("A", "B") }
source RawOrg at .orgs[?id]
derived CanonOrg at .canon[?id]
table gate version "1" hit Unique verify(complete) {
  inputs { tier: string cost 10 }
  outputs { keep: bool }
  rows {
    r1: "A\"B\n" || true;
    r2: - || false;
  }
}
rule r1 phase "match" salience 10 {
  when {
    ?o := RawOrg(name: ?n)
    ?cnt := count(?o) from RawOrg(active: true)
    exists RawOrg(tier: "A")
    not CanonOrg(name: ?n)
    ?d := decide gate(tier: ?n)
    where ?d.keep == true and 1..=5 != 0 or !false
  }
  then {
    /* block comment */
    assert CanonOrg(name: ?n)
    assert! CanonOrg(name: "x") unconditional
    retract ?o
  }
  effect "audit" { msg: "ok" }
}
query q1(d: string) { RawOrg(name: ?d) }`

	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)

	tokens, lex_err := forseti.lex_all(src, context.allocator, &diags)
	testing.expect_value(t, lex_err, nil)
	defer delete(tokens)

	testing.expect_value(t, diags.error_count, 0)
	testing.expect(t, len(tokens) > 20)
	testing.expect_value(t, tokens[0].kind, forseti.Token_Kind.Kw_Module)
	testing.expect_value(t, tokens[len(tokens) - 1].kind, forseti.Token_Kind.EOF)

	// Verify key token kinds appear in exact expected order for critical constructs
	seen_table := false
	seen_double_pipe := false
	seen_assert := false
	seen_assert_bang := false
	seen_dot_dot_eq := false
	seen_var_o := false
	for tok in tokens {
		lexeme := src[tok.span.offset:tok.span.offset + tok.span.len]
		#partial switch tok.kind {
		case .Kw_Table:
			seen_table = true
		case .Double_Pipe:
			seen_double_pipe = true
		case .Kw_Assert:
			seen_assert = true
		case .Kw_Assert_Bang:
			seen_assert_bang = true
			testing.expect_value(t, lexeme, "assert!")
		case .Dot_Dot_Eq:
			seen_dot_dot_eq = true
		case .Var:
			if lexeme == "?o" {
				seen_var_o = true
			}
		}
	}
	testing.expect(t, seen_table)
	testing.expect(t, seen_double_pipe)
	testing.expect(t, seen_assert)
	testing.expect(t, seen_assert_bang)
	testing.expect(t, seen_dot_dot_eq)
	testing.expect(t, seen_var_o)
}

@(test)
prop_lexer_malformed_utf8_progress_and_termination :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)
	rng_state := rand.create(t.seed)
	context.random_generator = rand.default_random_generator(&rng_state)

	buf: [192]byte
	for iter in 0 ..< 500 {
		defer free_all(context.temp_allocator)

		n := rand.int_max(len(buf) + 1)
		for i in 0 ..< n {
			// Bias slightly toward tricky ASCII + high bytes (invalid UTF-8)
			switch rand.int_max(5) {
			case 0:
				buf[i] = byte(0x80 + rand.int_max(0x80))
			case 1:
				choices := "\"/?!|.=<>+-*\\n\t"
				buf[i] = choices[rand.int_max(len(choices))]
			case:
				buf[i] = byte(rand.uint32() & 0xFF)
			}
		}
		sample := string(buf[:n])

		diags: forseti.Diagnostic_List
		d_err := forseti.diag_list_init(&diags)
		if !testing.expectf(t, d_err == nil, "seed=%d iter=%d diag_list_init err=%v", t.seed, iter, d_err) {
			return
		}
		defer forseti.diag_list_destroy(&diags)

		tokens, lex_err := forseti.lex_all(sample, context.temp_allocator, &diags)
		if !testing.expectf(t, lex_err == nil, "seed=%d iter=%d lex_all err=%v", t.seed, iter, lex_err) {
			return
		}
		if !testing.expectf(t, len(tokens) >= 1, "seed=%d iter=%d expected at least EOF token", t.seed, iter) {
			return
		}
		last := tokens[len(tokens) - 1]
		if !testing.expectf(t, last.kind == .EOF && last.span.offset == u32(n), "seed=%d iter=%d missing sticky EOF at end", t.seed, iter) {
			return
		}

		prev_end: u32 = 0
		for tok, idx in tokens[:len(tokens) - 1] {
			end := tok.span.offset + tok.span.len
			if !testing.expectf(t, tok.span.offset >= prev_end && end <= u32(n), "seed=%d iter=%d tok=%d non-monotonic span", t.seed, iter, idx) {
				return
			}
			prev_end = end
		}
	}
}

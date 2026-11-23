package forseti_tests

import "core:math/rand"
import "core:strings"
import "core:testing"
import "core:time"
import "core:unicode/utf8"
import "../lsp"

@(test)
prop_lsp_utf16_offset_roundtrip_and_surrogates :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	rng := rand.create(t.seed)
	gen := rand.default_random_generator(&rng)

	// Mix 1-byte ASCII, 2-byte UTF-8 (é), 3-byte UTF-8 (€), and 4-byte UTF-8 / UTF-16 surrogate pair (😀)
	pieces := [6]string{"a", "?", "é", "€", "😀", "\n"}

	for _ in 0 ..< 50 {
		b: strings.Builder
		strings.builder_init(&b)
		defer strings.builder_destroy(&b)

		n_pieces := 8 + rand.int_max(32, gen)
		for _ in 0 ..< n_pieces {
			strings.write_string(&b, pieces[rand.int_max(len(pieces), gen)])
		}
		src := strings.to_string(b)

		line_starts, ls_err := lsp.compute_line_starts(src)
		testing.expect_value(t, ls_err, nil)
		defer delete(line_starts)

		// Verify every rune boundary round-trips cleanly between byte offset and UTF-16 Lsp_Pos
		off := 0
		for off <= len(src) {
			pos := lsp.byte_offset_to_lsp_pos(src, line_starts[:], u32(off))
			back := lsp.lsp_pos_to_byte_offset(src, line_starts[:], pos)
			testing.expect_value(t, back, u32(off))
			if off == len(src) {
				break
			}
			_, w := utf8.decode_rune_in_string(src[off:])
			off += max(w, 1)
		}

		// Verify incremental range edit replaces the exact byte slice between two rune boundaries
		if len(src) > 0 {
			off1 := rand.int_max(len(src) + 1, gen)
			off2 := rand.int_max(len(src) + 1, gen)
			if off1 > off2 {
				off1, off2 = off2, off1
			}
			// Align off1, off2 to UTF-8 rune boundaries
			for off1 > 0 && (src[off1] & 0xC0) == 0x80 {
				off1 -= 1
			}
			for off2 < len(src) && (src[off2] & 0xC0) == 0x80 {
				off2 += 1
			}
			p1 := lsp.byte_offset_to_lsp_pos(src, line_starts[:], u32(off1))
			p2 := lsp.byte_offset_to_lsp_pos(src, line_starts[:], u32(off2))
			rep := "😀x"
			edited, ed_err := lsp.apply_lsp_edit(src, lsp.Lsp_Range{start = p1, end = p2}, rep)
			testing.expect_value(t, ed_err, nil)
			defer delete(edited)

			expected := strings.concatenate({src[:off1], rep, src[off2:]}, context.temp_allocator)
			testing.expect_value(t, edited, expected)
		}
	}
}

@(test)
test_lsp_framing_and_incomplete_buffer_resilience :: proc(t: ^testing.T) {
	payload := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`
	framed, err := lsp.format_lsp_frame(payload)
	testing.expect_value(t, err, nil)
	defer delete(framed)

	got, rest, ok := lsp.parse_lsp_frame(framed)
	testing.expect(t, ok)
	testing.expect_value(t, got, payload)
	testing.expect_value(t, len(rest), 0)

	srv: lsp.Lsp_Server
	lsp.server_init(&srv)
	defer lsp.server_destroy(&srv)

	// Incomplete buffer during typing must emit diagnostics without crashing or leaking
	bad_buf := "module typing version \"1.0\"\n// café 😀\nrule r { when { Raw("
	diags, d_err := lsp.server_update_document(&srv, "file:///typing.forseti", bad_buf, 1)
	testing.expect_value(t, d_err, nil)
	defer delete(diags)
	testing.expect(t, len(diags) > 0)
}

@(test)
test_lsp_malformed_json_and_shutdown_exit :: proc(t: ^testing.T) {
	srv: lsp.Lsp_Server
	lsp.server_init(&srv)
	defer lsp.server_destroy(&srv)

	uri := "file:///malformed.forseti"
	open_msg := `{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///malformed.forseti","version":1,"text":"module m version \"1.0\"\nschema S { a: string }\nsource Src : S at .s[?id]\nrule r { when { Src(a: ?x) } then { retract Src(a: ?x) } }"}}}`
	out1, has1, ex1 := lsp.server_handle_json_message(&srv, open_msg)
	testing.expect(t, has1)
	testing.expect(t, !ex1)
	delete(out1)

	// Malformed didChange ranges (missing start, negative integer, string character) must not panic
	bad_change := `{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///malformed.forseti","version":2},"contentChanges":[{"range":{"start":"bad","end":{"line":0,"character":1}},"text":"x"},{"range":{"start":{"line":-1,"character":"nope"},"end":{"line":0,"character":0}},"text":"y"}]}}`
	out2, has2, ex2 := lsp.server_handle_json_message(&srv, bad_change)
	testing.expect(t, has2)
	testing.expect(t, !ex2)
	delete(out2)

	// Malformed codeAction diagnostic ranges must return [] safely without panicking
	bad_action := `{"jsonrpc":"2.0","id":7,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///malformed.forseti"},"context":{"diagnostics":[{"code":"W2001","range":{"start":{"line":"bad"},"end":{"line":-1,"character":0}}}]}}}`
	out3, has3, ex3 := lsp.server_handle_json_message(&srv, bad_action)
	testing.expect(t, has3)
	testing.expect(t, !ex3)
	defer delete(out3)
	testing.expect(t, strings.contains(out3, `"result":[]`))

	// exit without prior shutdown must set exit_code = 1
	_, _, ex_early := lsp.server_handle_json_message(&srv, `{"jsonrpc":"2.0","method":"exit"}`)
	testing.expect(t, ex_early)
	testing.expect_value(t, srv.exit_code, 1)

	// shutdown followed by exit must set exit_code = 0
	sd_out, has_sd, ex_sd := lsp.server_handle_json_message(&srv, `{"jsonrpc":"2.0","id":9,"method":"shutdown"}`)
	testing.expect(t, has_sd)
	testing.expect(t, !ex_sd)
	delete(sd_out)
	_, _, ex_ok := lsp.server_handle_json_message(&srv, `{"jsonrpc":"2.0","method":"exit"}`)
	testing.expect(t, ex_ok)
	testing.expect_value(t, srv.exit_code, 0)
	_ = uri
}

@(test)
test_lsp_context_aware_completion :: proc(t: ^testing.T) {
	srv: lsp.Lsp_Server
	lsp.server_init(&srv)
	defer lsp.server_destroy(&srv)

	policy := "module comp_demo version \"1.0\"\n" +
		"schema RawOrg { org_id: string, employees: i64 }\n" +
		"schema CanonOrg { org_id: string, tier: string, band: i32 }\n" +
		"source Raw : RawOrg at .orgs.raw[?id]\n" +
		"derived Canon : CanonOrg at .orgs.canon[?id]\n" +
		"table tier_gate version \"1.0\" hit First {\n" +
		"  inputs { employees: i64 }\n" +
		"  outputs { tier: string, band: i32 }\n" +
		"  rows { r1: >= 100 || \"ent\" | 1; }\n" +
		"}\n" +
		"rule classify {\n" +
		"  when {\n" +
		"    ?r := Raw(org_id: ?oid, employees: ?emp)\n" +
		"    ?g := decide tier_gate(employees: ?emp)\n" +
		"  }\n" +
		"  then { assert Canon(org_id: ?r.org_id, tier: ?g.tier, band: ?g.band) }\n" +
		"}\n"

	diags, d_err := lsp.server_update_document(&srv, "file:///comp.forseti", policy, 1)
	testing.expect_value(t, d_err, nil)
	delete(diags)

	// Line 15: "  then { assert Canon(org_id: ?r.org_id, tier: ?g.tier, band: ?g.band) }"
	// Dot completion right after "?g." (line 15, char 50) returns table outputs `tier` and `band`
	comp_g, has_cg, _ := lsp.server_handle_json_message(&srv, `{"jsonrpc":"2.0","id":1,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///comp.forseti"},"position":{"line":15,"character":50}}}`)
	testing.expect(t, has_cg)
	defer delete(comp_g)
	testing.expect(t, strings.contains(comp_g, `"label":"tier"`))
	testing.expect(t, strings.contains(comp_g, `"label":"band"`))
	testing.expect(t, !strings.contains(comp_g, `"label":"module"`))

	// Dot completion right after "?r." (line 15, char 33) returns schema fields `org_id` and `employees`
	comp_r, has_cr, _ := lsp.server_handle_json_message(&srv, `{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///comp.forseti"},"position":{"line":15,"character":33}}}`)
	testing.expect(t, has_cr)
	defer delete(comp_r)
	testing.expect(t, strings.contains(comp_r, `"label":"org_id"`))
	testing.expect(t, strings.contains(comp_r, `"label":"employees"`))

	// Completion inside Raw( (line 12, char 14) includes schema fields of RawOrg
	comp_raw, has_raw, _ := lsp.server_handle_json_message(&srv, `{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///comp.forseti"},"position":{"line":12,"character":14}}}`)
	testing.expect(t, has_raw)
	defer delete(comp_raw)
	testing.expect(t, strings.contains(comp_raw, `"detail":"schema field"`))
	testing.expect(t, strings.contains(comp_raw, `"label":"org_id"`))

	// Completion preserves cached metadata across transient syntax errors while typing `?g.`
	broken := strings.concatenate({policy, "rule wip { then { assert Canon(org_id: ?r.org_id, tier: ?g."}, context.temp_allocator)
	b_diags, b_err := lsp.server_update_document(&srv, "file:///comp.forseti", broken, 2)
	testing.expect_value(t, b_err, nil)
	delete(b_diags)
	comp_wip, has_wip, _ := lsp.server_handle_json_message(&srv, `{"jsonrpc":"2.0","id":4,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///comp.forseti"},"position":{"line":17,"character":59}}}`)
	testing.expect(t, has_wip)
	defer delete(comp_wip)
	testing.expect(t, strings.contains(comp_wip, `"label":"tier"`))
	testing.expect(t, strings.contains(comp_wip, `"label":"band"`))
}

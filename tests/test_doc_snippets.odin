package forseti_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../forseti"

@(private = "file")
_verify_doc_forseti_snippets :: proc(t: ^testing.T, doc_path: string) -> int {
	raw, r_err := os.read_entire_file(doc_path, context.allocator)
	testing.expectf(t, r_err == nil, "unable to read %q: %v", doc_path, r_err)
	if r_err != nil {
		return 0
	}
	defer delete(raw)

	src := string(raw)
	lines := strings.split_lines(src, context.temp_allocator)
	defer free_all(context.temp_allocator)

	snippet_count := 0
	in_fence := false
	fence_start_line := 0
	buf: strings.Builder
	strings.builder_init(&buf, context.allocator)
	defer strings.builder_destroy(&buf)

	for raw_line, li in lines {
		line := strings.trim_right(raw_line, "\r")
		trimmed := strings.trim_space(line)
		if !in_fence {
			if trimmed == "```forseti" {
				in_fence = true
				fence_start_line = li + 1
				strings.builder_reset(&buf)
			}
			continue
		}

		if trimmed == "```" {
			in_fence = false
			snippet_count += 1
			snippet := strings.to_string(buf)

			expect_errors := make([dynamic]string, 0, 4, context.temp_allocator)
			expect_warnings := make([dynamic]string, 0, 4, context.temp_allocator)
			snip_lines := strings.split_lines(snippet, context.temp_allocator)
			for sl in snip_lines {
				st := strings.trim_space(sl)
				if strings.has_prefix(st, "// expect-error:") {
					code := strings.trim_space(st[len("// expect-error:"):])
					if len(code) > 0 {
						append(&expect_errors, code)
					}
				} else if strings.has_prefix(st, "// expect-warning:") {
					code := strings.trim_space(st[len("// expect-warning:"):])
					if len(code) > 0 {
						append(&expect_warnings, code)
					}
				}
			}

			diags: forseti.Diagnostic_List
			testing.expect_value(t, forseti.diag_list_init(&diags), nil)
			label := fmt.tprintf("%s:%d", doc_path, fence_start_line)
			ir, c_err := forseti.compile_source(snippet, label, &diags)
			testing.expectf(t, c_err == nil, "%s compile_source failed: %v", label, c_err)

			if len(expect_errors) > 0 {
				testing.expectf(t, diags.error_count > 0, "%s expected error(s) %v, got 0 errors", label, expect_errors[:])
				for want in expect_errors {
					found := false
					for d in diags.items {
						if d.severity == .Error && forseti.diag_code_string(d.code) == want {
							found = true
							break
						}
					}
					testing.expectf(t, found, "%s expected error code %s, got %d diag(s)", label, want, len(diags.items))
				}
			} else if len(expect_warnings) > 0 {
				testing.expectf(t, diags.error_count == 0, "%s expected 0 errors (warnings only), got %d errors", label, diags.error_count)
				for want in expect_warnings {
					found := false
					for d in diags.items {
						if d.severity == .Warning && forseti.diag_code_string(d.code) == want {
							found = true
							break
						}
					}
					testing.expectf(t, found, "%s expected warning code %s, got %d diag(s)", label, want, len(diags.items))
				}
			} else {
				if diags.error_count != 0 || diags.warning_count != 0 {
					msg_b: strings.Builder
					strings.builder_init(&msg_b, context.temp_allocator)
					for d in diags.items {
						fmt.sbprintf(&msg_b, "%s@%d:%d(%s); ", forseti.diag_code_string(d.code), d.line, d.col, d.message)
					}
					testing.expectf(
						t,
						false,
						"%s clean snippet emitted %d error(s), %d warning(s): %s",
						label,
						diags.error_count,
						diags.warning_count,
						strings.to_string(msg_b),
					)
				}
			}

			forseti.ir_destroy(&ir)
			forseti.diag_list_destroy(&diags)
			continue
		}

		strings.write_string(&buf, line)
		strings.write_byte(&buf, '\n')
	}

	testing.expectf(t, !in_fence, "unclosed ```forseti fence in %s", doc_path)
	return snippet_count
}

@(test)
test_doc_forseti_snippets_compile_and_match_expected_diagnostics :: proc(t: ^testing.T) {
	dsl_cnt := _verify_doc_forseti_snippets(t, "docs/dsl-reference.md")
	usage_cnt := _verify_doc_forseti_snippets(t, "usage-rules.md")
	testing.expect(t, dsl_cnt >= 1)
	testing.expect(t, usage_cnt >= 1)
}

@(test)
test_doc_diagnostic_catalog_covers_all_codes :: proc(t: ^testing.T) {
	raw, r_err := os.read_entire_file("docs/dsl-reference.md", context.allocator)
	testing.expect_value(t, r_err, nil)
	if r_err != nil {
		return
	}
	defer delete(raw)

	doc := string(raw)
	for code in forseti.Diag_Code {
		if code == .None {
			continue
		}
		cs := forseti.diag_code_string(code)
		testing.expectf(t, strings.contains(doc, cs), "docs/dsl-reference.md missing diagnostic code %s", cs)
	}
}

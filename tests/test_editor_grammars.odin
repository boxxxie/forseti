package forseti_tests

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "../forseti"

@(private = "file")
_FORSETI_KEYWORDS :: [35]string{
	"module", "version", "schema", "source", "derived", "at",
	"table", "hit", "verify", "inputs", "outputs", "rows", "cost",
	"rule", "phase", "salience", "when", "then", "effect", "where",
	"decide", "assert", "assert!", "unconditional", "retract",
	"not", "exists", "from", "query", "true", "false", "and", "or", "in", "enum",
}

@(test)
test_editor_grammars_and_comprehensive_fixture :: proc(t: ^testing.T) {
	tm_raw, tm_err := os.read_entire_file("editors/textmate/forseti.tmLanguage.json", context.allocator)
	testing.expect_value(t, tm_err, nil)
	defer delete(tm_raw)
	tm_str := string(tm_raw)

	tm_val, j_err := json.parse_string(tm_str, parse_integers = true)
	testing.expect_value(t, j_err, nil)
	if j_err == nil {
		defer json.destroy_value(tm_val)
		tm_obj, is_obj := tm_val.(json.Object)
		testing.expect(t, is_obj)
		if is_obj {
			testing.expect_value(t, string(tm_obj["scopeName"].(json.String)), "source.forseti")
		}
	}

	ts_raw, ts_err := os.read_entire_file("editors/tree-sitter-forseti/grammar.js", context.allocator)
	testing.expect_value(t, ts_err, nil)
	defer delete(ts_raw)
	ts_str := string(ts_raw)

	hq_raw, hq_err := os.read_entire_file("editors/tree-sitter-forseti/queries/highlights.scm", context.allocator)
	testing.expect_value(t, hq_err, nil)
	defer delete(hq_raw)
	hq_str := string(hq_raw)

	testing.expect(t, strings.contains(tm_str, `(?:^|(?<=[\\s|]))`))
	testing.expect(t, !strings.contains(tm_str, `(?<=\\s|^`))

	for kw in _FORSETI_KEYWORDS {
		testing.expectf(t, strings.contains(tm_str, kw), "TextMate grammar missing keyword %q", kw)
		testing.expectf(t, strings.contains(ts_str, kw), "Tree-sitter grammar missing keyword %q", kw)
		testing.expectf(t, strings.contains(hq_str, kw), "Tree-sitter highlights missing keyword %q", kw)
	}

	fix_raw, fix_err := os.read_entire_file("editors/fixtures/comprehensive.forseti", context.allocator)
	testing.expect_value(t, fix_err, nil)
	defer delete(fix_raw)
	fix_src := string(fix_raw)

	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)

	ir, c_err := forseti.compile_source(fix_src, "comprehensive.forseti", &diags)
	testing.expect_value(t, c_err, nil)
	defer forseti.ir_destroy(&ir)
	testing.expect_value(t, diags.error_count, 0)

	formatted, f_err := forseti.format_source(fix_src)
	testing.expect_value(t, f_err, nil)
	defer delete(formatted)
	testing.expect_value(t, formatted, fix_src)
}

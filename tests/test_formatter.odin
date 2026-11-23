package forseti_tests

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "core:time"
import "../forseti"

@(private = "file")
_collect_comments :: proc(src: string, alloc := context.allocator) -> [dynamic]string {
	out := make([dynamic]string, 0, 8, alloc)
	i := 0
	for i < len(src) {
		b := src[i]
		if b == '"' {
			i += 1
			for i < len(src) {
				if src[i] == '\\' && i + 1 < len(src) {
					i += 2
					continue
				}
				if src[i] == '"' {
					i += 1
					break
				}
				i += 1
			}
			continue
		}
		if b == '/' && i + 1 < len(src) && src[i + 1] == '/' {
			start := i
			i += 2
			for i < len(src) && src[i] != '\n' {
				i += 1
			}
			append(&out, strings.trim_right(src[start:i], "\r "))
			continue
		}
		if b == '/' && i + 1 < len(src) && src[i + 1] == '*' {
			start := i
			i += 2
			for i + 1 < len(src) && !(src[i] == '*' && src[i + 1] == '/') {
				i += 1
			}
			if i + 1 < len(src) {
				i += 2
			} else {
				i = len(src)
			}
			append(&out, src[start:i])
			continue
		}
		i += 1
	}
	return out
}

@(test)
test_format_source_canonical_tables_and_comments :: proc(t: ^testing.T) {
	messy := `// File header comment
module   fmt_demo   version   "1.0"

/* Schema for raw
   input records */
schema   RawOrg  {   org_id : string ,  employees : i64 , tier : enum ( "a" , "b" )  }
schema CanonOrg{org_id:string,tier:string,note:string}

source  Raw  :  RawOrg   at   .orgs.raw[ ?id ]
derived  Canon : CanonOrg at .orgs.canon[?id]

table   gate   version "1.0"  hit   Merge  verify( complete , no_dead_rules )  {
inputs { employees : i64  cost 1 ,  code : i32  cost 2 }
outputs { tier : string , note : string }
rows {
// Leading row comment
r_auto : >= 200 | 1 ..= 10 || "enterprise" | - ; // inline note
r_neg : >= -10 | in ( 11 , 12 ) || "smb" | "review" ;
r_default : - | - || - | "fallback" ;
}
}

rule   classify   phase  "main"  salience  10  {
when {
?_r := Raw( org_id : ?oid , employees : ?emp )
?g := decide  gate( employees : ?emp , code : 10 - 5 )
where  ?emp >= 0  and  not ( ?emp == 1 )
}
then {
assert!  Canon( org_id : ?oid , tier : ?g.tier , note : ?g.note )  unconditional
}
}

query  ent_orgs ( tier : string ) {
Canon( org_id : ?oid , tier : ?tier )
}`

	expected := `// File header comment
module fmt_demo version "1.0"

/* Schema for raw
   input records */
schema RawOrg { org_id: string, employees: i64, tier: enum("a", "b") }

schema CanonOrg { org_id: string, tier: string, note: string }

source Raw : RawOrg at .orgs.raw[?id]

derived Canon : CanonOrg at .orgs.canon[?id]

table gate version "1.0" hit Merge verify(complete, no_dead_rules) {
  inputs { employees: i64 cost 1, code: i32 cost 2 }
  outputs { tier: string, note: string }
  rows {
    // Leading row comment
    r_auto:    >= 200 | 1..=10      || "enterprise" | -; // inline note
    r_neg:     >= -10 | in (11, 12) || "smb"        | "review";
    r_default: -      | -           || -            | "fallback";
  }
}

rule classify phase "main" salience 10 {
  when {
    ?_r := Raw(org_id: ?oid, employees: ?emp)
    ?g := decide gate(employees: ?emp, code: 10 - 5)
    where ?emp >= 0 and not (?emp == 1)
  }
  then {
    assert! Canon(org_id: ?oid, tier: ?g.tier, note: ?g.note) unconditional
  }
}

query ent_orgs(tier: string) {
  Canon(org_id: ?oid, tier: ?tier)
}
`

	out1, err1 := forseti.format_source(messy)
	testing.expect_value(t, err1, nil)
	defer delete(out1)
	testing.expect_value(t, out1, expected)

	out2, err2 := forseti.format_source(out1)
	testing.expect_value(t, err2, nil)
	defer delete(out2)
	testing.expect_value(t, out2, out1)
}

@(test)
prop_format_source_idempotent_and_lossless :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	rng := rand.create(t.seed)
	gen := rand.default_random_generator(&rng)

	base := `// Header
module prop_fmt version "1.0"
schema Raw { id: string, n: i64 }
schema Out { id: string, tag: string }
source S : Raw at .s[?id]
derived D : Out at .d[?id]
table t version "1.0" hit First {
  inputs { n: i64 }
  outputs { tag: string }
  rows {
    r1: >= 100 || "big"; // row 1
    r_two: - || "small";
  }
}
rule r {
  when {
    ?_s := S(id: ?id, n: ?n)
    ?g := decide t(n: ?n)
    ?cnt := count(?id) from S(id: ?id, n: ?n)
    where ?cnt >= 0 and ?n - 1 >= -50
  }
  then { assert D(id: ?id, tag: ?g.tag) }
}
query q() { D(id: ?id, tag: ?t) }`

	orig_diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&orig_diags), nil)
	defer forseti.diag_list_destroy(&orig_diags)
	orig_toks, lex_err := forseti.lex_all(base, context.allocator, &orig_diags)
	testing.expect_value(t, lex_err, nil)
	defer delete(orig_toks)
	orig_comments := _collect_comments(base)
	defer delete(orig_comments)

	for iter in 0 ..< 40 {
		// Randomly inject messy whitespace/newlines/tabs between tokens of `base`
		b: strings.Builder
		strings.builder_init(&b)
		defer strings.builder_destroy(&b)

		prev_end := 0
		for tok in orig_toks {
			if tok.kind == .EOF {
				break
			}
			gap := base[prev_end:int(tok.span.offset)]
			if strings.contains(gap, "//") || strings.contains(gap, "/*") {
				strings.write_string(&b, gap)
			} else if len(gap) > 0 {
				choice := rand.int_max(4, gen)
				switch choice {
				case 0: strings.write_string(&b, "   ")
				case 1: strings.write_string(&b, "\t \t")
				case 2: strings.write_string(&b, "\n  ")
				case 3: strings.write_string(&b, "\n\n\t")
				}
			}
			lexeme := base[int(tok.span.offset):int(tok.span.offset + tok.span.len)]
			strings.write_string(&b, lexeme)
			prev_end = int(tok.span.offset + tok.span.len)
		}
		mutated := strings.to_string(b)

		fmt1, err1 := forseti.format_source(mutated)
		testing.expect_value(t, err1, nil)
		defer delete(fmt1)

		fmt2, err2 := forseti.format_source(fmt1)
		testing.expect_value(t, err2, nil)
		defer delete(fmt2)

		testing.expectf(t, fmt1 == fmt2, "formatter not idempotent on iter %d:\nfmt1:\n%s\nfmt2:\n%s", iter, fmt1, fmt2)

		d2: forseti.Diagnostic_List
		_ = forseti.diag_list_init(&d2)
		defer forseti.diag_list_destroy(&d2)
		toks2, l2_err := forseti.lex_all(fmt1, context.allocator, &d2)
		testing.expect_value(t, l2_err, nil)
		defer delete(toks2)

		testing.expect_value(t, len(toks2), len(orig_toks))
		if len(toks2) == len(orig_toks) {
			for ti in 0 ..< len(orig_toks) - 1 {
				testing.expect_value(t, toks2[ti].kind, orig_toks[ti].kind)
				s_orig := base[int(orig_toks[ti].span.offset):int(orig_toks[ti].span.offset + orig_toks[ti].span.len)]
				s_new := fmt1[int(toks2[ti].span.offset):int(toks2[ti].span.offset + toks2[ti].span.len)]
				testing.expect_value(t, s_new, s_orig)
			}
		}
		c2 := _collect_comments(fmt1)
		defer delete(c2)
		testing.expect_value(t, len(c2), len(orig_comments))
		if len(c2) == len(orig_comments) {
			for ci in 0 ..< len(orig_comments) {
				testing.expect_value(t, c2[ci], orig_comments[ci])
			}
		}
	}

	// Incomplete/broken syntax buffers must format without crashing or losing text
	incomplete := fmt.tprintf("module broken version \"1.0\"\nrule r {{\n  when {{ Raw(id: ?x // dangling")
	inc1, inc_err := forseti.format_source(incomplete)
	testing.expect_value(t, inc_err, nil)
	defer delete(inc1)
	inc2, inc2_err := forseti.format_source(inc1)
	testing.expect_value(t, inc2_err, nil)
	defer delete(inc2)
	testing.expect_value(t, inc2, inc1)
}

@(test)
test_format_source_preserves_mid_row_comments :: proc(t: ^testing.T) {
	src := `module row_comments version "1.0"
table t version "1.0" hit First {
inputs { a: i64, b: bool }
outputs { res: string }
rows {
r_block /* id note */ : >= /* cmp */ 10 | true /* b note */ || "hi" /* out note */ ; // tail
r_line : >= 20 // line break inside row
| false || "lo" ;
}
}`

	out1, err1 := forseti.format_source(src)
	testing.expect_value(t, err1, nil)
	defer delete(out1)

	out2, err2 := forseti.format_source(out1)
	testing.expect_value(t, err2, nil)
	defer delete(out2)
	testing.expect_value(t, out2, out1)

	orig_comments := _collect_comments(src)
	defer delete(orig_comments)
	fmt_comments := _collect_comments(out1)
	defer delete(fmt_comments)
	testing.expect_value(t, len(fmt_comments), len(orig_comments))
	for c in orig_comments {
		testing.expectf(t, strings.contains(out1, c), "formatted output lost mid-row comment %q:\n%s", c, out1)
	}

	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)
	ir, c_err := forseti.compile_source(out1, "row_comments.forseti", &diags)
	testing.expect_value(t, c_err, nil)
	defer forseti.ir_destroy(&ir)
	testing.expect_value(t, diags.error_count, 0)
}

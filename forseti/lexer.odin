package forseti

import "core:mem"
import "core:unicode/utf8"

Token_Kind :: enum u8 {
	EOF,
	Invalid,
	Ident,
	Var,
	Int,
	Float,
	String,

	// Keywords
	Kw_Module,
	Kw_Version,
	Kw_Schema,
	Kw_Source,
	Kw_Derived,
	Kw_At,
	Kw_Table,
	Kw_Hit,
	Kw_Verify,
	Kw_Inputs,
	Kw_Outputs,
	Kw_Rows,
	Kw_Cost,
	Kw_Rule,
	Kw_Phase,
	Kw_Salience,
	Kw_When,
	Kw_Then,
	Kw_Effect,
	Kw_Where,
	Kw_Decide,
	Kw_Assert,
	Kw_Assert_Bang,
	Kw_Unconditional,
	Kw_Retract,
	Kw_Not,
	Kw_Exists,
	Kw_From,
	Kw_Query,
	Kw_True,
	Kw_False,
	Kw_And,
	Kw_Or,
	Kw_In,
	Kw_Enum,

	// Punctuation and operators
	LBrace,
	RBrace,
	LParen,
	RParen,
	LBracket,
	RBracket,
	Comma,
	Colon,
	Colon_Eq,
	Semicolon,
	Dot,
	Dot_Dot,
	Dot_Dot_Eq,
	Pipe,
	Double_Pipe,
	Plus,
	Minus,
	Star,
	Slash,
	Percent,
	Bang,
	Eq_Eq,
	Bang_Eq,
	Lt,
	Lt_Eq,
	Gt,
	Gt_Eq,
}

Token :: struct {
	kind: Token_Kind,
	span: Span,
}

@(private)
Lexer :: struct {
	src:         string,
	pos:         int,
	line_starts: [dynamic]u32,
	diags:       ^Diagnostic_List,
	telemetry:   ^Telemetry_Sink,
}

@(private)
advance_codepoint :: proc "contextless" (src: string, pos: ^int) -> rune {
	if pos^ >= len(src) {
		return utf8.RUNE_EOF
	}
	b := src[pos^]
	if b < 0x80 {
		pos^ += 1
		return rune(b)
	}
	r, width := utf8.decode_rune_in_string(src[pos^:])
	pos^ += max(width, 1)
	return r
}

@(private)
is_ident_start :: proc "contextless" (b: byte) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b == '_'
}

@(private)
is_ident_cont :: proc "contextless" (b: byte) -> bool {
	return is_ident_start(b) || (b >= '0' && b <= '9')
}

@(private)
is_digit :: proc "contextless" (b: byte) -> bool {
	return b >= '0' && b <= '9'
}

@(private)
keyword_or_ident :: proc "contextless" (word: string) -> Token_Kind {
	switch word {
	case "module":
		return .Kw_Module
	case "version":
		return .Kw_Version
	case "schema":
		return .Kw_Schema
	case "source":
		return .Kw_Source
	case "derived":
		return .Kw_Derived
	case "at":
		return .Kw_At
	case "table":
		return .Kw_Table
	case "hit":
		return .Kw_Hit
	case "verify":
		return .Kw_Verify
	case "inputs":
		return .Kw_Inputs
	case "outputs":
		return .Kw_Outputs
	case "rows":
		return .Kw_Rows
	case "cost":
		return .Kw_Cost
	case "rule":
		return .Kw_Rule
	case "phase":
		return .Kw_Phase
	case "salience":
		return .Kw_Salience
	case "when":
		return .Kw_When
	case "then":
		return .Kw_Then
	case "effect":
		return .Kw_Effect
	case "where":
		return .Kw_Where
	case "decide":
		return .Kw_Decide
	case "assert":
		return .Kw_Assert
	case "unconditional":
		return .Kw_Unconditional
	case "retract":
		return .Kw_Retract
	case "not":
		return .Kw_Not
	case "exists":
		return .Kw_Exists
	case "from":
		return .Kw_From
	case "query":
		return .Kw_Query
	case "true":
		return .Kw_True
	case "false":
		return .Kw_False
	case "and":
		return .Kw_And
	case "or":
		return .Kw_Or
	case "in":
		return .Kw_In
	case "enum":
		return .Kw_Enum
	case:
		return .Ident
	}
}

@(private)
lex_skip_ws_and_comments :: proc(l: ^Lexer) -> mem.Allocator_Error {
	for l.pos < len(l.src) {
		b := l.src[l.pos]
		switch b {
		case ' ', '\t', '\r':
			l.pos += 1
		case '\n':
			l.pos += 1
			append(&l.line_starts, u32(l.pos)) or_return
		case '/':
			if l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '/' {
				l.pos += 2
				for l.pos < len(l.src) && l.src[l.pos] != '\n' {
					l.pos += 1
				}
			} else if l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '*' {
				start := l.pos
				l.pos += 2
				closed := false
				for l.pos < len(l.src) {
					if l.src[l.pos] == '\n' {
						l.pos += 1
						append(&l.line_starts, u32(l.pos)) or_return
						continue
					}
					if l.src[l.pos] == '*' && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '/' {
						l.pos += 2
						closed = true
						break
					}
					l.pos += 1
				}
				if !closed {
					diag_add(
						l.diags,
						l.line_starts[:],
						.E1001,
						.Error,
						Span{offset = u32(start), len = 2},
						"unterminated block comment",
						"close the comment with */",
						l.telemetry,
					) or_return
				}
			} else {
				return nil
			}
		case:
			return nil
		}
	}
	return nil
}

@(private)
lex_string :: proc(l: ^Lexer, start: int) -> (tok: Token, err: mem.Allocator_Error) {
	l.pos += 1 // opening '"'
	for l.pos < len(l.src) {
		b := l.src[l.pos]
		if b == '"' {
			l.pos += 1
			return Token{
				kind = .String,
				span = Span{offset = u32(start), len = u32(l.pos - start)},
			}, nil
		}
		if b == '\n' {
			l.pos += 1
			append(&l.line_starts, u32(l.pos)) or_return
			continue
		}
		if b == '\\' {
			esc_pos := l.pos
			l.pos += 1
			if l.pos >= len(l.src) {
				break
			}
			esc := l.src[l.pos]
			switch esc {
			case '"', '\\', 'n', 't', 'r', '0':
				l.pos += 1
			case:
				_ = advance_codepoint(l.src, &l.pos)
				if esc == '\n' {
					append(&l.line_starts, u32(l.pos)) or_return
				}
				diag_add(
					l.diags,
					l.line_starts[:],
					.E1001,
					.Error,
					Span{offset = u32(esc_pos), len = u32(l.pos - esc_pos)},
					"invalid escape sequence in string literal",
					`supported escapes are \", \\, \n, \t, \r, \0`,
					l.telemetry,
				) or_return
			}
			continue
		}
		_ = advance_codepoint(l.src, &l.pos)
	}
	diag_add(
		l.diags,
		l.line_starts[:],
		.E1001,
		.Error,
		Span{offset = u32(start), len = u32(l.pos - start)},
		"unterminated string literal",
		`add closing '"'`,
		l.telemetry,
	) or_return
	return Token{
		kind = .Invalid,
		span = Span{offset = u32(start), len = u32(l.pos - start)},
	}, nil
}

@(private)
lex_next :: proc(l: ^Lexer) -> (tok: Token, err: mem.Allocator_Error) {
	lex_skip_ws_and_comments(l) or_return
	if l.pos >= len(l.src) {
		return Token{kind = .EOF, span = Span{offset = u32(len(l.src)), len = 0}}, nil
	}

	start := l.pos
	b := l.src[l.pos]

	if b == '"' {
		return lex_string(l, start)
	}

	if b == '?' {
		l.pos += 1
		if l.pos < len(l.src) && is_ident_start(l.src[l.pos]) {
			for l.pos < len(l.src) && is_ident_cont(l.src[l.pos]) {
				l.pos += 1
			}
			return Token{
				kind = .Var,
				span = Span{offset = u32(start), len = u32(l.pos - start)},
			}, nil
		}
		diag_add(
			l.diags,
			l.line_starts[:],
			.E1001,
			.Error,
			Span{offset = u32(start), len = 1},
			"expected variable identifier after '?'",
			"example: ?org",
			l.telemetry,
		) or_return
		return Token{kind = .Invalid, span = Span{offset = u32(start), len = 1}}, nil
	}

	if is_ident_start(b) {
		l.pos += 1
		for l.pos < len(l.src) && is_ident_cont(l.src[l.pos]) {
			l.pos += 1
		}
		word := l.src[start:l.pos]
		kind := keyword_or_ident(word)
		if kind == .Kw_Assert && l.pos < len(l.src) && l.src[l.pos] == '!' {
			if l.pos + 1 >= len(l.src) || l.src[l.pos + 1] != '=' {
				l.pos += 1
				kind = .Kw_Assert_Bang
			}
		}
		return Token{
			kind = kind,
			span = Span{offset = u32(start), len = u32(l.pos - start)},
		}, nil
	}

	if is_digit(b) {
		l.pos += 1
		for l.pos < len(l.src) && (is_digit(l.src[l.pos]) || l.src[l.pos] == '_') {
			l.pos += 1
		}
		is_float := false
		if l.pos + 1 < len(l.src) && l.src[l.pos] == '.' && is_digit(l.src[l.pos + 1]) {
			is_float = true
			l.pos += 1
			for l.pos < len(l.src) && (is_digit(l.src[l.pos]) || l.src[l.pos] == '_') {
				l.pos += 1
			}
		}
		if l.pos < len(l.src) && (l.src[l.pos] == 'e' || l.src[l.pos] == 'E') {
			exp_start := l.pos
			l.pos += 1
			if l.pos < len(l.src) && (l.src[l.pos] == '+' || l.src[l.pos] == '-') {
				l.pos += 1
			}
			if l.pos < len(l.src) && is_digit(l.src[l.pos]) {
				is_float = true
				for l.pos < len(l.src) && (is_digit(l.src[l.pos]) || l.src[l.pos] == '_') {
					l.pos += 1
				}
			} else {
				l.pos = exp_start
			}
		}
		return Token{
			kind = .Float if is_float else .Int,
			span = Span{offset = u32(start), len = u32(l.pos - start)},
		}, nil
	}

	switch b {
	case '{':
		l.pos += 1
		return Token{kind = .LBrace, span = Span{offset = u32(start), len = 1}}, nil
	case '}':
		l.pos += 1
		return Token{kind = .RBrace, span = Span{offset = u32(start), len = 1}}, nil
	case '(':
		l.pos += 1
		return Token{kind = .LParen, span = Span{offset = u32(start), len = 1}}, nil
	case ')':
		l.pos += 1
		return Token{kind = .RParen, span = Span{offset = u32(start), len = 1}}, nil
	case '[':
		l.pos += 1
		return Token{kind = .LBracket, span = Span{offset = u32(start), len = 1}}, nil
	case ']':
		l.pos += 1
		return Token{kind = .RBracket, span = Span{offset = u32(start), len = 1}}, nil
	case ',':
		l.pos += 1
		return Token{kind = .Comma, span = Span{offset = u32(start), len = 1}}, nil
	case ';':
		l.pos += 1
		return Token{kind = .Semicolon, span = Span{offset = u32(start), len = 1}}, nil
	case '+':
		l.pos += 1
		return Token{kind = .Plus, span = Span{offset = u32(start), len = 1}}, nil
	case '-':
		l.pos += 1
		return Token{kind = .Minus, span = Span{offset = u32(start), len = 1}}, nil
	case '*':
		l.pos += 1
		return Token{kind = .Star, span = Span{offset = u32(start), len = 1}}, nil
	case '/':
		l.pos += 1
		return Token{kind = .Slash, span = Span{offset = u32(start), len = 1}}, nil
	case '%':
		l.pos += 1
		return Token{kind = .Percent, span = Span{offset = u32(start), len = 1}}, nil
	case ':':
		l.pos += 1
		if l.pos < len(l.src) && l.src[l.pos] == '=' {
			l.pos += 1
			return Token{kind = .Colon_Eq, span = Span{offset = u32(start), len = 2}}, nil
		}
		return Token{kind = .Colon, span = Span{offset = u32(start), len = 1}}, nil
	case '.':
		l.pos += 1
		if l.pos < len(l.src) && l.src[l.pos] == '.' {
			l.pos += 1
			if l.pos < len(l.src) && l.src[l.pos] == '=' {
				l.pos += 1
				return Token{kind = .Dot_Dot_Eq, span = Span{offset = u32(start), len = 3}}, nil
			}
			return Token{kind = .Dot_Dot, span = Span{offset = u32(start), len = 2}}, nil
		}
		return Token{kind = .Dot, span = Span{offset = u32(start), len = 1}}, nil
	case '|':
		l.pos += 1
		if l.pos < len(l.src) && l.src[l.pos] == '|' {
			l.pos += 1
			return Token{kind = .Double_Pipe, span = Span{offset = u32(start), len = 2}}, nil
		}
		return Token{kind = .Pipe, span = Span{offset = u32(start), len = 1}}, nil
	case '!':
		l.pos += 1
		if l.pos < len(l.src) && l.src[l.pos] == '=' {
			l.pos += 1
			return Token{kind = .Bang_Eq, span = Span{offset = u32(start), len = 2}}, nil
		}
		return Token{kind = .Bang, span = Span{offset = u32(start), len = 1}}, nil
	case '=':
		l.pos += 1
		if l.pos < len(l.src) && l.src[l.pos] == '=' {
			l.pos += 1
			return Token{kind = .Eq_Eq, span = Span{offset = u32(start), len = 2}}, nil
		}
		diag_add(
			l.diags,
			l.line_starts[:],
			.E1001,
			.Error,
			Span{offset = u32(start), len = 1},
			"unexpected '=' token",
			"use '==' for equality or ':=' for binding",
			l.telemetry,
		) or_return
		return Token{kind = .Invalid, span = Span{offset = u32(start), len = 1}}, nil
	case '<':
		l.pos += 1
		if l.pos < len(l.src) && l.src[l.pos] == '=' {
			l.pos += 1
			return Token{kind = .Lt_Eq, span = Span{offset = u32(start), len = 2}}, nil
		}
		return Token{kind = .Lt, span = Span{offset = u32(start), len = 1}}, nil
	case '>':
		l.pos += 1
		if l.pos < len(l.src) && l.src[l.pos] == '=' {
			l.pos += 1
			return Token{kind = .Gt_Eq, span = Span{offset = u32(start), len = 2}}, nil
		}
		return Token{kind = .Gt, span = Span{offset = u32(start), len = 1}}, nil
	}

	_ = advance_codepoint(l.src, &l.pos)
	span := Span{offset = u32(start), len = u32(l.pos - start)}
	diag_add(
		l.diags,
		l.line_starts[:],
		.E1001,
		.Error,
		span,
		"unexpected character in input",
		"",
		l.telemetry,
	) or_return
	return Token{kind = .Invalid, span = span}, nil
}

@(require_results)
lex_all :: proc(
	src: string,
	allocator := context.allocator,
	diags: ^Diagnostic_List = nil,
	telemetry: ^Telemetry_Sink = nil,
	line_starts_out: ^[dynamic]u32 = nil,
) -> (tokens: [dynamic]Token, err: mem.Allocator_Error) {
	scope := telemetry_span_begin(telemetry, .Lex, "lex")
	defer telemetry_span_end(telemetry, scope)

	l := Lexer{
		src       = src,
		diags     = diags,
		telemetry = telemetry,
	}
	l.line_starts = make([dynamic]u32, 0, 32, allocator) or_return
	defer if line_starts_out == nil || err != nil {
		delete(l.line_starts)
	}
	append(&l.line_starts, 0) or_return

	tokens = make([dynamic]Token, 0, max(len(src) / 6, 16), allocator) or_return
	defer if err != nil {
		delete(tokens)
	}

	for {
		tok := lex_next(&l) or_return
		append(&tokens, tok) or_return
		telemetry_count_add(telemetry, .Tokens_Lexed, 1)
		if tok.kind == .EOF {
			break
		}
	}

	if line_starts_out != nil {
		line_starts_out^ = l.line_starts
	}
	return tokens, nil
}

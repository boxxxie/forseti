package forseti

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"

Diagnostic_Severity :: enum u8 {
	Error,
	Warning,
	Hint,
}

Diag_Code :: enum u16 {
	None,
	E1001,
	E1002,
	E1003,
	E1004,
	E1005,
	E2001,
	E2002,
	E2003,
	E2004,
	E2005,
	E3001,
	E3002,
	E4001,
	W2001,
	W2002,
	W2003,
	W2004,
	W2005,
	W3001,
	W3002,
	W3003,
	W3004,
	W3005,
	W3006,
}

@(rodata)
diag_code_strings := [Diag_Code]string{
	.None  = "NONE",
	.E1001 = "E1001",
	.E1002 = "E1002",
	.E1003 = "E1003",
	.E1004 = "E1004",
	.E1005 = "E1005",
	.E2001 = "E2001",
	.E2002 = "E2002",
	.E2003 = "E2003",
	.E2004 = "E2004",
	.E2005 = "E2005",
	.E3001 = "E3001",
	.E3002 = "E3002",
	.E4001 = "E4001",
	.W2001 = "W2001",
	.W2002 = "W2002",
	.W2003 = "W2003",
	.W2004 = "W2004",
	.W2005 = "W2005",
	.W3001 = "W3001",
	.W3002 = "W3002",
	.W3003 = "W3003",
	.W3004 = "W3004",
	.W3005 = "W3005",
	.W3006 = "W3006",
}

diag_code_string :: proc "contextless" (code: Diag_Code) -> string {
	return diag_code_strings[code]
}

Diagnostic :: struct {
	code:     Diag_Code,
	severity: Diagnostic_Severity,
	span:     Span,
	line:     u32,
	col:      u32,
	end_line: u32,
	end_col:  u32,
	message:  string,
	hint:     string,
}

Diagnostic_List :: struct {
	items:         [dynamic]Diagnostic,
	arena:         vmem.Arena,
	error_count:   int,
	warning_count: int,
}

@(require_results)
diag_list_init :: proc(
	list: ^Diagnostic_List,
	allocator := context.allocator,
) -> (err: mem.Allocator_Error) {
	list^ = {}
	vmem.arena_init_growing(&list.arena) or_return
	defer if err != nil {
		diag_list_destroy(list)
	}
	list.items = make([dynamic]Diagnostic, 0, 16, allocator) or_return
	return nil
}

diag_list_destroy :: proc(list: ^Diagnostic_List) {
	vmem.arena_check_temp(&list.arena)
	delete(list.items)
	vmem.arena_destroy(&list.arena)
	list^ = {}
}

diag_add :: proc(
	list: ^Diagnostic_List,
	line_starts: []u32,
	code: Diag_Code,
	severity: Diagnostic_Severity,
	span: Span,
	message: string,
	hint: string = "",
	telemetry: ^Telemetry_Sink = nil,
) -> mem.Allocator_Error {
	if list == nil {
		return nil
	}
	line, col := resolve_line_col(line_starts, span.offset)
	end_line, end_col := resolve_line_col(line_starts, span.offset + span.len)

	arena_alloc := vmem.arena_allocator(&list.arena)
	cloned_msg := strings.clone(message, arena_alloc) or_return
	cloned_hint := ""
	if len(hint) > 0 {
		cloned_hint = strings.clone(hint, arena_alloc) or_return
	}

	append(&list.items, Diagnostic{
		code     = code,
		severity = severity,
		span     = span,
		line     = line,
		col      = col,
		end_line = end_line,
		end_col  = end_col,
		message  = cloned_msg,
		hint     = cloned_hint,
	}) or_return

	switch severity {
	case .Error:
		list.error_count += 1
		telemetry_count_add(telemetry, .Diagnostics_Errors, 1)
	case .Warning:
		list.warning_count += 1
		telemetry_count_add(telemetry, .Diagnostics_Warnings, 1)
	case .Hint:
	}
	return nil
}

diag_has_errors :: proc "contextless" (list: ^Diagnostic_List) -> bool {
	return list != nil && list.error_count > 0
}

diag_has_warnings :: proc "contextless" (list: ^Diagnostic_List) -> bool {
	return list != nil && list.warning_count > 0
}

@(rodata)
diag_severity_strings := [Diagnostic_Severity]string{
	.Error   = "error",
	.Warning = "warning",
	.Hint    = "hint",
}

@(require_results)
format_diagnostic_human :: proc(
	d: Diagnostic,
	src: string,
	filename: string,
	allocator := context.allocator,
) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	fmt.sbprintf(
		&b,
		"%s:%d:%d: %s[%s]: %s\n",
		filename,
		d.line,
		d.col,
		diag_severity_strings[d.severity],
		diag_code_strings[d.code],
		d.message,
	)

	if len(src) > 0 && int(d.span.offset) <= len(src) {
		line_start := int(d.span.offset)
		for line_start > 0 && src[line_start - 1] != '\n' {
			line_start -= 1
		}
		line_end := line_start
		for line_end < len(src) && src[line_end] != '\n' && src[line_end] != '\r' {
			line_end += 1
		}
		line_text := src[line_start:line_end]
		fmt.sbprintf(&b, "  %4d | %s\n", d.line, line_text)

		caret_col := max(int(d.col) - 1, 0)
		caret_len := max(int(d.span.len), 1)
		if line_start + caret_col + caret_len > line_end {
			caret_len = max(line_end - (line_start + caret_col), 1)
		}
		strings.write_string(&b, "       | ")
		for i := 0; i < caret_col; i += 1 {
			if line_start + i < line_end && src[line_start + i] == '\t' {
				strings.write_byte(&b, '\t')
			} else {
				strings.write_byte(&b, ' ')
			}
		}
		for _ in 0 ..< caret_len {
			strings.write_byte(&b, '^')
		}
		strings.write_byte(&b, '\n')
	}

	if len(d.hint) > 0 {
		fmt.sbprintf(&b, "  hint: %s\n", d.hint)
	}

	return strings.to_string(b), nil
}

@(require_results)
format_diagnostics_json :: proc(
	list: ^Diagnostic_List,
	filename: string,
	allocator := context.allocator,
) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	ok := list == nil || list.error_count == 0
	err_count := list.error_count if list != nil else 0
	warn_count := list.warning_count if list != nil else 0

	strings.write_string(&b, `{"file":`)
	write_json_escaped_string(&b, filename)
	fmt.sbprintf(
		&b,
		`,"ok":%t,"error_count":%d,"warning_count":%d,"diagnostics":[`,
		ok,
		err_count,
		warn_count,
	)

	if list != nil {
		for d, idx in list.items {
			if idx > 0 {
				strings.write_byte(&b, ',')
			}
			strings.write_string(&b, `{"code":`)
			write_json_escaped_string(&b, diag_code_strings[d.code])
			strings.write_string(&b, `,"severity":`)
			write_json_escaped_string(&b, diag_severity_strings[d.severity])
			fmt.sbprintf(
				&b,
				`,"line":%d,"col":%d,"end_line":%d,"end_col":%d,"offset":%d,"len":%d,"message":`,
				d.line,
				d.col,
				d.end_line,
				d.end_col,
				d.span.offset,
				d.span.len,
			)
			write_json_escaped_string(&b, d.message)
			strings.write_string(&b, `,"hint":`)
			write_json_escaped_string(&b, d.hint)
			strings.write_byte(&b, '}')
		}
	}

	strings.write_string(&b, "]}")
	return strings.to_string(b), nil
}

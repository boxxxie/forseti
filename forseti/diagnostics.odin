package forseti

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
	W2001,
	W2002,
	W2003,
	W2004,
	W2005,
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
	.W2001 = "W2001",
	.W2002 = "W2002",
	.W2003 = "W2003",
	.W2004 = "W2004",
	.W2005 = "W2005",
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

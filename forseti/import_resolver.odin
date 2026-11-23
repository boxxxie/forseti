package forseti

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

@(private)
_Import_Frame :: struct {
	abs_path:     string,
	display_path: string,
	src:          string,
	owns_src:     bool,
	parsed:       Parsed_Ast,
}

@(private)
_Import_Ctx :: struct {
	include_paths: []string,
	diags:         ^Diagnostic_List,
	telemetry:     ^Telemetry_Sink,
	allocator:     mem.Allocator,
	visiting:      map[string]bool,
	visited:       map[string]bool,
	stack:         [dynamic]string,
	units:         [dynamic]_Import_Frame,
}

@(private)
_canonical_import_key :: proc(path: string, allocator := context.temp_allocator) -> string {
	if abs, ok := os.get_absolute_path(path, allocator); ok == nil {
		return abs
	}
	cleaned, _ := filepath.clean(path, allocator)
	return cleaned
}

@(private)
_resolve_import_target :: proc(
	cur_file: string,
	raw_import: string,
	include_paths: []string,
) -> (resolved: string, found: bool) {
	if filepath.is_abs(raw_import) {
		if os.exists(raw_import) {
			return raw_import, true
		}
		return raw_import, false
	}
	if len(cur_file) > 0 {
		dir := filepath.dir(cur_file)
		cand, err := filepath.join({dir, raw_import}, context.temp_allocator)
		if err == nil && os.exists(cand) {
			return cand, true
		}
	}
	for inc in include_paths {
		cand, err := filepath.join({inc, raw_import}, context.temp_allocator)
		if err == nil && os.exists(cand) {
			return cand, true
		}
	}
	if os.exists(raw_import) {
		return raw_import, true
	}
	return raw_import, false
}

@(private)
_format_import_cycle :: proc(stack: []string, repeat_path: string) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, "circular import detected: ")
	for p, i in stack {
		if i > 0 {
			strings.write_string(&b, " -> ")
		}
		strings.write_string(&b, p)
	}
	strings.write_string(&b, " -> ")
	strings.write_string(&b, repeat_path)
	return strings.to_string(b)
}

@(private)
_collect_imports_dfs :: proc(
	ctx: ^_Import_Ctx,
	frame_in: _Import_Frame,
) -> mem.Allocator_Error {
	frame := frame_in
	canon := strings.clone(_canonical_import_key(frame.abs_path), ctx.allocator) or_return
	defer delete(canon, ctx.allocator)

	if canon in ctx.visited {
		if frame.owns_src {
			delete(frame.src, ctx.allocator)
		}
		parsed_ast_destroy(&frame.parsed)
		return nil
	}

	ctx.visiting[canon] = true
	append(&ctx.stack, frame.display_path) or_return

	for imp in frame.parsed.pool.imports {
		imp_rel := interner_get(&frame.parsed.interner, imp.path)
		resolved, exists := _resolve_import_target(frame.abs_path, imp_rel, ctx.include_paths)
		if !exists {
			diag_add(
				ctx.diags,
				frame.parsed.line_starts[:],
				.E2006,
				.Error,
				imp.span,
				fmt.tprintf("unable to resolve import %q", imp_rel),
				"verify import path or pass --include <dir>",
				ctx.telemetry,
				frame.display_path,
			) or_return
			continue
		}

		dep_canon := _canonical_import_key(resolved, context.temp_allocator)
		if dep_canon in ctx.visiting {
			diag_add(
				ctx.diags,
				frame.parsed.line_starts[:],
				.E2006,
				.Error,
				imp.span,
				_format_import_cycle(ctx.stack[:], resolved),
				"break the import cycle by extracting shared schemas into a common base file",
				ctx.telemetry,
				frame.display_path,
			) or_return
			continue
		}
		if dep_canon in ctx.visited {
			continue
		}

		raw_bytes, r_err := os.read_entire_file(resolved, ctx.allocator)
		if r_err != nil {
			diag_add(
				ctx.diags,
				frame.parsed.line_starts[:],
				.E2006,
				.Error,
				imp.span,
				fmt.tprintf("failed reading import %q", resolved),
				"",
				ctx.telemetry,
				frame.display_path,
			) or_return
			continue
		}
		dep_src := string(raw_bytes)
		dep_parsed, p_err := parse_source_to_ast(dep_src, resolved, ctx.diags, ctx.telemetry, ctx.allocator)
		if p_err != nil {
			delete(dep_src, ctx.allocator)
			return p_err
		}
		dep_frame := _Import_Frame{
			abs_path     = strings.clone(resolved, ctx.allocator) or_return,
			display_path = resolved,
			src          = dep_src,
			owns_src     = true,
			parsed       = dep_parsed,
		}
		dep_frame.display_path = dep_frame.abs_path
		_collect_imports_dfs(ctx, dep_frame) or_return
	}

	_ = pop(&ctx.stack)
	delete_key(&ctx.visiting, canon)
	ctx.visited[strings.clone(canon, ctx.allocator) or_return] = true
	append(&ctx.units, frame) or_return
	return nil
}

// Compiles `.forseti` source text with transitive `import` resolution, diamond deduplication, and cycle diagnostics.
@(require_results)
compile_source_with_imports :: proc(
	src: string,
	source_name: string = "",
	include_paths: []string = nil,
	diags: ^Diagnostic_List = nil,
	telemetry: ^Telemetry_Sink = nil,
	allocator := context.allocator,
) -> (ir: Rulebase_IR, err: mem.Allocator_Error) {
	root_parsed := parse_source_to_ast(src, source_name, diags, telemetry, allocator) or_return
	if len(root_parsed.pool.imports) == 0 {
		defer parsed_ast_destroy(&root_parsed)
		unit := Lower_Unit{
			pool        = &root_parsed.pool,
			interner    = &root_parsed.interner,
			line_starts = root_parsed.line_starts[:],
			src_len     = u32(len(src)),
			file        = source_name,
		}
		ir = lower_units_to_ir({unit}, telemetry, allocator) or_return
		defer if err != nil {
			ir_destroy(&ir)
		}
		analyze_ir(&ir, diags, telemetry) or_return
		return ir, nil
	}

	ctx := _Import_Ctx{
		include_paths = include_paths,
		diags         = diags,
		telemetry     = telemetry,
		allocator     = allocator,
		visiting      = make(map[string]bool, 8, allocator),
		visited       = make(map[string]bool, 8, allocator),
		stack         = make([dynamic]string, 0, 8, allocator),
		units         = make([dynamic]_Import_Frame, 0, 8, allocator),
	}
	defer {
		for k in ctx.visited {
			delete(k, allocator)
		}
		delete(ctx.visiting)
		delete(ctx.visited)
		delete(ctx.stack)
		for &u in ctx.units {
			if u.owns_src {
				delete(u.abs_path, allocator)
				delete(u.src, allocator)
			}
			parsed_ast_destroy(&u.parsed)
		}
		delete(ctx.units)
	}

	root_name := source_name if len(source_name) > 0 else "<source>"
	root_frame := _Import_Frame{
		abs_path     = root_name,
		display_path = root_name,
		src          = src,
		owns_src     = false,
		parsed       = root_parsed,
	}
	if d_err := _collect_imports_dfs(&ctx, root_frame); d_err != nil {
		return {}, d_err
	}

	lower_units := make([]Lower_Unit, len(ctx.units), context.temp_allocator)
	for &u, i in ctx.units {
		lower_units[i] = Lower_Unit{
			pool        = &u.parsed.pool,
			interner    = &u.parsed.interner,
			line_starts = u.parsed.line_starts[:],
			src_len     = u32(len(u.src)),
			file        = u.display_path,
		}
	}

	ir = lower_units_to_ir(lower_units, telemetry, allocator) or_return
	defer if err != nil {
		ir_destroy(&ir)
	}
	analyze_ir(&ir, diags, telemetry) or_return
	return ir, nil
}

// Reads and compiles a `.forseti` policy file along with all transitive `import` dependencies.
@(require_results)
compile_file :: proc(
	file_path: string,
	include_paths: []string = nil,
	diags: ^Diagnostic_List = nil,
	telemetry: ^Telemetry_Sink = nil,
	allocator := context.allocator,
) -> (ir: Rulebase_IR, err: mem.Allocator_Error) {
	raw_bytes, r_err := os.read_entire_file(file_path, allocator)
	if r_err != nil {
		diag_add(
			diags,
			nil,
			.E2006,
			.Error,
			Span{},
			fmt.tprintf("unable to read policy file %q", file_path),
			"",
			telemetry,
			file_path,
		) or_return
		return {}, nil
	}
	src := string(raw_bytes)
	defer delete(src, allocator)
	return compile_source_with_imports(src, file_path, include_paths, diags, telemetry, allocator)
}

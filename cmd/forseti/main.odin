package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "../../forseti"

Cli_Format :: enum u8 {
	Human,
	Json,
}

Cli_Options :: struct {
	subcmd:             string,
	file_path:          string,
	format:             Cli_Format,
	warnings_as_errors: bool,
	telemetry_path:     string,
}

print_usage :: proc() {
	fmt.println(`Usage: forseti <command> [options] <file.forseti>

Commands:
  check    Validate syntax, types, variable bindings, and lints
  ast      Parse source and print deterministic S-expression AST
  ir       Compile source and print canonical Rulebase_IR summary

Options:
  --format=human|json      Output format for 'check' (default: human)
  --warnings-as-errors     Treat compiler warnings (W*) as non-zero exit failures
  --telemetry <out.json>   Export compile telemetry (Chrome Trace JSON, or JSONL for .jsonl)
  -h, --help               Show this help message`)
}

parse_cli_args :: proc(args: []string) -> (opts: Cli_Options, show_help: bool, ok: bool) {
	if len(args) < 2 {
		return {}, true, true
	}
	first := args[1]
	if first == "-h" || first == "--help" || first == "help" {
		return {}, true, true
	}
	opts.subcmd = first

	i := 2
	for i < len(args) {
		arg := args[i]
		if arg == "-h" || arg == "--help" {
			return {}, true, true
		} else if arg == "--warnings-as-errors" {
			opts.warnings_as_errors = true
		} else if arg == "--format=json" {
			opts.format = .Json
		} else if arg == "--format=human" {
			opts.format = .Human
		} else if strings.has_prefix(arg, "--format=") {
			fmt.eprintfln("error: unknown format %q (expected human or json)", arg[len("--format="):])
			return {}, false, false
		} else if arg == "--telemetry" {
			if i + 1 >= len(args) {
				fmt.eprintln("error: --telemetry requires a file path argument")
				return {}, false, false
			}
			i += 1
			opts.telemetry_path = args[i]
		} else if strings.has_prefix(arg, "--telemetry=") {
			opts.telemetry_path = arg[len("--telemetry="):]
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("error: unknown option %q", arg)
			return {}, false, false
		} else if len(opts.file_path) == 0 {
			opts.file_path = arg
		} else {
			fmt.eprintfln("error: unexpected positional argument %q", arg)
			return {}, false, false
		}
		i += 1
	}

	if len(opts.file_path) == 0 {
		fmt.eprintln("error: missing <file.forseti> argument")
		return {}, false, false
	}
	return opts, false, true
}

write_telemetry_file :: proc(sink: ^forseti.Telemetry_Sink, path: string) -> bool {
	if len(path) == 0 {
		return true
	}
	data: string
	err: mem.Allocator_Error
	if strings.has_suffix(path, ".jsonl") {
		data, err = forseti.telemetry_export_jsonl(sink, context.allocator)
	} else {
		data, err = forseti.telemetry_export_chrome_trace(sink, context.allocator)
	}
	if err != nil {
		fmt.eprintfln("error: failed formatting telemetry: %v", err)
		return false
	}
	defer delete(data)

	if write_err := os.write_entire_file(path, data); write_err != nil {
		fmt.eprintfln("error: failed writing telemetry to %q: %v", path, write_err)
		return false
	}
	return true
}

emit_human_diagnostics :: proc(diags: ^forseti.Diagnostic_List, src, path: string) {
	for d in diags.items {
		formatted, f_err := forseti.format_diagnostic_human(d, src, path, context.allocator)
		if f_err == nil {
			fmt.eprint(formatted)
			delete(formatted)
		}
	}
}

run_cli :: proc() -> int {
	opts, show_help, ok := parse_cli_args(os.args)
	if !ok {
		return 2
	}
	if show_help {
		print_usage()
		return 0
	}

	raw, read_err := os.read_entire_file(opts.file_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("error: unable to read %q: %v", opts.file_path, read_err)
		return 2
	}
	defer delete(raw)
	src := string(raw)

	diags: forseti.Diagnostic_List
	if d_err := forseti.diag_list_init(&diags); d_err != nil {
		fmt.eprintfln("error: out of memory: %v", d_err)
		return 2
	}
	defer forseti.diag_list_destroy(&diags)

	telemetry: forseti.Telemetry_Sink
	if t_err := forseti.telemetry_init(&telemetry, enabled = len(opts.telemetry_path) > 0); t_err != nil {
		fmt.eprintfln("error: out of memory: %v", t_err)
		return 2
	}
	defer forseti.telemetry_destroy(&telemetry)

	switch opts.subcmd {
	case "check":
		ir, c_err := forseti.compile_source(src, opts.file_path, &diags, &telemetry, context.allocator)
		if c_err != nil {
			fmt.eprintfln("error: compilation failed: %v", c_err)
			return 2
		}
		defer forseti.ir_destroy(&ir)

		if opts.format == .Json {
			json_out, j_err := forseti.format_diagnostics_json(&diags, opts.file_path, context.allocator)
			if j_err != nil {
				fmt.eprintfln("error: failed formatting json: %v", j_err)
				return 2
			}
			defer delete(json_out)
			fmt.println(json_out)
		} else {
			emit_human_diagnostics(&diags, src, opts.file_path)
			if len(diags.items) == 0 {
				fmt.printfln("OK: %s (0 errors, 0 warnings)", opts.file_path)
			}
		}

		if !write_telemetry_file(&telemetry, opts.telemetry_path) {
			return 2
		}
		if diags.error_count > 0 || (opts.warnings_as_errors && diags.warning_count > 0) {
			return 1
		}
		return 0

	case "ast":
		parsed, p_err := forseti.parse_source_to_ast(src, opts.file_path, &diags, &telemetry, context.allocator)
		if p_err != nil {
			fmt.eprintfln("error: parse failed: %v", p_err)
			return 2
		}
		defer forseti.parsed_ast_destroy(&parsed)

		emit_human_diagnostics(&diags, src, opts.file_path)
		sexp, s_err := forseti.ast_print_sexp(&parsed.pool, &parsed.interner, context.allocator)
		if s_err != nil {
			fmt.eprintfln("error: failed formatting ast: %v", s_err)
			return 2
		}
		defer delete(sexp)
		fmt.println(sexp)

		if !write_telemetry_file(&telemetry, opts.telemetry_path) {
			return 2
		}
		return 1 if diags.error_count > 0 else 0

	case "ir":
		ir, c_err := forseti.compile_source(src, opts.file_path, &diags, &telemetry, context.allocator)
		if c_err != nil {
			fmt.eprintfln("error: compile failed: %v", c_err)
			return 2
		}
		defer forseti.ir_destroy(&ir)

		emit_human_diagnostics(&diags, src, opts.file_path)
		text, f_err := forseti.ir_format_text(&ir, context.allocator)
		if f_err != nil {
			fmt.eprintfln("error: failed formatting ir: %v", f_err)
			return 2
		}
		defer delete(text)
		fmt.print(text)

		if !write_telemetry_file(&telemetry, opts.telemetry_path) {
			return 2
		}
		if diags.error_count > 0 || (opts.warnings_as_errors && diags.warning_count > 0) {
			return 1
		}
		return 0

	case:
		fmt.eprintfln("error: unknown command %q", opts.subcmd)
		print_usage()
		return 2
	}
}

main :: proc() {
	exit_code: int
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		exit_code = run_cli()

		for _, entry in track.allocation_map {
			fmt.eprintfln("%v leaked %m", entry.location, entry.size)
		}
		for entry in track.bad_free_array {
			fmt.eprintfln("%v bad free at %p", entry.location, entry.memory)
		}
		mem.tracking_allocator_destroy(&track)
	} else {
		exit_code = run_cli()
	}

	if exit_code != 0 {
		os.exit(exit_code)
	}
}

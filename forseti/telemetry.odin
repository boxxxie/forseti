package forseti

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "core:time"

FORSETI_TELEMETRY :: #config(FORSETI_TELEMETRY, true)

Telemetry_Phase :: enum u8 {
	Lex,
	Parse,
	Ir_Lower,
	Analyze,
	Table_Verify,
	Compile,
	Sync,
	Match,
	Tms,
	Commit,
	Custom,
}

Telemetry_Counter :: enum u8 {
	Tokens_Lexed,
	Ast_Nodes,
	Ir_Schemas,
	Ir_Bindings,
	Ir_Tables,
	Ir_Rules,
	Ir_Queries,
	Diagnostics_Errors,
	Diagnostics_Warnings,
	Alpha_Tests,
	Alpha_Hits,
	Alpha_Nodes_Shared,
	Beta_Joins,
	Beta_Tuples_Staged,
	Segments_Created,
	Segments_Linked,
	Segments_Skipped_Unlinked,
	Rules_Fired,
	Slots_Skipped,
	Keys_Decoded,
	Jtms_Retractions,
	Derivations_Recorded,
}

Telemetry_Span_Event :: struct {
	phase:             Telemetry_Phase,
	name:              string,
	parent_idx:        i32,
	depth:             u16,
	start_ns:          i64,
	duration_ns:       i64,
	alloc_bytes_delta: i64,
}

Telemetry_Watermarks :: struct {
	peak_heap_bytes:       u64,
	peak_arena_bytes:      u64,
	live_session_memories: u64,
}

Telemetry_Scope :: struct {
	idx:        i32,
	start_tick: time.Tick,
	active:     bool,
}

Telemetry_Sink :: struct {
	enabled:     bool,
	origin_tick: time.Tick,
	events:      [dynamic]Telemetry_Span_Event,
	stack:       [dynamic; 64]i32,
	counters:    [Telemetry_Counter]u64,
	watermarks:  Telemetry_Watermarks,
	arena:       vmem.Arena,
}

@(rodata)
telemetry_phase_names := [Telemetry_Phase]string{
	.Lex          = "lex",
	.Parse        = "parse",
	.Ir_Lower     = "ir_lower",
	.Analyze      = "analyze",
	.Table_Verify = "table_verify",
	.Compile      = "compile",
	.Sync         = "sync",
	.Match        = "match",
	.Tms          = "tms",
	.Commit       = "commit",
	.Custom       = "custom",
}

@(rodata)
telemetry_counter_names := [Telemetry_Counter]string{
	.Tokens_Lexed            = "tokens_lexed",
	.Ast_Nodes               = "ast_nodes",
	.Ir_Schemas              = "ir_schemas",
	.Ir_Bindings             = "ir_bindings",
	.Ir_Tables               = "ir_tables",
	.Ir_Rules                = "ir_rules",
	.Ir_Queries              = "ir_queries",
	.Diagnostics_Errors      = "diagnostics_errors",
	.Diagnostics_Warnings    = "diagnostics_warnings",
	.Alpha_Tests               = "alpha_tests",
	.Alpha_Hits                = "alpha_hits",
	.Alpha_Nodes_Shared        = "alpha_nodes_shared",
	.Beta_Joins                = "beta_joins",
	.Beta_Tuples_Staged        = "beta_tuples_staged",
	.Segments_Created          = "segments_created",
	.Segments_Linked           = "segments_linked",
	.Segments_Skipped_Unlinked = "segments_skipped_unlinked",
	.Rules_Fired               = "rules_fired",
	.Slots_Skipped           = "slots_skipped",
	.Keys_Decoded            = "keys_decoded",
	.Jtms_Retractions        = "jtms_retractions",
	.Derivations_Recorded    = "derivations_recorded",
}

@(require_results)
telemetry_init :: proc(
	sink: ^Telemetry_Sink,
	enabled := true,
	allocator := context.allocator,
) -> (err: mem.Allocator_Error) {
	sink^ = {}
	sink.enabled = enabled
	sink.origin_tick = time.tick_now()
	when FORSETI_TELEMETRY {
		vmem.arena_init_growing(&sink.arena) or_return
		defer if err != nil {
			telemetry_destroy(sink)
		}
		sink.events = make([dynamic]Telemetry_Span_Event, 0, 32, allocator) or_return
	}
	return nil
}

telemetry_destroy :: proc(sink: ^Telemetry_Sink) {
	vmem.arena_check_temp(&sink.arena)
	delete(sink.events)
	vmem.arena_destroy(&sink.arena)
	sink^ = {}
}

telemetry_reset :: proc(sink: ^Telemetry_Sink) {
	clear(&sink.events)
	clear(&sink.stack)
	sink.counters = {}
	sink.watermarks = {}
	vmem.arena_free_all(&sink.arena)
	sink.origin_tick = time.tick_now()
}

// Merges events, counters, and watermarks from a worker/actor Telemetry_Sink into `dst` without cross-thread sharing.
telemetry_merge :: proc(dst: ^Telemetry_Sink, src: ^Telemetry_Sink) -> (err: mem.Allocator_Error) {
	when FORSETI_TELEMETRY {
		if dst == nil || src == nil || !dst.enabled {
			return nil
		}
		base_idx := i32(len(dst.events))
		for ev in src.events {
			cloned, alloc_err := strings.clone(ev.name, vmem.arena_allocator(&dst.arena))
			if alloc_err != nil {
				return alloc_err
			}
			new_parent := (ev.parent_idx + base_idx) if ev.parent_idx >= 0 else i32(-1)
			append(&dst.events, Telemetry_Span_Event{
				phase             = ev.phase,
				name              = cloned,
				parent_idx        = new_parent,
				depth             = ev.depth,
				start_ns          = ev.start_ns,
				duration_ns       = ev.duration_ns,
				alloc_bytes_delta = ev.alloc_bytes_delta,
			}) or_return
		}
		for c in Telemetry_Counter {
			dst.counters[c] += src.counters[c]
		}
		if src.watermarks.peak_heap_bytes > dst.watermarks.peak_heap_bytes {
			dst.watermarks.peak_heap_bytes = src.watermarks.peak_heap_bytes
		}
		if src.watermarks.peak_arena_bytes > dst.watermarks.peak_arena_bytes {
			dst.watermarks.peak_arena_bytes = src.watermarks.peak_arena_bytes
		}
		dst.watermarks.live_session_memories += src.watermarks.live_session_memories
		return nil
	} else {
		_ = dst
		_ = src
		return nil
	}
}

telemetry_span_begin :: proc(
	sink: ^Telemetry_Sink,
	phase: Telemetry_Phase,
	name: string = "",
) -> Telemetry_Scope {
	when FORSETI_TELEMETRY {
		if sink == nil || !sink.enabled {
			return {}
		}
		now := time.tick_now()
		start_ns := time.duration_nanoseconds(time.tick_diff(sink.origin_tick, now))
		parent_idx := i32(-1)
		if len(sink.stack) > 0 {
			parent_idx = sink.stack[len(sink.stack) - 1]
		}
		depth := u16(len(sink.stack))
		label := name if len(name) > 0 else telemetry_phase_names[phase]
		cloned, alloc_err := strings.clone(label, vmem.arena_allocator(&sink.arena))
		if alloc_err != nil {
			cloned = telemetry_phase_names[phase]
		}
		idx := i32(len(sink.events))
		_, append_err := append(&sink.events, Telemetry_Span_Event{
			phase      = phase,
			name       = cloned,
			parent_idx = parent_idx,
			depth      = depth,
			start_ns   = start_ns,
		})
		if append_err != nil {
			return {}
		}
		if len(sink.stack) < cap(sink.stack) {
			append(&sink.stack, idx)
		}
		return Telemetry_Scope{
			idx        = idx,
			start_tick = now,
			active     = true,
		}
	} else {
		_ = sink
		_ = phase
		_ = name
		return {}
	}
}

telemetry_span_end :: proc(
	sink: ^Telemetry_Sink,
	scope: Telemetry_Scope,
	alloc_bytes_delta: i64 = 0,
) {
	when FORSETI_TELEMETRY {
		if sink == nil || !sink.enabled || !scope.active {
			return
		}
		idx := int(scope.idx)
		if idx >= 0 && idx < len(sink.events) {
			now := time.tick_now()
			sink.events[idx].duration_ns = time.duration_nanoseconds(time.tick_diff(scope.start_tick, now))
			sink.events[idx].alloc_bytes_delta = alloc_bytes_delta
		}
		if len(sink.stack) > 0 && sink.stack[len(sink.stack) - 1] == scope.idx {
			pop(&sink.stack)
		}
	} else {
		_ = sink
		_ = scope
		_ = alloc_bytes_delta
	}
}

telemetry_count_add :: proc "contextless" (
	sink: ^Telemetry_Sink,
	counter: Telemetry_Counter,
	delta: u64 = 1,
) {
	when FORSETI_TELEMETRY {
		if sink == nil || !sink.enabled {
			return
		}
		sink.counters[counter] += delta
	} else {
		_ = sink
		_ = counter
		_ = delta
	}
}

telemetry_watermark_heap :: proc "contextless" (sink: ^Telemetry_Sink, bytes: u64) {
	when FORSETI_TELEMETRY {
		if sink == nil || !sink.enabled {
			return
		}
		if bytes > sink.watermarks.peak_heap_bytes {
			sink.watermarks.peak_heap_bytes = bytes
		}
	} else {
		_ = sink
		_ = bytes
	}
}

telemetry_watermark_arena :: proc "contextless" (sink: ^Telemetry_Sink, bytes: u64) {
	when FORSETI_TELEMETRY {
		if sink == nil || !sink.enabled {
			return
		}
		if bytes > sink.watermarks.peak_arena_bytes {
			sink.watermarks.peak_arena_bytes = bytes
		}
	} else {
		_ = sink
		_ = bytes
	}
}

@(private)
write_json_escaped_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case '\b':
			strings.write_string(b, `\b`)
		case '\f':
			strings.write_string(b, `\f`)
		case:
			if ch < 0x20 {
				fmt.sbprintf(b, `\u%04x`, ch)
			} else {
				strings.write_byte(b, ch)
			}
		}
	}
	strings.write_byte(b, '"')
}

@(require_results)
telemetry_export_jsonl :: proc(
	sink: ^Telemetry_Sink,
	allocator := context.allocator,
) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	if sink != nil {
		for ev in sink.events {
			strings.write_string(&b, `{"type":"span","phase":`)
			write_json_escaped_string(&b, telemetry_phase_names[ev.phase])
			strings.write_string(&b, `,"name":`)
			write_json_escaped_string(&b, ev.name)
			fmt.sbprintf(
				&b,
				`,"parent_idx":%d,"depth":%d,"start_ns":%d,"duration_ns":%d,"alloc_bytes_delta":%d`,
				ev.parent_idx,
				ev.depth,
				ev.start_ns,
				ev.duration_ns,
				ev.alloc_bytes_delta,
			)
			strings.write_string(&b, "}\n")
		}

		strings.write_string(&b, `{"type":"summary",`)
		fmt.sbprintf(
			&b,
			`"peak_heap_bytes":%d,"peak_arena_bytes":%d,"live_session_memories":%d,"counters":`,
			sink.watermarks.peak_heap_bytes,
			sink.watermarks.peak_arena_bytes,
			sink.watermarks.live_session_memories,
		)
		strings.write_byte(&b, '{')
		for counter in Telemetry_Counter {
			if int(counter) > 0 {
				strings.write_byte(&b, ',')
			}
			write_json_escaped_string(&b, telemetry_counter_names[counter])
			fmt.sbprintf(&b, ":%d", sink.counters[counter])
		}
		strings.write_string(&b, "}}\n")
	}

	return strings.to_string(b), nil
}

@(require_results)
telemetry_export_chrome_trace :: proc(
	sink: ^Telemetry_Sink,
	allocator := context.allocator,
) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	strings.write_string(&b, `{"traceEvents":[`)
	if sink != nil {
		for ev, idx in sink.events {
			if idx > 0 {
				strings.write_byte(&b, ',')
			}
			ts_us := f64(ev.start_ns) / 1000.0
			dur_us := f64(ev.duration_ns) / 1000.0
			strings.write_string(&b, `{"name":`)
			write_json_escaped_string(&b, ev.name)
			strings.write_string(&b, `,"cat":`)
			write_json_escaped_string(&b, telemetry_phase_names[ev.phase])
			fmt.sbprintf(
				&b,
				`,"ph":"X","ts":%.3f,"dur":%.3f,"pid":1,"tid":1,"args":`,
				ts_us,
				dur_us,
			)
			strings.write_byte(&b, '{')
			fmt.sbprintf(
				&b,
				`"parent_idx":%d,"depth":%d,"alloc_bytes_delta":%d`,
				ev.parent_idx,
				ev.depth,
				ev.alloc_bytes_delta,
			)
			strings.write_string(&b, "}}")
		}
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b), nil
}

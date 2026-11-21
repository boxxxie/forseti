package forseti

import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"

String_Interner :: struct {
	arena:   vmem.Arena,
	strings: [dynamic]string,
	lookup:  map[string]String_Id,
}

@(require_results)
interner_init :: proc(
	s: ^String_Interner,
	allocator := context.allocator,
) -> (err: mem.Allocator_Error) {
	vmem.arena_init_growing(&s.arena) or_return
	defer if err != nil {
		interner_destroy(s)
	}

	s.strings = make([dynamic]string, 0, 64, allocator) or_return
	s.lookup = make(map[string]String_Id, 64, allocator) or_return
	append(&s.strings, "") or_return
	s.lookup[""] = EMPTY_STRING
	return nil
}

interner_destroy :: proc(s: ^String_Interner) {
	vmem.arena_check_temp(&s.arena)
	delete(s.lookup)
	delete(s.strings)
	vmem.arena_destroy(&s.arena)
	s^ = {}
}

@(require_results)
intern :: proc(s: ^String_Interner, text: string) -> (id: String_Id, err: mem.Allocator_Error) {
	if existing, ok := s.lookup[text]; ok {
		return existing, nil
	}
	reserve(&s.strings, len(s.strings) + 1) or_return
	reserve(&s.lookup, len(s.lookup) + 1) or_return
	cloned := strings.clone(text, vmem.arena_allocator(&s.arena)) or_return
	id = String_Id(len(s.strings))
	append(&s.strings, cloned) or_return
	s.lookup[cloned] = id
	return id, nil
}

interner_get :: proc "contextless" (s: ^String_Interner, id: String_Id) -> string {
	idx := int(id)
	if idx < 0 || idx >= len(s.strings) {
		return ""
	}
	return s.strings[idx]
}

interner_len :: proc "contextless" (s: ^String_Interner) -> int {
	return len(s.strings)
}

@(require_results)
compute_line_starts :: proc(
	src: string,
	allocator := context.allocator,
) -> (starts: [dynamic]u32, err: mem.Allocator_Error) {
	starts = make([dynamic]u32, 0, 32, allocator) or_return
	defer if err != nil {
		delete(starts)
	}
	append(&starts, 0) or_return
	for i := 0; i < len(src); i += 1 {
		if src[i] == '\n' {
			append(&starts, u32(i + 1)) or_return
		}
	}
	return starts, nil
}

resolve_line_col :: proc "contextless" (line_starts: []u32, offset: u32) -> (line, col: u32) {
	if len(line_starts) == 0 {
		return 1, offset + 1
	}
	lo := 0
	hi := len(line_starts)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if line_starts[mid] <= offset {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	line_idx := max(lo - 1, 0)
	return u32(line_idx + 1), offset - line_starts[line_idx] + 1
}

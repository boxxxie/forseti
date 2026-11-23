package forseti_lsp

import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import "../forseti"

Lsp_Pos :: struct {
	line:      u32,
	character: u32,
}

Lsp_Range :: struct {
	start: Lsp_Pos,
	end:   Lsp_Pos,
}

compute_line_starts :: proc(src: string, allocator := context.allocator) -> (starts: [dynamic]u32, err: mem.Allocator_Error) {
	starts = make([dynamic]u32, 0, 32, allocator) or_return
	append(&starts, 0) or_return
	for i := 0; i < len(src); i += 1 {
		if src[i] == '\n' {
			append(&starts, u32(i + 1)) or_return
		}
	}
	return starts, nil
}

byte_offset_to_lsp_pos :: proc "contextless" (src: string, line_starts: []u32, byte_off: u32) -> Lsp_Pos {
	off := min(int(byte_off), len(src))
	if len(line_starts) == 0 {
		return Lsp_Pos{line = 0, character = 0}
	}

	lo := 0
	hi := len(line_starts) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if int(line_starts[mid]) <= off {
			lo = mid
		} else {
			hi = mid - 1
		}
	}

	line_start := int(line_starts[lo])
	utf16_col := u32(0)
	pos := line_start
	for pos < off {
		r, w := utf8.decode_rune_in_string(src[pos:])
		step := max(w, 1)
		if pos + step > off {
			break
		}
		if r >= 0x10000 {
			utf16_col += 2
		} else {
			utf16_col += 1
		}
		pos += step
	}
	return Lsp_Pos{line = u32(lo), character = utf16_col}
}

lsp_pos_to_byte_offset :: proc "contextless" (src: string, line_starts: []u32, pos: Lsp_Pos) -> u32 {
	if len(line_starts) == 0 {
		return 0
	}
	line_idx := min(int(pos.line), len(line_starts) - 1)
	line_start := int(line_starts[line_idx])
	line_end := len(src)
	if line_idx + 1 < len(line_starts) {
		line_end = int(line_starts[line_idx + 1]) - 1
		if line_end > line_start && src[line_end - 1] == '\r' {
			line_end -= 1
		}
	}

	cur := line_start
	u16_count := u32(0)
	for cur < line_end && u16_count < pos.character {
		r, w := utf8.decode_rune_in_string(src[cur:line_end])
		step := max(w, 1)
		units := u32(2) if r >= 0x10000 else u32(1)
		if u16_count + units > pos.character {
			break
		}
		u16_count += units
		cur += step
	}
	return u32(cur)
}

span_to_lsp_range :: proc "contextless" (src: string, line_starts: []u32, span: forseti.Span) -> Lsp_Range {
	start := byte_offset_to_lsp_pos(src, line_starts, span.offset)
	end := byte_offset_to_lsp_pos(src, line_starts, span.offset + span.len)
	return Lsp_Range{start = start, end = end}
}

apply_lsp_edit :: proc(
	src: string,
	range: Lsp_Range,
	new_text: string,
	allocator := context.allocator,
) -> (out: string, err: mem.Allocator_Error) {
	starts := compute_line_starts(src, allocator) or_return
	defer delete(starts)

	start_off := int(lsp_pos_to_byte_offset(src, starts[:], range.start))
	end_off := int(lsp_pos_to_byte_offset(src, starts[:], range.end))
	if end_off < start_off {
		end_off = start_off
	}
	return strings.concatenate({src[:start_off], new_text, src[end_off:]}, allocator)
}

write_json_escaped :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		switch ch {
		case '"':  strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case:
			if ch < 0x20 {
				strings.write_string(b, `\u00`)
				hex := "0123456789abcdef"
				strings.write_byte(b, hex[(ch >> 4) & 0xf])
				strings.write_byte(b, hex[ch & 0xf])
			} else {
				strings.write_byte(b, ch)
			}
		}
	}
	strings.write_byte(b, '"')
}

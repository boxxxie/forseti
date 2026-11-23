package forseti_lsp

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

format_lsp_frame :: proc(payload: string, allocator := context.allocator) -> (frame: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	fmt.sbprintf(&b, "Content-Length: %d\r\n\r\n%s", len(payload), payload)
	return strings.to_string(b), nil
}

parse_lsp_frame :: proc(buf: string) -> (payload: string, rest: string, ok: bool) {
	sep_idx := strings.index(buf, "\r\n\r\n")
	sep_len := 4
	if sep_idx < 0 {
		sep_idx = strings.index(buf, "\n\n")
		sep_len = 2
	}
	if sep_idx < 0 {
		return "", buf, false
	}

	headers := buf[:sep_idx]
	content_len := -1
	pos := 0
	for pos < len(headers) {
		nl := strings.index_byte(headers[pos:], '\n')
		line_end := len(headers) if nl < 0 else pos + nl
		line := strings.trim_space(headers[pos:line_end])
		if len(line) > 0 {
			if colon := strings.index_byte(line, ':'); colon > 0 {
				key := strings.trim_space(line[:colon])
				if strings.equal_fold(key, "Content-Length") {
					val_str := strings.trim_space(line[colon + 1:])
					if v, pok := strconv.parse_int(val_str); pok && v >= 0 {
						content_len = v
					}
				}
			}
		}
		if nl < 0 {
			break
		}
		pos = line_end + 1
	}

	body_start := sep_idx + sep_len
	if content_len < 0 || body_start + content_len > len(buf) {
		return "", buf, false
	}
	return buf[body_start:body_start + content_len], buf[body_start + content_len:], true
}

read_lsp_frame :: proc(f: ^os.File, allocator := context.allocator) -> (payload: string, eof: bool, ok: bool) {
	hdr := make([dynamic]byte, 0, 128, allocator)
	defer delete(hdr)

	one: [1]byte
	content_len := -1
	for {
		n, err := os.read(f, one[:])
		if n == 0 || err != nil {
			return "", len(hdr) == 0, false
		}
		append(&hdr, one[0])
		cur := string(hdr[:])
		if strings.has_suffix(cur, "\r\n\r\n") || strings.has_suffix(cur, "\n\n") {
			pos := 0
			for pos < len(cur) {
				nl := strings.index_byte(cur[pos:], '\n')
				line_end := len(cur) if nl < 0 else pos + nl
				line := strings.trim_space(cur[pos:line_end])
				if colon := strings.index_byte(line, ':'); colon > 0 {
					if strings.equal_fold(strings.trim_space(line[:colon]), "Content-Length") {
						if v, pok := strconv.parse_int(strings.trim_space(line[colon + 1:])); pok && v >= 0 {
							content_len = v
						}
					}
				}
				if nl < 0 {
					break
				}
				pos = line_end + 1
			}
			break
		}
	}

	if content_len < 0 {
		return "", false, false
	}
	body := make([]byte, content_len, allocator)
	got := 0
	for got < content_len {
		n, err := os.read(f, body[got:])
		if n <= 0 || err != nil {
			delete(body, allocator)
			return "", false, false
		}
		got += n
	}
	return string(body), false, true
}

write_lsp_frame :: proc(f: ^os.File, payload: string) -> bool {
	frame, err := format_lsp_frame(payload, context.temp_allocator)
	if err != nil {
		return false
	}
	raw := transmute([]byte)frame
	written := 0
	for written < len(raw) {
		n, w_err := os.write(f, raw[written:])
		if n <= 0 || w_err != nil {
			return false
		}
		written += n
	}
	return true
}

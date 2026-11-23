package bench_render

import "core:strings"
import "core:testing"

@(test)
test_duration_and_throughput_formatting :: proc(t: ^testing.T) {
	p := fmt_ns(0.77558, context.temp_allocator)
	n := fmt_ns(42.9, context.temp_allocator)
	u := fmt_ns(20172.18, context.temp_allocator)
	m := fmt_ns(32_349_291.5, context.temp_allocator)
	s := fmt_ns(1_942_309_878.5, context.temp_allocator)
	defer free_all(context.temp_allocator)

	testing.expect_value(t, p, "775.58 ps")
	testing.expect_value(t, n, "42.90 ns")
	testing.expect_value(t, u, "20.17 us")
	testing.expect_value(t, m, "32.35 ms")
	testing.expect_value(t, s, "1.942 s")

	ops_b := fmt_ops(1_289_362_629.0, context.temp_allocator)
	testing.expect_value(t, ops_b, "1.29B/s")
}

@(test)
test_temple_templates_render_clean_svg_and_markdown :: proc(t: ^testing.T) {
	x_labels := [2]string{"10", "100"}
	vals := [2]Maybe(f64){100.0, 200.0}
	v_line, ok := build_line_chart_view(
		"Test & Title",
		"Sub",
		x_labels[:],
		{{label = "s1", values = vals[:], color = "#58a6ff"}},
		y_log = true,
		y_unit_label = "Log10",
		allocator = context.temp_allocator,
	)
	defer free_all(context.temp_allocator)
	testing.expect(t, ok)

	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	_, err := line_chart_tmpl.with(strings.to_writer(&sb), v_line)
	testing.expect_value(t, err, nil)
	svg := strings.to_string(sb)
	testing.expect(t, strings.contains(svg, "<svg"))
	testing.expect(t, strings.contains(svg, "Test &amp; Title"))
	testing.expect(t, strings.contains(svg, "200.00 ns"))
}

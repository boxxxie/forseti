package forseti_specs

import "core:mem"
import "../forseti"

driver_record_bootstrap_telemetry :: proc(sink: ^forseti.Telemetry_Sink) {
	sc := forseti.telemetry_span_begin(sink, .Custom, "harness_bootstrap")
	forseti.telemetry_span_end(sink, sc)
}

driver_compile_external :: proc(
	src: string,
	filename: string,
	out_ir: ^forseti.Rulebase_IR,
	diags: ^forseti.Diagnostic_List,
	telemetry: ^forseti.Telemetry_Sink,
) -> mem.Allocator_Error {
	ir, err := forseti.compile_source(src, filename, diags, telemetry)
	if err != nil {
		return err
	}
	out_ir^ = ir
	return nil
}

driver_compile_internal :: proc(
	builder: ^forseti.Ir_Builder,
	out_ir: ^forseti.Rulebase_IR,
	diags: ^forseti.Diagnostic_List,
	telemetry: ^forseti.Telemetry_Sink,
) -> mem.Allocator_Error {
	ir, err := forseti.ir_builder_build(builder, diags, telemetry)
	if err != nil {
		return err
	}
	out_ir^ = ir
	return nil
}

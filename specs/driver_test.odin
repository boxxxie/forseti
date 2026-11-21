package forseti_specs

import "../forseti"

driver_record_bootstrap_telemetry :: proc(sink: ^forseti.Telemetry_Sink) {
	sc := forseti.telemetry_span_begin(sink, .Custom, "harness_bootstrap")
	forseti.telemetry_span_end(sink, sc)
}

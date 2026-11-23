package main

import "core:fmt"
import "core:os"
import "../../lsp"

main :: proc() {
	for arg in os.args[1:] {
		if arg == "-h" || arg == "--help" {
			fmt.println("Usage: forseti-lsp (JSON-RPC 2.0 stdio Language Server)")
			return
		}
	}
	exit_code := lsp.server_run_stdio()
	if exit_code != 0 {
		os.exit(exit_code)
	}
}

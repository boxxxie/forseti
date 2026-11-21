#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF_DIR="$ROOT_DIR/reference"
mkdir -p "$REF_DIR"

clone_shallow() {
	local name="$1"
	local url="$2"
	local dest="$REF_DIR/$name"
	if [[ -d "$dest/.git" ]]; then
		echo "[skip] $name already exists"
		return 0
	fi
	echo "[clone] $name <- $url"
	git clone --depth 1 --quiet "$url" "$dest"
}

clone_sparse() {
	local name="$1"
	local url="$2"
	shift 2
	local paths=("$@")
	local dest="$REF_DIR/$name"
	if [[ -d "$dest/.git" ]]; then
		echo "[skip] $name already exists"
		return 0
	fi
	echo "[sparse-clone] $name <- $url (${paths[*]})"
	git clone --depth 1 --filter=blob:none --sparse --no-checkout --quiet "$url" "$dest"
	git -C "$dest" sparse-checkout init --cone
	git -C "$dest" sparse-checkout set "${paths[@]}"
	git -C "$dest" checkout --quiet
}

# Full shallow clones (parallelized in batches)
clone_shallow tablex https://github.com/elixir-tablex/tablex.git &
clone_shallow runic https://github.com/zblanco/runic.git &
clone_shallow zen https://github.com/gorules/zen.git &
clone_shallow clara-rules https://github.com/oracle-samples/clara-rules.git &
clone_shallow odoyle-rules https://github.com/oakes/odoyle-rules.git &
clone_shallow pararules https://github.com/paranim/pararules.git &
wait

clone_shallow soar https://github.com/SoarGroup/Soar.git &
clone_shallow clips https://github.com/ricksladkey/CLIPS.git &
clone_shallow ascent https://github.com/s-arash/ascent.git &
clone_shallow souffle https://github.com/souffle-lang/souffle.git &
clone_shallow egglog https://github.com/egraphs-good/egglog.git &
wait

clone_shallow propaganda https://github.com/tgk/propaganda.git &
clone_shallow propagators-chirho https://github.com/loveJesus/propagators-chirho.git &
clone_shallow provsql https://github.com/PierreSenellart/provsql.git &
wait

# Sparse shallow clones for large monorepos (verified HEAD paths)
clone_sparse drools https://github.com/apache/incubator-kie-drools.git \
	drools-core drools-tms drools-alphanetwork-compiler drools-decisiontables drools-drl &
clone_sparse feldera-dbsp https://github.com/feldera/feldera.git crates/dbsp &
wait

echo "Done. Reference repositories are in $REF_DIR"

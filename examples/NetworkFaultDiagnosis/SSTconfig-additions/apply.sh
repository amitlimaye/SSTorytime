#!/bin/sh
# Append the agent-intent-drift arrow definitions to an SSTorytime SSTconfig
# directory. Idempotent: a file that already carries the marker is skipped.
#
#   usage: ./apply.sh /path/to/SSTorytime/SSTconfig
#
# N4L only reads the five fixed filenames in SSTconfig/, so new arrows have
# to be appended to the existing files rather than added as a new file.
#
# NOTE: arrows are cached in the database. After applying, reload with
#   N4L -wipe -u ...
# or the old arrow table will mask the new definitions.

set -e

target="${1:-}"
if [ -z "$target" ] || [ ! -d "$target" ]; then
	echo "usage: $0 /path/to/SSTorytime/SSTconfig" >&2
	exit 1
fi

here=$(cd "$(dirname "$0")" && pwd)
marker="BEGIN network-fault-diagnosis arrows"

for f in arrows-LT-1 arrows-NR-0 arrows-CN-2 arrows-EP-3; do
	src="$here/$f.add.sst"
	dst="$target/$f.sst"
	if [ ! -f "$dst" ]; then
		echo "skip: $dst does not exist" >&2
		continue
	fi
	if grep -q "$marker" "$dst"; then
		echo "skip: $dst already patched"
		continue
	fi
	cat "$src" >> "$dst"
	echo "patched: $dst"
done

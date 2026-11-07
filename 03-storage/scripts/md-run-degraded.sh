#!/bin/bash

udevadm settle --timeout=30

for st in /sys/block/md*/md/array_state; do
	[ -e "$st" ] || continue
	md=$(basename "$(dirname "$(dirname "$st")")")
	if [ "$(cat "$st")" = "inactive" ]; then
		logger -t md-degraded "$md inactive, starting degraded"
		mdadm --run "/dev/$md" && logger -t md-degraded "$md started"
	fi
done
exit 0

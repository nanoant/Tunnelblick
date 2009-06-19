#!/bin/sh -e
trap "" TSTP
trap "" HUP
trap "" INT
export PATH="/bin:/sbin:/usr/sbin:/usr/bin"

# Find the primary service ID and unload the OpenVPN marker
PSID="$( (scutil | grep Service | sed -e 's/.*Service : //')<<- EOF
	open
	show State:/Network/OpenVPN
	quit
EOF)"

# Unload the lease watcher
LEASE_WATCHER="$(dirname "${0}")/LeaseWatch.plist"
launchctl unload "${LEASE_WATCHER}"

# Restore configurations
scutil <<- EOF
	open
	get State:/Network/OpenVPN/OldDNS
	set State:/Network/Service/${PSID}/DNS
	remove State:/Network/OpenVPN/OldDNS
	remove State:/Network/OpenVPN/DNS
	remove State:/Network/OpenVPN
	quit
EOF

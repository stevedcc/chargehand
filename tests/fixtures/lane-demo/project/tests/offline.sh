#!/usr/bin/env bash
# Passes only when the suite has no outbound network.
if wget -q -T 5 -O /dev/null https://example.com; then
    echo "Failed!  - reached https://example.com from the suites phase"
    exit 1
fi
echo "Passed!  - no outbound network"

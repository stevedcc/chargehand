#!/usr/bin/env bash
# Passes only when the service "db" answers on db:5432.
if nc -z -w 5 db 5432; then
    echo "Passed!  - reached db:5432"
else
    echo "Failed!  - db:5432 unreachable"
    exit 1
fi

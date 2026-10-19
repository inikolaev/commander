#!/bin/bash
# Source from scripts using set -e. Preserve command output and its final exit code.
retry_apple_network() {
    local attempt status work
    work=$(mktemp -d "${TMPDIR:-/tmp}/commander-apple-retry.XXXXXX") || return 1
    for attempt in 1 2 3; do
        if "$@" > "$work/stdout" 2> "$work/stderr"; then
            cat "$work/stdout"
            cat "$work/stderr" >&2
            rm -rf "$work"
            return 0
        else
            status=$?
        fi
        cat "$work/stderr" >&2
        if [[ "$attempt" == 3 ]] || ! grep -Eiq \
            'NSURLErrorDomain.*Code=-100[134569]|timestamp service is not available|network connection.*lost|timed out|timeout|Could not connect|CloudKit.*(inconsistent|unavailable)|HTTP[^0-9]*(429|502|503|504)' \
            "$work/stdout" "$work/stderr"; then
            cat "$work/stdout"
            rm -rf "$work"
            return "$status"
        fi
        # Diagnostics go to stderr so JSON-producing commands remain parseable.
        cat "$work/stdout" >&2
        printf 'Transient Apple network failure; retry %s/3 in %ss.\n' "$((attempt + 1))" "$((attempt * 15))" >&2
        sleep "$((attempt * 15))"
    done
}

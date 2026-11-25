#!/bin/bash
# Sourced by build-app.sh and make-signing-cert.sh (and tested by check-signing.sh).
MOLE_REVIEW_IDENTITY="Mole Review Local"

# Prints the SHA-1 of the first valid code-signing identity named "Mole Review Local", or
# nothing. The hash, not the name, goes to codesign: two identities of one name make
# `codesign -s <name>` fail as ambiguous. The list is captured first and read with awk from
# a here-string, so no `grep -q` or `head` closes a pipe on `security` (SIGPIPE would fail
# the pipeline under pipefail and hide an identity that exists).
mole_review_identity_hash() {
    local ids
    ids=$(security find-identity -v -p codesigning 2> /dev/null) || ids=""
    awk -v id="\"$MOLE_REVIEW_IDENTITY\"" 'index($0, id) { print $2; exit }' <<< "$ids"
}

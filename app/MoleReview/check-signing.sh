#!/bin/bash
# Checks signing-identity.sh against a stubbed `security`: several identities (the first
# hash wins, so a duplicate cannot make codesign ambiguous), none, other names only, and a
# list long enough that an early-exiting reader would take SIGPIPE on the writer.
set -euo pipefail
cd "$(dirname "$0")"
source ./signing-identity.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT # SAFE: removes only the mktemp directory created above
mkdir "$work/bin"
cat > "$work/bin/security" << 'STUB'
#!/bin/bash
[[ "$*" == "find-identity -v -p codesigning" ]] || exit 2
cat "$STUB_IDENTITIES"
STUB
chmod +x "$work/bin/security"
export PATH="$work/bin:$PATH"
fail=0
expect() { # name, expected, list file
    STUB_IDENTITIES="$3" bash -c 'source ./signing-identity.sh; set -o pipefail; mole_review_identity_hash' > "$work/got" || true
    if [[ "$(cat "$work/got")" == "$2" ]]; then echo "ok   $1"; else
        echo "FAIL $1 (got '$(cat "$work/got")')"
        fail=1
    fi
}
{
    echo '  1) AAAA1111AAAA1111AAAA1111AAAA1111AAAA1111 "Mole Review Local"'
    echo '  2) BBBB2222BBBB2222BBBB2222BBBB2222BBBB2222 "Mole Review Local"'
    echo '     2 valid identities found'
} > "$work/two"
expect "two identities of the name: the first hash only" AAAA1111AAAA1111AAAA1111AAAA1111AAAA1111 "$work/two"
{
    echo '  1) CCCC3333CCCC3333CCCC3333CCCC3333CCCC3333 "Developer ID Application: Sample"'
    echo '     1 valid identities found'
} > "$work/other"
expect "another identity only: none" "" "$work/other"
printf '     0 valid identities found\n' > "$work/none"
expect "no identities: none" "" "$work/none"
{
    echo '  1) AAAA1111AAAA1111AAAA1111AAAA1111AAAA1111 "Mole Review Local"'
    for i in $(seq 2 20000); do printf '  %d) %040d "Sample Identity %d"\n' "$i" "$i" "$i"; done
} > "$work/long"
expect "a long list (first match early): found, no SIGPIPE failure" AAAA1111AAAA1111AAAA1111AAAA1111AAAA1111 "$work/long"
bash -n build-app.sh && bash -n make-signing-cert.sh && echo "ok   syntax"
exit "$fail"

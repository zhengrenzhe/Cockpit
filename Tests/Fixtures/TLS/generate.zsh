#!/bin/zsh
set -euo pipefail

umask 077
fixture_root=${0:A:h}
output="$fixture_root/generated"
fixture_root_real=$(cd "$fixture_root" && pwd -P)

case "$output" in
    "$fixture_root_real"/generated) ;;
    *) print -u2 "Refusing unsafe TLS fixture output path: $output"; exit 1 ;;
esac

if [[ -L "$output" ]]; then
    print -u2 "Refusing symlinked TLS fixture output path: $output"
    exit 1
fi

if [[ -e "$output" && ! -d "$output" ]]; then
    print -u2 "Refusing non-directory TLS fixture output path: $output"
    exit 1
fi

if [[ -d "$output" ]]; then
    output_real=$(cd "$output" && pwd -P)
    if [[ "$output_real" != "$fixture_root_real/generated" ]]; then
        print -u2 "Refusing TLS fixture output outside fixture root: $output_real"
        exit 1
    fi
fi

/bin/rm -rf -- "$output"
/bin/mkdir -p "$output"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$output/key.pem" \
  -out "$output/certificate.pem" \
  -days 2 -subj '/CN=localhost'
/usr/bin/openssl pkcs12 -export \
  -inkey "$output/key.pem" \
  -in "$output/certificate.pem" \
  -out "$output/identity.p12" \
  -passout pass:cockpit-test

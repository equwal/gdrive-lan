#!/bin/sh
# End-to-end check of gdrive.lan on g: nginx guard, folder and file upload, decrypted browse, ciphertext on Drive.
# Run as jose on g. Leaves nothing behind on the drive.
set -u
R=/home/jose/.local/state/nix/profiles/extra/bin/rclone
U=http://gdrive.lan
fail=0
chk() { n=$1; shift; if "$@"; then echo "ok   $n"; else echo "FAIL $n"; fail=1; fi; }
is() { [ "$1" = "$2" ]; }
code() { curl -gs -o /dev/null -w '%{http_code}' "$@"; }
jobid() { tr -d '\n' | sed -n 's/.*"jobid": *\([0-9]*\).*/\1/p'; }
post() { curl -gs -H 'Content-Type: application/json' -H "Origin: $2" -d "$3" "$U/$1"; }

# Guard: destructive rc methods and foreign origins get 403; raw (unencrypted) and local remotes are not served.
chk "purge blocked" is "$(code -X POST "$U/operations/purge?fs=gcrypt:&remote=x")" 403
chk "sync/sync blocked" is "$(code -X POST "$U/sync/sync?srcFs=/tmp&dstFs=gcrypt:")" 403
chk "foreign origin blocked" is "$(code -X POST -H 'Origin: http://evil.example' "$U/core/stats")" 403
chk "local fs not served" is "$(code "$U/%5B/etc%5D/passwd")" 403
chk "raw gdrive not served" is "$(code "$U/[gdrive:]/")" 403
# torrents.lan proxies only its allowlist to rcd; anything else falls through to rtweb, which answers 404.
chk "torrents.lan purge not proxied" is \
  "$(code -X POST -H 'Origin: http://torrents.lan' http://torrents.lan/gdrive/operations/purge)" 404
chk "own origin allowed" is "$(code -X POST -H 'Origin: http://gdrive.lan' "$U/core/stats")" 200

# Upload a folder and a single file the way the two pages do, then wait for both jobs.
T=$(mktemp -d)
N=gdrive-lan-test-$$
mkdir "$T/dir" && echo folder-body > "$T/dir/a.txt" && echo file-body > "$T/one.iso"
# Both pages make the parent first: two jobs that each create a new folder make two folders of that name on Drive.
chk "mkdir via torrents.lan" is "$(code -H 'Content-Type: application/json' -H 'Origin: http://torrents.lan' \
  -d "{\"fs\":\"gcrypt:\",\"remote\":\"$N\"}" http://torrents.lan/gdrive/operations/mkdir)" 200
j1=$(post sync/copy http://gdrive.lan "{\"srcFs\":\"$T/dir\",\"dstFs\":\"gcrypt:$N/dir\",\"_async\":true,\"_group\":\"gcrypt:$N/dir\"}" | jobid)
j2=$(curl -gs -H 'Content-Type: application/json' -H 'Origin: http://torrents.lan' http://torrents.lan/gdrive/operations/copyfile \
  -d "{\"srcFs\":\"$T\",\"srcRemote\":\"one.iso\",\"dstFs\":\"gcrypt:$N\",\"dstRemote\":\"one.iso\",\"_async\":true}" | jobid)
chk "jobs started ($j1, $j2)" [ -n "$j1" -a -n "$j2" ]
for j in $j1 $j2; do
  # rclone's shared Drive client_id hits RATE_LIMIT_EXCEEDED often; rclone retries, so allow 5 minutes.
  for _ in $(seq 150); do
    s=$(post job/status http://gdrive.lan "{\"jobid\":$j}")
    case $s in *'"finished": true'*) break ;; esac
    sleep 2
  done
  case $s in *'"success": true'*) chk "job $j succeeded" true ;; *) chk "job $j succeeded: $s" false ;; esac
done
chk "one folder named $N" is "$(post operations/list http://gdrive.lan '{"fs":"gcrypt:","remote":""}' | grep -c "\"Name\": \"$N\"")" 1

# The page lists uploads by stats group.
chk "upload listed by group" grep -q "\"gcrypt:$N/dir\"" <<EOF
$(post core/group-list http://gdrive.lan '{}')
EOF

# Browse: decrypted names and contents through rc-serve.
chk "browse lists one.iso" grep -q one.iso <<EOF
$(curl -gs "$U/[gcrypt:$N]/")
EOF
body=$(curl -gs "$U/[gcrypt:$N]/dir/a.txt")
chk "download decrypts" is "$body" folder-body
[ "$body" = folder-body ] || echo "     got: $(echo "$body" | head -c 300)"

# Drive itself holds only ciphertext names.
raw=$($R lsf -R gdrive:crypt 2>/dev/null)
chk "Drive has entries" [ -n "$raw" ]
chk "Drive has no plaintext names" is "$(echo "$raw" | grep -c -e "$N" -e one.iso -e a.txt)" 0

# Purge until gone: a duplicate folder (see mkdir above) needs one purge per copy.
for _ in 1 2 3; do
  curl -s -o /dev/null -H 'Content-Type: application/json' -d "{\"fs\":\"gcrypt:\",\"remote\":\"$N\"}" http://127.0.0.1:8103/operations/purge
done
rm -rf "$T"
exit $fail

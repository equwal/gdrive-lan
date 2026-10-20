#!/bin/sh
# Move the gcrypt crypt passwords out of jose's rclone.conf into /etc/keys/gcrypt.env (root 0400).
# /etc/keys sits on the LUKS root next to the cryptsetup keyfiles of the 4tb and 1tb disks.
# Run as root on g. Refuses to touch anything if the conf and crypt-passwords.txt disagree.
set -eu
R=/home/jose/.local/state/nix/profiles/extra/bin/rclone
C=/home/jose/.config/rclone/rclone.conf
P=/home/jose/.config/rclone/crypt-passwords.txt
ENV=/etc/keys/gcrypt.env
[ -e "$ENV" ] && { echo "$ENV exists; nothing to do"; exit 0; }

val() { sed -n '/^\[gcrypt\]/,/^\[/s/^'"$1"' = //p' "$C"; }
pw=$(val password); pw2=$(val password2)
[ -n "$pw" ] && [ -n "$pw2" ] || { echo "no gcrypt passwords in $C"; exit 1; }
if [ -e "$P" ]; then
  [ "$($R reveal "$pw")" = "$(sed -n 's/^password=//p' "$P")" ] &&
  [ "$($R reveal "$pw2")" = "$(sed -n 's/^salt=//p' "$P")" ] || { echo "$C and $P disagree"; exit 1; }
fi

umask 077
printf 'RCLONE_CONFIG_GCRYPT_PASSWORD=%s\nRCLONE_CONFIG_GCRYPT_PASSWORD2=%s\n' "$pw" "$pw2" > "$ENV"
chmod 0400 "$ENV"
sed -i '/^\[gcrypt\]/,/^\[/{/^password2\{0,1\} = /d}' "$C"
[ -e "$P" ] && { install -m 0400 -o root -g root "$P" /etc/keys/gcrypt-passwords.txt && rm "$P"; }
echo "moved gcrypt passwords to $ENV"

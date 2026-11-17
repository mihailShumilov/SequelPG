#!/bin/sh
# Install the pre-generated (pinned) host key and the client public key with
# the ownership/permissions sshd insists on, then run sshd in the foreground.
set -eu
install -m 600 /keys/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key
install -m 644 /keys/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ed25519_key.pub
install -d -m 700 -o "$TUNNEL_USER" -g "$TUNNEL_USER" "/home/$TUNNEL_USER/.ssh"
install -m 600 -o "$TUNNEL_USER" -g "$TUNNEL_USER" /keys/client_ed25519.pub "/home/$TUNNEL_USER/.ssh/authorized_keys"
echo "$TUNNEL_USER:$TUNNEL_PASSWORD" | chpasswd
exec /usr/sbin/sshd -D -e

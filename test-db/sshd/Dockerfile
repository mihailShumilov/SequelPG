# Minimal SSH bastion for tunnel tests: key + password auth, TCP forwarding
# only (no shell needed by the app, but kept for debugging).
FROM alpine:3.20
RUN apk add --no-cache openssh-server netcat-openbsd \
 && adduser -D -s /bin/sh tunnel
COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]

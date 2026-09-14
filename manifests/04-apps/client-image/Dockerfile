# Non-root client image for the demo/"attacker" pods in clientspace.
# Bakes redis-cli, psql, curl, dig and nc so plan 04/05/09 exec commands work
# without any boot-time package install (and without running as root).
FROM alpine:3.20

RUN apk add --no-cache \
      redis \
      postgresql-client \
      curl \
      bind-tools \
      netcat-openbsd \
 && addgroup -g 65532 client \
 && adduser -D -u 65532 -G client client

USER 65532:65532
ENTRYPOINT ["sleep", "infinity"]

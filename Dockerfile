# Bitnami Discourse accepts external Postgres/Redis via env vars.
# Production forum.societyprotocol.io stays on the current host until DNS moves.
FROM bitnamilegacy/discourse:3.5.0-debian-12-r0

ENV DISCOURSE_PORT_NUMBER=8080
ENV PORT=8080
EXPOSE 8080

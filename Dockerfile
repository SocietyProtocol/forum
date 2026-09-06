# Bitnami Discourse accepts external Postgres/Redis via env vars.
# Production forum.societyprotocol.io stays on the current host until DNS moves.
FROM bitnami/discourse:3.5.0

ENV DISCOURSE_PORT_NUMBER=8080
ENV PORT=8080
EXPOSE 8080

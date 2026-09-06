# Official prebuilt Discourse image used by Railway community templates.
# Production forum.societyprotocol.io stays on the current host until DNS moves.
FROM discourse/discourse:tests-passed

ENV UNICORN_BIND_ALL=true
ENV PORT=80
EXPOSE 80

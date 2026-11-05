# Discourse 2026.8.0-latest.1 for forum.societyprotocol.io.
FROM discourse/discourse:2026.8.0-latest.1

USER root
# The prebuilt image ships both discourse-calendar and discourse-events.
# Together they crash boot with MultiplePrependBlocks. Keep calendar.
COPY persist-uploads.sh /etc/runit/1.d/00-persist-uploads
COPY disable-events.sh /etc/runit/1.d/01-disable-events
COPY fix-nginx.sh /etc/runit/1.d/02-fix-nginx
COPY seed-uploads /opt/discourse-seed-uploads
# Plugin source. SIWE_REF is a full 40-char commit SHA and wins when set: the
# deploy script resolves it with git ls-remote, so every deploy fetches exactly
# that commit and a new SHA invalidates the cached layer. When SIWE_REF is empty
# (a manual docker build) the branch tip is cloned instead.
ARG SIWE_BRANCH=main
ARG SIWE_REF=
RUN chmod +x /etc/runit/1.d/00-persist-uploads /etc/runit/1.d/01-disable-events /etc/runit/1.d/02-fix-nginx \
  && rm -rf /var/www/discourse/plugins/discourse-events \
  && gem install rubyzip --no-document \
  && if [ -n "${SIWE_REF}" ]; then \
       { [ "${#SIWE_REF}" -eq 40 ] && case "${SIWE_REF}" in *[!0123456789abcdef]*) false ;; *) true ;; esac; } || { echo "SIWE_REF must be a full 40-char lowercase commit SHA" >&2; exit 1; }; \
       git init -q /var/www/discourse/plugins/discourse-siwe-auth \
         && git -C /var/www/discourse/plugins/discourse-siwe-auth remote add origin \
              https://github.com/SocietyProtocol/discourse-siwe-auth.git \
         && git -C /var/www/discourse/plugins/discourse-siwe-auth fetch -q --depth 1 origin "${SIWE_REF}" \
         && git -C /var/www/discourse/plugins/discourse-siwe-auth checkout -q FETCH_HEAD \
         && [ "$(git -C /var/www/discourse/plugins/discourse-siwe-auth rev-parse HEAD)" = "${SIWE_REF}" ] \
         || { echo "plugin checkout did not land on SIWE_REF ${SIWE_REF}" >&2; exit 1; }; \
     else \
       git clone --depth 1 --branch "${SIWE_BRANCH}" \
         https://github.com/SocietyProtocol/discourse-siwe-auth.git \
         /var/www/discourse/plugins/discourse-siwe-auth; \
     fi \
  && echo "discourse-siwe-auth HEAD: $(git -C /var/www/discourse/plugins/discourse-siwe-auth rev-parse HEAD)" \
  && chown -R discourse:discourse /var/www/discourse/plugins/discourse-siwe-auth \
  && mkdir -p /var/www/discourse/public/plugins/discourse-siwe-auth/javascripts \
  && cp /var/www/discourse/plugins/discourse-siwe-auth/public/javascripts/siwe.iife.js \
    /var/www/discourse/public/plugins/discourse-siwe-auth/javascripts/siwe.iife.js \
  && chown -R discourse:discourse /var/www/discourse/public/plugins/discourse-siwe-auth

# Boot precompile uses SKIP_EMBER_CLI_COMPILE=1, so SIWE Ember JS never
# lands in /assets. Compile it here, then skip the boot CSS-only pass.
WORKDIR /var/www/discourse
USER discourse
RUN SKIP_DB_AND_REDIS=1 LOAD_PLUGINS=1 bundle exec rake assets:precompile
USER root
ENV PRECOMPILE_ON_BOOT=0
ENV DISABLE_LETSENCRYPT=1
ENV UNICORN_WORKERS=2
# 8080 is a Railway leftover kept until the AWS proxy port is confirmed (see fix-nginx.sh).
ENV PORT=8080
EXPOSE 80 8080

# Labels go last so changing them never invalidates the expensive layers above.
# Keep the base.name tag in sync with the FROM line (scripts/test_placeholders.py checks).
# The plugin label shows the pinned SHA; "unpinned" means the branch tip was cloned
# and the real SHA is only in the build log ("discourse-siwe-auth HEAD: ...").
ARG FORUM_REVISION=unknown
LABEL org.opencontainers.image.base.name="discourse/discourse:2026.8.0-latest.1" \
      org.opencontainers.image.revision="${FORUM_REVISION}" \
      io.societyprotocol.discourse.tag="2026.8.0-latest.1" \
      io.societyprotocol.siwe-auth.ref="${SIWE_REF:-unpinned}" \
      io.societyprotocol.siwe-auth.branch="${SIWE_BRANCH}"
CMD ["/sbin/boot"]

# Match production forum.societyprotocol.io (Discourse 2026.8.0-latest.1).
# Production DNS stays on the current host until we move it.
FROM discourse/discourse:2026.8.0-latest.1

USER root
# The prebuilt image ships both discourse-calendar and discourse-events.
# Together they crash boot with MultiplePrependBlocks. Keep calendar.
COPY persist-uploads.sh /etc/runit/1.d/00-persist-uploads
COPY disable-events.sh /etc/runit/1.d/01-disable-events
COPY fix-nginx.sh /etc/runit/1.d/02-fix-nginx
COPY seed-uploads /opt/discourse-seed-uploads
RUN chmod +x /etc/runit/1.d/00-persist-uploads /etc/runit/1.d/01-disable-events /etc/runit/1.d/02-fix-nginx \
  && rm -rf /var/www/discourse/plugins/discourse-events \
  && gem install rubyzip --no-document \
  && git clone --depth 1 --branch railway-migration \
    https://github.com/SocietyProtocol/discourse-siwe-auth.git \
    /var/www/discourse/plugins/discourse-siwe-auth \
  && git -C /var/www/discourse/plugins/discourse-siwe-auth rev-parse HEAD \
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
ENV PORT=8080
EXPOSE 80 8080
CMD ["/sbin/boot"]

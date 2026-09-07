# Match production forum.societyprotocol.io (Discourse 2026.8.0-latest.1).
# Production DNS stays on the current host until we move it.
FROM discourse/discourse:2026.8.0-latest.1

USER root
# The prebuilt image ships both discourse-calendar and discourse-events.
# Together they crash boot with MultiplePrependBlocks. Keep calendar.
COPY disable-events.sh /etc/runit/1.d/00-disable-events
COPY fix-nginx.sh /etc/runit/1.d/01-fix-nginx
RUN chmod +x /etc/runit/1.d/00-disable-events /etc/runit/1.d/01-fix-nginx \
  && rm -rf /var/www/discourse/plugins/discourse-events \
  && gem install rubyzip --no-document \
  && git clone --depth 1 --branch railway-migration \
    https://github.com/SocietyProtocol/discourse-siwe-auth.git \
    /var/www/discourse/plugins/discourse-siwe-auth \
  && chown -R discourse:discourse /var/www/discourse/plugins/discourse-siwe-auth

ENV DISABLE_LETSENCRYPT=1
ENV UNICORN_WORKERS=2
ENV PORT=8080
EXPOSE 80 8080
CMD ["/sbin/boot"]

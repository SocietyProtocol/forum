# Match production forum.societyprotocol.io (Discourse 2026.8.0-latest.1).
# Production DNS stays on the current host until we move it.
FROM discourse/discourse:2026.8.0-latest.1

USER root
RUN gem install rubyzip --no-document \
  && git clone --depth 1 --branch railway-migration \
    https://github.com/SocietyProtocol/discourse-siwe-auth.git \
    /var/www/discourse/plugins/discourse-siwe-auth \
  && chown -R discourse:discourse /var/www/discourse/plugins/discourse-siwe-auth

ENV DISABLE_LETSENCRYPT=1
ENV UNICORN_WORKERS=2
ENV PORT=80
EXPOSE 80
CMD ["/sbin/boot"]

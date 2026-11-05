#!/bin/bash
# Also listen on 8080 in addition to 80 (Discourse nginx ships on 80 only).
# This began as a Railway workaround ($PORT=8080). It is KEPT on AWS on purpose:
# diagnostics on the box curl http://127.0.0.1:8080 inside the forum container,
# and the Caddy upstream / apps.yml port mapping for the forum services could not
# be read when this was reviewed. Remove it only after confirming nothing targets
# 8080 (see docs/UPGRADE.md, "Railway leftovers"). Removing the listener is safe;
# keeping it is harmless.
rm -f /etc/nginx/sites-enabled/default
conf=/etc/nginx/conf.d/outlets/server/10-http.conf
if [ -f "$conf" ] && ! grep -q "listen 8080" "$conf"; then
  sed -i 's/listen 80;/listen 80 default_server;\n  listen 8080 default_server;/' "$conf"
fi

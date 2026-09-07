#!/bin/bash
# Railway proxies to $PORT (often 8080). Discourse nginx ships on 80 only.
rm -f /etc/nginx/sites-enabled/default
conf=/etc/nginx/conf.d/outlets/server/10-http.conf
if [ -f "$conf" ] && ! grep -q "listen 8080" "$conf"; then
  sed -i 's/listen 80;/listen 80 default_server;\n  listen 8080 default_server;/' "$conf"
fi

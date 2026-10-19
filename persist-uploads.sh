#!/bin/bash
# Keep Discourse uploads on the persistent volume across image deploys.
VOL="${FORUM_VOLUME_PATH:-/shared}"
mkdir -p "$VOL/uploads" "$VOL/backups/default"
if [ -d /opt/discourse-seed-uploads ]; then
  cp -an /opt/discourse-seed-uploads/. "$VOL/uploads/" || true
fi
if [ "$VOL" != "/shared" ]; then
  if [ -L /shared ]; then
    rm -f /shared
  elif [ -d /shared ]; then
    cp -a /shared/. "$VOL/" || true
    rm -rf /shared
  fi
  ln -sfn "$VOL" /shared
fi
uploads=/var/www/discourse/public/uploads
if [ -L "$uploads" ]; then
  rm -f "$uploads"
elif [ -d "$uploads" ]; then
  cp -a "$uploads"/. "$VOL/uploads/" || true
  rm -rf "$uploads"
fi
ln -sfn "$VOL/uploads" "$uploads"
chown -R discourse:www-data "$VOL/uploads" "$VOL/backups"

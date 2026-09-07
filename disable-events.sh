#!/bin/bash
# The prebuilt Discourse image ships calendar and events together.
# Together they crash boot. Remove events before rake/unicorn start.
rm -rf /var/www/discourse/plugins/discourse-events

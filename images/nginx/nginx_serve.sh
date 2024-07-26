#!/bin/sh
set -euo pipefail
export NGINX_API_ENDPOINT=${NGINX_API_ENDPOINT:-/v1/oracle}
export NGINX_API_ADDR=${NGINX_API_ADDR:-localhost} # hostname with port
export NGINX_API_HOST=${NGINX_API_ADDR%:*}         # just hostname

export NGINX_AUTH_ENDPOINT=${NGINX_AUTH_ENDPOINT:-/v1/auth}
export NGINX_AUTH_ADDR=${NGINX_AUTH_ADDR:-localhost} # hostname with port
export NGINX_AUTH_HOST=${NGINX_AUTH_ADDR%:*}         # just hostname

until getent hosts "${NGINX_API_HOST}"; do
  echo "No route to Web host: ${NGINX_API_HOST}"
  sleep 1
done

until getent hosts "${NGINX_AUTH_HOST}"; do
  echo "No route to Auth host: ${NGINX_AUTH_HOST}"
  sleep 1
done

nginx -g 'daemon off;'

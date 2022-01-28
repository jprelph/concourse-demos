#!/usr/bin/env bash

set -e

export LOG_UUID=FALSE

. /defaults.sh

cat > ${NGINX_CONF_DIR}/server_certs.conf <<-EOF_CERT_CONF
    ssl_certificate     ${SERVER_CERT};
    ssl_certificate_key ${SERVER_KEY};
    # Can add SSLv3 for IE 6 but this opens up to poodle
    ssl_protocols ${SSL_PROTOCOLS};
    # reduction to only the best ciphers
    # And make sure we prefer them
    ssl_ciphers ${SSL_CIPHERS};
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_stapling on;
    ssl_dhparam ${NGINX_CONF_DIR}/dhparam.pem;
EOF_CERT_CONF

: "${LOCATIONS_CSV:=/}"

INTERNAL_LISTEN_PORT="${INTERNAL_LISTEN_PORT:-10418}"
NGIX_LISTEN_CONF="${NGINX_CONF_DIR}/nginx_listen.conf"

cat > ${NGIX_LISTEN_CONF} <<-EOF-LISTEN
		set \$http_listen_port '${HTTP_LISTEN_PORT}';
		set \$https_listen_port '${HTTPS_LISTEN_PORT}';
		set \$internal_listen_port '${INTERNAL_LISTEN_PORT}';
		listen localhost:${INTERNAL_LISTEN_PORT} ssl;
EOF-LISTEN

if [ "${CUSTOM_SECURITY_DEFAULTS:-}" == "TRUE" ]; then
    msg "Disabling inbuilt security headers add per location"
    > /etc/nginx/conf/security_defaults.conf
fi

if [ -n "${LOAD_BALANCER_CIDR:-}" ]; then
    msg "Using proxy_protocol from '$LOAD_BALANCER_CIDR' (real client ip is forwarded correctly by loadbalancer)..."
    export REMOTE_IP_VAR="proxy_protocol_addr"
    cat >> ${NGIX_LISTEN_CONF} <<-EOF-LISTEN-PP
		listen ${HTTP_LISTEN_PORT} proxy_protocol;
		listen ${HTTPS_LISTEN_PORT} proxy_protocol ssl;
		real_ip_recursive on;
		real_ip_header proxy_protocol;
		set \$real_client_ip_if_set '\$proxy_protocol_addr ';
		set_real_ip_from ${LOAD_BALANCER_CIDR};
	EOF-LISTEN-PP
else
    msg "No \$LOAD_BALANCER_CIDR set, using straight SSL (client ip will be from loadbalancer if used)..."
    export REMOTE_IP_VAR="remote_addr"
    cat >> ${NGIX_LISTEN_CONF} <<-EOF-LISTEN-NONPP
		listen ${HTTP_LISTEN_PORT};
		listen ${HTTPS_LISTEN_PORT} ssl;
		set \$real_client_ip_if_set '';
	EOF-LISTEN-NONPP
fi

NGIX_SYSDIG_SERVER_CONF="${NGINX_CONF_DIR}/nginx_sysdig_server.conf"
touch ${NGIX_SYSDIG_SERVER_CONF}
if [ -n "${DISABLE_SYSDIG_METRICS:-}" ]; then
    cat > ${NGIX_SYSDIG_SERVER_CONF} <<-EOF-SYSDIG-SERVER
    server {
      listen 10088;
      location /nginx_status {
        stub_status on;
        access_log   off;
        allow 127.0.0.1;
        deny all;
      }
    }
EOF-SYSDIG-SERVER
fi

if [ "${CUSTOM_PROXY_CONFIG}" != "TRUE" ]; then
  IFS=',' read -a LOCATIONS_ARRAY <<< "$LOCATIONS_CSV"
  for i in "${!LOCATIONS_ARRAY[@]}"; do
      /enable_location.sh $((${i} + 1)) ${LOCATIONS_ARRAY[$i]}
  done
fi

if [ -z "${NAME_RESOLVER:-}" ]; then
    if [ "${DNSMASK}" == "TRUE" ]; then
        dnsmasq -p 5462
        export NAME_RESOLVER=127.0.0.1:5462
    else
        export NAME_RESOLVER=$(grep 'nameserver' /etc/resolv.conf | head -n1 | cut -d' ' -f2)
    fi
fi

if [ "${HTTPS_REDIRECT}" == "TRUE" ]; then
    cat > ${NGINX_CONF_DIR}/ssl_redirect.conf <<-EOF-REDIRECT-TRUE
	if (\$ssl_protocol = "") {
	  rewrite ^ https://\$host\$https_port_string\$request_uri? permanent;
	}
	EOF-REDIRECT-TRUE
else
    touch ${NGINX_CONF_DIR}/ssl_redirect.conf
fi

msg "Resolving proxied names using resolver:${NAME_RESOLVER}"
echo "resolver ${NAME_RESOLVER};">${NGINX_CONF_DIR}/resolver.conf

echo "HTTPS_LISTEN_PORT=${HTTPS_LISTEN_PORT}">/tmp/readyness.cfg

if [ -f ${UUID_FILE} ]; then
    export LOG_UUID=TRUE
fi
if [ -n "${CLIENT_MAX_BODY_SIZE:-}" ]; then
    UPLOAD_SETTING="client_max_body_size ${CLIENT_MAX_BODY_SIZE}m;"
    echo "${UPLOAD_SETTING}">${NGINX_CONF_DIR}/upload_size.conf
    msg "Setting '${UPLOAD_SETTING};'"
fi

if [ -f /etc/keys/client-ca ]; then
    msg "Loading client certs."
    cat > ${NGINX_CONF_DIR}/client_certs.conf <<-EOF_CLIENT_CONF
      ssl_client_certificate /etc/keys/client-ca;
      ssl_verify_client optional;
EOF_CLIENT_CONF
else
    msg "No client certs mounted - not loading..."
fi

case "${LOG_FORMAT_NAME}" in
    json|text)
        msg "Logging set to ${LOG_FORMAT_NAME}"

        if [ "${NO_LOGGING_URL_PARAMS:-}" == TRUE ]; then
            sed -i -e 's/\$request_uri/\$uri/g' ${NGINX_CONF_DIR}/logging.conf
        fi

        if [ "${NO_LOGGING_BODY:-}" == TRUE ]; then
            sed --in-place '/\$request_body/d' ${NGINX_CONF_DIR}/logging.conf
        fi

        if [ "${NO_LOGGING_RESPONSE:-}" == TRUE ]; then
            sed --in-place '/\$response_body/d' ${NGINX_CONF_DIR}/logging.conf
            touch ${NGINX_CONF_DIR}/response_body.conf
        else
		cat > ${NGINX_CONF_DIR}/response_body.conf <<-EOF-LOGGING-BODY-TRUE

			lua_need_request_body on;
                        set \$response_body "";
			body_filter_by_lua '
				local resp_body = string.sub(ngx.arg[1], 1, 1000)
				ngx.ctx.buffered = (ngx.ctx.buffered or "") .. resp_body
				if ngx.arg[2] then
					ngx.var.response_body = ngx.ctx.buffered
				end
			';
EOF-LOGGING-BODY-TRUE
        fi

        echo "map \$request_uri \$loggable { ~^/nginx_status/  0; default 1;}">>${NGINX_CONF_DIR}/logging.conf #remove logging for the sysdig agent.

        echo "access_log /dev/stdout extended_${LOG_FORMAT_NAME} if=\$loggable;" >> ${NGINX_CONF_DIR}/logging.conf
        ;;
    *)
        exit_error_msg "Invalid log format specified:${LOG_FORMAT_NAME}. Expecting json or text."
    ;;
esac

if [ -n "${ADD_NGINX_SERVER_CFG:-}" ]; then
    msg "Adding extra config for server context."
    echo ${ADD_NGINX_SERVER_CFG}>${NGINX_CONF_DIR}/nginx_server_extras.conf
fi

if [ -n "${ADD_NGINX_HTTP_CFG:-}" ]; then
    msg "Adding extra config for http context."
    echo ${ADD_NGINX_HTTP_CFG}>${NGINX_CONF_DIR}/nginx_http_extras.conf
fi


eval "${NGINX_BIN} -g \"daemon off;\""

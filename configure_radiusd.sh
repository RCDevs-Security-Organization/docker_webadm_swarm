#!/bin/bash
#set -eu

function wait_that_webadm_is_reachable {
    if [ "$#" -ne 1 ] && [ "$#" -ne 2 ]; then
      echo "wait_that_webadm_is_reachable error: wrong number of parameters! Exiting"
      exit 1
    fi

    WA_SERVER_NAME="${1:-webadm_1}"
    TIMEOUT="${2:-500}"

    URL_TO_CHECK="https://$WA_SERVER_NAME"

    echo "Waiting for $WA_SERVER_NAME server to be ready..."
    LIMIT_SLEEP=$TIMEOUT
    INDEX_SLEEP=1
    while ! curl -ks "$URL_TO_CHECK"; do
        if [[ "$INDEX_SLEEP" -gt "$LIMIT_SLEEP" ]]; then
            echo "Exiting as timeout for waiting for webadm-u server to be ready has been reached!"
            exit 1
        fi
        INDEX_SLEEP=$((INDEX_SLEEP+1))
        sleep 1
    done
}

if [ ! -f /opt/radiusd/temp/.setup ]; then
    RADIUSD_SECRET=$(cat /run/secrets/radiusd_secret)
    ROOT_PASSWORD=$(cat /run/secrets/slapd_admin_pwd)
    CUSTOM_ORGANIZATIONAL_UNIT_NAME=$(cat /custom_organizational_unit_name)
    CUSTOM_ORGANIZATION_NAME=$(cat /custom_organization_name)
    CUSTOM_COUNTRY_CODE=$(cat /custom_country_code)
    sed -i 's/read RESP/RESP=y/g' /opt/radiusd/bin/setup
    sed -i "s/read HOSTNAME/HOSTNAME=$(hostname -s)/g" /opt/radiusd/bin/setup
    sed -i "s/read SERVER/SERVER=webadm_1/g" /opt/radiusd/bin/setup
    wait_that_webadm_is_reachable "webadm_1"
    ROOT="/opt/radiusd" OPENSSL_CONF="$ROOT/lib/openssl.ini" OPENSSL_SAN="DNS:$HOSTNAME" SSL_PROTOCOL="TLSv1.2" SSL_CIPHERSUITE="HIGH:MEDIUM" PATH="$ROOT/libexec:/bin:/sbin:/usr/bin:/usr/sbin:$PATH" /opt/radiusd/libexec/openssl rand -out /opt/radiusd/temp/radiusd.rnd -hex 256
    ROOT="/opt/radiusd" OPENSSL_CONF="$ROOT/lib/openssl.ini" OPENSSL_SAN="DNS:$HOSTNAME" SSL_PROTOCOL="TLSv1.2" SSL_CIPHERSUITE="HIGH:MEDIUM" PATH="$ROOT/libexec:/bin:/sbin:/usr/bin:/usr/sbin:$PATH" /opt/radiusd/libexec/openssl genrsa -out /opt/radiusd/conf/radiusd.key 4096
    SUBJECT_RADIUSD="/CN=$HOSTNAME/OU=$CUSTOM_ORGANIZATIONAL_UNIT_NAME/O=$CUSTOM_ORGANIZATION_NAME/C=$CUSTOM_COUNTRY_CODE"
    ROOT="/opt/radiusd" OPENSSL_CONF="$ROOT/lib/openssl.ini" OPENSSL_SAN="DNS:$HOSTNAME" SSL_PROTOCOL="TLSv1.2" SSL_CIPHERSUITE="HIGH:MEDIUM" PATH="$ROOT/libexec:/bin:/sbin:/usr/bin:/usr/sbin:$PATH" /opt/radiusd/libexec/openssl req -sha256 -new -key /opt/radiusd/conf/radiusd.key -out /opt/radiusd/conf/radiusd.csr -subj "$SUBJECT_RADIUSD"
    CSR_FORMATTED=$(sed 's|$|\\n|g' /opt/radiusd/conf/radiusd.csr | tr -d '\n' | sed 's|/|\\/|g')
    while [[ ! -s "/opt/radiusd/conf/radiusd.crt" ]]; do
        curl -ks --user "Default\admin:$ROOT_PASSWORD" https://webadm_1/manag/  --data "{\"method\":\"Sign_Certificate_Request\", \"params\": {\"request\": \"$CSR_FORMATTED\"}, \"id\":0, \"jsonrpc\":\"2.0\"}" | tac | tac | grep -oE -- "-----BEGIN CERTIFICATE-----[^-]*-----END CERTIFICATE-----" | sed 's/\\n/\n/g' | sed 's|\\/|/|g' > /opt/radiusd/conf/radiusd.crt
    done
    touch "/opt/radiusd/temp/.setup"
    sed -i "s/secret = testing123/secret = $RADIUSD_SECRET/g" /opt/radiusd/conf/clients.conf
    curl -ks https://webadm_1/cacert > /opt/radiusd/conf/ca.crt
    sed -i 's|server_url = "http://localhost:8080/openotp/"|server_url = "https://webadm_1:8443/openotp/,https://wa2:8443/openotp/"|g' /opt/radiusd/conf/radiusd.conf
fi
exec "$@"
#!/bin/bash
set -eu
if [ ! -f /opt/slapd/conf/.setup ]; then
    ADMINPWD=$(cat /run/secrets/slapd_admin_pwd)
    PROXYPWD=$(cat /run/secrets/slapd_proxy_pwd)
    export ADMINPWD
    export PROXYPWD
    sed -i 's/ADMINPWD=""//g' /opt/slapd/bin/setup
    sed -i 's/PROXYPWD=""//g' /opt/slapd/bin/setup
    /opt/slapd/bin/slapd stop
    /opt/slapd/bin/setup silent
    /opt/slapd/bin/slapd stop
    cat <<EOF >> /opt/slapd/conf/slapd.conf
serverID ${HOSTNAME: -1}
syncrepl rid=001
    provider=ldap://$REMOTE_SERVER
    bindmethod=simple
    binddn="cn=admin,o=Root"
    credentials="$ADMINPWD"
    searchbase=""
    schemachecking=on
    type=refreshAndPersist
    starttls=no
    tls_reqcert=never
    retry="10 5 60 +"
mirrormode on
EOF
    touch /opt/slapd/conf/.setup
    sleep 5
fi
exec "$@"

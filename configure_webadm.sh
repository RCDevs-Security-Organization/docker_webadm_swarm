#!/bin/bash
set -aeu

function set_servers_xml_header() {
    cat <<EOF > /opt/webadm/conf/servers.xml
<?xml version="1.0" encoding="UTF-8" ?>
<Servers>
EOF
}

function set_servers_xml_footer() {
    cat <<EOF >> /opt/webadm/conf/servers.xml
</Servers>
EOF
}

function set_servers_xml_ldaps() {
    LDAPS=$1
    IFS=','
    for LDAP in $LDAPS; do    
    cat <<EOF >> /opt/webadm/conf/servers.xml
	<LdapServer name="$LDAP"
		host="$LDAP"
		port="636"
		encryption="SSL"
		ca_file="" />
EOF
    done
    unset IFS
}

function set_servers_xml_sqls() {
    SQLS=$1
    PWD=$2
    IFS=','
    for SQL in $SQLS; do    
    cat <<EOF >> /opt/webadm/conf/servers.xml
	<SqlServer name="SQL $SQL"
		type="mariadb"
		host="$SQL"
		user="webadm"
		password="$PWD"
		database="webadm"
		encryption="SSL" />
EOF
    done
    unset IFS
}

function set_servers_xml_sessions() {
    SESSIONS=$1
    PWD=$2
    IFS=','
    for SESSION in $SESSIONS; do    
    cat <<EOF >> /opt/webadm/conf/servers.xml
	<SessionServer name="Session Server $SESSION"
		host="$SESSION"
		port="4000"
		secret="$PWD" />
EOF
    done
    unset IFS
}

function set_servers_xml_pkis() {
    PKIS=$1
    PWD=$2
    IFS=','
    for PKI in $PKIS; do    
    cat <<EOF >> /opt/webadm/conf/servers.xml
	<PkiServer name="PKI Server $PKI"
		host="$PKI"
		port="5000"
		secret="$PWD"
		ca_file="" />
EOF
    done
    unset IFS
}

function set_rsignd_conf_clients() {
    CLIENTS=$1
    PWD=$2
    IFS=','
    for CLIENT in $CLIENTS; do    
    cat <<EOF >> /opt/webadm/conf/rsignd.conf
client {
       hostname $CLIENT
       secret $PWD
}
EOF
    done
    unset IFS
}


if [ ! -f "/opt/webadm/conf/.docker_setup" ] && [ ! -f "/opt/webadm/temp/.setup" ]; then
    MARIADB_WEBADM_PASSWORD=$(cat /run/secrets/mariadb_webadm_pwd)
    PROXYPWD=$(cat /run/secrets/slapd_proxy_pwd)
    CUSTOM_ORGANIZATIONAL_UNIT_NAME=$(cat /custom_organizational_unit_name)
    CUSTOM_ORGANIZATION_NAME=$(cat /custom_organization_name)
    CUSTOM_COUNTRY_CODE=$(cat /custom_country_code)
    echo "Configuring webadm..."
    openssl rand -out /opt/webadm/temp/webadm.rnd -hex 256
    cp /run/secrets/ca_crt /opt/webadm/pki/ca/ca.crt
    cp /run/secrets/ca_key /opt/webadm/pki/ca/ca.key
    openssl genrsa -out /opt/webadm/pki/webadm.key 4096
    SUBJECT_WEBADM="/CN=$HOSTNAME/OU=$CUSTOM_ORGANIZATIONAL_UNIT_NAME/O=$CUSTOM_ORGANIZATION_NAME/C=$CUSTOM_COUNTRY_CODE"
    ROOT="/opt/webadm" OPENSSL_CONF="$ROOT/lib/openssl.ini" OPENSSL_SAN="DNS:$HOSTNAME" SSL_PROTOCOL="TLSv1.2" SSL_CIPHERSUITE="HIGH:MEDIUM" PATH="$ROOT/libexec:/bin:/sbin:/usr/bin:/usr/sbin:$PATH" /opt/webadm/libexec/openssl req -sha256 -new -key /opt/webadm/pki/webadm.key -out /opt/webadm/pki/webadm.csr -subj "$SUBJECT_WEBADM" -reqexts setup_req
    ROOT="/opt/webadm" OPENSSL_CONF="$ROOT/lib/openssl.ini"  SSL_PROTOCOL="TLSv1.2" SSL_CIPHERSUITE="HIGH:MEDIUM" PATH="$ROOT/libexec:/bin:/sbin:/usr/bin:/usr/sbin:$PATH" /opt/webadm/libexec/openssl x509 -req -days 365 -in /opt/webadm/pki/webadm.csr -out /opt/webadm/pki/webadm.crt -CA /opt/webadm/pki/ca/ca.crt -CAkey /opt/webadm/pki/ca/ca.key -CAserial /opt/webadm/pki/ca/serial -CAcreateserial -extfile <(printf "subjectAltName=DNS:%s" "$HOSTNAME")        
    cp /opt/webadm/conf/webadm.conf.default /opt/webadm/conf/webadm.conf
    sed -i "s/^proxy_password.*/proxy_password \"$PROXYPWD\"/" /opt/webadm/conf/webadm.conf
    sed -i 's/#cloud_wsproxy No/cloud_wsproxy Yes/g' /opt/webadm/conf/webadm.conf
    cp /opt/webadm/pki/ca/ca.crt /opt/webadm/pki/trusted/bundle.crt
    cp /opt/webadm/pki/ca/serial /opt/webadm/pki/trusted/
    touch "/opt/webadm/conf/.docker_setup" "/opt/webadm/temp/.setup"
    cp /run/secrets/webadm_license_key /opt/webadm/conf/license.key
    set_servers_xml_header
    set_servers_xml_ldaps "slapd_1,slapd_2"
    set_servers_xml_sqls "mariadb_1,mariadb_2" "$MARIADB_WEBADM_PASSWORD"
    set_servers_xml_sessions "webadm_1,webadm_2" "$MARIADB_WEBADM_PASSWORD"
    set_servers_xml_pkis "$HOSTNAME" "$MARIADB_WEBADM_PASSWORD"    
    set_rsignd_conf_clients "webadm_1,webadm_2" "$MARIADB_WEBADM_PASSWORD"    
    set_servers_xml_footer
    sed -i 's/host="ldap1"/host="slapd_1"/g' /opt/webadm/conf/servers.xml
fi
touch "/opt/webadm/conf/.docker_setup" "/opt/webadm/temp/.setup"
echo "end"
exec "$@"
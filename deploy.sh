#!/bin/bash

source .env

AVAILABLE_NODES=()

function exit_with_message() {
    echo "$1"
    if [[ -s "./logs" ]]; then
        cat ./logs
    fi
    exit "${2:-1}"
}

function get_available_workers() {
    mapfile -t AVAILABLE_NODES < <(docker node ls --filter role=worker --format '{{.Hostname}}')

    if [ "${#AVAILABLE_NODES[@]}" -lt 2 ]; then
        exit_with_message "Deployment requires at least 2 nodes. Exiting!"
    fi
}

REQUIRED_COMMANDS=("docker" "read" "rm" "mapfile")
for REQUIRED_COMMAND in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$REQUIRED_COMMAND" >/dev/null 2>&1; then
        exit_with_message "$REQUIRED_COMMAND command is not available. Exiting!"
    fi
done

function initial_deployment() {

    get_available_workers

    rm -f ./compose.yml ./ca.crt ./ca.key ./logs
    docker config rm mariadb_init mariadb_sync_cnf configure_slapd configure_webadm custom_organizational_unit_name custom_organization_name custom_country_code configure_radiusd > ./logs 2>&1
    docker secret rm mariadb_webadm_pwd mariadb_root_pwd slapd_admin_pwd slapd_proxy_pwd webadm_license_key ca_crt ca_key radiusd_secret > ./logs 2>&1


    CUSTOM_COMMON_NAME=""
    CUSTOM_ORGANIZATIONAL_UNIT_NAME=""
    CUSTOM_ORGANIZATION_NAME=""
    CUSTOM_COUNTRY_CODE=""
    PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
    echo "Password is $PASSWORD"

    while [[ -z "$CUSTOM_COMMON_NAME" ]]; do
    read -r -p "Enter Common Name of Certificate Authority: " CUSTOM_COMMON_NAME
    done

    while [[ -z "$CUSTOM_ORGANIZATIONAL_UNIT_NAME" ]]; do
    read -r -p "Enter Organizational Unit name of Certificate Authority: " CUSTOM_ORGANIZATIONAL_UNIT_NAME
    done
    if ! echo "$CUSTOM_ORGANIZATIONAL_UNIT_NAME" | docker config create custom_organizational_unit_name - > ./logs 2>&1; then
        exit_with_message "Cannot create config for \$CUSTOM_ORGANIZATIONAL_UNIT_NAME environment variable. Exiting!"
    fi

    while [[ -z "$CUSTOM_ORGANIZATION_NAME" ]]; do
    read -r -p "Enter Organization Name of Certificate Authority: " CUSTOM_ORGANIZATION_NAME
    done
    if ! echo "$CUSTOM_ORGANIZATION_NAME" | docker config create custom_organization_name - > ./logs 2>&1; then
        exit_with_message "Cannot create config for \$CUSTOM_ORGANIZATION_NAME environment variable. Exiting!"
    fi

    while [[ -z "$CUSTOM_COUNTRY_CODE" ]]; do
    read -r -p "Enter Country Code of Certificate Authority: " CUSTOM_COUNTRY_CODE
    done
    if !  echo "$CUSTOM_COUNTRY_CODE" | docker config create custom_country_code - > ./logs 2>&1; then
        exit_with_message "Cannot create config for \$CUSTOM_COUNTRY_CODE environment variable. Exiting!"
    fi


    SUBJECT_CA="/CN=$CUSTOM_COMMON_NAME/OU=$CUSTOM_ORGANIZATIONAL_UNIT_NAME/O=$CUSTOM_ORGANIZATION_NAME/C=$CUSTOM_COUNTRY_CODE"
    docker run --rm -v "$PWD:/share" alpine/openssl genrsa -out /share/ca.key 4096 > ./logs 2>&1
    if [[ ! -s "./ca.key" ]]; then
        exit_with_message "Cannot create CA key file. Exiting!"
    fi
    if ! docker secret create ca_key ./ca.key > ./logs 2>&1; then
        exit_with_message "Cannot create secret for ca.key file. Exiting!"
    fi
    docker run --rm -v "$PWD:/share" -e "SUBJECT_CA=$SUBJECT_CA" alpine/openssl req -sha256 -new -key /share/ca.key -x509 -days 18250 -out /share/ca.crt -subj "$SUBJECT_CA" > ./logs 2>&1
    if [[ ! -s "./ca.crt" ]]; then
        exit_with_message "Cannot create CA certificate file. Exiting!"
    fi
    if ! docker secret create ca_crt ./ca.crt > ./logs 2>&1; then
        exit_with_message "Cannot create secret for ca.crt file. Exiting!"
    fi
    rm -f ./ca.crt ./ca.key

    truncate -s 0 ./logs

    if ! docker run --rm -v "$PWD/templates:/templates" -e "NODE1=${AVAILABLE_NODES[0]}" -e "NODE2=${AVAILABLE_NODES[1]}" dinutac/jinja2docker:latest /templates/compose.yml.j2  --format=yaml > compose.yml 2>./logs; then
        exit_with_message "Cannot create compose file. Exiting!"
    fi

    TEMPLATE_CONFIGS=("mariadb_init" "mariadb_sync_cnf")
    for TEMPLATE_CONFIG in "${TEMPLATE_CONFIGS[@]}"; do
        if ! docker config create --template-driver golang "$TEMPLATE_CONFIG" "./$TEMPLATE_CONFIG.tmpl" > ./logs 2>&1; then
            exit_with_message "Cannot create config for $TEMPLATE_CONFIG.tmpl file. Exiting!"
        fi
    done

    FILE_CONFIGS=("configure_slapd" "configure_webadm" "configure_radiusd")
    for FILE_CONFIG in "${FILE_CONFIGS[@]}"; do
        if ! docker config create "$FILE_CONFIG" "./$FILE_CONFIG.sh" > ./logs 2>&1; then
            exit_with_message "Cannot create config for $FILE_CONFIG.sh file. Exiting!"
        fi
    done

    SECRETS=("mariadb_webadm_pwd" "mariadb_root_pwd" "slapd_admin_pwd" "slapd_proxy_pwd" "radiusd_secret")
    for SECRET in "${SECRETS[@]}"; do
        if ! printf "%s"  "$PASSWORD" | docker secret create "$SECRET" - > ./logs 2>&1; then
            exit_with_message "Cannot create secret for $SECRET. Exiting!"
        fi
    done
    if ! docker secret create webadm_license_key ./license.key > ./logs 2>&1; then
        exit_with_message "Cannot create secret for license.key"
    fi

    docker stack deploy --detach=true --compose-file ./compose.yml webadm
}

function clean_deployment() {

    get_available_workers

    rm -f ./compose.yml ./logs

    echo "Run this command on ${AVAILABLE_NODES[0]} and ${AVAILABLE_NODES[1]} before continuing:"
    echo
    echo "docker exec -it \$(docker ps --filter name=mariadb --format '{{.ID}}') cp /etc/mysql/mariadb.conf.d/50-sync.cnf /etc/mysql/mariadb.conf.d/51-sync.cnf"
    echo
    read -r -p "Press Enter only when above action is done!"

    if ! docker stack rm webadm > ./logs 2>&1; then
        exit_with_message "Error during deletion of stack"
    fi
    docker config rm mariadb_init mariadb_sync_cnf configure_slapd configure_webadm custom_organizational_unit_name custom_organization_name custom_country_code configure_radiusd > /dev/null 2>/dev/null
    docker secret rm mariadb_webadm_pwd mariadb_root_pwd slapd_admin_pwd slapd_proxy_pwd webadm_license_key ca_crt ca_key radiusd_secret > /dev/null 2>/dev/null

    if ! docker run --rm -v "$PWD/templates:/templates" -e "NODE1=${AVAILABLE_NODES[0]}" -e "NODE2=${AVAILABLE_NODES[1]}" dinutac/jinja2docker:latest /templates/compose2.yml.j2  --format=yaml > compose.yml 2>./logs; then
        exit_with_message "Cannot create compose file. Exiting!"
    fi

    docker stack deploy --detach=true --compose-file ./compose.yml webadm

}

function update() {
    docker stack deploy --detach=true --compose-file ./compose.yml webadm
}

function destroy() {
    docker stack rm webadm
    docker config rm mariadb_init mariadb_sync_cnf configure_slapd configure_webadm custom_organizational_unit_name custom_organization_name custom_country_code configure_radiusd > /dev/null 2>&1
    docker secret rm mariadb_webadm_pwd mariadb_root_pwd slapd_admin_pwd slapd_proxy_pwd webadm_license_key ca_crt ca_key radiusd_secret > /dev/null 2>&1
}

case $1 in
  --init)
    initial_deployment
    ;;

  --clean)
    clean_deployment
    ;;

  --update)
    update
    ;;

  --destroy)
    destroy
    ;;

  *)
    echo "A valid option is missing! Available options are:"
    echo "--init: first deployment"
    echo "--clean: clean deployment"
    echo "--update: update deployment"
    exit 1
    ;;
esac



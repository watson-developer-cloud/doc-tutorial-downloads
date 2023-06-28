#!/bin/bash

set -euo pipefail

printUsage() {
  echo "Usage: $(basename ${0}) [releaseName] [WEX_DATA_DIR]"
  exit 1
}

if [ $# -lt 1 ] ; then
  printUsage
fi


SCRIPT_DIR=$(dirname $(dirname "$0"))

. ${SCRIPT_DIR}/lib/function.bash

OC_ARGS=""
SED_REG_OPT="$(get_sed_reg_opt)"
BASE64_OPT="$(get_base64_opt)"

TENANT_NAME=$1
shift
WEX_DATA=$1
shift
while getopts n: OPT
do
  case $OPT in
    "n" ) OC_ARGS="${OC_ARGS} --namespace=$OPTARG" ;;
esac
done

export TENANT_NAME=${TENANT_NAME}
export SCRIPT_DIR=${SCRIPT_DIR}
ORG_OC_ARGS=${OC_ARGS}

SECRET_NAME=$(oc get ${OC_ARGS} secret -o jsonpath='{.items[*].metadata.name}' -l tenant=${TENANT_NAME},app=ck-secret)

# Unescape '='
TMPFILE=${WEX_DATA}/tmp_crawler.ini
sed -e 's/\\//g' ${WEX_DATA}/config/certs/crawler.ini > ${TMPFILE}
. ${TMPFILE}

oc ${OC_ARGS} get secret ${SECRET_NAME} -o yaml | \
sed ${SED_REG_OPT} -e "s/^(  CK: ).+$/\1$(echo -n ${CK} | base64 ${BASE64_OPT})/" \
       -e "s/^(  OK: ).+$/\1$(echo -n ${OK} | base64 ${BASE64_OPT})/" \
       -e "s/^(  Password: ).+$/\1$(echo -n ${Password} | base64 ${BASE64_OPT})/" | \
oc ${OC_ARGS} apply -f -
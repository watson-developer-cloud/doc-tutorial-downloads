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

KUBECTL_ARGS=""
SED_REG_OPT="`get_sed_reg_opt`"
BASE64_OPT="`get_base64_opt`"

RELEASE_NAME=$1
shift
WEX_DATA=$1
shift
while getopts n: OPT
do
  case $OPT in
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG" ;;
esac
done

export RELEASE_NAME=${RELEASE_NAME}
export SCRIPT_DIR=${SCRIPT_DIR}
ORG_KUBECTL_ARGS=${KUBECTL_ARGS}

SECRET_NAME=`kubectl ${KUBECTL_ARGS} get secret -l release=${RELEASE_NAME},app.kubernetes.io/component=core-discovery-wex-core-ck-secret -o jsonpath="{.items[*].metadata.name}"`

# Unescape '='
TMPFILE=${WEX_DATA}/tmp_crawler.ini
sed -e 's/\\//g' ${WEX_DATA}/config/certs/crawler.ini > ${TMPFILE}
. ${TMPFILE}

kubectl ${KUBECTL_ARGS} get secret ${SECRET_NAME} -o yaml | \
sed ${SED_REG_OPT} -e "s/^(  CK: ).+$/\1`echo -n ${CK} | base64 ${BASE64_OPT}`/" \
       -e "s/^(  OK: ).+$/\1`echo -n ${OK} | base64 ${BASE64_OPT}`/" \
       -e "s/^(  Password: ).+$/\1`echo -n ${Password} | base64 ${BASE64_OPT}`/" | \
kubectl ${KUBECTL_ARGS} apply -f -
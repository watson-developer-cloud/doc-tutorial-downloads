#!/bin/bash

set -euo pipefail

printUsage() {
  echo "Usage: $(basename ${0}) <tanant_name>"
  exit 1
}

SCRIPT_DIR=$(dirname $0)
OC_ARGS=""
. ${SCRIPT_DIR}/lib/function.bash

TENANT_NAME=$1
shift

while getopts n: OPT
do
  case $OPT in
    "n" ) OC_ARGS="${OC_ARGS} --namespace=$OPTARG"
          NAMESPACE=${OPTARG} ;;
esac
done

export SCRIPT_DIR=${SCRIPT_DIR}
ORG_OC_ARGS=${OC_ARGS}
PG_JOB_NAME="crust-discovery-wire-postgres-restore"
PG_JOB_TEMPLATE="${SCRIPT_DIR}/src/postgres-config-job-template.yml"
PG_JOB_FILE="${SCRIPT_DIR}/src/postgres-config-job.yml"
WD_VERSION=${WD_VERSION:-$(get_version)}

brlog "INFO" "Start postgresql configuration"

if [ $(compare_version ${WD_VERSION} "4.0.0") -ge 0 ] ; then
  PG_CONFIG_REPO="$(get_image_repo)"
  PG_CONFIG_TAG="${PG_CONFIG_TAG:-$(get_pg_config_tag)}"
  PG_CONFIG_IMAGE="${PG_CONFIG_REPO}/configure-postgres:${PG_CONFIG_TAG}"
else
  PG_CONFIG_IMAGE=$(oc ${OC_ARGS} get deploy -o jsonpath="{..image}" |tr -s '[[:space:]]' '\n' | sort | uniq | grep training-data-crud | sed -e "s/training-data-crud/configure-postgres/g")
fi
PG_CONFIGMAP=$(get_pg_configmap)
PG_SECRET=$(get_pg_secret)
NAMESPACE=${NAMESPACE:-$(oc config view --minify --output 'jsonpath={..namespace}')}
SERVICE_ACCOUNT=$(get_service_account)
PG_JOB_NAME="${TENANT_NAME}-discovery-wire-postgres-restore"
WD_VERSION=${WD_VERSION:-$(get_version)}
if [ $(compare_version "${WD_VERSION}" "2.2.1") -le 0 ] ; then
  PG_SECRET_PASS_KEY="STKEEPER_PG_SU_PASSWORD"
else
  PG_SECRET_PASS_KEY="pg_su_password"
fi

sed -e "s|#image#|${PG_CONFIG_IMAGE}|g" \
  -e "s/#pg-configmap#/${PG_CONFIGMAP}/g" \
  -e "s/#pg-secret#/${PG_SECRET}/g" \
  -e "s/#release#/${TENANT_NAME}/g" \
  -e "s/#namespace#/${NAMESPACE}/g" \
  -e "s/#service-account#/${SERVICE_ACCOUNT}/g" \
  -e "s/#pg-pass-key#/${PG_SECRET_PASS_KEY}/g" \
  "${PG_JOB_TEMPLATE}" > "${PG_JOB_FILE}"

oc ${OC_ARGS} apply -f "${PG_JOB_FILE}"

brlog "INFO" "Waiting for configuration job to be completed..."
while :
do
  if [ "$(oc ${OC_ARGS} get job -o jsonpath='{.status.succeeded}' ${PG_JOB_NAME})" = "1" ] ; then
    brlog "INFO" "Completed postgres config job"
    break;
  else
    sleep 5
  fi
done

oc ${OC_ARGS} delete job ${PG_JOB_NAME}

brlog "INFO" "Done postgresql configuration"
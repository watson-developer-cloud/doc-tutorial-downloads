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

brlog "INFO" "Start postgresql configuration"

PG_CONFIG_IMAGE=`oc ${OC_ARGS} get deploy -o jsonpath="{..image}" |tr -s '[[:space:]]' '\n' | sort | uniq | grep training-data-crud | sed -e "s/training-data-crud/configure-postgres/g"`
PG_CONFIGMAP=`oc get ${OC_ARGS} configmap -l tenant=${TENANT_NAME},app.kubernetes.io/component=postgres-cxn -o jsonpath="{.items[0].metadata.name}"`
PG_SECRET=`oc ${OC_ARGS} get secret -l tenant=${TENANT_NAME},cr=${TENANT_NAME}-discovery-postgres -o jsonpath="{.items[*].metadata.name}"`
NAMESPACE=${NAMESPACE:-`oc config view --minify --output 'jsonpath={..namespace}'`}
SERVICE_ACCOUNT=`oc ${OC_ARGS} get serviceaccount -l app.kubernetes.io/component=admin-sa -o jsonpath="{.items[*].metadata.name}"`
PG_JOB_NAME="${TENANT_NAME}-discovery-wire-postgres-restore"

sed -e "s|@image@|${PG_CONFIG_IMAGE}|g" \
  -e "s/@pg-configmap@/${PG_CONFIGMAP}/g" \
  -e "s/@pg-secret@/${PG_SECRET}/g" \
  -e "s/@release@/${TENANT_NAME}/g" \
  -e "s/@namespace@/${NAMESPACE}/g" \
  -e "s/@service-account@/${SERVICE_ACCOUNT}/g" \
  "${PG_JOB_TEMPLATE}" > "${PG_JOB_FILE}"

oc ${OC_ARGS} apply -f "${PG_JOB_FILE}"

brlog "INFO" "Waiting for configuration job to be completed..."
while :
do
  if [ "`oc ${OC_ARGS} get job -o jsonpath='{.status.succeeded}' ${PG_JOB_NAME}`" = "1" ] ; then
    brlog "INFO" "Completed postgres config job"
    break;
  else
    sleep 5
  fi
done

oc ${OC_ARGS} delete job ${PG_JOB_NAME}

brlog "INFO" "Done postgresql configuration"
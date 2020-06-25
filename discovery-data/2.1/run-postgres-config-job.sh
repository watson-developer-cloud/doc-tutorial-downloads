#!/bin/bash

set -euo pipefail

printUsage() {
  echo "Usage: $(basename ${0}) [-n namespace]"
  exit 1
}

SCRIPT_DIR=$(dirname $0)
. ${SCRIPT_DIR}/lib/function.bash
KUBECTL_ARGS=""

while getopts n: OPT
do
  case $OPT in
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG"
          NAMESPACE=${OPTARG} ;;
esac
done

export SCRIPT_DIR=${SCRIPT_DIR}
ORG_KUBECTL_ARGS=${KUBECTL_ARGS}
PG_JOB_NAME="bedrock-discovery-wire-postgres-restore"
PG_JOB_TEMPLATE="${SCRIPT_DIR}/src/postgres-config-job-template.yml"
PG_JOB_FILE="${SCRIPT_DIR}/src/postgres-config-job.yml"
ADMIN_RELEASE_NAME="admin"
PG_RELEASE_NAME="bedrock"
JOB_RELEASE_NAME="bedrock"

PG_CONFIG_IMAGE=`kubectl ${KUBECTL_ARGS} get pods -o jsonpath="{..image}" |tr -s '[[:space:]]' '\n' | sort | uniq | grep training-data-crud`
PG_SERVICE=`kubectl get svc ${KUBECTL_ARGS} -o jsonpath="{.items[0].metadata.name}" -l release=${PG_RELEASE_NAME},component=stolon-proxy`
PG_PORT=`kubectl get svc ${KUBECTL_ARGS} -o jsonpath='{.items[0].spec.ports[0].port}' -l release=${PG_RELEASE_NAME},component=stolon-proxy`
PG_SECRET=`kubectl ${KUBECTL_ARGS} get secret -l release=${PG_RELEASE_NAME},helm.sh/chart=postgresql -o jsonpath="{.items[*].metadata.name}"`
NAMESPACE=${NAMESPACE:-`kubectl config view --minify --output 'jsonpath={..namespace}'`}
SERVICE_ACCOUNT=`kubectl get serviceaccount -l release=${ADMIN_RELEASE_NAME} -o jsonpath="{.items[*].metadata.name}" | tr -s '[[:space:]]' '\n' | grep -v privileged`
PG_JOB_NAME="${JOB_RELEASE_NAME}-discovery-wire-postgres-restore"

sed -e "s|@image@|${PG_CONFIG_IMAGE}|g" \
  -e "s/@pg-host@/${PG_SERVICE}/g" \
  -e "s/@pg-port@/${PG_PORT}/g" \
  -e "s/@pg-secret@/${PG_SECRET}/g" \
  -e "s/@release@/${JOB_RELEASE_NAME}/g" \
  -e "s/@namespace@/${NAMESPACE}/g" \
  -e "s/@service-account@/${SERVICE_ACCOUNT}/g" \
  -e "s/training-data-crud/configure-postgres/g" \
  "${PG_JOB_TEMPLATE}" > "${PG_JOB_FILE}"

kubectl ${KUBECTL_ARGS} apply -f "${PG_JOB_FILE}"

brlog "INFO" "Waiting for configuration job to be completed..."
while :
do
  if [ "`kubectl ${KUBECTL_ARGS} get job -o jsonpath='{.status.succeeded}' ${PG_JOB_NAME}`" = "1" ] ; then
    brlog "INFO" "Completed postgres config job"
    break;
  else
    sleep 5
  fi
done

kubectl ${KUBECTL_ARGS} delete job ${PG_JOB_NAME}
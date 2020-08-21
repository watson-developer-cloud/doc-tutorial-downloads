#!/bin/bash

set -euo pipefail

printUsage() {
  echo "Usage: $(basename ${0}) [releaseName]"
  exit 1
}

runPythonScripts() {
  POD=$1
  SCRIPT=$2
  kubectl ${KUBECTL_ARGS} cp "src/${SCRIPT}" ${POD}:/tmp/
  kubectl ${KUBECTL_ARGS} exec ${POD} -- bash -c "export MANAGEMENT_PORT=${MANAGEMENT_PORT} && \
  export ZING_PORT=${ZING_PORT} && \
  python3 /tmp/${SCRIPT}"
  kubectl ${KUBECTL_ARGS} exec ${POD} -- bash -c "rm -f /tmp/${SCRIPT}"
}

if [ $# -lt 1 ] ; then
  printUsage
fi

SCRIPT_DIR=$(dirname $0)
KUBECTL_ARGS=""

. ${SCRIPT_DIR}/lib/function.bash

RELEASE_NAME=$1
shift
while getopts n: OPT
do
  case $OPT in
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG" ;;
esac
done

export RELEASE_NAME=${RELEASE_NAME}
export ETCD_RELEASE_NAME="crust"
export SCRIPT_DIR=${SCRIPT_DIR}
ORG_KUBECTL_ARGS=${KUBECTL_ARGS}

brlog "INFO" "Running post restore scripts"

GATEWAY_POD=`kubectl get pods ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${RELEASE_NAME},run=gateway`
INGESTION_API_POD=`kubectl get pods ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${RELEASE_NAME},run=ingestion-api`

brlog "INFO" "Waiting for central pods to be ready..."
while :
do
  if kubectl describe pod ${KUBECTL_ARGS} -l release=${RELEASE_NAME},run=orchestrator | grep -e "ContainersReady.*False" -e "PodScheduled.*False" > /dev/null ; then
    sleep 5;
  else
    brlog "INFO" "Central pods are ready";
    break;
  fi
done

if [ `compare_version "${BACKUP_FILE_VERSION}" 2.1.2` -le 0 ] ; then
  ${SCRIPT_DIR}/src/update-stats.sh ${ETCD_RELEASE_NAME}
fi

export MANAGEMENT_PORT=9443
export ZING_PORT=9463
export KUBECTL_ARGS="${KUBECTL_ARGS} -c nginx"

if [ `compare_version "${BACKUP_FILE_VERSION}" 2.1.2` -le 0 ] ; then
  brlog "INFO" "Submitting rebuild datasets of Content Miner projects"
  runPythonScripts ${GATEWAY_POD} rebuild_cm_projects.py
  brlog "INFO" "Completing submitting rebuild datasets of Content Miner projects. It will be rebuilt soon."
fi

if [ `compare_version "${BACKUP_FILE_VERSION}" 2.1.2` -le 0 ] ; then
  brlog "INFO" "Rebuild all collections."
  runPythonScripts ${GATEWAY_POD} rebuild_collections.py
  brlog "INFO" "Completed submitting the requsts of rebuild collections. They will be rebuilt soon."
fi

brlog "INFO" "Completed post restore scripts"

export KUBECTL_ARGS=${ORG_KUBECTL_ARGS}

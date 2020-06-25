#!/bin/bash

set -euo pipefail

printUsage() {
  echo "Usage: $(basename ${0}) [releaseName] [-n namespace]"
  exit 1
}

runPythonScripts() {
  POD=$1
  SCRIPT=$2
  kubectl ${KUBECTL_ARGS} cp "src/${SCRIPT}" ${POD}:/tmp/
  kubectl ${KUBECTL_ARGS} exec ${POD} -- bash -c "pip3 install -q --user --no-cache-dir requests && \
  export MANAGEMENT_PORT=${MANAGEMENT_PORT} && \
  export ZING_PORT=${ZING_PORT} && \
  export PG_JAR="${PG_JAR}" && \
  python3 /tmp/${SCRIPT}"
  kubectl ${KUBECTL_ARGS} exec ${POD} -- bash -c "rm -f /tmp/${SCRIPT}"
}

if [ $# -lt 1 ] ; then
  printUsage
fi

SCRIPT_DIR=$(dirname $0)
. ${SCRIPT_DIR}/lib/function.bash
KUBECTL_ARGS=""

RELEASE_NAME=$1
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

brlog "INFO" "Running post restore scripts"

GATEWAY_POD=` kubectl get pods ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${RELEASE_NAME},run=gateway`

brlog "INFO" "Waiting for central pods to be ready..."
while :
do
  if kubectl describe pod ${KUBECTL_ARGS} -l release=${RELEASE_NAME},run=orchestrator | grep -e "ContainersReady.*False" > /dev/null ; then
    sleep 5;
  else
    brlog "INFO" "Central pods are ready";
    break;
  fi
done

export PG_JAR=""
export MANAGEMENT_PORT=9443
export ZING_PORT=9443
# If the number of gateway's container is greater than 1, this is WD 2.1.2 or later. Then we need to use nginx container to run python.
if [ `kubectl get pods ${KUBECTL_ARGS} -o jsonpath="{.items[0].spec.containers[*].name}" -l release=${RELEASE_NAME},run=gateway | wc -w` -gt 1 ] ; then
  export PG_JAR=`kubectl ${KUBECTL_ARGS} -c ingestion-api exec ${GATEWAY_POD} -- bash -c 'find /opt/ibm/wex -name "postgresql-*.jar" | tail -n 1'`
  export KUBECTL_ARGS="${KUBECTL_ARGS} -c nginx"
  export ZING_PORT=9463
else
  export PG_JAR=`kubectl ${KUBECTL_ARGS} exec ${GATEWAY_POD} -- bash -c 'find /opt/ibm/wex/wexshared -name "postgresql-*.jar" | tail -n 1'`
fi

# echo "Deleting Sample Projects"
# runPythonScripts ${GATEWAY_POD} delete_sample_project.py
# echo "Complete deleting Sample Project. It will be recreated soon."

brlog "INFO" "Submitting rebuild datasets of Content Miner projects"
runPythonScripts ${GATEWAY_POD} rebuild_cm_projects.py
brlog "INFO" "Completing submitting rebuild datasets of Content Miner projects. It will be rebuilt soon."

brlog "INFO" "Updating crawler configuration"
## update crawler configuration
runPythonScripts ${GATEWAY_POD} update_crawler_conf.py
brlog "INFO" "Completed updating crawler configuration"

brlog "INFO" "Completed post restore scripts"

export KUBECTL_ARGS=${ORG_KUBECTL_ARGS}

#!/bin/bash

set -euo pipefail

printUsage() {
  echo "Usage: $(basename ${0}) [releaseName]"
  exit 1
}

runPythonScripts() {
  POD=$1
  SCRIPT=$2
  oc ${OC_ARGS} cp "src/${SCRIPT}" ${POD}:/tmp/
  oc ${OC_ARGS} exec ${POD} -- bash -c "export MANAGEMENT_PORT=${MANAGEMENT_PORT} && \
  export ZING_PORT=${ZING_PORT} && \
  python3 /tmp/${SCRIPT}"
  oc ${OC_ARGS} exec ${POD} -- bash -c "rm -f /tmp/${SCRIPT}"
}

if [ $# -lt 1 ] ; then
  printUsage
fi

SCRIPT_DIR=$(dirname $0)
OC_ARGS="${OC_ARGS:-}"

. ${SCRIPT_DIR}/lib/function.bash

RELEASE_NAME=$1
shift
while getopts n: OPT
do
  case $OPT in
    "n" ) OC_ARGS="${OC_ARGS} --namespace=$OPTARG" ;;
esac
done

export RELEASE_NAME=${RELEASE_NAME}
export ETCD_RELEASE_NAME="crust"
export SCRIPT_DIR=${SCRIPT_DIR}
ORG_OC_ARGS=${OC_ARGS}

brlog "INFO" "Running post restore scripts"

brlog "INFO" "Waiting for central pods to be ready..."
while :
do
  if oc describe pod ${OC_ARGS} -l release=${RELEASE_NAME},run=orchestrator | grep -e "ContainersReady.*False" -e "PodScheduled.*False" > /dev/null ; then
    sleep 5;
  else
    brlog "INFO" "Central pods are ready";
    break;
  fi
done

brlog "INFO" "Completed post restore scripts"

export OC_ARGS=${ORG_OC_ARGS}

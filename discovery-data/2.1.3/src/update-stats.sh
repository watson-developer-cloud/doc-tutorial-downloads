#!/bin/bash

set -euo pipefail

printUsage() {
  echo "Usage: $(basename ${0}) [releaseName]"
  exit 1
}

if [ $# -lt 1 ] ; then
  printUsage
fi

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

echo "Update dataset Configuration..."

ETCD_POD=`kubectl get pods ${KUBECTL_ARGS} -o jsonpath="{.items[0].metadata.name}" -l release=${RELEASE_NAME},helm.sh/chart=etcd`

kubectl ${KUBECTL_ARGS} exec ${ETCD_POD} -- bash -c 'export ETCDCTL_API=3 &&
  for key in `etcdctl --insecure-skip-tls-verify=true --insecure-transport=false get --prefix --keys-only=true "/wex/global/dataset/" | grep stats.json` ; do \
    UPDATED=$(etcdctl --insecure-skip-tls-verify=true --insecure-transport=false get --prefix --print-value-only ${key} | sed -re "s/lastIngested\":[0-9]+,/lastIngested\":`date +%s%3N`,/") && \
    etcdctl --insecure-skip-tls-verify=true --insecure-transport=false put "${key}" "${UPDATED}" > /dev/null; \
  done'

echo "Updated dataset Configuration"
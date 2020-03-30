#!/bin/bash

set -euo pipefail

ROOT_DIR_PG="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd -P)"
typeset -r ROOT_DIR_PG

# shellcheck source=lib/restore-utilites.bash
source "${ROOT_DIR_PG}/lib/restore-updates.bash"
source "${ROOT_DIR_PG}/lib/function.bash"

KUBECTL_ARGS=""
PG_BACKUP="/tmp/pg_backup.tar.gz"
PG_BACKUP_DIR="pg_backup"
PG_BACKUP_PREFIX="/tmp/${PG_BACKUP_DIR}/pg_"
PG_BACKUP_SUFFIX=".dump"

printUsage() {
  echo "Usage: $(basename ${0}) [command] [releaseName] [-f backupFile] [-n namespace]"
  exit 1
}

if [ $# -lt 2 ] ; then
  printUsage
fi

COMMAND=$1
shift
RELEASE_NAME=$1
shift
while getopts f:n: OPT
do
  case $OPT in
    "f" ) BACKUP_FILE="$OPTARG" ;;
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG" ;;
  esac
done

echo "Postgressql: "
echo "Release name: $RELEASE_NAME"

# backup
if [ ${COMMAND} = 'backup' ] ; then
  PG_POD=`kubectl get pods ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${RELEASE_NAME},helm.sh/chart=postgresql`
  BACKUP_FILE=${BACKUP_FILE:-"pg_`date "+%Y%m%d_%H%M%S"`.backup"}
  echo "Start backup postgresql..."
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c 'export PGUSER=${PGUSER:-${STKEEPER_PG_SU_USERNAME}} && \
  export PGPASSWORD=${PGPASSWORD:-`cat ${STKEEPER_PG_SU_PASSWORDFILE}`} && \
  export PGHOST=${PGHOST:-localhost} && \
  rm -rf /tmp/'${PG_BACKUP_DIR}' '${PG_BACKUP}' && \
  mkdir -p /tmp/'${PG_BACKUP_DIR}' && \
  for DATABASE in $( psql -l | grep ${PGUSER} | cut -d "|" -f 1 | grep -v -e template -e postgres -e "^\s*$"); do pg_dump ${DATABASE} > '${PG_BACKUP_PREFIX}'${DATABASE}'${PG_BACKUP_SUFFIX}'; done && \
  tar zcf '${PG_BACKUP}' -C /tmp '${PG_BACKUP_DIR}
  wait_cmd ${PG_POD} "tar zcf" ${KUBECTL_ARGS}
  kube_cp_to_local ${PG_POD} "${BACKUP_FILE}" "${PG_BACKUP}" ${KUBECTL_ARGS}
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "rm -rf /tmp/${PG_BACKUP_DIR} ${PG_BACKUP}"
  echo "Done: ${BACKUP_FILE}"
fi

# restore
if [ ${COMMAND} = 'restore' ] ; then
  if [ -z ${BACKUP_FILE} ] ; then
    printUsage
  fi
  if [ ! -e "${BACKUP_FILE}" ] ; then
    echo "no such file: ${BACKUP_FILE}"
    echo "Nothing to Restore"
    echo
    exit 1
  fi

  # Check the sequetial installation. If discovery has multiple release but only a gateway release, it should be the sequetial installation.
  IS_SEQ_INS=false
  SDU_RELEASE_NAME=${RELEASE_NAME}
  RELEASE_NUM=`kubectl get pod ${KUBECTL_ARGS} -o jsonpath="{.items[*].metadata.labels.release}" -l "app.kubernetes.io/name=discovery" | tr ' ' '\n' | uniq | wc -l`
  if [ ${RELEASE_NUM} -gt 1 ] ; then
    GATEWAY_RELEASE_NUM=`kubectl get pod ${KUBECTL_ARGS} -o jsonpath="{.items[*].metadata.labels.release}" -l "app.kubernetes.io/name=discovery,run=gateway" | tr ' ' '\n' | uniq | wc -l`
    if [ ${GATEWAY_RELEASE_NUM} == 1 ] ; then
      IS_SEQ_INS=true
      SDU_RELEASE_NAME="core"
    fi
  fi

  echo "Checking the SDU Resource Type..." 
  # check sdu deployment exists. If exists, this is wd 2.1.0 or earlier. If not, this is wd 2.1.1, and the sdu resource type is statefulset
  if [ `kubectl get deployment ${KUBECTL_ARGS} -l release=${SDU_RELEASE_NAME},run=sdu | wc -l` != '0' ] ; then
    SDU_RESOURCE_TYPE="deployment"
  else
    SDU_RESOURCE_TYPE="sts"
  fi

  echo "SDU Resource Type: ${SDU_RESOURCE_TYPE}"

  SDU_API_RESOURCE=`kubectl get ${SDU_RESOURCE_TYPE} ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${SDU_RELEASE_NAME},run=sdu`
  SDU_API_REPLICAS=`kubectl get ${SDU_RESOURCE_TYPE} ${KUBECTL_ARGS} -o jsonpath='{.items[0].spec.replicas}' -l release=${SDU_RELEASE_NAME},run=sdu`
  echo "Change replicas of ${SDU_API_RESOURCE} to 0".
  kubectl scale ${SDU_RESOURCE_TYPE} ${KUBECTL_ARGS} ${SDU_API_RESOURCE} --replicas=0
  echo "Waiting for ${SDU_API_RESOURCE} to be scaled..."
  while :
  do
    if [ `kubectl get pod ${KUBECTL_ARGS} -l release=${SDU_RELEASE_NAME},run=sdu | wc -l` = '0' ] ; then
      break
    else
      sleep 1
    fi
  done
  echo "Complete scale."

  PG_POD=""

  for POD in `kubectl get pods ${KUBECTL_ARGS} -o jsonpath='{.items[*].metadata.name}' -l release=${RELEASE_NAME},helm.sh/chart=postgresql` ; do
    if kubectl logs ${KUBECTL_ARGS} --since=30s ${POD} | grep 'our db requested role is master' > /dev/null ; then
      PG_POD=${POD}
    fi
  done
  echo "Start restore postgresql: ${BACKUP_FILE}"
  kube_cp_from_local ${PG_POD} "${BACKUP_FILE}" "${PG_BACKUP}" ${KUBECTL_ARGS}
  kubectl exec ${KUBECTL_ARGS} ${PG_POD} -- bash -c 'export PGUSER=${PGUSER:-${STKEEPER_PG_SU_USERNAME}} && \
  export PGPASSWORD=${PGPASSWORD:-`cat ${STKEEPER_PG_SU_PASSWORDFILE}`} && \
  export PGHOST=${PGHOST:-localhost} && \
  cd tmp && rm -rf '${PG_BACKUP_DIR}' && tar xf '${PG_BACKUP}' && \
  for DATABASE in $(ls '${PG_BACKUP_DIR}' | cut -d "/" -f 2 | sed -e "s/^pg_//g" -e "s/.dump$//g"); do
  pgrep -f "postgres: ${PGUSER} ${PGPASSWORD} ${DATABASE}" | xargs --no-run-if-empty kill && \
  PGPASSWORD=${PGPASSWORD} psql -U ${PGUSER} -d ${DATABASE} -c "REVOKE CONNECT ON DATABASE ${DATABASE} FROM public;" && \
  PGPASSWORD=${PGPASSWORD} psql -U ${PGUSER} -d ${DATABASE} -c "SELECT pid, pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid();" && \
  dropdb --if-exists ${DATABASE} && \
  createdb ${DATABASE} && \
  PGPASSWORD=${PGPASSWORD} psql -U ${PGUSER} -d ${DATABASE} -c "GRANT CONNECT ON DATABASE ${DATABASE} TO public;" && \
  psql ${DATABASE} < '${PG_BACKUP_PREFIX}'${DATABASE}'${PG_BACKUP_SUFFIX}'; done && \
  rm -rf '${PG_BACKUP_DIR}' '${PG_BACKUP}
  wait_cmd ${PG_POD} "dropdb --if-exists" ${KUBECTL_ARGS}
  echo "Done"

  echo "Restore replicas of ${SDU_API_RESOURCE}"
  kubectl scale ${SDU_RESOURCE_TYPE} ${KUBECTL_ARGS} ${SDU_API_RESOURCE} --replicas=${SDU_API_REPLICAS}

  echo "Applying updates"
  if "${IS_SEQ_INS}" ; then
    kubectl exec ${KUBECTL_ARGS} ${PG_POD} -- bash -c 'export PGUSER=${PGUSER:-${STKEEPER_PG_SU_USERNAME}} && \
    export PGPASSWORD=${PGPASSWORD:-`cat ${STKEEPER_PG_SU_PASSWORDFILE}`} && \
    export PGHOST=${PGHOST:-localhost} && \
    psql -d ranker_training -c "ALTER TABLE queries ADD COLUMN IF NOT EXISTS usage_opt_out boolean DEFAULT true; ALTER TABLE queries ALTER COLUMN usage_opt_out SET NOT NULL;"'
  fi
  . ./lib/restore-updates.bash
  postgresql_updates
  echo "Completed Updates"
  echo
fi

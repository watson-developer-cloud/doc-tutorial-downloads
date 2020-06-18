#!/bin/bash

set -euo pipefail

ROOT_DIR_PG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
typeset -r ROOT_DIR_PG

# shellcheck source=lib/restore-utilites.bash
source "${ROOT_DIR_PG}/lib/restore-updates.bash"
source "${ROOT_DIR_PG}/lib/function.bash"

KUBECTL_ARGS=""
PG_BACKUP="/tmp/pg_backup.tar.gz"
PG_BACKUP_DIR="pg_backup"
PG_BACKUP_PREFIX="/tmp/${PG_BACKUP_DIR}/pg_"
PG_BACKUP_SUFFIX=".dump"
PG_SCRIPT_VERSION="2.1.3"
TMP_WORK_DIR="/tmp/pg_backup"
POSTGRES_CONFIG_JOB="wire-postgres"

printUsage() {
  echo "Usage: $(basename ${0}) [command] [releaseName] [-f backupFile]"
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
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG"
          SCRIPT_ARGS="-n ${OPTARG}";;
  esac
done

SCRIPT_ARGS=${SCRIPT_ARGS:-""}

echo "Postgressql: "
echo "Release name: $RELEASE_NAME"

WD_VERSION=`get_version`

# backup
if [ ${COMMAND} = 'backup' ] ; then
  PG_POD=`kubectl get pods ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${RELEASE_NAME},helm.sh/chart=postgresql,component=stolon-keeper`
  BACKUP_FILE=${BACKUP_FILE:-"pg_`date "+%Y%m%d_%H%M%S"`.backup"}
  echo "Start backup postgresql..."
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c 'export PGUSER=${PGUSER:-${STKEEPER_PG_SU_USERNAME}} && \
  export PGPASSWORD=${PGPASSWORD:-`cat ${STKEEPER_PG_SU_PASSWORDFILE}`} && \
  export PGHOST=${PGHOST:-localhost} && \
  rm -rf /tmp/'${PG_BACKUP_DIR}' '${PG_BACKUP}' && \
  mkdir -p /tmp/'${PG_BACKUP_DIR}' && \
  for DATABASE in $( psql -l | grep ${PGUSER} | cut -d "|" -f 1 | grep -v -e template -e postgres -e "^\s*$"); do pg_dump ${DATABASE} > '${PG_BACKUP_PREFIX}'${DATABASE}'${PG_BACKUP_SUFFIX}'; done && \
  touch /tmp/'${PG_BACKUP_DIR}'/version_'${PG_SCRIPT_VERSION}' && \
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

  SDU_RELEASE_NAME="core"
  SDU_RESOURCE_TYPE="sts"
  DFS_RELEASE_NAME="core"

  echo "SDU Resource Type: ${SDU_RESOURCE_TYPE}"

  SDU_API_RESOURCE=`kubectl get ${SDU_RESOURCE_TYPE} ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${SDU_RELEASE_NAME},run=sdu`
  SDU_API_REPLICAS=`kubectl get ${SDU_RESOURCE_TYPE} ${KUBECTL_ARGS} -o jsonpath='{.items[0].spec.replicas}' -l release=${SDU_RELEASE_NAME},run=sdu`
  DFS_INDUCTION_RESOURCE=`kubectl get deployment ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${DFS_RELEASE_NAME},run=dfs-induction`
  DFS_INDUCTION_REPLICAS=`kubectl get deployment ${KUBECTL_ARGS} -o jsonpath='{.items[0].spec.replicas}' -l release=${DFS_RELEASE_NAME},run=dfs-induction`
  scale_resource deployment ${DFS_INDUCTION_RESOURCE} 0 false
  scale_resource sts ${SDU_API_RESOURCE} 0 true
  trap "scale_resource sts ${SDU_API_RESOURCE} ${SDU_API_REPLICAS} false; scale_resource deployment ${DFS_INDUCTION_RESOURCE} ${DFS_INDUCTION_REPLICAS} false" 0 1 2 3 15

  PG_POD=""

  for POD in `kubectl get pods ${KUBECTL_ARGS} -o jsonpath='{.items[*].metadata.name}' -l release=${RELEASE_NAME},helm.sh/chart=postgresql,component=stolon-keeper` ; do
    if kubectl logs ${KUBECTL_ARGS} --since=30s ${POD} | grep 'our db requested role is master' > /dev/null ; then
      PG_POD=${POD}
    fi
  done
  echo "Start restore postgresql: ${BACKUP_FILE}"

  mkdir -p ${TMP_WORK_DIR}
  echo 'export PGUSER=${PGUSER:-${STKEEPER_PG_SU_USERNAME}} && \
  export PGPASSWORD=${PGPASSWORD:-`cat ${STKEEPER_PG_SU_PASSWORDFILE}`} && \
  export PGHOST=${PGHOST:-localhost} && \
  cd tmp && rm -rf '${PG_BACKUP_DIR}' && tar xf '${PG_BACKUP}' && \
  for DATABASE in $(ls '${PG_BACKUP_DIR}'/*.dump | cut -d "/" -f 2 | sed -e "s/^pg_//g" -e "s/.dump$//g"); do
  pgrep -f "postgres: ${PGUSER} ${PGPASSWORD} ${DATABASE}" | xargs --no-run-if-empty kill && \
  PGPASSWORD=${PGPASSWORD} psql -U ${PGUSER} -d ${DATABASE} -c "REVOKE CONNECT ON DATABASE ${DATABASE} FROM public;" && \
  PGPASSWORD=${PGPASSWORD} psql -U ${PGUSER} -d ${DATABASE} -c "SELECT pid, pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid();" && \
  dropdb --if-exists ${DATABASE} && \
  createdb ${DATABASE} && \
  PGPASSWORD=${PGPASSWORD} psql -U ${PGUSER} -d ${DATABASE} -c "GRANT CONNECT ON DATABASE ${DATABASE} TO public;" && \
  psql ${DATABASE} < '${PG_BACKUP_PREFIX}'${DATABASE}'${PG_BACKUP_SUFFIX}'; done && \
  rm -rf '${PG_BACKUP_DIR}' '${PG_BACKUP} > ${TMP_WORK_DIR}/pg_restore.sh

  kube_cp_from_local ${PG_POD} "${BACKUP_FILE}" "${PG_BACKUP}" ${KUBECTL_ARGS}
  kubectl cp ${KUBECTL_ARGS} ${TMP_WORK_DIR}/pg_restore.sh ${PG_POD}:/tmp/pg_restore.sh
  kubectl exec ${KUBECTL_ARGS} ${PG_POD} -- bash -c 'chmod +x /tmp/pg_restore.sh && /tmp/pg_restore.sh &> /tmp/pg_restore.log &'
  wait_cmd ${PG_POD} "/tmp/pg_restore.sh" ${KUBECTL_ARGS}
  kubectl exec ${KUBECTL_ARGS} ${PG_POD} -- bash -c 'cat /tmp/pg_restore.log; rm -rf /tmp/pg_restore.sh /tmp/pg_restore.log'
  echo "Done"

  echo "Run postgres-config job"
  ./run-postgres-config-job.sh ${SCRIPT_ARGS}

  echo "Restore replicas of ${SDU_API_RESOURCE}"
  scale_resource sts ${SDU_API_RESOURCE} ${SDU_API_REPLICAS} false
  scale_resource deployment ${DFS_INDUCTION_RESOURCE} ${DFS_INDUCTION_REPLICAS} false
  trap 0 1 2 3 15

  echo "Applying updates"
  . ./lib/restore-updates.bash
  postgresql_updates
  echo "Completed Updates"
  echo
fi

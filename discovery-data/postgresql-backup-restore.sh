#!/bin/bash

set -euo pipefail

ROOT_DIR_PG="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd -P)"
typeset -r ROOT_DIR_PG

# shellcheck source=lib/restore-utilites.bash
source "${ROOT_DIR_PG}/lib/restore-updates.bash"

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
  PG_POD=`kubectl get pod ${KUBECTL_ARGS} -l component=postgresql -o jsonpath="{.items[*].metadata.name}" | sed -n 1p`
  BACKUP_FILE=${BACKUP_FILE:-"pg_`date "+%Y%m%d_%H%M%S"`.backup"}
  echo "Start backup postgresql..."
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c 'source "${WEX_HOME}/sbin/profile.sh" && \
  mkdir -p /tmp/'${PG_BACKUP_DIR}' && \
  for DATABASE in $( psql -l | grep dadmin | cut -d "|" -f 1 | grep -v -e template -e postgres -e "^\s*$"); do pg_dump ${DATABASE} > '${PG_BACKUP_PREFIX}'${DATABASE}'${PG_BACKUP_SUFFIX}'; done && \
  tar zcf '${PG_BACKUP}' -C /tmp '${PG_BACKUP_DIR}
  kubectl ${KUBECTL_ARGS} cp "${PG_POD}:${PG_BACKUP}" "${BACKUP_FILE}"
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "rm -rf /tmp/${PG_BACKUP_DIR}"
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
  PG_POD=`kubectl get pods ${KUBECTL_ARGS} | grep "${RELEASE_NAME}-watson-discovery" | grep -e "gateway" | grep -v "watson-discovery-*-test" | cut -d ' ' -f 1 | sed -n 1p`
  echo "Start restore postgresql: ${BACKUP_FILE}"
  kubectl cp "${BACKUP_FILE}" "${PG_POD}:${PG_BACKUP}" ${KUBECTL_ARGS}
  kubectl exec ${KUBECTL_ARGS} ${PG_POD} -- bash -c 'source "${WEX_HOME}/sbin/profile.sh" && \
  cd tmp && tar xf '${PG_BACKUP}' && \
  for DATABASE in $(ls '${PG_BACKUP_DIR}' | cut -d "/" -f 2 | sed -e "s/^pg_//g" -e "s/.dump$//g"); do 
  pgrep -f "postgres: ${PGUSER} ${PGPASSWORD} ${DATABASE}" | xargs --no-run-if-empty kill && \
  PGPASSWORD=${PGPASSWORD} psql -U ${PGUSER} -d ${DATABASE} -c "REVOKE CONNECT ON DATABASE ${DATABASE} FROM public;" && \
  PGPASSWORD=${PGPASSWORD} psql -U ${PGUSER} -d ${DATABASE} -c "SELECT pid, pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid();" && \
  dropdb --if-exists ${DATABASE} && \
  createdb ${DATABASE} && \
  PGPASSWORD=${PGPASSWORD} psql -U ${PGUSER} -d ${DATABASE} -c "GRANT CONNECT ON DATABASE ${DATABASE} TO public;" && \
  psql ${DATABASE} < '${PG_BACKUP_PREFIX}'${DATABASE}'${PG_BACKUP_SUFFIX}'; done && \
  rm -rf '${PG_BACKUP_DIR}' '${PG_BACKUP}
  echo "Done"
  echo "Applying updates"
  ./lib/restore-updates.bash
  postgresql_updates
  echo "Completed Updates"
  echo
fi


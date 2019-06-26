#!/bin/bash

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
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} -n $OPTARG" ;;
  esac
done

echo "Release name: $RELEASE_NAME"

PG_PODS=`kubectl ${KUBECTL_ARGS} get pods | grep "${RELEASE_NAME}-watson-discovery-postgresql" | grep -v watson-discovery-postgresql-test | cut -d ' ' -f 1`

# backup
if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"pg_`date "+%Y%m%d_%H%M%S"`.backup"}
  echo "Start backup postgresql..."
  PG_POD=`echo ${PG_PODS} | tr ' ' $'\n' | sed -n 1p`
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
    exit 1
  fi
  echo "Start restore postgresql: ${BACKUP_FILE}"
  for PG_POD in ${PG_PODS}
  do
    echo "Restore to ${PG_POD}..."
    kubectl ${KUBECTL_ARGS} cp "${BACKUP_FILE}" "${PG_POD}:${PG_BACKUP}"
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c 'source "${WEX_HOME}/sbin/profile.sh" && \
    cd tmp && tar xf '${PG_BACKUP}' && \
    for DATABASE in $(ls '${PG_BACKUP_DIR}' | cut -d "/" -f 2 | sed -e "s/^pg_//g" -e "s/.dump$//g"); do 
    pgrep -f "postgres: ${PGUSER} ${DATABASE}" | xargs --no-run-if-empty kill && \
    dropdb ${DATABASE} && \
    createdb ${DATABASE} && \
    psql ${DATABASE} < '${PG_BACKUP_PREFIX}'${DATABASE}'${PG_BACKUP_SUFFIX}'; done && \
    rm -rf '${PG_BACKUP_DIR}' '${PG_BACKUP}
  done
  echo "Done"
fi

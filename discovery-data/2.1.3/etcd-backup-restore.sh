#!/bin/bash

set -euo pipefail

ROOT_DIR_ETCD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
typeset -r ROOT_DIR_ETCD

# shellcheck source=lib/restore-utilites.bash
source "${ROOT_DIR_ETCD}/lib/restore-updates.bash"
source "${ROOT_DIR_ETCD}/lib/function.bash"

KUBECTL_ARGS=""
ETCD_BACKUP="/tmp/etcd.backup"
ETCD_BACKUP_DIR="/tmp/etcd_backup"
ETCD_BACKUP_FILE="${ETCD_BACKUP_DIR}/etcd_snapshot.db"
TMP_WORK_DIR="tmp/etcd_backup"
PG_SERVICE_FILE="${ETCD_BACKUP_DIR}/pg_service_name.txt"
DATASTORE_ARCHIVE_OPTION="${DATASTORE_ARCHIVE_OPTION--z}"
ETCD_ARCHIVE_OPTION="${ETCD_ARCHIVE_OPTION-$DATASTORE_ARCHIVE_OPTION}"
if [ -n "${ETCD_ARCHIVE_OPTION}" ] ; then
  read -a ETCD_TAR_OPTIONS <<< ${ETCD_ARCHIVE_OPTION}
else
  ETCD_TAR_OPTIONS=("")
fi
VERIFY_ARCHIVE=${VERIFY_ARCHIVE:-true}
VERIFY_DATASTORE_ARCHIVE=${VERIFY_DATASTORE_ARCHIVE:-$VERIFY_ARCHIVE}
ARCHIVE_ON_LOCAL=${ARCHIVE_ON_LOCAL:-false}

printUsage() {
  echo "Usage: $(basename ${0}) [command] [releaseName] [-f backupFile]"
  exit 1
}

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

GATEWAY_RELEASE_NAME="core"
PG_RELEASE_NAME="crust"

mkdir -p ${TMP_WORK_DIR}

GATEWAY_POD=`kubectl get pod ${KUBECTL_ARGS} -o jsonpath="{.items[0].metadata.name}" -l release=${GATEWAY_RELEASE_NAME},run=gateway`
PG_SERVICE_NAME=`kubectl exec ${KUBECTL_ARGS} ${GATEWAY_POD} -- bash -c 'echo -n ${PGHOST}'`
PGPORT=`kubectl get svc ${KUBECTL_ARGS} -o jsonpath='{.items[0].spec.ports[0].port}' -l release=${PG_RELEASE_NAME},component=stolon-proxy`

brlog "INFO" "ETCD: "
brlog "INFO" "Release name: $RELEASE_NAME"

# backup etcd
if [ ${COMMAND} = 'backup' ] ; then
  ETCD_POD=`kubectl get pods ${KUBECTL_ARGS} -o jsonpath="{.items[0].metadata.name}" -l release=${RELEASE_NAME},helm.sh/chart=etcd`
  BACKUP_FILE=${BACKUP_FILE:-"etcd_snapshot_`date "+%Y%m%d_%H%M%S"`.db"}
  brlog "INFO" "Start backup etcd..."
  ETCD_ENDPOINT=`kubectl ${KUBECTL_ARGS} exec ${ETCD_POD} -- bash -c 'echo -n ${ETCD_INITIAL_ADVERTISE_PEER_URLS}'`
  kubectl ${KUBECTL_ARGS} exec ${ETCD_POD} --  bash -c "rm -rf ${ETCD_BACKUP_DIR} ${ETCD_BACKUP} && \
  mkdir -p ${ETCD_BACKUP_DIR} && \
  ETCDCTL_API=3 etcdctl --insecure-skip-tls-verify=true --insecure-transport=false --endpoints ${ETCD_ENDPOINT} get --prefix '/' -w fields > ${ETCD_BACKUP_FILE} && \
  echo -n '${PG_SERVICE_NAME}' > ${PG_SERVICE_FILE}"
  wait_cmd ${ETCD_POD} "etcdctl --insecure-skip-tls-verify=true" ${KUBECTL_ARGS}
  if "${ARCHIVE_ON_LOCAL}" ; then 
    brlog "INFO" "Transferring backup files"
    mkdir -p "`dirname ${TMP_WORK_DIR}${ETCD_BACKUP_DIR}`"
    kube_cp_to_local -r ${ETCD_POD} "${TMP_WORK_DIR}${ETCD_BACKUP_DIR}" "${ETCD_BACKUP_DIR}" ${KUBECTL_ARGS}
    kubectl ${KUBECTL_ARGS} exec ${ETCD_POD} -- bash -c "rm -rf ${ETCD_BACKUP_DIR}"
    brlog "INFO" "Archiving data"
    tar ${ETCD_TAR_OPTIONS[@]} -cf "${BACKUP_FILE}" -C "${TMP_WORK_DIR}${ETCD_BACKUP_DIR}" .
  else
    brlog "INFO" "Archiving data..."
    kubectl ${KUBECTL_ARGS} exec ${ETCD_POD} -- bash -c "tar ${ETCD_ARCHIVE_OPTION} -cf ${ETCD_BACKUP} -C ${ETCD_BACKUP_DIR} ."
    brlog "INFO" "Trasnfering archive..."
    kube_cp_to_local ${ETCD_POD} "${BACKUP_FILE}" "${ETCD_BACKUP}" ${KUBECTL_ARGS}
    kubectl ${KUBECTL_ARGS} exec ${ETCD_POD} --  bash -c "rm -rf ${ETCD_BACKUP_DIR} ${ETCD_BACKUP}"
  fi
  if "${VERIFY_DATASTORE_ARCHIVE}" && brlog "INFO" "Verifying backup archive" && ! tar ${ETCD_TAR_OPTIONS[@]} -tf ${BACKUP_FILE} &> /dev/null ; then
    brlog "ERROR" "Backup file is broken, or does not exist."
    exit 1
  fi
  brlog "INFO" "Done: ${BACKUP_FILE}"
fi

# restore etcd
if [ ${COMMAND} = 'restore' ] ; then
  if [ -z ${BACKUP_FILE} ] ; then
    printUsage
  fi
  if [ ! -e "${BACKUP_FILE}" ] ; then
    brlog "WARN" "no such file: ${BACKUP_FILE}"
    brlog "WARN" "Nothing to Restore"
    echo
    exit 1
  fi
  ETCD_POD=`kubectl get pods ${KUBECTL_ARGS} -o jsonpath="{.items[0].metadata.name}" -l release=${RELEASE_NAME},helm.sh/chart=etcd`
  REPLACE_SVC_STRING="-watson-discovery-postgresql"
  brlog "INFO" "Start restore etcd: ${BACKUP_FILE}"
  if "${ARCHIVE_ON_LOCAL}" ; then
    brlog "INFO" "Extracting archive"
    mkdir -p "${TMP_WORK_DIR}${ETCD_BACKUP_DIR}"
    tar ${ETCD_TAR_OPTIONS[@]} -xf ${BACKUP_FILE} -C "${TMP_WORK_DIR}${ETCD_BACKUP_DIR}"
    brlog "INFO" "Transferring backup files"
    kube_cp_from_local -r ${ETCD_POD} "${TMP_WORK_DIR}${ETCD_BACKUP_DIR}" "${ETCD_BACKUP_DIR}" ${KUBECTL_ARGS}
  else
    brlog "INFO" "Transferting archive..."
    kube_cp_from_local ${ETCD_POD} "${BACKUP_FILE}" "${ETCD_BACKUP}" ${KUBECTL_ARGS}
    brlog "INFO" "Extracting archive..."
    kubectl ${KUBECTL_ARGS} exec ${ETCD_POD} -- bash -c "rm -rf ${ETCD_BACKUP_DIR} && mkdir -p ${ETCD_BACKUP_DIR} && tar -C ${ETCD_BACKUP_DIR} ${ETCD_ARCHIVE_OPTION} -xf ${ETCD_BACKUP}"
  fi
  kubectl ${KUBECTL_ARGS} exec ${ETCD_POD} -- bash -c 'export ETCDCTL_API=3 && \
  export ETCD_BACKUP='${ETCD_BACKUP_FILE}' && \
  export REPLACE_SVC_STRING=`cat '${PG_SERVICE_FILE}'` && \
  etcdctl --insecure-skip-tls-verify=true --insecure-transport=false del --prefix "/" && \
  sed -i -e "s@jdbc://jdbc%3Apostgresql%3A%2F%2F.*${REPLACE_SVC_STRING}.*%2Fdadmin@jdbc://jdbc%3Apostgresql%3A%2F%2F'${PG_SERVICE_NAME}'%3A'${PGPORT}'%2Fdadmin@g" ${ETCD_BACKUP} && \
  sed -i -e "s@jdbc:postgresql://.*${REPLACE_SVC_STRING}.*/dadmin@jdbc:postgresql://'${PG_SERVICE_NAME}':'${PGPORT}'/dadmin@g" ${ETCD_BACKUP} && \
  cat ${ETCD_BACKUP} | grep -e "\"Key\" : " -e "\"Value\" :" | sed -e "s/^\"Key\" : \"\(.*\)\"$/\1\t/g" -e "s/^\"Value\" : \"\(.*\)\"$/\1\t/g" | awk '"'"'{ORS="";print}'"'"' | sed -e "s/\\\\n/\\n/g" -e "s/\\\\\"/\"/g" | sed -e "s/\\\\\\\\/\\\\/g"  | xargs --no-run-if-empty -t -d "\t" -n2 etcdctl --insecure-skip-tls-verify=true --insecure-transport=false put && \
  rm -rf ${ETCD_BACKUP} '${ETCD_BACKUP_DIR}
  wait_cmd ${ETCD_POD} "etcdctl --insecure-skip-tls-verify=true --insecure-transport=false put" ${KUBECTL_ARGS}
  brlog "INFO" "Done"
  brlog "INFO" "Applying updates"
  . ./lib/restore-updates.bash
  etcd_updates
  brlog "INFO" "Completed Updates"
  echo
fi


rm -rf ${TMP_WORK_DIR}
if [ -z "$(ls tmp)" ] ; then
  rm -rf tmp
fi
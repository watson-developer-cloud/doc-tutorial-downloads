#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
typeset -r SCRIPT_DIR

# shellcheck source=lib/restore-utilites.bash
source "${SCRIPT_DIR}/lib/restore-updates.bash"
source "${SCRIPT_DIR}/lib/function.bash"

OC_ARGS="${OC_ARGS:-}"
ETCD_BACKUP="/tmp/etcd.backup"
ETCD_BACKUP_DIR="/tmp/etcd_backup"
ETCD_BACKUP_FILE="${ETCD_BACKUP_DIR}/etcd_snapshot.db"
PG_SERVICE_FILE="${ETCD_BACKUP_DIR}/pg_service_name.txt"
TMP_WORK_DIR="tmp/etcd_workspace"
CURRENT_COMPONENT="etcd"

printUsage() {
  echo "Usage: $(basename ${0}) [command] [tenantName] [-f backupFile]"
  exit 1
}

COMMAND=$1
shift
TENANT_NAME=$1
shift
while getopts f:n: OPT
do
  case $OPT in
    "f" ) BACKUP_FILE="$OPTARG" ;;
    "n" ) OC_ARGS="${OC_ARGS} --namespace=$OPTARG" ;;
  esac
done

brlog "INFO" "ETCD: "
brlog "INFO" "Tenant name: $TENANT_NAME"

ETCD_ARCHIVE_OPTION="${ETCD_ARCHIVE_OPTION--z}"
if [ -n "${ETCD_ARCHIVE_OPTION}" ] ; then
  read -a ETCD_TAR_OPTIONS <<< ${ETCD_ARCHIVE_OPTION}
else
  ETCD_TAR_OPTIONS=("")
fi
VERIFY_ARCHIVE=${VERIFY_ARCHIVE:-true}
VERIFY_DATASTORE_ARCHIVE=${VERIFY_DATASTORE_ARCHIVE:-$VERIFY_ARCHIVE}
ARCHIVE_ON_LOCAL=${ARCHIVE_ON_LOCAL:-false}

rm -rf ${TMP_WORK_DIR}
mkdir -p ${TMP_WORK_DIR}
mkdir -p ${BACKUP_RESTORE_LOG_DIR}

wd_version=${WD_VERSION:-$(get_version)}

setup_etcd_env

# backup etcd
if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"etcd_snapshot_$(date "+%Y%m%d_%H%M%S").db"}
  brlog "INFO" "Start backup etcd..."
  run_cmd_in_pod ${ETCD_POD} "rm -rf ${ETCD_BACKUP_DIR} ${ETCD_BACKUP} && \
  mkdir -p ${ETCD_BACKUP_DIR} && \
  export ETCDCTL_USER='${ETCD_USER}:${ETCD_PASSWORD}' && \
  export ETCDCTL_CERT='/etc/etcdtls/operator/etcd-tls/etcd-client.crt' && \
  export ETCDCTL_CACERT='/etc/etcdtls/operator/etcd-tls/etcd-client-ca.crt' && \
  export ETCDCTL_KEY='/etc/etcdtls/operator/etcd-tls/etcd-client.key' && \
  export ETCDCTL_ENDPOINTS='https://${ETCD_SERVICE}:2379' && \
  etcdctl get --prefix '/' -w fields > ${ETCD_BACKUP_FILE}" ${OC_ARGS}

  if "${ARCHIVE_ON_LOCAL}" ; then 
    brlog "INFO" "Transferring backup files"
    mkdir -p "$(dirname ${TMP_WORK_DIR}${ETCD_BACKUP_DIR})"
    kube_cp_to_local -r ${ETCD_POD} "${TMP_WORK_DIR}${ETCD_BACKUP_DIR}" "${ETCD_BACKUP_DIR}" ${OC_ARGS}
    oc ${OC_ARGS} exec ${ETCD_POD} -- bash -c "rm -rf ${ETCD_BACKUP_DIR}"
    brlog "INFO" "Archiving data"
    tar "${ETCD_TAR_OPTIONS[@]}" -cf "${BACKUP_FILE}" -C "${TMP_WORK_DIR}${ETCD_BACKUP_DIR}" .
  else
    brlog "INFO" "Archiving data..."
    run_cmd_in_pod ${ETCD_POD} "tar ${ETCD_ARCHIVE_OPTION} -cf ${ETCD_BACKUP} -C ${ETCD_BACKUP_DIR} ." ${OC_ARGS}
    brlog "INFO" "Trasnfering archive..."
    kube_cp_to_local ${ETCD_POD} "${BACKUP_FILE}" "${ETCD_BACKUP}" ${OC_ARGS}
    oc ${OC_ARGS} exec ${ETCD_POD} --  bash -c "rm -rf ${ETCD_BACKUP_DIR} ${ETCD_BACKUP}"
  fi
  if "${VERIFY_DATASTORE_ARCHIVE}" && brlog "INFO" "Verifying backup archive" && ! tar "${ETCD_TAR_OPTIONS[@]}" -tf ${BACKUP_FILE} &> /dev/null ; then
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
  brlog "INFO" "Start restore etcd: ${BACKUP_FILE}"

  if "${ARCHIVE_ON_LOCAL}" ; then
    brlog "INFO" "Extracting archive"
    mkdir -p "${TMP_WORK_DIR}${ETCD_BACKUP_DIR}"
    tar "${ETCD_TAR_OPTIONS[@]}" -xf ${BACKUP_FILE} -C "${TMP_WORK_DIR}${ETCD_BACKUP_DIR}"
    brlog "INFO" "Transferring backup files"
    kube_cp_from_local -r ${ETCD_POD} "${TMP_WORK_DIR}${ETCD_BACKUP_DIR}" "${ETCD_BACKUP_DIR}" ${OC_ARGS}
  else
    brlog "INFO" "Transferting archive..."
    kube_cp_from_local ${ETCD_POD} "${BACKUP_FILE}" "${ETCD_BACKUP}" ${OC_ARGS}
    brlog "INFO" "Extracting archive..."
    run_cmd_in_pod ${ETCD_POD} "rm -rf ${ETCD_BACKUP_DIR} && mkdir -p ${ETCD_BACKUP_DIR} && tar -C ${ETCD_BACKUP_DIR} ${ETCD_ARCHIVE_OPTION} -xf ${ETCD_BACKUP}" ${OC_ARGS}
  fi
  brlog "INFO" "Restoring data..."
  cmd='export ETCDCTL_API=3 && \
  export ETCDCTL_USER='${ETCD_USER}':'${ETCD_PASSWORD}' && \
  export ETCDCTL_CERT=/etc/etcdtls/operator/etcd-tls/etcd-client.crt && \
  export ETCDCTL_CACERT=/etc/etcdtls/operator/etcd-tls/etcd-client-ca.crt && \
  export ETCDCTL_KEY=/etc/etcdtls/operator/etcd-tls/etcd-client.key && \
  export ETCDCTL_ENDPOINTS=https://'${ETCD_SERVICE}':2379 && \
  export ETCD_BACKUP='${ETCD_BACKUP_FILE}' && \
  etcdctl del --prefix "/" && \
  cat ${ETCD_BACKUP} | \
  grep -e "\"Key\" : " -e "\"Value\" :" | \
  sed -e "s/^\"Key\" : \"\(.*\)\"$/\1\t/g" -e "s/^\"Value\" : \"\(.*\)\"$/\1\t/g" | \
  awk '"'"'{ORS="";print}'"'"' | \
  sed -e '"'"'s/\\\\n/\\n/g'"'"' -e "s/\\\\\"/\"/g" | \
  sed -e "s/\\\\\\\\/\\\\/g" | '

  if [ $(compare_version "$(get_version)" "4.0.6") -ge 0 ] && [ $(compare_version "$(get_backup_version)" "4.0.6") -ge 0 ] ; then
    instance_tupples=$(get_instance_tuples)
    for tuple in ${instance_tupples}
    do
      ORG_IFS=${IFS}
      IFS=","
      set -- ${tuple}
      IFS=${ORG_IFS}
      # source and destination tenant IDs
      src=$1
      dst=$2
      if [ "${src}" = "${dst}" ] ; then
        continue
      fi
      cmd+="sed -e 's/${src}/${dst}/g' | "
    done
  fi

  cmd+='while read -r -d $'"'\t'"' line1 ; read -r -d $'"'\t'"' line2; do etcdctl put "$line1" "$line2" ; done && \
  rm -rf ${ETCD_BACKUP} '${ETCD_BACKUP_DIR} ${OC_ARGS}
  run_cmd_in_pod ${ETCD_POD} "${cmd}"
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
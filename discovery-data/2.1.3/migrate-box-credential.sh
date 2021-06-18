#!/bin/bash

set -euo pipefail

printUsage() {
  echo "Usage:
  $(basename ${0}) <command> <output_json_file> <user_data_directory> <backup_file>"
  exit 1
}

runPythonScripts() {
  POD=$1
  shift
  SCRIPT=$1
  shift
  EXTRA_ARGS="$@"
  kubectl ${KUBECTL_ARGS} cp "src/${SCRIPT}" ${POD}:/tmp/
  kubectl ${KUBECTL_ARGS} exec ${POD} -- bash -c "export MANAGEMENT_PORT=${MANAGEMENT_PORT} && \
  export ZING_PORT=${ZING_PORT} && \
  python3 /tmp/${SCRIPT} ${EXTRA_ARGS}"
  kubectl ${KUBECTL_ARGS} exec ${POD} -- bash -c "rm -f /tmp/${SCRIPT}"
}

if [ $# -lt 2 ] ; then
  printUsage
fi

SCRIPT_DIR=$(dirname $0)
KUBECTL_ARGS=""

. ${SCRIPT_DIR}/lib/function.bash

CMD=$1
shift
USER_JSON_MAPPING=$1
shift

SCRIPT_DIR=${SCRIPT_DIR}
ORG_KUBECTL_ARGS=${KUBECTL_ARGS}
TMP_WORK_DIR="tmp/backup"
ETCD_BACKUP_FILE="etcd.backup"
ETCD_SNAPSHOT_FILE="etcd_snapshot.db"
USER_DATA_ARCHIVE="mnt.tgz"
GATEWAY_RELEASE_NAME="core"
MAKE_JSON_SCRIPT="make_box_mapping.py"
MIGRATE_BOX_SCRIPT="migrate_box_crawler.py"
LIST_FILES_SCRIPT="list_files_to_be_resourced.py"
BOX_JSON_MAPPING="user_mapping.json"
MANAGEMENT_PORT=9443
ZING_PORT=9463
USER_DATA_ARCHIVE_OPTION=${USER_DATA_ARCHIVE_OPTION:-""}

GATEWAY_POD=`kubectl get pods ${KUBECTL_ARGS} -o jsonpath='{.items[0].metadata.name}' -l release=${GATEWAY_RELEASE_NAME},run=gateway`

KUBECTL_ARGS="${KUBECTL_ARGS} -c nginx"

if [ "${CMD}" = "make-json" ] ; then
  brlog "INFO" "Making json file for user and password mapping"
  runPythonScripts ${GATEWAY_POD} ${MAKE_JSON_SCRIPT} /tmp/${BOX_JSON_MAPPING}
  wait_cmd ${GATEWAY_POD} "python3 /tmp/${MAKE_JSON_SCRIPT}" ${KUBECTL_ARGS}
  kubectl cp ${KUBECTL_ARGS} ${POD}:/tmp/${BOX_JSON_MAPPING} "${USER_JSON_MAPPING}"
  kubectl exec ${KUBECTL_ARGS} ${POD} -- bash -c "rm -rf /tmp/${BOX_JSON_MAPPING}"
  brlog "INFO" "Done ${USER_JSON_MAPPING}"
fi

if [ "${CMD}" = "migrate" ] ; then

  if [ $# -lt 2 ] ; then
    printUsage
  fi

  brlog "INFO" "Migrate the box credentials."

  USER_DATA_DIR=$1
  shift
  BACKUP_FILE=$1
  shift

  mkdir -p ${TMP_WORK_DIR}

  brlog "INFO" "Extracting backup file..."
  tar xf ${BACKUP_FILE} -C ${TMP_WORK_DIR}

  if [ ! -e ${TMP_WORK_DIR}/${ETCD_SNAPSHOT_FILE} ] ; then 
    tar xf ${TMP_WORK_DIR}/tmp/${ETCD_BACKUP_FILE} -C ${TMP_WORK_DIR}
  fi

  brlog "INFO" "Getting the list of the migration files"
  kubectl cp ${KUBECTL_ARGS} ${TMP_WORK_DIR}/${ETCD_SNAPSHOT_FILE} ${GATEWAY_POD}:/tmp/${ETCD_SNAPSHOT_FILE}

  MIGRATION_FILES=`runPythonScripts ${GATEWAY_POD} ${LIST_FILES_SCRIPT} /tmp/${ETCD_SNAPSHOT_FILE}`
  tar zcf ${TMP_WORK_DIR}/${USER_DATA_ARCHIVE} -C ${USER_DATA_DIR} ${MIGRATION_FILES}

  brlog "INFO" "Transferring migration files..."
  kubectl cp ${KUBECTL_ARGS} "${USER_JSON_MAPPING}" ${GATEWAY_POD}:/tmp/${BOX_JSON_MAPPING}
  kubectl cp ${KUBECTL_ARGS} ${TMP_WORK_DIR}/${USER_DATA_ARCHIVE} ${GATEWAY_POD}:/tmp/${USER_DATA_ARCHIVE}

  kubectl exec ${KUBECTL_ARGS} ${GATEWAY_POD} -- bash -c "mkdir -p /tmp/mnt && tar xf /tmp/${USER_DATA_ARCHIVE} -C /tmp/mnt"
  wait_cmd ${GATEWAY_POD} "mkdir -p /tmp/mnt" ${KUBECTL_ARGS}

  brlog "INFO" "Start migraion."
  runPythonScripts ${GATEWAY_POD} ${MIGRATE_BOX_SCRIPT} /tmp /tmp/${BOX_JSON_MAPPING} 
  wait_cmd ${GATEWAY_POD} "python3 /tmp/${MAKE_JSON_SCRIPT}" ${KUBECTL_ARGS}
  kubectl exec ${KUBECTL_ARGS} ${GATEWAY_POD} -- bash -c "rm -rf /tmp/${BOX_JSON_MAPPING} /tmp/mnt"

  rm -rf ${TMP_WORK_DIR}
  if [ -z "$(ls tmp)" ] ; then
    rm -rf tmp
  fi

  brlog "INFO" "Done"
fi

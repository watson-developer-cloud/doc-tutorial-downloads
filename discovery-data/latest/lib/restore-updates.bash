#!/bin/bash

set -euo pipefail

UPDATE_DIR="$SCRIPT_DIR/src"
source "${SCRIPT_DIR}/lib/function.bash"

ELASTIC_POD_CONTAINER=$(get_elastic_pod_container)
ETCD_VARIABLES=$(export_etcd_variable_command)

elastic_updates(){
  if ls "$UPDATE_DIR"/*.elupdate &> /dev/null ; then
    for ELASTIC_COMMAND in "$UPDATE_DIR"/*.elupdate; do
      value=$(<${ELASTIC_COMMAND})
      oc ${OC_ARGS} exec ${ELASTIC_POD} -c "${ELASTIC_POD_CONTAINER}" -- bash -c "${value}" >> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
    done
  fi
  if [ $(compare_version "${BACKUP_FILE_VERSION:-$(get_backup_version)}" "2.1.2") -le 0 ] ; then 
    if ls "$UPDATE_DIR"/*.elupdate_script &> /dev/null ; then
      for ELASTIC_COMMAND in "$UPDATE_DIR"/*.elupdate_script; do
        UPDATE_SCRIPT_NAME=$(basename ${ELASTIC_COMMAND})
        _oc_cp ${ELASTIC_COMMAND} ${ELASTIC_POD}:/tmp/${UPDATE_SCRIPT_NAME} ${OC_ARGS}
        oc ${OC_ARGS} exec ${ELASTIC_POD} -c "${ELASTIC_POD_CONTAINER}" -- bash /tmp/${UPDATE_SCRIPT_NAME}
        oc ${OC_ARGS} exec ${ELASTIC_POD} -c "${ELASTIC_POD_CONTAINER}" -- rm /tmp/${UPDATE_SCRIPT_NAME}
      done
    fi
  fi
}

etcd_updates(){
  if ls "$UPDATE_DIR"/*.etcdupdate &> /dev/null ; then
    for ETCD_COMMAND in "$UPDATE_DIR"/*.etcdupdate; do
      value=$(<${ETCD_COMMAND})
      oc ${OC_ARGS} exec ${ETCD_POD} -- sh -c "export ETCDCTL_API=3 && \
        ${ETCD_VARIABLES} && \
        ${value}" >> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
    done
  fi
}

hdp_updates(){
  if ls "$UPDATE_DIR"/*.hdpupdate &> /dev/null ; then
    for HDP_COMMAND in "$UPDATE_DIR"/*.hdpupdate; do
      value=$(<${HDP_COMMAND})
      oc ${OC_ARGS} exec ${HDP_POD} -- bash -c "${value}"
    done
  fi
}

postgresql_updates(){
  if ls "$UPDATE_DIR"/*.pgupdate &> /dev/null ; then
    for PSQL_COMMAND in "$UPDATE_DIR"/*.pgupdate; do
      value=$(<${PSQL_COMMAND})
      oc ${OC_ARGS} exec ${PG_POD} -- bash -c "export PGUSER=\${STKEEPER_PG_SU_USERNAME} && \
        export PGPASSWORD=\${STKEEPER_PG_SU_PASSWORD} && \
        export PGHOST=\${HOSTNAME} && \
        ${value}" >> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
    done
  fi
}

wddata_updates(){
  if ls "$UPDATE_DIR"/*.wdupdate &> /dev/null ; then
    for WDDATA_COMMAND in "$UPDATE_DIR"/*.wdupdate; do
      value=$(<${WDDATA_COMMAND})
      oc ${OC_ARGS} exec ${GATEWAY_POD} -- bash -c "${value}" >> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
    done
  fi
}

minio_updates(){
  if ls "$UPDATE_DIR"/*.minioupdate &> /dev/null ; then
    for WDDATA_COMMAND in "$UPDATE_DIR"/*.minioupdate; do
      value=$(<${WDDATA_COMMAND})
      oc ${OC_ARGS} exec ${MINIO_POD} -- bash -c "${value}" >> "${BACKUP_RESTORE_LOG_DIR}/${CURRENT_COMPONENT}.log"
    done
  fi
}
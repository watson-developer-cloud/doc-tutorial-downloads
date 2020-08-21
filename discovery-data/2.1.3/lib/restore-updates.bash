#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd -P)"
UPDATE_DIR="$ROOT_DIR/src"

elastic_updates(){
  if ls "$UPDATE_DIR"/*.elupdate &> /dev/null ; then
    for ELASTIC_COMMAND in "$UPDATE_DIR"/*.elupdate; do
      value=$(<${ELASTIC_COMMAND})
      kubectl ${KUBECTL_ARGS} exec ${ELASTIC_POD} -- bash -c "${value}"
    done
  fi
  if [ `compare_version "${BACKUP_FILE_VERSION}" "2.1.2"` -le 0 ] ; then 
    if ls "$UPDATE_DIR"/*.elupdate_script &> /dev/null ; then
      for ELASTIC_COMMAND in "$UPDATE_DIR"/*.elupdate_script; do
        UPDATE_SCRIPT_NAME=$(basename ${ELASTIC_COMMAND})
        kubectl ${KUBECTL_ARGS} cp ${ELASTIC_COMMAND} ${ELASTIC_POD}:/tmp/${UPDATE_SCRIPT_NAME}
        kubectl ${KUBECTL_ARGS} exec ${ELASTIC_POD} -- bash /tmp/${UPDATE_SCRIPT_NAME}
        kubectl ${KUBECTL_ARGS} exec ${ELASTIC_POD} -- rm /tmp/${UPDATE_SCRIPT_NAME}
      done
    fi
  fi
}

etcd_updates(){
  if ls "$UPDATE_DIR"/*.etcdupdate &> /dev/null ; then
    for ETCD_COMMAND in "$UPDATE_DIR"/*.etcdupdate; do
      value=$(<${ETCD_COMMAND})
      kubectl ${KUBECTL_ARGS} exec ${ETCD_POD} -- bash -c "${value}"
    done
  fi
}

hdp_updates(){
  if ls "$UPDATE_DIR"/*.hdpupdate &> /dev/null ; then
    for HDP_COMMAND in "$UPDATE_DIR"/*.hdpupdate; do
      value=$(<${HDP_COMMAND})
      kubectl ${KUBECTL_ARGS} exec ${HDP_POD} -- bash -c "${value}"
    done
  fi
}

postgresql_updates(){
  if ls "$UPDATE_DIR"/*.pgupdate &> /dev/null ; then
    for PSQL_COMMAND in "$UPDATE_DIR"/*.pgupdate; do
      value=$(<${PSQL_COMMAND})
      kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "${value}"
    done
  fi
}

wddata_updates(){
  if ls "$UPDATE_DIR"/*.wdupdate &> /dev/null ; then
    for WDDATA_COMMAND in "$UPDATE_DIR"/*.wdupdate; do
      value=$(<${WDDATA_COMMAND})
      kubectl ${KUBECTL_ARGS} exec ${GATEWAY_POD} -- bash -c "${value}"
    done
  fi
}

minio_updates(){
  if ls "$UPDATE_DIR"/*.minioupdate &> /dev/null ; then
    for WDDATA_COMMAND in "$UPDATE_DIR"/*.minioupdate; do
      value=$(<${WDDATA_COMMAND})
      kubectl ${KUBECTL_ARGS} exec ${MINIO_POD} -- bash -c "${value}"
    done
  fi
}
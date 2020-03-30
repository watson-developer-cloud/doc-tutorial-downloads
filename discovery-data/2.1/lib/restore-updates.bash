#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd -P)"
UPDATE_DIR="$ROOT_DIR/src"

elastic_updates(){
  if test -f "$UPDATE_DIR"/*.elupdate; then
    for ELASTIC_COMMAND in "$UPDATE_DIR"/*.elupdate; do
      value=$(<${ELASTIC_COMMAND})
      kubectl ${KUBECTL_ARGS} exec ${ELASTIC_POD} -- bash -c "${value}"
    done
  fi
}

etcd_updates(){
  if test -f "$UPDATE_DIR"/*.etcdupdate; then
    for ETCD_COMMAND in "$UPDATE_DIR"/*.etcdupdate; do
      value=$(<${ETCD_COMMAND})
      kubectl ${KUBECTL_ARGS} exec ${ETCD_POD} -- bash -c "${value}"
    done
  fi
}

hdp_updates(){
  if test -f "$UPDATE_DIR"/*.hdpupdate; then
    for HDP_COMMAND in "$UPDATE_DIR"/*.hdpupdate; do
      value=$(<${HDP_COMMAND})
      kubectl ${KUBECTL_ARGS} exec ${HDP_POD} -- bash -c "${value}"
    done
  fi
}

postgresql_updates(){
  if test -f "$UPDATE_DIR"/*.pgupdate; then
    for PSQL_COMMAND in "$UPDATE_DIR"/*.pgupdate; do
      value=$(<${PSQL_COMMAND})
      kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "${value}"
    done
  fi
}

wddata_updates(){
  if test -f "$UPDATE_DIR"/*.wdupdate; then
    for WDDATA_COMMAND in "$UPDATE_DIR"/*.wdupdate; do
      value=$(<${WDDATA_COMMAND})
      kubectl ${KUBECTL_ARGS} exec ${GATEWAY_POD} -- bash -c "${value}"
    done
  fi
}

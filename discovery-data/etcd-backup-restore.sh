#!/bin/bash

KUBECTL_ARGS=""
ETCD_BACKUP="/tmp/etcd_snapshot.db"

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
ETCD_POD=`kubectl ${KUBECTL_ARGS} get pods | grep "${RELEASE_NAME}-watson-discovery-etcd" | grep -v watson-discovery-etcd-test | cut -d ' ' -f 1 | sed -n 1p`

# backup etcd
if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"etcd_snapshot_`date "+%Y%m%d_%H%M%S"`.db"}
  echo "Start backup etcd..."
  ETCD_ENDPOINT=`kubectl ${KUBECTL_ARGS} exec ${ETCD_POD} -- bash -c 'echo -n ${ETCD_INITIAL_ADVERTISE_PEER_URLS}'`
  kubectl ${KUBECTL_ARGS} exec ${ETCD_POD} --  bash -c "ETCDCTL_API=3 etcdctl --insecure-skip-tls-verify=true --insecure-transport=false --endpoints ${ETCD_ENDPOINT} get --prefix '/' -w fields > ${ETCD_BACKUP}"
  kubectl ${KUBECTL_ARGS} cp "${ETCD_POD}:${ETCD_BACKUP}" "${BACKUP_FILE}"
  echo "Done: ${BACKUP_FILE}"
fi

# restore etcd
if [ ${COMMAND} = 'restore' ] ; then
  if [ -z ${BACKUP_FILE} ] ; then
    printUsage
  fi
  if [ ! -e "${BACKUP_FILE}" ] ; then
    echo "no such file: ${BACKUP_FILE}"
    exit 1
  fi
  echo "Start restore etcd: ${BACKUP_FILE}"
  kubectl ${KUBECTL_ARGS} cp "${BACKUP_FILE}" "${ETCD_POD}:${ETCD_BACKUP}"
  kubectl ${KUBECTL_ARGS} exec ${ETCD_POD} -- bash -c 'export ETCDCTL_API=3 && \
  etcdctl --insecure-skip-tls-verify=true --insecure-transport=false del --prefix "/" && \
  cat '${ETCD_BACKUP}' | grep -e "\"Key\" : " -e "\"Value\" :" | sed -e "s/^\"Key\" : \"\(.*\)\"$/\1\t/g" -e "s/^\"Value\" : \"\(.*\)\"$/\1\t/g" | awk '"'"'{ORS="";print}'"'"' | sed -e "s/\\\\n/\\n/g" -e "s/\\\\\"/\"/g" | xargs --no-run-if-empty -t -d "\t" -n2 etcdctl --insecure-skip-tls-verify=true --insecure-transport=false put && \
  rm -f '${ETCD_BACKUP}
  echo "Done"
fi

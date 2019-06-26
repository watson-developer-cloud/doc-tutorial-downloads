#!/bin/bash

KUBECTL_ARGS=""
ELASTIC_REPO="my_backup"
ELASTIC_SNAPSHOT="snapshot"
ELASTIC_BACKUP="elastic_snapshot.tar.gz"

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
ELASTIC_POD=`kubectl ${KUBECTL_ARGS} get pods | grep "${RELEASE_NAME}-watson-discovery-elastic" | grep -v watson-discovery-elastic-test | cut -d ' ' -f 1 | sed -n 1p`

# backup elastic search
if [ ${COMMAND} = 'backup' ] ; then
  BACKUP_FILE=${BACKUP_FILE:-"elastic_`date "+%Y%m%d_%H%M%S"`.snapshot"}
  echo "Start backup elasticsearch..."
  kubectl ${KUBECTL_ARGS} exec ${ELASTIC_POD} --  bash -c 'source ${WEX_HOME}/sbin/profile.sh && \
  mkdir -p ${ELASTIC_BACKUP_DIR} && cd /tmp && \
  curl -XPUT -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'" -H "Content-Type: application/json" -d'"'"'{"type": "fs","settings": {"location": "/tmp/elastic_backups"}}'"'"' && \
  curl -XPUT -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}'?wait_for_completion=true" -H "Content-Type: application/json" -d'"'"'{"indices": "*","ignore_unavailable": true,"include_global_state": false}'"'"' && \
  tar czvf /tmp/'${ELASTIC_BACKUP}' -C /tmp $(basename ${ELASTIC_BACKUP_DIR})'
  kubectl ${KUBECTL_ARGS} cp "${ELASTIC_POD}:/tmp/${ELASTIC_BACKUP}" "${BACKUP_FILE}"
  kubectl ${KUBECTL_ARGS} exec ${ELASTIC_POD} --  bash -c 'source ${WEX_HOME}/sbin/profile.sh && \
  curl -XDELETE -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} ${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}' && \
  curl -XDELETE -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} ${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}' && \
  rm -rf ${ELASTIC_BACKUP_DIR}/*'
  echo "Done: ${BACKUP_FILE}"
fi

if [ ${COMMAND} = 'restore' ] ; then
  if [ -z ${BACKUP_FILE} ] ; then
    printUsage
  fi
  if [ ! -e "${BACKUP_FILE}" ] ; then
    echo "no such file: ${BACKUP_FILE}"
    exit 1
  fi
  echo "Start restore elasticsearch: ${BACKUP_FILE}"
  kubectl ${KUBECTL_ARGS} cp "${BACKUP_FILE}" "${ELASTIC_POD}:/tmp/${ELASTIC_BACKUP}"
  kubectl ${KUBECTL_ARGS} exec ${ELASTIC_POD} -- bash -c 'source ${WEX_HOME}/sbin/profile.sh && \
  cd /tmp && \
  tar xvf '${ELASTIC_BACKUP}' && \
  curl -XDELETE -k -u $ELASTIC_USER:$ELASTIC_PASSWORD "$ELASTIC_ENDPOINT/_all" && \
  curl -XPUT -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'" -H "Content-Type: application/json" -d'"'"'{"type": "fs","settings": {"location": "/tmp/elastic_backups"}}'"'"' && \
  curl -XPOST -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} "{$ELASTIC_ENDPOINT}/_snapshot/my_backup/snapshot/_restore" && \
  curl -XDELETE -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} ${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}'/'${ELASTIC_SNAPSHOT}' && \
  curl -XDELETE -k -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} ${ELASTIC_ENDPOINT}/_snapshot/'${ELASTIC_REPO}' && \
  rm -rf '${ELASTIC_BACKUP}' ${ELASTIC_BACKUP_DIR}/*'
  echo "Done"
fi

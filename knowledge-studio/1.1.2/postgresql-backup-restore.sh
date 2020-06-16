#!/bin/bash

printUsage() {
  echo "Usage: $(basename ${0}) [command] [releaseName] [backupDir] [-n namespace]"
  exit 1
}

set_pgpass() {
  PG_PASS=${BACKUP_DIR}/.pgpass
  echo "*:*:*:*:${SQL_PASSWORD}" > ${PG_PASS}
  chmod 600 ${PG_PASS}
  kubectl ${KUBECTL_ARGS} cp ${PG_PASS} ${PG_POD}:/home/stolon
  rm ${PG_PASS}
}

cmd_check(){
  if [ $? -ne 0 ] ; then
    echo "[FAIL] $DBNAME $COMMAND"
    exit 1
  fi
}

if [ $# -lt 3 ] ; then
  printUsage
fi

COMMAND=$1
shift
RELEASE_NAME=$1
shift
BACKUP_DIR=$1
shift
while getopts f:n: OPT
do
  case $OPT in
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG" ;;
  esac
done


SCRIPT_DIR=$(dirname $0)
. ${SCRIPT_DIR}/lib/utils.sh

SQL_PASSWORD=`kubectl ${KUBECTL_ARGS} get secret $RELEASE_NAME-ibm-postgresql-auth-secret --template '{{.data.pg_su_password}}' | base64 --decode`

DBNAME=postgresql
echo "COMMAND:$COMMAND"
echo "RELEASE_NAME:$RELEASE_NAME"
echo "BACKUP_DIR:$BACKUP_DIR"
#echo "SQL_PASSWORD:$SQL_PASSWORD"

echo "get single postgreSQL pod"
# get one healthy pod with STATUS "Running" (not "Terminating", e.g.)
PG_POD=`kubectl ${KUBECTL_ARGS} get pods -o=go-template --template='{{range $pod := .items}}{{range .status.containerStatuses}}{{if .ready}}{{$pod.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}' | grep ${RELEASE_NAME}-ibm-postgresql-proxy | head -n 1`
RELEASE_NAME_UNDERSCORE=${RELEASE_NAME//-/_}
echo "RELEASE_NAME_UNDERSCORE:$RELEASE_NAME_UNDERSCORE"

if [ ${COMMAND} = 'backup' ] ; then
  echo "PG_POD:$PG_POD"
  # In pod
  echo "make backup dir"
  mkdir -p ${BACKUP_DIR}
  
  # .pgpass
  echo "enable command in non interactive mode"
  set_pgpass
  
  # Each pg_dump command requires your password
  echo "run pg_dump"
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- pg_dump -h localhost -p 5432 -U stolon --clean -Fc jobq_${RELEASE_NAME_UNDERSCORE} > ${BACKUP_DIR}/jobq_${RELEASE_NAME_UNDERSCORE}.custom
  cmd_check
  
  echo "run pg_dump (1/4)"
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- pg_dump -h localhost -p 5432 -U stolon --clean -Fc model_management_api > ${BACKUP_DIR}/model_management_api.custom
  cmd_check
  
  echo "run pg_dump (2/4)"
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- pg_dump -h localhost -p 5432 -U stolon --clean -Fc model_management_api_v2 > ${BACKUP_DIR}/model_management_api_v2.custom
  cmd_check
  
  echo "run pg_dump (3/4)"
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- pg_dump -h localhost -p 5432 -U stolon --clean -Fc awt > ${BACKUP_DIR}/awt.custom
  cmd_check
  
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- rm /home/stolon/.pgpass
  echo "[SUCCESS] $DBNAME $COMMAND"
elif [ ${COMMAND} = 'restore' ] ; then
  echo "restore"
  if [ ! -d "${BACKUP_DIR}" ] ; then
    echo "no backup directory: ${BACKUP_DIR}" >&2
    echo "failed to restore" >&2
    exit 1
  fi
  echo "PG_POD:$PG_POD"
  
  # .pgpass
  echo "enable command in non interactive mode"
  set_pgpass
  echo "run pg_restore"
  kubectl ${KUBECTL_ARGS} cp ${BACKUP_DIR}/jobq_${RELEASE_NAME_UNDERSCORE}.custom ${PG_POD}:/tmp/jobq_${RELEASE_NAME_UNDERSCORE}.custom
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- pg_restore -Fc --clean -d jobq_${RELEASE_NAME_UNDERSCORE} -h localhost -p 5432 -U stolon /tmp/jobq_${RELEASE_NAME_UNDERSCORE}.custom
  cmd_check
  
  echo "run pg_restore (1/4)"
  kubectl ${KUBECTL_ARGS} cp ${BACKUP_DIR}/model_management_api.custom ${PG_POD}:/tmp/model_management_api.custom
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- pg_restore -Fc --clean -d model_management_api -h localhost -p 5432 -U stolon /tmp/model_management_api.custom
  cmd_check
  
  echo "run pg_restore (2/4)"
  kubectl ${KUBECTL_ARGS} cp ${BACKUP_DIR}/model_management_api_v2.custom ${PG_POD}:/tmp/model_management_api_v2.custom
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- pg_restore -Fc --clean -d model_management_api_v2 -h localhost -p 5432 -U stolon /tmp/model_management_api_v2.custom
  cmd_check
  
  echo "run pg_restore (3/4)"
  kubectl ${KUBECTL_ARGS} cp ${BACKUP_DIR}/awt.custom ${PG_POD}:/tmp/awt.custom
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- pg_restore -Fc --clean -d awt -h localhost -p 5432 -U stolon  /tmp/awt.custom
  cmd_check
  
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- rm /home/stolon/.pgpass
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- rm /tmp/jobq_${RELEASE_NAME_UNDERSCORE}.custom
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- rm /tmp/model_management_api.custom
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- rm /tmp/model_management_api_v2.custom
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- rm /tmp/awt.custom

  echo "[SUCCESS] $DBNAME $COMMAND"
else
  printUsage
fi
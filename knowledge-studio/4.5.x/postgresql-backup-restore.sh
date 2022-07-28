#!/bin/bash

printUsage() {
  echo "Usage: $(basename ${0}) [command] [releaseName] [backupDir] [-n namespace]"
  exit 1
}

check_environment() {
  MAX_COUNT=60
  COUNT=0
  PG_POD_COUNT=`kubectl ${KUBECTL_ARGS} get pod | grep ${RELEASE_NAME_UNDERSCORE}-edb-postgresql-backup-restore-job | wc -l`
  while [[ ${PG_POD_COUNT} != "0" ]]
  do
    (( COUNT += 1 ))
    if [ $COUNT -gt $MAX_COUNT ]; then
      fail "Other ${COMMAND} pod is exist"
    fi
    sleep 5
    PG_POD_COUNT=`kubectl ${KUBECTL_ARGS} get pod | grep ${RELEASE_NAME_UNDERSCORE}-edb-postgresql-backup-restore-job | wc -l`
  done
  echo "Done"
}

wait_for_pod_ready() {
  MAX_COUNT=60
  COUNT=0
  echo "postgreSQL pod name: $PG_POD"
  PG_POD_STAUS=`kubectl ${KUBECTL_ARGS} get pod ${PG_POD} -o jsonpath="{.status.phase}"`
  while [[ ${PG_POD_STAUS} != "Running" ]]
  do
    (( COUNT += 1 ))
    if [ $COUNT -gt $MAX_COUNT ]; then
      fail "Wait PostgreSQL ${COMMAND} pod time out"
    fi
    sleep 5
    PG_POD_STAUS=`kubectl ${KUBECTL_ARGS} get pod ${PG_POD} -o jsonpath="{.status.phase}"`
  done
  echo "Done"
}

wait_for_job_complete() {
  MAX_COUNT=60
  COUNT=0
  JOB_COMPLETE=`kubectl ${KUBECTL_ARGS} exec -it ${PG_POD} -- ls /tmp | grep ${COMMAND}_job_complete | wc -l`
  while [[ ${JOB_COMPLETE} == "0" ]]
  do
    (( COUNT += 1 ))
    if [ $COUNT -gt $MAX_COUNT ]; then
      fail "Wait PostgreSQL ${COMMAND} job time out"
    fi
    sleep 5
    JOB_COMPLETE=`kubectl ${KUBECTL_ARGS} exec -it ${PG_POD} -- ls /tmp | grep ${COMMAND}_job_complete | wc -l`
  done
  echo "Done"
}

cmd_check(){
  if [ $? -ne 0 ] ; then
    fail "$DBNAME $COMMAND"
  fi
}

fail(){
  echo "[FAIL] $1"
  rm -f ${SCRIPT_DIR}/lib/postgresql-backup-restore-job.yaml
  kubectl ${KUBECTL_ARGS} delete job ${RELEASE_NAME_UNDERSCORE}-edb-postgresql-backup-restore-job
  exit 1
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
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG" NAMESPACE=$OPTARG ;;
  esac
done


SCRIPT_DIR=$(dirname $0)
. ${SCRIPT_DIR}/lib/utils.sh

PGPASSWORD=`kubectl ${KUBECTL_ARGS} get secret $RELEASE_NAME-edb-postgresql-auth-secret --template '{{.data.password}}' | base64 --decode`
DBNAME=postgresql
PGPORT=5432
PGUSER=postgres
echo "COMMAND:$COMMAND"
echo "RELEASE_NAME:$RELEASE_NAME"
echo "BACKUP_DIR:$BACKUP_DIR"

RELEASE_NAME_UNDERSCORE=${RELEASE_NAME//-/_}
echo "RELEASE_NAME_UNDERSCORE:$RELEASE_NAME_UNDERSCORE"

echo "create $COMMAND job"
sed -e "s/\${NAMESPACE}/${NAMESPACE}/g" \
    -e "s/\${RELEASE_NAME_UNDERSCORE}/${RELEASE_NAME_UNDERSCORE}/g" \
    -e "s/\${PGPASSWORD}/${PGPASSWORD}/g" -e "s/\${PGPORT}/${PGPORT}/g" \
    -e "s/\${PGUSER}/${PGUSER}/g" -e "s/\${COMMAND}/${COMMAND}/g" \
    ${SCRIPT_DIR}/lib/postgresql-backup-restore-job-template.yaml > ${SCRIPT_DIR}/lib/postgresql-backup-restore-job.yaml

echo "Verify there is no other ${COMMAND} pod exist..."
check_environment

kubectl ${KUBECTL_ARGS} apply -f ${SCRIPT_DIR}/lib/postgresql-backup-restore-job.yaml
cmd_check

sleep 5

echo "get postgreSQL ${COMMAND} pod"
PG_POD=`kubectl ${KUBECTL_ARGS} get pods -o jsonpath='{.items[0].metadata.name}' -l function=${RELEASE_NAME_UNDERSCORE}-edb-postgresql-${COMMAND}`
cmd_check

echo "wait for postgreSQL ${COMMAND} pod : $PG_POD to be ready..."
wait_for_pod_ready
echo "wait for postgreSQL ${COMMAND} job to be completed..."
wait_for_job_complete

if [ ${COMMAND} = 'backup' ] ; then
  echo "make backup dir"
  mkdir -p ${BACKUP_DIR}
  
  # Each pg_dump command requires your password
  echo "run pg_dump (1/4):"
  kubectl ${KUBECTL_ARGS} cp ${PG_POD}:/tmp/jobq_${RELEASE_NAME_UNDERSCORE}.custom ${BACKUP_DIR}/jobq_wks.custom
  cmd_check
  
  echo "run pg_dump (2/4):"
  kubectl ${KUBECTL_ARGS} cp ${PG_POD}:/tmp/model_management_api.custom ${BACKUP_DIR}/model_management_api.custom
  cmd_check
  
  echo "run pg_dump (3/4)"
  kubectl ${KUBECTL_ARGS} cp ${PG_POD}:/tmp/model_management_api_v2.custom ${BACKUP_DIR}/model_management_api_v2.custom
  cmd_check
  
  echo "run pg_dump (4/4)"
  kubectl ${KUBECTL_ARGS} cp ${PG_POD}:/tmp/awt.custom ${BACKUP_DIR}/awt.custom
  cmd_check
  rm -f ${SCRIPT_DIR}/lib/postgresql-backup-restore-job.yaml
  kubectl ${KUBECTL_ARGS} delete job ${RELEASE_NAME_UNDERSCORE}-edb-postgresql-backup-restore-job
  echo "[SUCCESS] $DBNAME $COMMAND"
elif [ ${COMMAND} = 'restore' ] ; then
  echo "restore"
  if [ ! -d "${BACKUP_DIR}" ] ; then
    echo "no backup directory: ${BACKUP_DIR}" >&2
    echo "failed to restore" >&2
    exit 1
  fi
  
  echo "run pg_restore (1/4)" 
  kubectl ${KUBECTL_ARGS} cp ${BACKUP_DIR}/jobq_wks.custom ${PG_POD}:/tmp/jobq_${RELEASE_NAME_UNDERSCORE}.custom
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- pg_restore -Fc --clean -d jobq_${RELEASE_NAME_UNDERSCORE} /tmp/jobq_${RELEASE_NAME_UNDERSCORE}.custom
  cmd_check
  
  echo "run pg_restore (2/4)"
  kubectl ${KUBECTL_ARGS} cp ${BACKUP_DIR}/model_management_api.custom ${PG_POD}:/tmp/model_management_api.custom
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- pg_restore -Fc --clean -d model_management_api /tmp/model_management_api.custom
  cmd_check
  
  echo "run pg_restore (3/4)"
  kubectl ${KUBECTL_ARGS} cp ${BACKUP_DIR}/model_management_api_v2.custom ${PG_POD}:/tmp/model_management_api_v2.custom
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- pg_restore -Fc --clean -d model_management_api_v2 /tmp/model_management_api_v2.custom
  cmd_check
  
  echo "run pg_restore (4/4)"
  kubectl ${KUBECTL_ARGS} cp ${BACKUP_DIR}/awt.custom ${PG_POD}:/tmp/awt.custom
  kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- pg_restore -Fc --clean -d awt /tmp/awt.custom
  cmd_check
  
  rm -f ${SCRIPT_DIR}/lib/postgresql-backup-restore-job.yaml
  kubectl ${KUBECTL_ARGS} delete job ${RELEASE_NAME_UNDERSCORE}-edb-postgresql-backup-restore-job

  echo "[SUCCESS] $DBNAME $COMMAND"
else
  printUsage
fi

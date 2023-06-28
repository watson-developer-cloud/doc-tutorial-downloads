#!/bin/bash

set -euo pipefail

printUsage() {
  echo "Usage: $(basename ${0}) [tenant_name]"
  exit 1
}

runPythonScripts() {
  POD=$1
  SCRIPT=$2
  _oc_cp "src/${SCRIPT}" ${POD}:/tmp/ ${OC_ARGS}
  oc ${OC_ARGS} exec ${POD} -- bash -c "export MANAGEMENT_PORT=${MANAGEMENT_PORT} && \
  export ZING_PORT=${ZING_PORT} && \
  python3 /tmp/${SCRIPT}"
  oc ${OC_ARGS} exec ${POD} -- bash -c "rm -f /tmp/${SCRIPT}"
}

if [ $# -lt 1 ] ; then
  printUsage
fi

SCRIPT_DIR=$(dirname $0)
TMP_WORK_DIR="tmp/post-restore"
OC_ARGS="${OC_ARGS:-}"

. ${SCRIPT_DIR}/lib/function.bash

TENANT_NAME=$1
shift
while getopts n: OPT
do
  case $OPT in
    "n" ) OC_ARGS="${OC_ARGS} --namespace=$OPTARG" ;;
esac
done

export TENANT_NAME=${TENANT_NAME}
export SCRIPT_DIR=${SCRIPT_DIR}

brlog "INFO" "Running post restore scripts"

mkdir -p ${TMP_WORK_DIR}

## Restore tenants
brlog "INFO" "Waiting for API pods to be ready..."
while :
do
  if ! oc get pod ${OC_ARGS} -l tenant=${TENANT_NAME},run=gateway |& grep gateway &> /dev/null; then
    sleep 5
    continue
  fi
  if oc describe pod ${OC_ARGS} -l tenant=${TENANT_NAME},run=gateway | grep -e "ContainersReady.*False" -e "PodScheduled.*False" > /dev/null ; then
    sleep 5;
  else
    brlog "INFO" "API pods are ready";
    break;
  fi
done

WD_VERSION=${WD_VERSION:-$(get_version)}
PG_POD=""

if [ $(compare_version "${WD_VERSION}" "4.0.0") -ge 0 ] ; then
  PG_JOB_TEMPLATE="${SCRIPT_DIR}/src/backup-restore-job-template.yml"
  PG_JOB_FILE="${SCRIPT_DIR}/src/pg-backup-restore-job.yml"
  PG_BACKUP_RESTORE_JOB="wd-discovery-postgres-backup-restore"
  PG_ARCHIVE_OPTION="temp"
  COMMAND=post-restore
  run_pg_job
  PG_POD=${POD}
else
  PG_POD=$(get_primary_pg_pod)
fi

if require_tenant_backup ; then

  brlog "INFO" "Restore tenants information"

  for tenants_file in $(ls -t tmp_wd_tenants_*.txt) ; do
    if [ -n "$(cat ${tenants_file})" ] ; then
      kube_cp_from_local ${PG_POD} "${tenants_file}" "/tmp/tenants" ${OC_ARGS}
      fetch_cmd_result ${PG_POD} 'export PGUSER=${PGUSER:-$STKEEPER_PG_SU_USERNAME} && \
        export PGPASSWORD=${PGPASSWORD:-$STKEEPER_PG_SU_PASSWORD} && \
        export PGHOST=${PGHOST:-$HOSTNAME} && \
        while ! psql -d dadmin -t -c "SELECT * FROM tenants" &> /dev/null; do sleep 10; done && \
        if ! psql -d dadmin -t -c "SELECT * FROM tenants;" | grep "default" > /dev/null ; then \
          psql -d dadmin -c "TRUNCATE tenants" && \
          psql -d dadmin -c "\COPY tenants FROM '"'"'/tmp/tenants'"'"'" ;\
        else\
          echo "COPY" ;\
        fi&& \
        rm -f /tmp/tenants' ${OC_ARGS} | grep COPY >& /dev/null
    fi
  done
fi
## End restore tenants

## Set default as tenant ID
if [ $(compare_version "${WD_VERSION}" "2.2.1") -ge 0 ] && [ $(compare_version "${WD_VERSION}" "4.0.5") -le 0 ] && [ $(compare_version "${BACKUP_FILE_VERSION}" "2.2.0") -le 0 ] ; then
  brlog "INFO" "Update tenant id to default"
  fetch_cmd_result ${PG_POD} 'export PGUSER=${PGUSER:-$STKEEPER_PG_SU_USERNAME} && \
      export PGPASSWORD=${PGPASSWORD:-$STKEEPER_PG_SU_PASSWORD} && \
      export PGHOST=${PGHOST:-$HOSTNAME} && \
      psql -d dadmin -c "UPDATE tenants SET id = '"'default'"' ;" && \
      psql -d dadmin -c "UPDATE projects SET tenant_id = '"'default'"' ;" && \
      psql -d dadmin -c "UPDATE datasets SET tenant_id = '"'default'"' ;" ' ${OC_ARGS}
fi
## End set default

## Update ranker version to run retrain
brlog "INFO" "Update ranker training version"
fetch_cmd_result ${PG_POD} 'export PGUSER=${PGUSER:-$STKEEPER_PG_SU_USERNAME} && \
      export PGPASSWORD=${PGPASSWORD:-$STKEEPER_PG_SU_PASSWORD} && \
      export PGHOST=${PGHOST:-$HOSTNAME} && \
      psql -d ranker_training -c "UPDATE data SET version = version+1;" && \
      psql -d ranker_training -c "WITH T AS (SELECT DISTINCT ON (training_set_id) training_job_id from jobs ORDER BY training_set_id, data_version DESC) UPDATE jobs SET state = '"'"'INVALIDATE_RANKER'"'"' where training_job_id IN (select training_job_id from T);"
      ' ${OC_ARGS}


## End update ranker

if [ $(compare_version "${WD_VERSION}" "4.0.0") -ge 0 ] ; then
  oc ${OC_ARGS} delete -f $PG_JOB_FILE
fi

rm -rf ${TMP_WORK_DIR}
if [ -z "$(ls tmp)" ] ; then
  rm -rf tmp
fi

brlog "INFO" "Completed post restore scripts"

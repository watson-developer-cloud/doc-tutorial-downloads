#!/bin/bash

set -euo pipefail

printUsage() {
  echo "Usage: $(basename ${0}) [tenant_name]"
  exit 1
}

runPythonScripts() {
  POD=$1
  SCRIPT=$2
  oc ${OC_ARGS} cp "src/${SCRIPT}" ${POD}:/tmp/
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

brlog "INFO" "Restore tenants information"

PG_POD=""

for POD in `oc get pods ${OC_ARGS} -o jsonpath='{.items[*].metadata.name}' -l tenant=${TENANT_NAME},component=stolon-keeper` ; do
  if oc logs ${OC_ARGS} --since=30s ${POD} | grep 'our db requested role is master' > /dev/null ; then
    PG_POD=${POD}
  fi
done

for tenants_file in `ls -t tmp_wd_tenants_*.txt` ; do
  if [ -n "`cat ${tenants_file}`" ] ; then
    kube_cp_from_local ${PG_POD} "${tenants_file}" "/tmp/tenants" ${OC_ARGS}
    fetch_cmd_result ${PG_POD} 'export PGUSER=${STKEEPER_PG_SU_USERNAME} && \
      export PGPASSWORD=${STKEEPER_PG_SU_PASSWORD} && \
      export PGHOST=${HOSTNAME} && \
      if ! psql -d dadmin -t -c "SELECT * FROM tenants;" | grep "default" > /dev/null ; then \
        psql -d dadmin -c "TRUNCATE tenants" && \
        psql -d dadmin -c "COPY tenants FROM '"'"'/tmp/tenants'"'"'" ;\
      else\
        echo "COPY" ;\
      fi&& \
      rm -f /tmp/tenants' ${OC_ARGS} | grep COPY >& /dev/null
  fi
done

## End restore tenants

if [ `compare_version "${WD_VERSION}" "2.2.1"` -ge 0 ] && [ `compare_version "${BACKUP_FILE_VERSION}" "2.2.0"` -le 0 ] ; then
  fetch_cmd_result ${PG_POD} 'export PGUSER=${STKEEPER_PG_SU_USERNAME} && \
      export PGPASSWORD=${STKEEPER_PG_SU_PASSWORD} && \
      export PGHOST=${HOSTNAME} && \
      psql -d dadmin -c "UPDATE projects SET tenant_id = '"'default'"' ;" &&\
      psql -d dadmin -c "UPDATE datasets SET tenant_id = '"'default'"' ;" ' ${OC_ARGS}
fi

rm -rf ${TMP_WORK_DIR}
if [ -z "$(ls tmp)" ] ; then
  rm -rf tmp
fi

brlog "INFO" "Completed post restore scripts"

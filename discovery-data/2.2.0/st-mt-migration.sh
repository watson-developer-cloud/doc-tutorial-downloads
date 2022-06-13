#!/usr/bin/env bash

set -euo pipefail

printUsage() {
  echo "Usage: $(basename ${0}) [tenant_name]"
  exit 1
}

if [ $# -lt 1 ] ; then
  printUsage
fi

SCRIPT_DIR=$(dirname $0)
TMP_WORK_DIR="tmp/mt-migration"
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

brlog "INFO" "Start migration from ST to MT"
was_quiesced=true

mkdir -p ${TMP_WORK_DIR}

if [ "$(get_quiesce_status ${TENANT_NAME})" != "QUIESCED" ] ; then
  was_quiesced=false
  COMMAND=backup
  quiesce
fi

source_version="$(get_backup_version)"

### Preprocess
brlog "INFO" "Clean up datasets"

setup_etcd_env
setup_pg_env
DATASETS=$(fetch_cmd_result ${ETCD_POD} "ETCDCTL_API=3 ETCDCTL_ENDPOINTS='${ETCD_ENDPOINT}' etcdctl --cert=/etc/etcdtls/operator/etcd-tls/etcd-client.crt --key=/etc/etcdtls/operator/etcd-tls/etcd-client.key --cacert=/etc/etcdtls/operator/etcd-tls/etcd-client-ca.crt get /wex/global/dataset --prefix | grep '^/.*/-\.json$' | cut -d / -f 5| tr '\n' ',' | sed -E \"s/,/','/g; s/^/'/; s/..\$//\"")
fetch_cmd_result ${PG_POD} "PGUSER=${PGUSER} PGPASSWORD=${PGPASSWORD} psql -d dadmin -c \"DELETE FROM ds WHERE dsid NOT IN ($DATASETS)\" && echo 'OK'"

## Start migration

oc annotate ${OC_ARGS} wd ${TENANT_NAME} --overwrite watsonDiscoveryMigrationSourceVersion=${source_version}
oc annotate ${OC_ARGS} wd ${TENANT_NAME} --overwrite watsonDiscoveryEnableMigration=true
while :
do
  migration_status=$(oc get ${OC_ARGS} watsondiscoverymigration ${TENANT_NAME} -o jsonpath='{.status.migrationStatus}' || echo "NotFound")
  if [ "${migration_status}" = "Completed" ] ; then
    break
  else
    sleep 60
  fi
done

oc annotate ${OC_ARGS} wd ${TENANT_NAME} --overwrite watsonDiscoveryEnableMigration-
oc annotate ${OC_ARGS} wd ${TENANT_NAME} --overwrite watsonDiscoveryMigrationSourceVersion-

if ! "${was_quiesced}" ; then
  unquiesce
fi
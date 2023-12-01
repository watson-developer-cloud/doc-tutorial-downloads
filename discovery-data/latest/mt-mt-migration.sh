#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

. ${SCRIPT_DIR}/lib/function.bash

#############
# Parse args
#############

while [[ $# -gt 0 ]]
do
  OPT=$1
  case $OPT in
    -n | --namespace)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      nsopt="-n $2"
      shift 2
      ;;
    -i | --instance)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      instance_name="$2"
      shift 2
      ;;
    -- | -)
      shift 1
      param+=( "$@" )
      break
      ;;
    -* )
      brlog "ERROR" "illegal option: $1"
      exit 1
      ;;
    *)
      brlog "ERROR" "illegal argument: $1"
      exit 1
      ;;
    esac
done

#############
# Constants
#############

declare -r nsopt
declare -r instance_name

TMP_WORK_DIR="${SCRIPT_DIR}/tmp/mt-mt-workspace"
CURRENT_COMPONENT="migration"
TENANT_NAME="${instance_name:-wd}"
MINIO_MT_MIGRATION_SCRIPTS="${SCRIPT_DIR}/src/minio-mt-migration.sh"
BACKUP_RESTORE_DIR_IN_POD="/tmp/"
OC_ARGS="${nsopt:-}"


##############
# Pre process
##############

mkdir -p "${TMP_WORK_DIR}"
mkdir -p "${BACKUP_RESTORE_LOG_DIR}"

##############
# Main
##############

mappings=$(get_instance_tuples)

BACKUP_RESTORE_DIR_IN_POD="/tmp/backup-restore-workspace"
PG_JOB_TEMPLATE="${SCRIPT_DIR}/src/backup-restore-job-template.yml"
PG_JOB_FILE="${SCRIPT_DIR}/src/pg-backup-restore-job.yml"
PG_BACKUP_RESTORE_JOB="wd-discovery-postgres-backup-restore"
PG_ARCHIVE_OPTION="temp"
COMMAND=post-restore
run_pg_job
PG_POD=${POD}


setup_s3_env
launch_s3_pod
MC_POD=${POD}

ELASTIC_POD=$(oc get pods ${OC_ARGS} -o jsonpath="{.items[0].metadata.name}" -l tenant=${TENANT_NAME},app=elastic,ibm-es-data=True)

brlog "INFO" "Start MT migration"

for tuple in ${mappings}
do
  ORG_IFS=${IFS}
  IFS=","
  set -- ${tuple}
  IFS=${ORG_IFS}
  # source and destination tenant IDs
  src=$1
  dst=$2
  if [ "${src}" = "${dst}" ] ; then
    brlog "INFO" "Migration not required: ${src}"
    continue
  fi

  brlog "INFO" "Migrating ${src} to ${dst}"

  ##############
  # Postgres
  ##############


  ##########################
  brlog "INFO" "    Migrating dadmin tables"

  CMD="psql -d dadmin -t -A -c \"SELECT table_name FROM information_schema.columns WHERE table_schema = 'public' AND column_name = 'tenant_id' ORDER BY table_name\""
  standard_mt_tables=($(oc exec ${OC_ARGS} "${PG_POD}" -- bash -c "${CMD}"))
  echo "Updating tables with tenant_id: ${standard_mt_tables[*]}"
  foreign_key_tables=(wd_collections wd_collections_status wd_collections_project wd_datasets_collection wd_collection_document_status wd_collections_enrichment_job_status wd_datasets wd_datasets_status wd_datasets_project wd_enrichments wd_enrichments_lang wd_enrichments_project wd_collection_stats wd_enrichments_webhook_secret wd_collections_webhook_secret)

  SQL="BEGIN;"

  for table in "${foreign_key_tables[@]}"; do
    SQL+=" ALTER TABLE IF EXISTS ${table} DISABLE TRIGGER ALL;"
  done

  # wd_crawler update
  CMD="psql -d dadmin -t -A -c \"SELECT tenant_id, dataset_id, crawler_id, body FROM wd_crawlers WHERE path = 'INFO' AND tenant_id='${src}'\""
  crawlers=$(oc exec ${OC_ARGS} "${PG_POD}" -- bash -c "${CMD}")

  if [ -n "${crawlers}" ]; then
    for crawler in ${crawlers} ; do
      ORG_IFS=$IFS
      IFS="|"
      columns=(${crawler})
      IFS=${ORG_IFS}
      updated=$(echo "${columns[3]}" | sed -e "s/${src}/${dst}/g" | sed -e 's/"/\\"/g')
      SQL+=" UPDATE wd_crawlers SET body = '${updated}' WHERE tenant_id = '${columns[0]}' AND dataset_id = '${columns[1]}' AND crawler_id = '${columns[2]}' AND path = 'INFO';"
    done
  fi

  # export_status update
  CMD="psql -d dadmin -t -A -c \"SELECT job_id, body FROM wd_export_status WHERE tenant_id='${src}'\""
  export_status=$(oc exec ${OC_ARGS} "${PG_POD}" -- bash -c "${CMD}")
  if [ -n "${export_status}" ] ; then
    ORG_IFS=$IFS
    IFS=$'\n'
    for status in ${export_status} ; do
      IFS="|"
      columns=(${status})
      IFS=${ORG_IFS}
      updated=$(echo "${columns[1]}" | sed -e "s/${src}/${dst}/g" | sed -e 's/"/\\"/g')
      SQL+=" UPDATE wd_export_status SET body = '${updated}' WHERE job_id = '${columns[0]}';"
    done
    IFS=${ORG_IFS}
  fi

  SQL+=" UPDATE tenants SET id = '$dst' WHERE id = '$src';"

  for table in "${standard_mt_tables[@]}"; do
    SQL+=" UPDATE $table SET tenant_id = '$dst' WHERE tenant_id = '$src';"
  done

  for table in "${foreign_key_tables[@]}"; do
    SQL+=" ALTER TABLE IF EXISTS ${table} ENABLE TRIGGER ALL;"
  done

  SQL+=" COMMIT;"

  CMD="psql --dbname=dadmin --tuples-only --csv --command=\"$SQL\""
  run_cmd_in_pod "${PG_POD}" "${CMD}" ${OC_ARGS}



  ##########################
  brlog "INFO" "    Migrating cnm tables"

  SQL="\
    INSERT INTO mono (id, data) SELECT '$dst', data FROM mono WHERE id = '$src';\
    UPDATE gear SET mono_id = '$dst' WHERE mono_id = '$src';\
    UPDATE wd_collection SET mono_id = '$dst' WHERE mono_id = '$src';\
    DELETE FROM mono WHERE id = '$src';\
  "

  CMD="psql --dbname=cnm --tuples-only --csv --command=\"$SQL\""
  run_cmd_in_pod "$PG_POD" "$CMD" $OC_ARGS

  ##########################
  brlog "INFO" "    Migrating ranker_training tables"

  SQL="UPDATE tenants SET tenant_id='$dst' WHERE tenant_id='$src'"

  CMD="psql --dbname=ranker_training --tuples-only --csv --command=\"$SQL\""
  run_cmd_in_pod "$PG_POD" "$CMD" $OC_ARGS

  ##########################
  brlog "INFO" "    Migrating sdu tables"
  sdu_tables=(annotations collections documents images pages pdf_page_batch task_results tasks training_documents)

  SQL="BEGIN;"

  for table in ${sdu_tables[@]} ; do
    SQL+=" ALTER TABLE ${table} DISABLE TRIGGER ALL;"
  done

  for table in ${sdu_tables[@]} ; do
    SQL+=" UPDATE $table SET tenant_id = '$dst' WHERE tenant_id = '$src';"
  done

  for table in ${sdu_tables[@]} ; do
    SQL+=" ALTER TABLE ${table} ENABLE TRIGGER ALL;"
  done

  SQL+=" COMMIT;"

  CMD="psql --dbname=sdu --tuples-only --csv --command=\"$SQL\""
  run_cmd_in_pod "$PG_POD" "$CMD" $OC_ARGS

  ##############
  # MinIO
  ##############

  brlog "INFO" "    Migrating MinIO contents"

  bucket_suffix="$(get_bucket_suffix)"
  if [ -n "${bucket_suffix}" ] ; then
    run_script_in_pod ${MC_POD} "${SCRIPT_DIR}/src/minio-mt-migration.sh" "-s ${src} -t ${dst} --suffix ${bucket_suffix}"
  else
    run_script_in_pod ${MC_POD} "${SCRIPT_DIR}/src/minio-mt-migration.sh" "-s ${src} -t ${dst}"
  fi

  ##############
  # ElasticSearch
  ##############

  brlog "INFO" "    Migrating ElasticSearch index"
  if [ "$(oc ${OC_ARGS} get elasticsearchcluster ${TENANT_NAME} -o jsonpath='{.spec.nodes[?(@.name=="data")].replicas}')" = "1" ] ; then
    replica=0
  else
    replica=1
  fi
  _oc_cp "${SCRIPT_DIR}/src/tenant_index_template.json" "${ELASTIC_POD}:/tmp/tenant_index_template.json" ${OC_ARGS} -c elasticsearch
  run_script_in_pod ${ELASTIC_POD} "${SCRIPT_DIR}/src/elastic-mt-migration.sh" "-s ${src} -t ${dst} --template /tmp/tenant_index_template.json --replica ${replica}" -c elasticsearch

done

oc ${OC_ARGS} delete -f "${PG_JOB_FILE}"
oc ${OC_ARGS} delete -f "${S3_JOB_FILE}"

rm -rf ${TMP_WORK_DIR}
if [ -z "$(ls tmp)" ] ; then
  rm -rf tmp
fi

brlog "INFO" "Migration done"

exit
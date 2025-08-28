#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/lib/function.bash"

s3_buckets=${S3_BUCKETS:-}
s3_access_key="${S3_ACCESS_KEY:-dummy_key}"
s3_secret_key="${S3_SECRET_KEY:-dummy_key}"
s3_endpoint="${S3_ENDPOINT_URL:-https://localhost}"
s3_backup_dir=${S3_BACKUP_DIR:-s3_backup}
s3_cert_path="${S3_CERT_PATH:-/tmp/ca.cert}"
s3_common_bucket="${S3_COMMON_BUCKET:-common}"
aws_config_dir="${S3_CONFIG_DIR:-/tmp/.aws}"

show_help(){
cat << EOS
Usage: $0 (backup|restore) [options]

Options:
  -h, --help              Print help info
  -f, --file              Backup file name
  -d, --backup-dir       Directory where the backup file will be saved (when backup) or retrieved from (when restore)
  -l, --log-level         Log level. "ERROR", "WARN", "INFO" or "DEBUG"
EOS
}

check_bucket_exists() {
  local bucket=$1
  result="$(aws s3 "${aws_args[@]}" ls "s3://${bucket}" 2>&1)"
  rc=$?
  if [ $rc -eq 0 ] ; then
    return 0
  elif echo "${result}" | grep "NoSuchBucket" > /dev/null ; then
    # bucket does not exists
    return 1
  else
    echo "${result}" >&2
    return 2
  fi
}

sync_bucket() {
  local bucket=$1
  local src=$2
  local dst=$3
  local extra=${4:-}

  brlog "DEBUG" "sync_bucket bucket:${bucket} src:${src} dst:${dst} extra:${extra}"

  set +eo pipefail
  brlog "INFO" "Check if ${bucket} exists"
  check_bucket_exists "${bucket}"
  rc=$?
  set -eo pipefail
  if [ $rc -eq 0 ] ; then
    brlog "INFO" "Bucket '${bucket}' exists."
  elif [ $rc -eq 1 ] ; then
    brlog "WARN" "bucket does not exists: '${bucket}'"
    brlog "INFO" "Create bucket"
    aws s3 mb "${aws_args[@]}" "s3://${bucket}"
  else
    brlog "ERROR" "Unexpected error"
    exit 1
  fi

  brlog "INFO" "Start sync"
  set -x
  aws s3 sync "${aws_args[@]}" --no-progress --delete "${src}" "${dst}" ${extra}
  set +x
}

while (( $# > 0 )); do
  case "$1" in
    -h | --help )
      show_help
      exit 0
      ;;
    -l | --log-level)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      export BACKUP_RESTORE_LOG_LEVEL="$2"
      shift 1
      ;;
    -f | --file)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      s3_backup_file="$2"
      shift 1
      ;;
    -d | --backup-dir)
      if [[ -z "$2" ]] || [[ "$2" =~ ^-+ ]]; then
        brlog "ERROR" "option requires an argument: $1"
        exit 1
      fi
      s3_backup_dir="$2"
      shift 1
      ;;
    *)
      if [[ ! -z "$1" ]] && [[ ! "$1" =~ ^-+ ]]; then
        if [ "$1" = "backup" -o "$1" = "restore" ] ; then
          COMMAND=$1
        else
          brlog "ERROR" "illegal argument: $1"
          exit 1
        fi
      fi
      ;;
  esac
  shift
done

if [ -n "${MINIO_ARCHIVE_OPTION}" ] ; then
  read -a MINIO_TAR_OPTIONS <<< ${MINIO_ARCHIVE_OPTION}
else
  MINIO_TAR_OPTIONS=("")
fi
VERIFY_DATASTORE_ARCHIVE=${VERIFY_DATASTORE_ARCHIVE-true}

# NOTE: reload the function once necessary variables are exported.
source "${SCRIPT_DIR}/lib/function.bash"

brlog "INFO" "S3 ${COMMAND}"
brlog "DEBUG" "s3_backup_file: ${s3_backup_file}"
brlog "DEBUG" "s3_backup_dir: ${s3_backup_dir}"
brlog "DEBUG" "s3_buckets: ${s3_buckets}"

# Configure credentials.
brlog "INFO" "Start ${COMMAND}: ${s3_buckets}"
rm -rf ${aws_config_dir}
mkdir -p ${aws_config_dir}
export AWS_CONFIG_FILE="${aws_config_dir}/config"
export AWS_SHARED_CREDENTIALS_FILE="${aws_config_dir}/credentials"
rm -f "${AWS_SHARED_CREDENTIALS_FILE}"
cat <<EOF > "${AWS_SHARED_CREDENTIALS_FILE}"
[default]
aws_access_key_id=${s3_access_key}
aws_secret_access_key=${s3_secret_key}
EOF
aws_args=( --endpoint-url "${s3_endpoint}" --ca-bundle "${s3_cert_path}" )
brlog "INFO" "Existing s3 buckets:"
aws s3 "${aws_args[@]}" ls "s3://${s3_common_bucket}"

if [ "${COMMAND}" = "restore" ] ; then
  brlog "INFO" "Unpacking backup source data ..."
  tar "${MINIO_TAR_OPTIONS[@]}" -xf "${s3_backup_dir}/${s3_backup_file}" -C "${s3_backup_dir}"
  # Remove extracted backup source file.
  rm -f "${s3_backup_dir}/${s3_backup_file}"

  # Restore each bucket.
  for bucket_path in "${s3_backup_dir}"/*
  do
    bucket="$(basename "${bucket_path}")"
    # Add bucket suffix if needed.
    if [ -n "${BUCKET_SUFFIX}" ] && [[ "${bucket}" != *"${BUCKET_SUFFIX}" ]] ; then
      mv "${s3_backup_dir}/${bucket}" "${s3_backup_dir}/${bucket}${BUCKET_SUFFIX}"
      bucket="${bucket}${BUCKET_SUFFIX}"
    fi
    brlog "INFO" "Process ${bucket}"
    sync_bucket "${bucket}" "${s3_backup_dir}/${bucket}" "s3://${bucket}"
  done
  brlog "INFO" "Restore successfully completed."
fi 

if [ "${COMMAND}" = "backup" ] ; then
  mkdir -p "${s3_backup_dir}"
  buckets=(${s3_buckets//,/ })
  EXCLUDE_OBJECTS=$(cat "${SCRIPT_DIR}/src/minio_exclude_paths")
  EXCLUDE_OBJECTS+=$'\n'
  EXCLUDE_OBJECTS+="$(cat "${SCRIPT_DIR}/src/mcg_exclude_paths")"
  brlog "DEBUG" "EXCLUDE_OBJECTS: ${EXCLUDE_OBJECTS[*]}"

  # Backup each bucket.
  for bucket in "${buckets[@]}"
  do
    brlog "INFO" "Process ${bucket}"
    # Get exclude arguments.  
    EXTRA_AWS_SYNC_COMMAND=()
    ORG_IFS=${IFS}
    IFS=$'\n'
    for line in ${EXCLUDE_OBJECTS}
    do
      base_bucket_name=${bucket%"${BUCKET_SUFFIX}"}
      brlog "DEBUG" "base_bucket_name: ${base_bucket_name}"
      if [[ ${line} == ${base_bucket_name}* ]] ; then
        exclude_bucket_name="${line#"$base_bucket_name" }"
        if [ "${exclude_bucket_name}" = "*" ] ; then
          brlog "DEBUG" "SKIP ${bucket}"
          continue 2
        fi
        EXTRA_AWS_SYNC_COMMAND+=( "--exclude" "${exclude_bucket_name}" )
      fi
    done
    IFS=${ORG_IFS}
    brlog "DEBUG" "EXTRA_AWS_SYNC_COMMAND: ${EXTRA_AWS_SYNC_COMMAND[*]}"
    sync_bucket "${bucket}" "s3://${bucket}" "${s3_backup_dir}/${bucket}" "${EXTRA_AWS_SYNC_COMMAND[*]}"
  done
  archive_backup "${s3_backup_file}" "${s3_backup_dir}" "${MINIO_TAR_OPTIONS[@]}"
  brlog "INFO" "Backup created"
fi

brlog "INFO" "S3 ${COMMAND} DONE."
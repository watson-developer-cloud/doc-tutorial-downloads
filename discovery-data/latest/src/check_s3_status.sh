#!/usr/bin/env bash

set -euo pipefail

s3_access_key="${S3_ACCESS_KEY:-dummy_key}"
s3_secret_key="${S3_SECRET_KEY:-dummy_key}"
s3_endpoint="${S3_ENDPOINT_URL:-https://localhost}"
s3_cert_path="${S3_CERT_PATH:-/tmp/ca.cert}"
s3_common_bucket="${S3_COMMON_BUCKET:-common}"
aws_config_dir="${S3_CONFIG_DIR:-/tmp/.aws}"

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

aws s3 "${aws_args[@]}" ls "s3://${s3_common_bucket}"
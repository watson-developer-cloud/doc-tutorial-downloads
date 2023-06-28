#!/usr/bin/env bash

set -euo pipefail

show_help(){
cat << EOS
Usage: $0 [options]

Options:
  -h, --help              Print help info
  -s, --source            Source name where create data
  -t, --target            Loop count to create data
EOS
}

replica=0

while (( $# > 0 )); do
  case "$1" in
    -h | --help )
      show_help
      exit 0
      ;;
    -s | --source )
      shift
      source="$1"
      ;;
    -t | --target )
      shift
      target="$1"
      ;;
    --template)
      shift
      template="$1"
      ;;
    --replica)
      shift
      replica="$1"
      ;;
    * )
      if [[ -z "$action" ]]; then
        action="$1"
      else
        echo "Invalid argument."
        show_help
        exit 1
      fi
      ;;
  esac
  shift
done

if [ -z "${source+UNDEF}" ] ; then
  echo "Source tenant ID not defined"
  exit 1
fi

if [ -z "${target+UNDEF}" ] ; then
  echo "Target tenant ID not defined"
  exit 1
fi

ELASTIC_OPTIONS=(
  "-k"
  "-s"
  "-u"
  "${ELASTIC_USER}:${ELASTIC_PASSWORD}"
  "-H"
  "Content-Type: application/json"
)

ELASTIC_ENDPOINT=https://localhost:9200

source_index="tenant_${source}_notice"
target_index="tenant_${target}_notice"

json_disable_read_write='{
    "settings": {
        "index.blocks.write": "true"
    }
}'

json_clone_settings='{
    "settings": {
        "index.blocks.write": null 
    }
}'

indices=$(curl "${ELASTIC_OPTIONS[@]}" "${ELASTIC_ENDPOINT}/_cat/indices?h=index")

if echo "${indices}" | grep "${source_index}" > /dev/null ; then
  echo "Migrate ${source_index} to ${target_index}"
  curl "${ELASTIC_OPTIONS[@]}" -X PUT  "${ELASTIC_ENDPOINT}/${source_index}/_settings" -d"${json_disable_read_write}"
  curl "${ELASTIC_OPTIONS[@]}" -X POST "${ELASTIC_ENDPOINT}/${source_index}/_clone/${target_index}" -d"${json_clone_settings}"

  MAX_RETRY_COUNT=5
  retry_count=0
  while :
  do
    curl "${ELASTIC_OPTIONS[@]}" "${ELASTIC_ENDPOINT}/_cluster/health/${target_index}?wait_for_status=green&timeout=30s" | grep -e "yellow" -e "green" && break
    ((retry_count))
    if [ ${retry_count} -ge ${MAX_RETRY_COUNT} ] ; then
      curl "${ELASTIC_OPTIONS[@]}" -X POST "${ELASTIC_ENDPOINT}/_cluster/reroute?retry_failed=true"
      retry_count=0
    fi
  done

  curl "${ELASTIC_OPTIONS[@]}"  -X DELETE "${ELASTIC_ENDPOINT}/${source_index}"
else
  echo "Source index ${source_index} not found. Create index for ${target_index}."
  sed -e "s/#tenant_id#/${target}/g" "${template}" > /tmp/index_request.json
  sed -e "s/#replica_size#/${replica}/g" "${template}" > /tmp/index_request.json
  curl "${ELASTIC_OPTIONS[@]}" -X PUT "${ELASTIC_ENDPOINT}/${target_index}" -d@/tmp/index_request.json
  echo
  rm -f /tmp/index_request.json
fi

for index in ${indices}
do
  tenant_id=$(curl "${ELASTIC_OPTIONS[@]}" "${ELASTIC_ENDPOINT}/${index}/_settings" | jq -r .\"${index}\".settings.index.tenant_id)
  if echo "${tenant_id}" | grep "${source}" > /dev/null ; then
    echo "Update tenant ID in ${index}"
    curl "${ELASTIC_OPTIONS[@]}" -XPUT ${ELASTIC_ENDPOINT}/${index}/_settings  --data-raw "{\"index.tenant_id\": \"${target}\"}"
    echo
  fi
done
#!/usr/bin/env bash

set -euo pipefail

TMP_WORK_DIR="/tmp/elastic-workdir"

function generate_new_settings() {
    local index="$1"
    local org_settings_json="$2"
    local new_settings_json="$3"

    UNNECESSARY_settings="provided_name creation_date uuid version"

    echo "Generating new settings"
    \cp "${org_settings_json}" "${new_settings_json}"

    echo "Removing unnecessary settings"
    for key in ${UNNECESSARY_settings} ; do
        jq ". | del(.\"${index}\".settings.index.${key})" "${new_settings_json}" > tmp.json
        \cp tmp.json "${new_settings_json}"
    done
    \rm tmp.json
}


function get_mappings() {
    local index="$1"
    local mappings_json="$2"

    echo "Getting mappings"
    curl -sSfk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" "${ELASTIC_ENDPOINT}/${index}/_mappings" > "${mappings_json}"
}


function create_new_index() {
    local index="$1"
    local new_settings_json="$2"
    local mappings_json="$3"
    local new_index="$4"

    echo "Creating new index ${new_index}"

    local settings="$(jq ".\"${index}\".settings" "${new_settings_json}")"
    local mappings=$(jq ".\"${index}\".mappings" "${mappings_json}")

    index_data='{"settings":'${settings}', "mappings":'${mappings}'}'
    index_data_json=index_data.json
    echo "${index_data}" > "${index_data_json}"

    curl -sSfk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" -H "Content-Type: application/json" -XPUT "${ELASTIC_ENDPOINT}/${new_index}" -d@"${TMP_WORK_DIR}/${index_data_json}"
    echo ""
}


function execute_reindex() {
    local index="$1"
    local new_index="$2"

    echo "Executing reindex index to ${new_index}"

    reindex_body='{"source": {"index": "'${index}'"}, "dest": {"index": "'${new_index}'"}}'
    reindex_body_json=reindex_body.json

    echo "${reindex_body}" > "${reindex_body_json}"

    reindex_task="$(curl -sSfk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" -H "Content-Type: application/json" -XPOST "${ELASTIC_ENDPOINT}/_reindex?wait_for_completion=false" -d@"${TMP_WORK_DIR}/${reindex_body_json}")"
    if [ -z "${reindex_task}" ] ; then
        echo "Failed to launch reindex task"
        exit 1
    fi
    task_id="$(echo "${reindex_task}" | jq -r '.task')"
    if [ -z "${task_id}" ] || [ "${task_id}" = "null" ] ; then
        echo "Failed to get task ID of reindex"
        exit 1
    fi
    echo "Reindex task ID: ${task_id}"
    base_interval=${TASK_CHECK_BASE_INTERVAL:-10}
    max_interval=${MAX_TASK_CHECK_INTERVAL:-300}
    local count=0
    while ((count++));
    do
        # Ignore failure
        task_status="$(curl -sSk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" "${ELASTIC_ENDPOINT}/_tasks/${task_id}")"
        if [ "$( echo "${task_status}" | jq -r '.completed')" != "true" ] ; then
            echo "In Progress: $(echo "${task_status}" | jq -r '.task.description')"
            interval=$((base_interval * count))
            sleep $((interval < max_interval ? interval : max_interval))
            continue
        fi
        reindex_result="$(echo "${task_status}" | jq -r '.response')"
        if [ "$(echo "${reindex_result}" | jq -r '.timed_out' )" = "true" ] || [ "$(echo "${reindex_result}" | jq -r '.failures' )" != "[]"  ] ; then
            echo "Failed to reindex: ${new_index}"
            echo "${reindex_result}"
            exit 1
        fi
        break
    done

    echo "Reindexed: ${new_index}"
}


function set_index_readonly() {
    local index="$1"

    echo "Setting index ${index} to read-only"

    READONLY_TRUE_BODY='{"settings": {"index.blocks.write": true}}'
    READONLY_TRUE_BODY_JSON=READONLY_TRUE_BODY.json
    echo "${READONLY_TRUE_BODY}" > "${READONLY_TRUE_BODY_JSON}"

    curl -sSfk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" -H "Content-Type: application/json" -XPUT "${ELASTIC_ENDPOINT}/${index}/_settings" -d@"${TMP_WORK_DIR}/${READONLY_TRUE_BODY_JSON}"
    echo ""
}


function unset_index_readonly() {
    local index="$1"

    echo "Unsetting index ${index} to read-only"

    READONLY_FALSE_BODY='{"settings": {"index.blocks.write": false}}'
    READONLY_FALSE_BODY_JSON=readonly_false_body.json
    echo "${READONLY_FALSE_BODY}" > "${READONLY_FALSE_BODY_JSON}"

    curl -sSfk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" -H "Content-Type: application/json" -XPUT "${ELASTIC_ENDPOINT}/${index}/_settings" -d@"${TMP_WORK_DIR}/${READONLY_FALSE_BODY_JSON}"
    echo ""
}


function clone_index() {
    local src_index="$1"
    local dst_index="$2"

    replica_num="$(get_replica_num "${src_index}")"

    set_index_readonly "${src_index}"
    echo "Renaming index from ${src_index} to ${dst_index}"

    clone_body='{"settings": {"index.number_of_replicas": '${replica_num}'}}'
    clone_body_json=clone_body.json
    echo "${clone_body}" > "${clone_body_json}"

    curl -sSfk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" -H "Content-Type: application/json" -XPOST "${ELASTIC_ENDPOINT}/${src_index}/_clone/${dst_index}" -d@"${TMP_WORK_DIR}/${clone_body_json}"
    echo ""

    unset_index_readonly "${src_index}"
    unset_index_readonly "${dst_index}"
}


function get_replica_num() {
    local index="$1"

    settings="$(curl -sSfk -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} ${ELASTIC_ENDPOINT}/${index}/_settings)"

    echo "${settings}" | jq -r ".\"${index}\".settings.index.number_of_replicas"
}


function remove_index() {
    local index="$1"

    echo "Removing index ${index}"
    curl -sSfk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" -XDELETE "${ELASTIC_ENDPOINT}/${index}"
    echo ""
}

function remove_index_if_exists(){
    local index="$1"
    http_status="$(curl -sSk -XHEAD -o /dev/null -w '%{http_code}' -I -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" "${ELASTIC_ENDPOINT}/${index}")"
    if [ "${http_status}" = "200" ] ; then
        echo "Remove existing index : ${index}"
        remove_index "${index}"
    elif [ "${http_status}" != "404" ] ; then
        echo "Failed to check if index exist: ${index}"
        exit 1
    fi
}

# Main logic start from here
trap 'if [ $? -ne 0 ] ; then echo "Error: Please contact support. Do not run this scripts again."; fi' 0 1 2 3 15
rm -rf "${TMP_WORK_DIR}"
mkdir -p "${TMP_WORK_DIR}"
cd "${TMP_WORK_DIR}"

echo "Checking status of ElasticSearch"
cluster_stats="$(curl -sSfk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" "${ELASTIC_ENDPOINT}/_cluster/stats")"
if [ -z "${cluster_stats}" ] ; then
    echo "Failed to get stats"
    exit 1
fi
cluster_status="$(echo "${cluster_stats}" | jq -r '.status')"
if [ -z "${cluster_status}" ] || [ "${cluster_status}" = "red" ] ; then
    echo "Unhealthy cluster status: ${cluster_status}"
    exit 1
fi

index_count="$(echo "${cluster_stats}" | jq -r '.indices.count')"
if [ -z "${index_count}" ] ; then
    echo "Failed to get index count"
    exit 1
fi

if [ "${index_count}" = "0" ] ; then
    echo "ElasticSearch has no index"
    echo "Completed!"
    exit 0
fi

echo "Getting index list"
indices="$(curl -sSkf -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" "${ELASTIC_ENDPOINT}/_cat/indices?h=index")"

if [[ -z "${indices}" ]] ; then
    echo "Failed to get index list"
    exit 1
fi

total=$(echo "$indices" | wc -w)
echo "Total number of indices: ${total}"

count=1
for index in ${indices} ; do
    org_settings_json="${index}.settings.json"
    new_settings_json="${index}.settings.new.json"
    mappings_json="${index}.mappings.json"

    version="$(curl -sSkf -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" "${ELASTIC_ENDPOINT}/${index}/_settings" | jq -r .[].settings.index.version.created)"
    if [[ ${version} = 7* ]]; then
        echo "[${count} / ${total}] Skip ElasticSearch 7 index: ${index}"
    elif [[ ${version} = 6* ]]; then
        echo "[${count} / ${total}] ElasticSearch 6 index found: ${index}"
        echo "----------------------------"
        echo "Updating index - ${index} ..."
        curl -sSkf -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" "${ELASTIC_ENDPOINT}/${index}/_settings" > "${org_settings_json}"
        generate_new_settings "${index}" "${org_settings_json}" "${new_settings_json}"

        get_mappings "${index}" "${mappings_json}"

        new_index="${index}_new"

        remove_index_if_exists "${new_index}"

        create_new_index "${index}" "${new_settings_json}" "${mappings_json}" "${new_index}"

        execute_reindex "${index}" "${new_index}"

        # TMP_index=${index}_tmp
        # clone_index ${index} ${TMP_index}

        remove_index "${index}"

        clone_index "${new_index}" "${index}"

        remove_index "${new_index}"
        echo "----------------------------"
    else
        echo "Failed to get version of index: ${index}"
        exit 1
    fi
    ((count++))
done

rm -rf "${TMP_WORK_DIR}"

trap 0 1 2 3 15
echo "Completed!"
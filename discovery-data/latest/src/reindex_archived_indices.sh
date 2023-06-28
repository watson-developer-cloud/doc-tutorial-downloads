#!/bin/bash

TMP_WORK_DIR=/tmp/elastic-workdir

function generate_new_settings() {
    INDEX=$1
    ORG_SETTINGS_JSON=$2

    UNNECESSARY_SETTINGS="provided_name creation_date uuid version"

    ARCHIVED_SETTINGS=$(cat ${ORG_SETTINGS_JSON} | jq -r ".\"${INDEX}\".settings.archived")

    echo "Generating new settings for index ${INDEX} ..."
    if [ "${ARCHIVED_SETTINGS}" != "null" ] ; then
        \cp ${ORG_SETTINGS_JSON} ${NEW_SETTINGS_JSON}

        echo "Archived settings: ${ARCHIVED_SETTINGS}"
        for p in $(echo ${ARCHIVED_SETTINGS} | jq -r ". | keys | .[]") ; do
            echo "Moving settings under parent key: ${p} ..."
            for k in $(echo ${ARCHIVED_SETTINGS} | jq -r ".${p} | keys | .[]"); do
                v=$(echo ${ARCHIVED_SETTINGS} | jq -r ".${p}.${k}")
                echo "Moving setting - ${k}: ${v} ..."
                cat ${NEW_SETTINGS_JSON} | jq ".\"${INDEX}\".settings.${p} |= .+{\"${k}\": \"${v}\"} | del(.\"${INDEX}\".settings.archived.${p}.${k})" > tmp.json
                \cp tmp.json ${NEW_SETTINGS_JSON}
            done

            echo "Removing parent settings: ${p} ..."
            cat ${NEW_SETTINGS_JSON} | jq ". | del(.\"${INDEX}\".settings.archived.${p})" > tmp.json
            \cp tmp.json ${NEW_SETTINGS_JSON}
        done

        echo "Removing archived settings ..."
        cat ${NEW_SETTINGS_JSON} | jq ". | del(.\"${INDEX}\".settings.archived)" > tmp.json
        \cp tmp.json ${NEW_SETTINGS_JSON}

        echo "Removing unnecessary settings ..."
        for k in $(echo ${UNNECESSARY_SETTINGS}) ; do
            cat ${NEW_SETTINGS_JSON} | jq ". | del(.\"${INDEX}\".settings.index.${k})" > tmp.json
            \cp tmp.json ${NEW_SETTINGS_JSON}
        done

        \rm tmp.json
    else
        echo "Error occurred while generating new settings!"
    fi
}


function get_mappings() {
    INDEX=$1
    MAPPINGS_JSON=$2

    echo "Getting mappings of index ${INDEX} ..."
    curl -sSk -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} ${ELASTIC_ENDPOINT}/${INDEX}/_mappings > ${MAPPINGS_JSON}
}


function create_new_index() {
    INDEX=$1
    NEW_SETTINGS_JSON=$2
    MAPPINGS_JSON=$3
    NEW_INDEX=$4

    echo "Creating new index ${NEW_INDEX} ..."

    SETTINGS=$(cat ${NEW_SETTINGS_JSON} | jq .\"${INDEX}\".settings)
    MAPPINGS=$(cat ${MAPPINGS_JSON} | jq .\"${INDEX}\".mappings)

    INDEX_DATA='{"settings":'${SETTINGS}', "mappings":'${MAPPINGS}'}'
    INDEX_DATA_JSON=index_data.json
    echo ${INDEX_DATA} > ${INDEX_DATA_JSON}

    curl -sSk -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} -H "Content-Type: application/json" -XPUT ${ELASTIC_ENDPOINT}/${NEW_INDEX} -d@${TMP_WORK_DIR}/${INDEX_DATA_JSON}
    echo ""
}


function execute_reindex() {
    INDEX=$1
    NEW_INDEX=$2

    echo "Executing reindex index to ${NEW_INDEX} ..."

    REINDEX_BODY='{"source": {"index": "'${INDEX}'"}, "dest": {"index": "'${NEW_INDEX}'"}}'
    REINDEX_BODY_JSON=reindex_body.json
    echo ${REINDEX_BODY} > ${REINDEX_BODY_JSON}

    curl -sSk -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} -H "Content-Type: application/json" -XPOST ${ELASTIC_ENDPOINT}/_reindex -d@${TMP_WORK_DIR}/${REINDEX_BODY_JSON}
    echo ""
}


function set_index_readonly() {
    INDEX=$1

    echo "Setting index ${INDEX} to read-only ..."

    READONLY_TRUE_BODY='{"settings": {"index.blocks.write": true}}'
    READONLY_TRUE_BODY_JSON=readonly_true_body.json
    echo ${READONLY_TRUE_BODY} > ${READONLY_TRUE_BODY_JSON}

    curl -sSk -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} -H "Content-Type: application/json" -XPUT ${ELASTIC_ENDPOINT}/${INDEX}/_settings -d@${TMP_WORK_DIR}/${READONLY_TRUE_BODY_JSON}
    echo ""
}


function unset_index_readonly() {
    INDEX=$1

    echo "Unsetting index ${INDEX} to read-only ..."

    READONLY_FALSE_BODY='{"settings": {"index.blocks.write": false}}'
    READONLY_FALSE_BODY_JSON=readonly_false_body.json
    echo ${READONLY_FALSE_BODY} > ${READONLY_FALSE_BODY_JSON}

    curl -sSk -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} -H "Content-Type: application/json" -XPUT ${ELASTIC_ENDPOINT}/'${INDEX}'/_settings -d@${TMP_WORK_DIR}/${READONLY_FALSE_BODY_JSON}
    echo ""
}


function clone_index() {
    OLD_NAME=$1
    NEW_NAME=$2

    REPLICA_NUM=$(get_replica_num ${OLD_NAME})

    set_index_readonly ${OLD_NAME}
    echo "Renaming index from ${OLD_NAME} to ${NEW_NAME} ..."

    CLONE_BODY='{"settings": {"index.number_of_replicas": '${REPLICA_NUM}'}}'
    CLONE_BODY_JSON=clone_body.json
    echo ${CLONE_BODY} > ${CLONE_BODY_JSON}

    curl -sSk -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} -H "Content-Type: application/json" -XPOST ${ELASTIC_ENDPOINT}/${OLD_NAME}/_clone/${NEW_NAME} -d@${TMP_WORK_DIR}/${CLONE_BODY_JSON}
    echo ""

    unset_index_readonly ${OLD_NAME}
    unset_index_readonly ${NEW_NAME}
}


function get_replica_num() {
    INDEX=$1

    SETTINGS=$(curl -sSk -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} ${ELASTIC_ENDPOINT}/${INDEX}/_settings)

    echo ${SETTINGS} | jq -r ".\"${INDEX}\".settings.index.number_of_replicas"
}


function remove_index() {
    INDEX=$1

    echo "Removing index ${INDEX} ..."
    curl -sSk -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} -XDELETE ${ELASTIC_ENDPOINT}/${INDEX}
    echo ""
}


# Main logic start from here
rm -rf ${TMP_WORK_DIR}
mkdir -p ${TMP_WORK_DIR}
cd ${TMP_WORK_DIR}

INDICES=$(curl -sSk -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} ${ELASTIC_ENDPOINT}/_cat/indices?h=index)
TOTAL=$(echo $INDICES | wc -w)

echo "Total number of indices: ${TOTAL}"

COUNT=1
for INDEX in $(echo ${INDICES}); do
    ORG_SETTINGS_JSON=${INDEX}.settings.json
    NEW_SETTINGS_JSON=${INDEX}.settings.new.json
    MAPPINGS_JSON=${INDEX}.mappings.json

    curl -sSk -u ${ELASTIC_USER}:${ELASTIC_PASSWORD} ${ELASTIC_ENDPOINT}/${INDEX}/_settings > ${ORG_SETTINGS_JSON}
    ARCHIVED_SETTINGS=$(cat ${ORG_SETTINGS_JSON} | jq -r ".\"${INDEX}\".settings.archived")

    echo "----------------------------"
    if [ "${ARCHIVED_SETTINGS}" != "null" ]; then
        echo "[${COUNT} / ${TOTAL}] Updating index - ${INDEX} ..."
        generate_new_settings ${INDEX} ${ORG_SETTINGS_JSON}

        get_mappings ${INDEX} ${MAPPINGS_JSON}

        NEW_INDEX=${INDEX}_new
        create_new_index ${INDEX} ${NEW_SETTINGS_JSON} ${MAPPINGS_JSON} ${NEW_INDEX}

        execute_reindex ${INDEX} ${NEW_INDEX}

        # TMP_INDEX=${INDEX}_tmp
        # clone_index ${INDEX} ${TMP_INDEX}

        remove_index ${INDEX}

        clone_index ${NEW_INDEX} ${INDEX}
    else
        echo "[${COUNT} / ${TOTAL}] No archived settings - ${INDEX}"
    fi

    ((COUNT++))
done

rm -rf ${TMP_WORK_DIR}
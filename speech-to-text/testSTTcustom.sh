#!/bin/bash

##########################################################################
# Prerequisites: Add service credentials and set variables
# You must have curl installed to execute this scrpt. See the following
# link to download the version of curl for your operating system:
#   https://curl.haxx.se/
##########################################################################

#
# Specify your IBM Cloud service credentials for USERNAME and PASSWORD:
#
# o If you use IAM service credentials, leave USERNAME set to "apikey"
#   and set PASSWORD to the value of your IAM API key.
# o If you use pre-IAM service credentials, set the values to your USERNAME
#   and PASSWORD.
#
# See the following instructions for getting your own credentials:
#   https://cloud.ibm.com/docs/watson?topic=watson-iam
#

USERNAME="apikey"
PASSWORD="YOUR_IAM_APIKEY"

#
# Set URL to the URL for your service instance as provided in your service
# credentials.
#

URL="YOUR_URL"

#
# Set INSECURE to "-k" to use insecure SSL connections that bypass the use
# of SSL certificates if you encounter certificate problems when using curl.
# Set the variable to "" to use secure SSL connections.
#

INSECURE="-k"

#
# Set the following variables to use your own corpus file and name in Step 2:
#
# o CORPUS_FILE defines the name of a corpus text file to be added to the
#   custom model.
# o CORPUS_NAME is the name of the new corpus that is added to the model.
#

CORPUS_FILE="corpus.txt"
CORPUS_NAME="corpus1"

#
# Leave the following variables unchanged.
#

TEMPFILE="testSTTcustom.tmp"
RESPCODE=""
RESPJSON=""

##########################################################################
# The following functions are defined here and used throughout the script.
##########################################################################

function getHttpResponse ()
{
  RESPCODE=`cat $TEMPFILE | sed -n -e 's/.*HTTP\/1\.1 \([2-9][0-9]\{2\}\) .*/\1/p'`
  RESPJSON=`cat $TEMPFILE | sed -n -e '/^[a-zA-Z].*$/d' -e '/^[^a-zA-Z].*$/p'`
  rm $TEMPFILE
}

function getCorpusStatus ()
{
  STATUS='being_processed'
  TIME=10

  while [ "$STATUS" != 'analyzed' ]; do
    sleep 10
    RESPONSE=`curl -X GET $INSECURE -u "$USERNAME":"$PASSWORD" \
      "$URL/v1/customizations/$1/corpora/$2" 2> /dev/null`
    STATUS=`echo $RESPONSE | sed -e 's/.*\"status\": \"\([^\"]*\)\".*/\1/'`
    printf "Status: %-15s ( %d )\n" "$STATUS" $TIME
    let "TIME += 10"
  done
}

function getModelStatus ()
{
  STATUS='pending'
  TIME=10

  while [ "$STATUS" != $2 ]; do
    sleep 10
    RESPONSE=`curl -X GET $INSECURE -u "$USERNAME":"$PASSWORD" \
      "$URL/v1/customizations/$1" 2> /dev/null`
    STATUS=`echo $RESPONSE | sed -e 's/.*\"status\": \"\([^\"]*\)\".*/\1/'`
    printf "Status: %-9s ( %d )\n" "$STATUS" $TIME
    let "TIME += 10"
  done
}

##########################################################################
# Step 1: Create a custom model
# You can change "name" and "description" to suit your own model.
##########################################################################

printf "\nCreating custom model...\n"
curl -X POST $INSECURE -i -u "$USERNAME":"$PASSWORD" \
  --header "Content-Type: application/json" \
  --data "{\"name\": \"Custom model number one\", \
    \"base_model_name\": \"en-US_BroadbandModel\", \
    \"description\": \"My first STT custom model\"}" \
  "$URL/v1/customizations" 2> /dev/null > $TEMPFILE
getHttpResponse

printf "Model creation returns: $RESPCODE\n"
if [ $RESPCODE != 201 ]; then
  echo "Failed to create model"
  printf "$RESPJSON\n"
  exit -1
fi

CUSTOMIZATION_ID=`echo $RESPJSON | sed -e 's/.*\"customization_id\": \"\([^\"]*\)\".*/\1/'`
printf "Model customization_id: $CUSTOMIZATION_ID\n"

##########################################################################
# Step 2: Add a corpus file
# Add a plain text file, ideally one sentence per line, but not necessary.
# In this example, we name it 'corpus1'; you can name it whatever you want
# (no spaces); if adding more than one corpus, add them with different names.
# After the corpus is uploaded, there is some analysis done to extract OOVs.
# You cannot upload a new corpus or words while this analysis is ongoing,
# so we need to loop until the status becomes 'analyzed' for this corpus.
##########################################################################

printf "\nAdding corpus file...\n"
curl -X POST $INSECURE -i -u "$USERNAME":"$PASSWORD" \
  --data-binary "@$CORPUS_FILE" \
  "$URL/v1/customizations/$CUSTOMIZATION_ID/corpora/$CORPUS_NAME" 2> /dev/null > $TEMPFILE
getHttpResponse

printf "Adding corpus file returns: $RESPCODE\n"
if [ $RESPCODE != 201 ]; then
  echo "Failed to add corpus file"
  printf "$RESPJSON\n"
  exit -1
fi

#
# Get status of corpus file just added.
#

printf "\nChecking status of corpus analysis...\n"
getCorpusStatus "$CUSTOMIZATION_ID" "$CORPUS_NAME"
printf "Corpus analysis done!\n"

#
# Show all OOVs words found in the corpus file. This step is necessary only
# to look at the OOV words and validate the auto-added sounds-like field,
# which is generally a good thing to do.
#

printf "\nListing words...\n"
curl -X GET $INSECURE -i -u "$USERNAME":"$PASSWORD" \
  "$URL/v1/customizations/$CUSTOMIZATION_ID/words?sort=count" 2> /dev/null > $TEMPFILE
getHttpResponse

printf "Listing words returns: $RESPCODE\n"
FILENAME=$CUSTOMIZATION_ID.OOVs.corpus
printf "$RESPJSON" > $FILENAME
printf "Words added from corpus saved in file:\n   $FILENAME\n"

##########################################################################
# Step 3: Add a single user-specified word
# You can pass sounds_like and display_as fields or leave empty (if empty,
# the service will try to create its own version of sounds_like).
##########################################################################

printf "\nAdding single word...\n"
curl -X PUT $INSECURE -i -u "$USERNAME":"$PASSWORD" \
  --header "Content-Type: application/json" \
  --data "{\"sounds_like\": [\"T. C. P. I. P.\"], \"display_as\": \"TCP/IP\"}" \
  "$URL/v1/customizations/$CUSTOMIZATION_ID/words/tcpip" 2> /dev/null > $TEMPFILE
getHttpResponse

printf "Adding single word returns: $RESPCODE\n"
if [ $RESPCODE != 201 ]; then
  echo "Failed to add single word"
  printf "$RESPJSON\n"
  exit -1
fi
printf "Single word added!\n"

##########################################################################
# Step 4: Add multiple user-specified words
# Alternatively, you can add multiple words to the custom model in a single
# request. You must monitor the status of the operation until the model is
# 'ready.'
##########################################################################

printf "\nAdding multiple words...\n"
curl -X POST $INSECURE -i -u "$USERNAME":"$PASSWORD" \
  --header "Content-Type: application/json" \
  --data "{\"words\": \
    [{\"word\": \"IEEE\", \"sounds_like\": [\"I. triple E.\"], \"display_as\": \"IEEE\"},\
    {\"word\": \"hhonors\", \"sounds_like\": [\"H. honors\", \"hilton honors\"], \"display_as\": \"HHonors\"}]}" \
  "$URL/v1/customizations/$CUSTOMIZATION_ID/words" 2> /dev/null > $TEMPFILE
getHttpResponse

printf "Adding multiple words returns: $RESPCODE\n"
if [ $RESPCODE != 201 ]; then
  echo "Failed to add multiple words"
  printf "$RESPJSON\n"
  exit -1
fi

#
# Get status of model, looping until status is 'ready.'
#

printf "\nChecking status of model for adding multiple words...\n"
getModelStatus "$CUSTOMIZATION_ID" "ready"
printf "Multiple words added!\n"

#
# Show all words added to the model so far.
#

printf "\nListing words...\n"
curl -X GET $INSECURE -i -u "$USERNAME":"$PASSWORD" \
  "$URL/v1/customizations/$CUSTOMIZATION_ID/words?word_type=user&sort=alphabetical" 2> /dev/null > $TEMPFILE
getHttpResponse

printf "Listing words returns: $RESPCODE\n"
FILENAME=$CUSTOMIZATION_ID.OOVs.user
printf "$RESPJSON" > $FILENAME
printf "Words added by user saved in file:\n   $FILENAME\n"

##########################################################################
# Step 5: Train the model
# After adding words to the custom model, you must train the mode on the
# new words. You must monitor the status of the operation until the model
# is 'available.'
##########################################################################

printf "\nTraining custom model...\n"
curl -X POST $INSECURE -i -u "$USERNAME":"$PASSWORD" \
  "$URL/v1/customizations/$CUSTOMIZATION_ID/train" 2> /dev/null > $TEMPFILE
getHttpResponse

printf "Training request returns: $RESPCODE\n"
if [ $RESPCODE != 200 ]; then
  echo "Training failed to start"
  printf "$RESPJSON\n"
  exit -1
fi

#
# Get status of model, looping until status is 'available.'
#

printf "\nChecking status of model for training...\n"
getModelStatus "$CUSTOMIZATION_ID" "available"
printf "Training complete!\n"

#
# Show information about custom models owned by the user.
#

printf "\nGetting custom models...\n"
curl -X GET $INSECURE -i -u "$USERNAME":"$PASSWORD" \
  "$URL/v1/customizations" 2> /dev/null > $TEMPFILE
getHttpResponse

printf "Listing custom models returns: $RESPCODE\n"
if [ $RESPCODE != 200 ]; then
  echo "Listing models failed"
  printf "$RESPJSON\n"
  exit -1
fi
printf "$RESPJSON\n"

#
# Comment the following call to exit to delete the custom model.
#

exit 0

##########################################################################
# Step 6: Delete the custom model (OPTIONAL)
# To delete the custom model, comment the previous call to 'exit'. This is
# potentially useful for experimentation with multiple test models.
##########################################################################

printf "\nDeleting custom model...\n"
curl -X DELETE $INSECURE -i -u "$USERNAME":"$PASSWORD" \
  "$URL/v1/customizations/$CUSTOMIZATION_ID" 2> /dev/null > $TEMPFILE
getHttpResponse

printf "Deleting custom model returns: $RESPCODE\n"
if [ $RESPCODE != 200 ]; then
  echo "Deleting model failed"
  printf "$RESPJSON\n"
  exit -1
fi
printf "Custom model deleted!\n"

#
# Show information about custom models owned by the user.
#

printf "\nGetting custom models...\n"
curl -X GET $INSECURE -i -u "$USERNAME":"$PASSWORD" \
  "$URL/v1/customizations" 2> /dev/null > $TEMPFILE
getHttpResponse

printf "Listing custom models returns: $RESPCODE\n"
if [ $RESPCODE != 200 ]; then
  echo "Listing models failed"
  printf "$RESPJSON\n"
  exit -1
fi
printf "$RESPJSON\n"

exit 0

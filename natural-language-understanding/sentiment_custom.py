# -*- coding: utf-8 -*-
import json
import sys
import ntpath
import requests
from requests.packages.urllib3.exceptions import InsecureRequestWarning

requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

##########################################################################
# Add your IBM Cloud service credentials here.
# o If you use IAM service credentials, leave 'username' set to 'apikey'
#   and set 'password' to the value of your IAM API key.
# o If you use pre-IAM service credentials, set the values to your
#   'username' and 'password'.
# Also set 'url' to the URL for your service instance as provided in your
# service credentials.
# See the following instructions for getting your own credentials:
#   https://cloud.ibm.com/docs/watson?topic=watson-iam
##########################################################################
username = 'apikey'
password = 'YOUR_IAM_APIKEY'
url = 'YOUR_URL'

##########################################################################
# Step 1: Create a new custom sentiment model.
# Add a corpus file (CSV). We name it 'CNSST_train.csv' - you can name it
# whatever you want. Use the following format for your CSV file:
##########################
# doc,label
# I am happy,positive
# I am sad,negative
# The sky is blue,neutral
##########################
#
# Also change data 'name' and 'language' code below to suit your own model.
# Supported lang codes are: ar, de, en, es, fr, it, ja, ko, nl, pt, zh.
##########################################################################
training_data = 'CNSST_train.csv'
data = {'name':'Custom model #1', 'language':'en'}

headers = {'Content-Type' : 'multipart/form-data'}
data.update({'version':'1.0.1'})
url, _, _ = url.partition('/instances')
uri = url + '/v1/models/sentiment?version=2019-01-01'

print('\nCreating custom model...')
with open(training_data, 'rb') as f:
    resp = requests.post(uri, auth=(username, password), verify=False,
                         data=data, files={'training_data': \
                         (ntpath.basename(training_data), f, 'text/csv')})

print('Model creation returned: ', resp.status_code)
if resp.status_code != 201:
    print('Failed to create model')
    print(resp.text)
    sys.exit(-1)
print('\nCustom model training started...')
respJson = resp.json()
model_id = respJson['model_id']
print('Custom Model ID: ', model_id)

##########################################################################
# Step 2: Retrieve custom sentiment model by ID.
# The status in the output shows the training status.
# To only see the status of your model, comment out
# lines starting with 'Creating custom model...' through 'Custom Model ID:'
# in step 1. Replace the value of 'model_id' below and rerun the script.
# The model_id value was printed to the terminal when you created a model
# in step 1.
##########################################################################
print('\nGetting custom model...')
uri = url + '/v1/models/sentiment/' + model_id + '?version=2019-01-01'
resp = requests.get(uri, auth=(username, password), verify=False, headers=headers)
print('Get model returned: ', resp.status_code)
respJson = resp.json()
print(json.dumps(respJson, indent=4, sort_keys=True))

sys.exit(0)

##########################################################################
# Step 3:(OPTIONAL) TO DELETE SENTIMENT CUSTOM MODEL.
# Comment out 'sys.exit(0)' in Step:2.
# Useful for experimentation with multiple test models.
##########################################################################
print('\nDelete custom model...')
uri = url + '/v1/models/sentiment/' + model_id + '?version=2019-01-01'
response = requests.delete(uri, auth=(username, password), verify=False, headers=headers)
print('Delete model returned: ', resp.status_code)
print('Custom model deleted: ', model_id)

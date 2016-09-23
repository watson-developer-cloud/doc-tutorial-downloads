# -*- coding: utf-8 -*-
import requests
import json
import sys, time
from requests.packages.urllib3.exceptions import InsecureRequestWarning

requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

##########################################################################
# Step 1: Create a custom model
# Change "name" and "description" to suit your own model
##########################################################################
data = {"name" : "Custom model #1", "base_model_name" : "en-US_BroadbandModel", "description" : "My first STT custom model"}
uri = "https://stream.watsonplatform.net/speech-to-text/api/v1/customizations"

##########################################################################
# Add Bluemix credentials here
# See following instructions for getting your own credentials:
# http://www.ibm.com/smarterplanet/us/en/ibmwatson/developercloud/doc/getting_started/gs-credentials.shtml#getCreds
##########################################################################
username = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
password = "ZZZZZZZZZZZZ"
headers = {'Content-Type' : "application/json"}

##########################################################################
# Create the custom model
##########################################################################
jsonObject = json.dumps(data).encode('utf-8')
resp = requests.post(uri, auth=(username,password), verify=False, headers=headers, data=jsonObject)
print "Model creation returns: ", resp.status_code
if resp.status_code != 201:
   print "Failed to create model"
   print resp.text
   sys.exit(-1)

respJson = resp.json()
customID = respJson['customization_id']
print "Model customization_id: ", customID

##########################################################################
# Step 2: Add a corpus file (plain text file - ideally one sentence per line,
# but not necessary). In this example, we name it 'corpus1' - you can name
# it whatever you want (no spaces) - if adding more than one corpus, add
# them with different names
##########################################################################
uri = "https://stream.watsonplatform.net/speech-to-text/api/v1/customizations/"+customID+"/corpora/corpus1"

# 'corpus.txt' is name of local file containing the corpus to be uploaded
# >>>> REPLACE THE FILE BELOW WITH YOUR OWN CORPUS FILE
with open('corpus.txt', 'rb') as f:
   r = requests.post(uri, auth=(username,password), verify=False, headers=headers, data=f)

print "\nAdding corpus file returns: ", r.status_code
if r.status_code != 201:
   print "Failed to add corpus file"
   print r.text
   sys.exit(-1)

##########################################################################
# Step 3: Get status of corpus file just added
# After corpus is uploaded, there is some analysis done to extract OOVs.
# One cannot upload a new corpus or words while this analysis is on-going so
# we need to loop until the status becomes 'analyzed' for this corpus.
##########################################################################
uri = "https://stream.watsonplatform.net/speech-to-text/api/v1/customizations/"+customID+"/corpora"
r = requests.get(uri, auth=(username,password), verify=False, headers=headers)
respJson = r.json()
status = respJson['corpora'][0]['status']
print "Checking status of corpus analysis..."
time_to_run = 10
while (status != 'analyzed'):
    time.sleep(10)
    r = requests.get(uri, auth=(username,password), verify=False, headers=headers)
    respJson = r.json()
    status = respJson['corpora'][0]['status']
    print "status: ", status, "(", time_to_run, ")"
    time_to_run += 10

print "Corpus analysis done!"

##########################################################################
# Show all OOVs found
# This step is only necessary if user wants to look at the OOVs and
# validate the auto-added sounds-like field. Probably a good thing to do though.
##########################################################################
uri = "https://stream.watsonplatform.net/speech-to-text/api/v1/customizations/"+customID+"/words"
r = requests.get(uri, auth=(username,password), verify=False, headers=headers)
print r.text   # NEED TO FIX THIS - does not work when piping output to a file                 # and words have utf-8 characters

##########################################################################
# Step 4: Add a single user word
# One can pass sounds_like and display_as fields or leave empty (if empty
# the service will try to create its own version of sounds_like)
##########################################################################
data = {"sounds_like" : ["T. C. P. I. P."], "display_as" : "TCP/IP"}
wordToAdd = "tcpip"
u = unicode(wordToAdd, "utf-8")
uri = "https://stream.watsonplatform.net/speech-to-text/api/v1/customizations/"+customID+"/words/"+u
jsonObject = json.dumps(data).encode('utf-8')
r = requests.put(uri, auth=(username,password), verify=False, headers=headers, data=jsonObject)
print "Adding single word returns: ", r.status_code

# Alternatively, one can add multiple words in one request
data = {"words" : [{"word" : "IEEE", "sounds_like" : ["I. triple E."], "display_as" : "IEEE"}, {"word" : "hhonors", "sounds_like" : ["H. honors", "hilton honors"], "display_as" : "HHonors"}]}
uri = "https://stream.watsonplatform.net/speech-to-text/api/v1/customizations/"+customID+"/words"
jsonObject = json.dumps(data).encode('utf-8')
r = requests.post(uri, auth=(username,password), verify=False, headers=headers, data=jsonObject)
print "\nAdding multiple words returns: ", r.status_code

##########################################################################
# Get status of model - only continue to training if 'ready'
##########################################################################
uri = "https://stream.watsonplatform.net/speech-to-text/api/v1/customizations/"+customID
r = requests.get(uri, auth=(username,password), verify=False, headers=headers)
respJson = r.json()
status = respJson['status']
time_to_run = 10
while (status != 'ready'):
    time.sleep(10)
    r = requests.get(uri, auth=(username,password), verify=False, headers=headers)
    respJson = r.json()
    status = respJson['status']
    print "status: ", status, "(", time_to_run, ")"
    time_to_run += 10

# Show all words added so far
uri = "https://stream.watsonplatform.net/speech-to-text/api/v1/customizations/"+customID+"/words"
r = requests.get(uri, auth=(username,password), verify=False, headers=headers)
print r.text   # NEED TO FIX THIS - does not work when piping output to a file and words have utf-8 chars

##########################################################################
# Step 5: Start training the model
# After starting this step, need to check its status and wait until the
# status becomes 'available'.
##########################################################################
uri = "https://stream.watsonplatform.net/speech-to-text/api/v1/customizations/"+customID+"/train"
data = {}
jsonObject = json.dumps(data).encode('utf-8')
r = requests.post(uri, auth=(username,password), verify=False, data=jsonObject)
print "Training request sent, returns: ", r.status_code

if r.status_code != 200:
   print "Training failed to start - exiting!"
   sys.exit(-1)

##########################################################################
# Get status of training and loop until done
##########################################################################
uri = "https://stream.watsonplatform.net/speech-to-text/api/v1/customizations/"+customID
r = requests.get(uri, auth=(username,password), verify=False, headers=headers)
respJson = r.json()
status = respJson['status']
time_to_run = 10
while (status != 'available'):
    time.sleep(10)
    r = requests.get(uri, auth=(username,password), verify=False, headers=headers)
    respJson = r.json()
    status = respJson['status']
    print "status: ", status, "(", time_to_run, ")"
    time_to_run += 10

print "Training complete!"
sys.exit(0)

##########################################################################
# STEP 6 (OPTIONAL): TO LIST AND DELETE THE CUSTOM MODEL:
# Comment the previous call to 'sys.exit(0)'; useful for experimentation
# with multiple test models
##########################################################################
uri = "https://stream.watsonplatform.net/speech-to-text/api/v1/customizations/"
r = requests.get(uri, auth=(username,password), verify=False, headers=headers)
print "\nGet models returns: "
print r.text

uri = "https://stream.watsonplatform.net/speech-to-text/api/v1/customizations/"+customID
r = requests.delete(uri, auth=(username,password), verify=False, headers=headers)
respJson = r.json()
print "\nModel deletion returns: ", resp.status_code

uri = "https://stream.watsonplatform.net/speech-to-text/api/v1/customizations/"
r = requests.get(uri, auth=(username,password), verify=False, headers=headers)
print "\nGet models returns: "
print r.text
sys.exit(0)

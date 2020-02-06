# -*- coding: utf-8 -*-
import requests
import json
import codecs
import sys, time
from requests.packages.urllib3.exceptions import InsecureRequestWarning

requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

headers = {'Content-Type' : "application/json"}

##########################################################################
# Add your IBM Cloud service credentials here.
# o If you use IAM service credentials, leave 'username' set to "apikey"
#   and set 'password' to the value of your IAM API key.
# o If you use pre-IAM service credentials, set the values to your
#   'username' and 'password'.
# Also set 'url' to the URL for your service instance as provided in your
# service credentials.
# See the following instructions for getting your own credentials:
#   https://cloud.ibm.com/docs/watson?topic=watson-iam
##########################################################################

username = "apikey"
password = "YOUR_IAM_APIKEY"
url = "YOUR_URL"

##########################################################################
# Step 1: Create a custom model
# Change "name" and "description" to suit your own model.
##########################################################################

print "\nCreating custom mmodel..."
data = {"name" : "Custom model #1", "base_model_name" : "en-US_BroadbandModel", "description" : "My first STT custom model"}
uri = url+"/v1/customizations"
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
# Step 2: Add a corpus file (plain text file)
# Ideally, add one sentence per line, but this is not necessary. In this
# example, we name it 'corpus1' - you can name it whatever you want (no
# spaces) - if adding more than one corpus, add them with different names.
##########################################################################

# 'corpus.txt' is name of local file containing the corpus to be uploaded
# 'corpus1' is the name of the new corpus
# >>>> REPLACE THE VALUES BELOW WITH YOUR OWN CORPUS FILE AND NAME

corpus_file = "corpus.txt"
corpus_name = "corpus1"

print "\nAdding corpus file..."
uri = url+"/v1/customizations/"+customID+"/corpora/"+corpus_name
with open(corpus_file, 'rb') as f:
   r = requests.post(uri, auth=(username,password), verify=False, headers=headers, data=f)

print "Adding corpus file returns: ", r.status_code
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

print "Checking status of corpus analysis..."
uri = url+"/v1/customizations/"+customID+"/corpora/"+corpus_name
r = requests.get(uri, auth=(username,password), verify=False, headers=headers)
respJson = r.json()
status = respJson['status']
time_to_run = 10
while (status != 'analyzed'):
    time.sleep(10)
    r = requests.get(uri, auth=(username,password), verify=False, headers=headers)
    respJson = r.json()
    status = respJson['status']
    print "status: ", status, "(", time_to_run, ")"
    time_to_run += 10

print "Corpus analysis done!"

##########################################################################
# Show all OOVs found
# This step is only necessary if user wants to look at the OOVs and
# validate the auto-added sounds-like field. Probably a good thing to do
# though.
##########################################################################

print "\nListing words..."
uri = url+"/v1/customizations/"+customID+"/words?sort=count"
r = requests.get(uri, auth=(username,password), verify=False, headers=headers)
print "Listing words returns: ", r.status_code
file=codecs.open(customID+".OOVs.corpus", 'wb', 'utf-8')
file.write(r.text)
print "Words list from added corpus saved in file: "+customID+".OOVs.corpus"

##########################################################################
# Step 4: Add a single user word
# One can pass sounds_like and display_as fields or leave empty (if empty
# the service will try to create its own version of sounds_like).
##########################################################################

print "\nAdding single word..."
data = {"sounds_like" : ["T. C. P. I. P."], "display_as" : "TCP/IP"}
wordToAdd = "tcpip"
u = unicode(wordToAdd, "utf-8")
uri = url+"/v1/customizations/"+customID+"/words/"+u
jsonObject = json.dumps(data).encode('utf-8')
r = requests.put(uri, auth=(username,password), verify=False, headers=headers, data=jsonObject)

print "Adding single word returns: ", r.status_code
print "Single word added!"

# Alternatively, one can add multiple words in one request
print "\nAdding multiple words..."
data = {"words" : [{"word" : "IEEE", "sounds_like" : ["I. triple E."], "display_as" : "IEEE"}, {"word" : "hhonors", "sounds_like" : ["H. honors", "hilton honors"], "display_as" : "HHonors"}]}
uri = url+"/v1/customizations/"+customID+"/words"
jsonObject = json.dumps(data).encode('utf-8')
r = requests.post(uri, auth=(username,password), verify=False, headers=headers, data=jsonObject)

print "Adding multiple words returns: ", r.status_code

##########################################################################
# Get status of model - only continue to training if 'ready'.
##########################################################################

uri = url+"/v1/customizations/"+customID
r = requests.get(uri, auth=(username,password), verify=False, headers=headers)
respJson = r.json()
status = respJson['status']
print "Checking status of model for multiple words..."
time_to_run = 10
while (status != 'ready'):
    time.sleep(10)
    r = requests.get(uri, auth=(username,password), verify=False, headers=headers)
    respJson = r.json()
    status = respJson['status']
    print "status: ", status, "(", time_to_run, ")"
    time_to_run += 10

print "Multiple words added!"

# Show all words added so far
print "\nListing words..."
uri = url+"/v1/customizations/"+customID+"/words?word_type=user&sort=alphabetical"
r = requests.get(uri, auth=(username,password), verify=False, headers=headers)

print "Listing user-added words returns: ", r.status_code
file=codecs.open(customID+".OOVs.user", 'wb', 'utf-8')
file.write(r.text)
print "Words list from user-added words saved in file: "+customID+".OOVs.user"

##########################################################################
# Step 5: Start training the model
# After starting this step, need to check its status and wait until the
# status becomes 'available'.
##########################################################################

print "\nTraining custom model..."
uri = url+"/v1/customizations/"+customID+"/train"
data = {}
jsonObject = json.dumps(data).encode('utf-8')
r = requests.post(uri, auth=(username,password), verify=False, data=jsonObject)

print "Training request returns: ", r.status_code
if r.status_code != 200:
   print "Training failed to start - exiting!"
   sys.exit(-1)

##########################################################################
# Get status of training and loop until done.
##########################################################################

uri = url+"/v1/customizations/"+customID
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

print "\nGetting custom models..."
uri = url+"/v1/customizations"
r = requests.get(uri, auth=(username,password), verify=False, headers=headers)

print "Get models returns: ", r.status_code
print r.text

sys.exit(0)

##########################################################################
# Step 6 (OPTIONAL): TO LIST AND DELETE THE CUSTOM MODEL:
# Comment the previous call to 'sys.exit(0)'; useful for experimentation
# with multiple test models.
##########################################################################

print "\nDeleting custom model..."
uri = url+"/v1/customizations/"+customID
r = requests.delete(uri, auth=(username,password), verify=False, headers=headers)
respJson = r.json()
print "Model deletion returns: ", resp.status_code

print "\nGetting custom models..."
uri = url+"/v1/customizations"
r = requests.get(uri, auth=(username,password), verify=False, headers=headers)
print "Get models returns: ", r.status_code
print r.text

sys.exit(0)

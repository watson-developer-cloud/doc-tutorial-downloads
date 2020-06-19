#!/usr/bin/env python3

import requests
import json
import os
import re
import urllib.parse
import urllib3
from urllib3.exceptions import InsecureRequestWarning
urllib3.disable_warnings(InsecureRequestWarning)

managementPort = os.environ["MANAGEMENT_PORT"]
wexBaseUrl = 'https://localhost:' + managementPort + '/wex/api/v1/'
managementSvc=os.environ.get("MANAGEMENT_SVC")
if managementSvc is not None:
  wexBaseUrl = 'https://' + managementSvc + '/wex/api/v1/'

def err():
  print("Error on running post restore scripts")
  exit(1)

def get(baseUrl, endpoint):
  r = requests.get(baseUrl + endpoint,verify=False)
  if r.status_code != requests.codes.ok :
    print(r.text)
    print("can not get " + endpoint)
    err()
  return r.json()
def post(baseUrl, endpoint):
  r = requests.post(baseUrl + endpoint, json.dumps({}), headers={'Content-Type': 'application/json'}, verify=False)
  if r.status_code != 200 :
    print(r.text)
    print("can not rebuild collection: " + endpoint)
    # err()
  return r.text

collections = get(wexBaseUrl, "collections")
for collection in collections["items"]:
  collectionId = collection["id"]
  post(wexBaseUrl, "collections/" + collectionId + '/wipe?sub_indices=tables,notice&only_sub_indices=false')

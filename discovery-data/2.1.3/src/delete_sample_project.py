#!/usr/bin/env python3

import requests
import json
import os
import urllib.parse
import time
import urllib3
from urllib3.exceptions import InsecureRequestWarning
urllib3.disable_warnings(InsecureRequestWarning)

managementPort = os.environ["MANAGEMENT_PORT"]
wexBaseUrl = 'https://localhost:' + managementPort + '/wex/api/v1/'
wdApiBaseUrl = 'https://localhost:10443/wd-api/api/v2/'
sampleCollectionName = "Sample Collection"
commonParam = "?version=1111-11-11"
waitWdApiTimeoutMinutes = 10

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
def put(baseUrl, endpoint, jsonData):
  r = requests.put(baseUrl + endpoint, json.dumps(jsonData), headers={'Content-Type': 'application/json'}, verify=False)
  if r.status_code != requests.codes.ok :
    print(r.text)
    print("can not put " + endpoint + ":\n" + jsonData)
    err()
  return r.json()
def delete(baseUrl, endpoint):
  r = requests.delete(baseUrl + endpoint, verify=False)
  if(r.status_code != requests.codes.ok and r.status_code != 204):
    print("Warning: Can not delete " + endpoint)
    print(r.text)
    if(baseUrl == wexBaseUrl):
      print("If scripts can not delete the collection or datasets because it is referred by collections, you may use them on other cluster in previous cluster. Then, you can ignore the warning above.")

def waitForWdApiToBeReady():
  start = time.time()
  while True :
    if(start - time.time() > waitWdApiTimeoutMinutes * 60):
      print("WD api has not been ready after " + str(waitForWdApiToBeReady) + " minutes")
      err()
    r = requests.get(wdApiBaseUrl + "projects" + commonParam,verify=False)
    if r.status_code == requests.codes.ok:
      break
    time.sleep(1)


collections = get(wexBaseUrl, "collections")
for collection in collections["items"]:
  if collection["name"] == "Sample Collection":
    delete(wexBaseUrl, "collections/" + collection["id"])
    time.sleep(10)
    for dataset in collection["datasets"]:
      delete(wexBaseUrl, "datasets/" + dataset)

waitForWdApiToBeReady()
projects = get(wdApiBaseUrl, "projects" + commonParam)
for project in projects["projects"]:
  if(project["name"] == "Sample Project"):
    delete(wdApiBaseUrl, "projects/" + project["project_id"] + commonParam)
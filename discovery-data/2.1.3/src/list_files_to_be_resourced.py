#!/usr/bin/env python3

import json
import re
import sys

if len(sys.argv) != 2:
  print("ETCD dump file is not specified")
  exit(1)

file_params = {
  "ac-crawler-seed-jdbccrawler": "jdbc_driver_classpath",
  "fc-crawler-seed-box-connector": "private_key_path",
  "fc-crawler-seed-salesforce-connector": "jar_location"
}

with open(sys.argv[1]) as file:
  while True:
    buf = file.readline()
    if not buf:
      break
    if not re.match(r'^"Key" : "/wex/global/dataset/.+/crconf/.+"$', buf):
      continue
    # Skip to its value
    while True:
      buf = file.readline()
      match = re.match(r'"Value" : "(.+)"$', buf)
      if match:
        break
    match2 = re.match(r'^{\\"crawlerType\\":\\"([af]c-crawler-seed-.+)\\",\\"general_settings', match.group(1))
    if not match2 or not match2.group(1) in file_params.keys():
      continue
    #print(match2.group(1))
    crawler_type = match2.group(1)
    jsonStr = match.group(1).replace('\\"', '"')
    crawler_conf = json.loads(jsonStr)
    param = file_params[crawler_type]
    data_source = crawler_conf["datasource_settings"]
    if not data_source:
      continue
    path = data_source[param]
    match = re.match('^/mnt/(.+)$', path)
    if not match:
      continue
    print(match.group(1))
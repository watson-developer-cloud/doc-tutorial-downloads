#!/usr/bin/env python2
import argparse
import json
import os
import shlex
import subprocess
import time

from json import JSONDecoder


DOCUMENT_FILENAME = 'doc.json'

def parse_object_pairs(pairs):
    return pairs

parser = argparse.ArgumentParser(description='Script for uploading documents to a Discovery collection')
parser.add_argument('-u', required=True, help='username:password')
parser.add_argument('-i', '--input-file', required=True, help='Cranfield data file')
parser.add_argument('-e', '--environment', required=True, help='Discovery environment id')
parser.add_argument('-c', '--collection', required=True, help='collection id')
parser.add_argument('-d', '--debug', action='store_true', help='Enable debug output for script')
parser.add_argument('-v', action='store_true', help='Enable verbose output for curl')

args = parser.parse_args()

VERBOSE_CURL = '-v' if args.v else ''

VERSION = '2017-09-01'
COLLECTION_URL = 'https://gateway.watsonplatform.net/discovery/api/v1/environments/%s/collections/%s/documents' % (args.environment, args.collection)

args = parser.parse_args()

decoder = JSONDecoder(object_pairs_hook=parse_object_pairs)
with open(args.input_file, 'rb') as input_file:
    json_data = decoder.decode(input_file.read())
    for doc in json_data:
        if doc[0] == 'add':
            doc_data = dict(doc[1][0][1])
            json_doc = json.dumps(doc_data)
            with open(DOCUMENT_FILENAME, 'w') as outfile:
                outfile.write(json_doc)

            curl_cmd = 'curl -X POST -u "%s" %s -F file=@%s "%s/%d?version=%s"' % (args.u, VERBOSE_CURL, DOCUMENT_FILENAME, COLLECTION_URL, doc_data['id'], VERSION)
            if args.debug:
                print curl_cmd
            process = subprocess.Popen(shlex.split(curl_cmd), stdout=subprocess.PIPE)
            output = process.communicate()[0]
            if args.debug:
               print output

            time.sleep(0.1)

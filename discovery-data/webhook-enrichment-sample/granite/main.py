import flask
import gzip
import json
import jwt
import logging
import os
import queue
import re
import requests
import threading
import time

WD_API_URL = os.getenv('WD_API_URL')
WD_API_KEY = os.getenv('WD_API_KEY')
WEBHOOK_SECRET = os.getenv('WEBHOOK_SECRET')
IBM_CLOUD_API_KEY = os.getenv('IBM_CLOUD_API_KEY')
WML_ENDPOINT_URL = os.getenv('WML_ENDPOINT_URL', 'https://us-south.ml.cloud.ibm.com')
WML_INSTANCE_CRN = os.getenv('WML_INSTANCE_CRN')

# Enrichment task queue
q = queue.Queue()

app = flask.Flask(__name__)
app.logger.setLevel(logging.INFO)
app.logger.handlers[0].setFormatter(logging.Formatter('[%(asctime)s] %(levelname)s in %(module)s: %(message)s (%(filename)s:%(lineno)d)'))

def get_iam_token():
    data = {'grant_type': 'urn:ibm:params:oauth:grant-type:apikey', 'apikey': IBM_CLOUD_API_KEY}
    response = requests.post('https://iam.cloud.ibm.com/identity/token', data=data)
    if response.status_code == 200:
        return response.json()['access_token']
    else:
        raise Exception('Failed to get IAM token.')

IAM_TOKEN = None

def extract_entities(text):
    global IAM_TOKEN
    if IAM_TOKEN is None:
        IAM_TOKEN = get_iam_token()
    # Prompt
    payload = {
        'model_id': 'ibm/granite-13b-instruct-v1',
        'input': f'''Act as a webmaster who must extract structured information from emails. Read the below email and extract and categorize each entity. If no entity is found, output "None".

Input:
"Golden Bank is a competitor of Silver Bank in the US" said John Doe.

Named Entities:
Golden Bank: company, Silver Bank: company, US: country, John Doe: person

Input:
{text}

Named Entities:
''',
        'parameters': {
            'decoding_method': 'greedy',
            'max_new_tokens': 50,
            'min_new_tokens': 1,
            'stop_sequences': [],
            'repetition_penalty': 1
        },
        'wml_instance_crn': WML_INSTANCE_CRN
    }
    params = {'version': '2023-05-29'}
    headers = {'Authorization': f'Bearer {IAM_TOKEN}'}
    response = requests.post(f'{WML_ENDPOINT_URL}/ml/v1-beta/generation/text', json=payload, params=params, headers=headers)
    if response.status_code == 200:
        result = response.json()['results'][0]['generated_text']
        app.logger.info('LLM result: %s', result)
        entities = []
        if result == 'None':
            # No entity found
            return entities
        for pair in re.split(r',\s*', result):
            text_type = re.split(r':\s*', pair)
            entities.append({'text': text_type[0], 'type': text_type[1]})
        return entities
    elif response.status_code == 401:
        # Token expired. Re-generate it.
        IAM_TOKEN = get_iam_token()
        return extract_entities(text)
    else:
        raise Exception(f'Failed to generate: {response.text}')

def enrich(doc):
    app.logger.info('doc: %s', doc)
    features_to_send = []
    for feature in doc['features']:
        # Target 'text' field
        if feature['properties']['field_name'] != 'text':
            continue
        location = feature['location']
        begin = location['begin']
        end = location['end']
        text = doc['artifact'][begin:end]
        try:
            # Entity extraction example
            results = extract_entities(text)
            app.logger.info('entities: %s', results)
            for entity in results:
                entity_text = entity['text']
                entity_type = entity['type']
                for matched in re.finditer(re.escape(entity_text), text):
                    features_to_send.append(
                        {
                            'type': 'annotation',
                            'location': {
                                'begin': matched.start() + begin,
                                'end': matched.end() + begin,
                            },
                            'properties': {
                                'type': 'entities',
                                'confidence': 1.0,
                                'entity_type': entity_type,
                                'entity_text': matched.group(0),
                            },
                        }
                    )
        except Exception as e:
            # Notice example
            features_to_send.append(
                {
                    'type': 'notice',
                    'properties': {
                        'description': str(e),
                        'created': round(time.time() * 1000),
                    },
                }
            )
    app.logger.info('features_to_send: %s', features_to_send)
    return {'document_id': doc['document_id'], 'features': features_to_send}

def enrichment_worker():
    while True:
        item = q.get()
        version = item['version']
        data = item['data']
        project_id = data['project_id']
        collection_id = data['collection_id']
        batch_id = data['batch_id']
        batch_api = f'{WD_API_URL}/v2/projects/{project_id}/collections/{collection_id}/batches/{batch_id}'
        params = {'version': version}
        auth = ('apikey', WD_API_KEY)
        headers = {'Accept-Encoding': 'gzip'}
        try:
            # Get documents from WD
            response = requests.get(batch_api, params=params, auth=auth, headers=headers, stream=True)
            status_code = response.status_code
            app.logger.info('Pulled a batch: %s, status: %d', batch_id, status_code)
            if status_code == 200:
                # Annotate documents
                enriched_docs = [enrich(json.loads(line)) for line in response.iter_lines()]
                files = {
                    'file': (
                        'data.ndjson.gz',
                        gzip.compress(
                            '\n'.join(
                                [json.dumps(enriched_doc) for enriched_doc in enriched_docs]
                            ).encode('utf-8')
                        ),
                        'application/x-ndjson'
                    )
                }
                # Upload annotated documents
                response = requests.post(batch_api, params=params, files=files, auth=auth)
                status_code = response.status_code
                app.logger.info('Pushed a batch: %s, status: %d', batch_id, status_code)
        except Exception as e:
            app.logger.error('An error occurred: %s', e, exc_info=True)
            # Retry
            q.put(item)

# Turn on the enrichment worker thread
threading.Thread(target=enrichment_worker, daemon=True).start()

# Webhook endpoint
@app.route('/webhook', methods=['POST'])
def webhook():
    # Verify JWT token
    header = flask.request.headers.get('Authorization')
    _, token = header.split()
    try:
        jwt.decode(token, WEBHOOK_SECRET, algorithms=['HS256'])
    except jwt.PyJWTError as e:
        app.logger.error('Invalid token: %s', e)
        return {'status': 'unauthorized'}, 401
    # Process webhook event
    data = flask.json.loads(flask.request.data)
    app.logger.info('Received event: %s', data)
    event = data['event']
    if event == 'ping':
        # Receive this event when a webhook enrichment is created
        code = 200
        status = 'ok'
    elif event == 'enrichment.batch.created':
        # Receive this event when a batch of the documents gets ready
        code = 202
        status = 'accepted'
        # Put an enrichment request into the queue
        q.put(data)
    else:
        # Unknown event type
        code = 400
        status = 'bad request'
    return {'status': status}, code

PORT = os.getenv('PORT', '8080')
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(PORT))

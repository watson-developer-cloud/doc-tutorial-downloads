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

# Enrichment task queue
q = queue.Queue()

# Extractors by regular expressions
year_entity_extractor = re.compile('\d{4}')
sentence_break_detector = re.compile('\.\s*|!\s*|\?\s*')
transmission_extractor = re.compile('TRANSMISSION')
slip_classifier = re.compile('SLIP')

app = flask.Flask(__name__)
app.logger.setLevel(logging.INFO)
app.logger.handlers[0].setFormatter(logging.Formatter('[%(asctime)s] %(levelname)s in %(module)s: %(message)s (%(filename)s:%(lineno)d)'))

def enrich(doc):
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
            for matched in year_entity_extractor.finditer(text):
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
                            'entity_type': 'Year',
                            'entity_text': matched.group(0),
                        },
                    }
                )
            # Sentence classification example
            sentence_start = 0
            for matched in sentence_break_detector.finditer(text):
                sentence_end = matched.start() + 1
                sentence_text = text[sentence_start:sentence_end]
                if transmission_extractor.search(sentence_text):
                    class_name = 'Transmission'
                else:
                    class_name = 'No Transmission'
                features_to_send.append(
                    {
                        'type': 'annotation',
                        'location': {
                            'begin': sentence_start + begin,
                            'end': sentence_end + begin,
                        },
                        'properties': {
                            'type': 'element_classes',
                            'class_name': class_name,
                            'confidence': 1.0,
                        },
                    },
                )
                sentence_start = matched.end()
            # Document classification example
            if slip_classifier.search(text):
                class_name = 'Slip'
            else:
                class_name = 'No Slip'
            features_to_send.append(
                {
                    'type': 'annotation',
                    'properties': {
                        'type': 'document_classes',
                        'class_name': class_name,
                        'confidence': 1.0,
                    },
                },
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

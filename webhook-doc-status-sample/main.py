from dataclasses import dataclass
import json
from asyncio import Future
import asyncio
from typing import Any, BinaryIO, Dict
import logging

from fastapi import FastAPI, Request, UploadFile
from fastapi.responses import JSONResponse

from ibm_watson import DiscoveryV2
from ibm_watson.discovery_v2 import QueryLargePassages

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)

app = FastAPI()

# in-memory store for mapping (project_id, collection_id, document_id) to Future object
docproc_requests: dict[(str, str, str), Future] = {}

discovery = DiscoveryV2(version='2023-03-31')


@app.post("/webhook")
async def webhook(
    request: Request,
):
    status_code = 200
    try:
        body = await request.json()
    except json.decoder.JSONDecodeError:
        content = await request.body()
        body = f"Invalid JSON or no body. Body was: {str(content)}"
        status_code = 400
    if status_code == 200:
        event = body["event"]
        response_body: dict[str, Any] = {}
        if event == "ping":
            response_body["accepted"] = True
        elif event == "document.status":
            data = body["data"]
            project_id = data['project_id']
            collection_id = data['collection_id']
            status = data["status"]
            if status in set(["available", "failed"]):
                for document_id in data["document_ids"]:
                    # resume the suspended document processing request
                    notify_document_completion_status(project_id, collection_id, document_id, status)
            response_body["accepted"] = True
        else:
            status_code = 400
    return JSONResponse(content=response_body, status_code=status_code)


@app.post("/projects/{project_id}/collections/{collection_id}/extract")
async def post_and_extraction(
    project_id: str,
    collection_id: str,
    file: UploadFile
):
    # Ingest the received document into the underlying Discovery project/collection
    logger.info(f'using project/collection {project_id}/{collection_id}')
    document_id = add_document(project_id, collection_id, file.file, file.filename)

    # Wait until the ingested document become available
    logger.info(f'waiting for {document_id} become available')
    available = await wait_document_completion(project_id, collection_id, document_id)

    # Retrieve the processed document
    logger.info(f'{document_id} is available:{available}')
    document = get_document(project_id, collection_id, document_id)
    return JSONResponse(content=document)


def add_document(
    project_id: str, 
    collection_id: str, 
    file: BinaryIO, 
    filename: Any
):
    response = discovery.add_document(project_id, collection_id, file=file, filename=filename)
    document_id = response.get_result()['document_id']
    return document_id


def get_document(
    project_id: str, 
    collection_id: str, 
    document_id: str,
):
    response = discovery.query(project_id=project_id, collection_ids=[collection_id], filter=f'document_id::{document_id}', passages=QueryLargePassages(enabled=False))
    document = response.get_result()['results'][0]
    return document


async def wait_document_completion(
    project_id: str,
    collection_id: str,
    document_id: str,
):
    global docproc_requests
    docproc_request = Future()
    key = (project_id, collection_id, document_id)
    docproc_requests[key] = docproc_request

    # Start a background task to pull the processing status periodically when the collection is not configured with document status webhook
    if not is_webhook_status_enabled(project_id, collection_id):
        asyncio.create_task(wait_document_available(project_id, collection_id, document_id))

    # Wait until the document become available or failed
    status = await docproc_request
    return status == "available"


def is_webhook_status_enabled(
    project_id: str,
    collection_id: str
):
    webhook = discovery.get_collection(project_id, collection_id).get_result().get('webhooks')
    return (webhook is not None) and ('document_status' in webhook)


async def wait_document_available(
    project_id: str,
    collection_id: str,
    document_id: str
):
    # Pull the document processing status periodically (1 sec interval) and wait until the completion
    while(discovery.list_documents(
        project_id,
        collection_id,
        parent_document_id=document_id,
        count=0,
        status='pending,processing'
    ).get_result()['matching_results'] != 0
    ):
        await asyncio.sleep(1)
    
    # Retrieve the document processing status
    status = discovery.get_document(
        project_id,
        collection_id,
        document_id
    ).get_result()['status']

    # Then, notify it
    notify_document_completion_status(
        project_id,
        collection_id,
        document_id,
        status
    )


def notify_document_completion_status(
    project_id: str,
    collection_id: str,
    document_id: str,
    status: str
):
    global docproc_requests
    key = (project_id, collection_id, document_id)
    docproc_request = docproc_requests.get(key)
    if docproc_request:
        docproc_request.set_result(status)
        docproc_requests.pop(key)





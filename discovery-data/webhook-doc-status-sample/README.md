# Document Processing application using Document Status webhook

Document Processing application that utilizes Watson Discovery collection and webhook support of Document Status API.
This is just a sample application, not production code.

## Requirements
- Instance of Watson Discovery Plus/Enterprise plan on IBM Cloud.

## Setup Instructions

### Deploy the document processing application to Code Engine
In this tutorial, we will use [IBM Cloud Code Engine](https://www.ibm.com/cloud/code-engine) as the infrastructure for the application of document processing which receives the document processing status events. Of course, you can deploy the application in any environment you like.

1. [Create a project](https://cloud.ibm.com/docs/codeengine?topic=codeengine-manage-project#create-a-project) of Code Engine.
2. [Deploy the application](https://cloud.ibm.com/docs/codeengine?topic=codeengine-app-source-code) from this repository source code.
   - In **Create application**, click **Specify build details** and enter the following:
      - Source
         - Code repo URL: `https://github.com/watson-developer-cloud/doc-tutorial-downloads`
         - Code repo access: `None`
         - Branch name: `master`
         - Context directory: `discovery-data/webhook-doc-status-sample`
      - Strategy
         - Strategy: `Dockerfile`
      - Output
         - Enter your container image registry information.
   - Set **Min number of instances** and **Max number of instances** to `1`.
3. [Add service binding](https://cloud.ibm.com/docs/codeengine?topic=codeengine-bind-services) to the application.
   - In **IBM Cloud service instance**, specify the service instance of Watson Discovery Plus/Enterprise plan on IBM Cloud
4. Confirm that the application status changes to **Ready**.

### Configure Discovery collection
1. Create a project.
2. Create a collection in the project and apply the document status webhook to the collection. `{webhook-doc-status-sample-url}` is URL to the deployed application.
```sh
curl  -X POST {auth} \
  '{url}/v2/projects/{project_id}/collections?version=2023-03-31' \
  --header 'Content-Type: application/json' \
  --data-raw '{
  "name":"DocProc App",
  "webhooks": {
    "document_status": [
      {
        "url": "{webhook-doc-status-sample-url}/webhook"
      }
      ]
  }
}'
```

### Process documents
Process a document and return it for realtime use.
The file is stored in the collection and is processed according to the collection's configuration settings. To remove the processed documents in the collection, you need to remove them manually via Tooling or API.

Example:

```sh
curl -X POST \
  '{webhook-doc-status-sample-url}/projects/{project_id}/collections/{collection_id}/extract' \
  -H 'accept: application/json' \
  -H 'Content-Type: multipart/form-data' \
  -F 'file=@sample.pdf;type=application/pdf'
```

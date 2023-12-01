# Entity Extraction using a foundation model of [watsonx.ai](https://www.ibm.com/products/watsonx-ai)

In this tutorial, we will extract entities from email using watsonx.ai Granite model.

## Requirements
- Instance of Watson Discovery Plus/Enterprise plan on IBM Cloud.
- Instance of [Watson Machine Learning](https://cloud.ibm.com/catalog/services/watson-machine-learning).
- An API key of IBM Cloud. You can see how to manage API keys [here](https://cloud.ibm.com/docs/account?topic=account-manapikey).

## Setup Instructions

### Deploy the webhook enrichment app to Code Engine
In this tutorial, we will use [IBM Cloud Code Engine](https://www.ibm.com/cloud/code-engine) as the infrastructure for the application of webhook enrichment. Of course, you can deploy the application in any environment you like.

1. [Create a project](https://cloud.ibm.com/docs/codeengine?topic=codeengine-manage-project#create-a-project) of Code Engine.
2. [Create a secret](https://cloud.ibm.com/docs/codeengine?topic=codeengine-secret#secret-create) in the project. This secret contains the following key-value pairs:
   - `WD_API_URL`: The API endpoint URL of your Discovery instance
   - `WD_API_KEY`: The API key of your Discovery instance
   - `WEBHOOK_SECRET`: A key to pass with the request that can be used to authenticate with the application. e.g. `purple unicorn`
   - `IBM_CLOUD_API_KEY`: The API key of IBM Cloud. It is used to access Watson Machine Leanring API.
   - `WML_ENDPOINT_URL`: The API endpoint URL of your Watson Machine Learning. See [the documentation](https://cloud.ibm.com/apidocs/machine-learning).
   - `WML_INSTANCE_CRN`: The CRN of your Watson Mechine Learning instance. You can find your instance and CRN using `ibmcloud` command: `ibmcloud resources`
3. [Deploy the application](https://cloud.ibm.com/docs/codeengine?topic=codeengine-app-source-code) from this repository source code.
   - In **Create application**, click **Specify build details** and enter the following:
      - Source
         - Code repo URL: `https://github.com/watson-developer-cloud/doc-tutorial-downloads`
         - Code repo access: `None`
         - Branch name: `master`
         - Context directory: `discovery-data/webhook-enrichment-sample/granite`
      - Strategy
         - Strategy: `Dockerfile`
      - Output
         - Enter your container image registry information.
   - Open **Environment variables (optional)**, and add environment variables.
      - Define as: `Reference to full secret`
      - Secret: The name of the secret you created in Step 2.
   - We recommend setting **Min number of instances** to `1`.
4. Confirm that the application status changes to **Ready**.

### Configure Discovery webhook enrichment
1. Create a project.
2. Create a webhook enrichment using Discovery API.
   ```bash
   curl -X POST {auth} \
   --header 'Content-Type: multipart/form-data' \
   --form 'enrichment={"name":"my-first-webhook-enrichment", \
     "type":"webhook", \
     "options":{"url":"{your_code_engine_app_domain}/webhook", \
       "secret":"{your_webhook_secret}", \
       "location_encoding":"utf-32"}}' \
   '{url}/v2/projects/{project_id}/enrichments?version=2023-03-31'
   ```
3. Create a collection in the project and apply the webhook enrichment to the collection.
   ```bash
   curl -X POST {auth} \
   --header 'Content-Type: application/json' \
   --data '{"name":"my-collection", \
     "enrichments":[{"enrichment_id":"{enrichment_id}", \
       "fields":["text"]}]}' \
   '{url}/v2/projects/{project_id}/collections?version=2023-03-31'
   ```

### Ingest documents to Discovery
1. Upload [email.txt](data/email.txt) to the collection.
2. You can find the enrichment results by webhook by previewing your query results after the document processing is complete.

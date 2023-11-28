package slate.controllers;

import slate.models.WebhookEvent;
import slate.models.WebhookEventData;
import slate.models.WebhookEvent.WebhookEventType;
import slate.services.EnrichmentService;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.ResponseBody;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

@RestController
public class WebhookController {

    private static final Logger logger = LoggerFactory.getLogger(WebhookController.class);
    private final EnrichmentService enrichmentService;

    @Autowired
    WebhookController(EnrichmentService enrichmentService) {
        this.enrichmentService = enrichmentService;
    }

    @PostMapping("/webhook")
    @ResponseBody
    public ResponseEntity<Object> webhook(@RequestBody WebhookEvent event) {
        try {
            switch (event.getEvent()) {
                case PING -> {
                    logger.info("accepted " + WebhookEventType.PING.getEventName() + " event from project " + 
                            ((WebhookEventData.ForPing)event.getData()).getMetadata().getProjectId());
                    break;
                }
                case ENRICHMENT_BATCH_CREATED -> {
                    // enriching batches will be done asynchronously
                    enrichmentService.enrich(event);
                    logger.info("accepted " + WebhookEventType.ENRICHMENT_BATCH_CREATED.getEventName() + " event from collection " + 
                            ((WebhookEventData.ForEnrichmentBatchCreated)event.getData()).getCollectionId());
                    break;
                }
            }
            return ResponseEntity.ok().build();
        } catch (Exception e) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "Bad request", e);
        }
    }
}
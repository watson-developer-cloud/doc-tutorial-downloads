package slate.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

@JsonIgnoreProperties(ignoreUnknown = true)
public class WebhookEventData {

    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class ForPing extends WebhookEventData {
        @JsonProperty("url")
        private String url;
        @JsonProperty("events")
        private List<String> events;
        @JsonProperty("metadata")
        private PingEventMetadata metadata;
        public String getUrl() { return url; }
        public List<String> getEvents() { return events; }
        public PingEventMetadata getMetadata() { return metadata; }
        public static class PingEventMetadata {
            @JsonProperty("project_id")
            private UUID projectId;
            @JsonProperty("enrichment_id")
            private UUID enrichmentId;
            @JsonProperty("created_at")
            private OffsetDateTime createdAt;
            @JsonProperty("updated_at")
            private OffsetDateTime updatedAt;

            public UUID getProjectId() { return projectId; }
        }
    }

    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class ForEnrichmentBatchCreated extends WebhookEventData {
        @JsonProperty("project_id")
        private UUID projectId;
        @JsonProperty("collection_id")
        private UUID collectionId;
        @JsonProperty("enrichment_id")
        private UUID enrichmentId;
        @JsonProperty("batch_id")
        private UUID batchId;
        public UUID getProjectId() { return projectId; }
        public UUID getCollectionId() { return collectionId; }
        public UUID getEnrichmentId() { return enrichmentId; }
        public UUID getBatchId() { return batchId; }
    }
}

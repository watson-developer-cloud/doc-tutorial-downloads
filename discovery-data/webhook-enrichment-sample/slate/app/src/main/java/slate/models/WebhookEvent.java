package slate.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonSubTypes;
import com.fasterxml.jackson.annotation.JsonTypeInfo;
import com.fasterxml.jackson.annotation.JsonValue;

import java.time.OffsetDateTime;

@JsonIgnoreProperties(ignoreUnknown = true)
public class WebhookEvent {

    private static final String PING_EVENT_NAME = "ping";
    private static final String ENRICHMENT_BATCH_CREATED_EVENT_NAME = "enrichment.batch.created";
    public enum WebhookEventType {
        PING(PING_EVENT_NAME),
        ENRICHMENT_BATCH_CREATED(ENRICHMENT_BATCH_CREATED_EVENT_NAME)
        ;

        @JsonValue
        private String eventName;
        WebhookEventType(String eventName) {
            this.eventName = eventName;
        }
        public String getEventName() { return eventName; }
    }

    @JsonProperty("event")
    private WebhookEventType event;

    @JsonProperty("version")
    private String version;

    @JsonProperty("instance_id")
    private String instanceId;

    @JsonProperty("created_at")
    private OffsetDateTime createdAt;

    @JsonTypeInfo(use = JsonTypeInfo.Id.NAME, include = JsonTypeInfo.As.EXTERNAL_PROPERTY, property = "event")
    @JsonSubTypes(value = {
            @JsonSubTypes.Type(
                    value = WebhookEventData.ForPing.class,
                    name = PING_EVENT_NAME),
            @JsonSubTypes.Type(
                    value = WebhookEventData.ForEnrichmentBatchCreated.class,
                    name = ENRICHMENT_BATCH_CREATED_EVENT_NAME)
    })
    @JsonProperty("data")
    private WebhookEventData data;

    public WebhookEventType getEvent() { return event; }
    public String getVersion() { return version; }
    public String getInstanceId() { return instanceId; }
    public OffsetDateTime getCreatedAt() { return createdAt; }
    public WebhookEventData getData() { return data; }
}

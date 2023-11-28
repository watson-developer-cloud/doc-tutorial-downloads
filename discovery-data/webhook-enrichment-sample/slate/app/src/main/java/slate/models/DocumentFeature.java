package slate.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonSubTypes;
import com.fasterxml.jackson.annotation.JsonTypeInfo;
import com.fasterxml.jackson.annotation.JsonValue;

@JsonIgnoreProperties(ignoreUnknown = true)
public class DocumentFeature {

    /**
     * Ref: https://cloud.ibm.com/docs/discovery-data?topic=discovery-data-external-enrichment#feature-types
     */
	@JsonProperty("type")
	private final FeaturePropertyType type;

	@JsonProperty("location")
	private final Location location;

	@JsonTypeInfo(use = JsonTypeInfo.Id.NAME, include = JsonTypeInfo.As.EXTERNAL_PROPERTY, property = "type")
	@JsonSubTypes(value = {
			@JsonSubTypes.Type(value = FieldFeatureProperties.class, name = FeaturePropertyType.Constants.FIELD),
			@JsonSubTypes.Type(value = AnnotationFeatureProperties.class, name = FeaturePropertyType.Constants.ANNOTATION),
			@JsonSubTypes.Type(value = NoticeFeatureProperties.class, name = FeaturePropertyType.Constants.NOTICE)
	})
	@JsonProperty("properties")
	private final FeatureProperties properties;

	public FeaturePropertyType getType() {
		return type;
	}

	public Location getLocation() {
		return location;
	}

	public FeatureProperties getProperties() {
		return properties;
	}

	public DocumentFeature(
        @JsonProperty("type") FeaturePropertyType type,
        @JsonProperty("location") Location location,
        @JsonProperty("properties") FeatureProperties properties
	) {
		this.type = type;
		this.location = location;
		this.properties = properties;
	}

	public enum FeaturePropertyType {
		FIELD(Constants.FIELD),
		ANNOTATION(Constants.ANNOTATION),
		NOTICE(Constants.NOTICE);

		@JsonValue
		private final String value;

		private FeaturePropertyType(String value) {
			this.value = value;
		}

		private static class Constants {
			private static final String FIELD = "field";
			private static final String ANNOTATION = "annotation";
			private static final String NOTICE = "notice";
		}
	}


    public interface FeatureProperties {}

    public static enum FieldType {
        STRING("string"),
        LONG("long"),
        DOUBLE("double"),
        DATE("date"),
        JSON("json");

        @JsonValue
        private final String value;

        private FieldType(String value) {
            this.value = value;
        }
    }
    
    /**
     * Ref: https://cloud.ibm.com/docs/discovery-data?topic=discovery-data-external-enrichment#field-type
     */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class FieldFeatureProperties implements FeatureProperties {

        @JsonProperty("field_name")
        private final String fieldName;

        @JsonProperty("field_index")
        private final int fieldIndex;

        @JsonProperty("field_type")
        private final FieldType fieldType;

        public String getFieldName() {
            return fieldName;
        }

        public int getFieldIndex() {
            return fieldIndex;
        }

        public FieldType getFieldType() {
            return fieldType;
        }

        public FieldFeatureProperties(
            @JsonProperty("field_name") String fieldName,
            @JsonProperty("field_index") int fieldIndex,
            @JsonProperty("field_type") FieldType fieldType
        ) {
            this.fieldName = fieldName;
            this.fieldIndex = fieldIndex;
            this.fieldType = fieldType;
        }

    }

    public enum AnnotationType {
        ENTITIES("entities"),
        ELEMENT_CLASSES("element_classes"),
        DOCUMENT_CLASSES("document_classes");

        @JsonValue
        private final String value;

        private AnnotationType(String value) {
            this.value = value;
        }
    }

    /**
     * Ref: https://cloud.ibm.com/docs/discovery-data?topic=discovery-data-external-enrichment#annotation-type
     */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class AnnotationFeatureProperties implements FeatureProperties {

        @JsonProperty("type")
        private final AnnotationType type;

        @JsonProperty("confidence")
        private final double confidence;

        @JsonProperty("entity_type")
        private final String entityType;

        @JsonProperty("entity_text")
        private final String entityText;

        public AnnotationType getType() {
            return type;
        }

        public double getConfidence() {
            return confidence;
        }
        
        public String getEntityType() {
            return entityType;
        }

        public String getEntityText() {
            return entityText;
        }

        public AnnotationFeatureProperties(
            @JsonProperty("type") AnnotationType type,
            @JsonProperty("confidence") double confidence,
            @JsonProperty("entity_type") String entityType,
            @JsonProperty("entity_text") String entityText
        ) {
            this.type = type;
            this.confidence = confidence;
            this.entityType = entityType;
            this.entityText = entityText;
        }

    }

    /**
     * Ref: https://cloud.ibm.com/docs/discovery-data?topic=discovery-data-external-enrichment#notice-type
     */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class NoticeFeatureProperties implements FeatureProperties {

        @JsonProperty("description")
        private final String description;

        @JsonProperty("created")
        private final long created;


        public String getDescription() {
            return description;
        }

        public long getCreated() {
            return created;
        }

        public NoticeFeatureProperties(
            @JsonProperty("description") String description,
            @JsonProperty("created") long created
        ) {
            this.description = description;
            this.created = created;
        }
    }
}
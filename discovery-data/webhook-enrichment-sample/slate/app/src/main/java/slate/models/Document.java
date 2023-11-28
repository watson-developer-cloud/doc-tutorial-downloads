package slate.models;

import java.util.Collections;
import java.util.List;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * Ref:
 *   - https://cloud.ibm.com/docs/discovery-data?topic=discovery-data-external-enrichment#binary-attachment-pull-batches
 *   - https://cloud.ibm.com/docs/discovery-data?topic=discovery-data-external-enrichment#binary-attachment-push-batches
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public class Document {
    
	@JsonProperty("document_id")
	private final String documentId;

	@JsonProperty("artifact")
	private final String artifact;

	@JsonProperty("features")
	private final List<DocumentFeature> features;

	public String getDocumentId() {
		return documentId;
	}

	public String getArtifact() {
		return artifact;
	}

	public List<DocumentFeature> getFeatures() {
		return features;
	}

	public Document(
		@JsonProperty("document_id") String documentId,
		@JsonProperty("artifact") String artifact,
		@JsonProperty("features") List<DocumentFeature> features
	) {
		this.documentId = documentId;
		this.artifact = artifact;
		this.features = Collections.unmodifiableList(features);
	}

	public Document(
		String documentId,
		List<DocumentFeature> features
	) {
		this(documentId, null, features);
	}

}

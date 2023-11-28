package slate.models;

import java.util.List;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * Ref: https://www.ibm.com/docs/en/cloud-paks/cp-data/4.7.x?topic=functions-writing-deployable-python#example-python-code
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public class ScoringOutput {

    @JsonProperty("predictions")
    private List<Prediction> predictions;

    public List<Prediction> getPredictions() { return predictions; }

    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class Prediction {
        @JsonProperty("fields")
        private List<String> fields;

        @JsonProperty("values")
        private List<List<PredictionPerInputFieldValue>> values;

        public List<String> getFields() { return fields; }

        public List<List<PredictionPerInputFieldValue>> getValues() { return values; }
    }

    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class PredictionPerInputFieldValue {
        @JsonProperty("mentions")
        private List<Mention> mentions;

        public List<Mention> getMentions() { return mentions; }
    }

    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class Mention {
        @JsonProperty("span")
        private Span span;

        @JsonProperty("type")
        private String type;

        @JsonProperty("confidence")
        private double confidence;

        public Span getSpan() { return span; }

        public String getType() { return type; }

        public double getConfidence() { return confidence; }
    }

    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class Span {
        @JsonProperty("begin")
        private int begin;
        
        @JsonProperty("end")
        private int end;

        @JsonProperty("text")
        private String text;

        public int getBegin() { return begin; }

        public int getEnd() { return end; }

        public String getText() { return text; }
    }
}

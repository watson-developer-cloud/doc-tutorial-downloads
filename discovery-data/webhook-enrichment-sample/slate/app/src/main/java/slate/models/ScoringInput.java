package slate.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;

/**
 * Ref: https://www.ibm.com/docs/en/cloud-paks/cp-data/4.7.x?topic=functions-writing-deployable-python#exschema
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public class ScoringInput {

    @JsonProperty("input_data")
    private List<InputField> inputData;

    public ScoringInput(List<InputField> inputData) {
        this.inputData = inputData;
    }

    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class InputField {

        @JsonProperty("fields")
        private List<String> fields;

        @JsonProperty("values")
        private List<List<String>> values;
    
        public InputField(List<String> fields, List<List<String>> values) {
            this.fields = fields;
            this.values = values;
        }
    }
}

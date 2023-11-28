package slate.models;

import com.fasterxml.jackson.annotation.JsonProperty;

public class Location {
    
	@JsonProperty("begin")
	private final int begin;

	@JsonProperty("end")
	private final int end;

    public int getBegin() { return begin; }

    public int getEnd() { return end; }

    public Location(
        @JsonProperty("begin") int begin,
        @JsonProperty("end") int end
    ) {
        this.begin = begin;
        this.end = end;
    }
}

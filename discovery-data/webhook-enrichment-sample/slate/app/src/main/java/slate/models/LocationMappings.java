package slate.models;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;


/**
 * Class to recalculate utf-32 based offsets to utf-16 based offsets
 */
public class LocationMappings {
    private final int[] inUtf16s;
    private final int[] inUtf32s;

    public static LocationMappings generateLocationMappings(String text) {
        final int textLength = text.length();
        int inUtf16 = 0;
        int inUtf32 = 0;
        List<LocationMapping> mappings = new ArrayList<>();
        while (inUtf16 < textLength) {
            int codePoint = text.codePointAt(inUtf16);
            int lengthInUtf16 = Character.charCount(codePoint);
            inUtf16 = inUtf16 + lengthInUtf16;
            inUtf32 = inUtf32 + 1;
            if (lengthInUtf16 != 1) {
                mappings.add(new LocationMapping(inUtf16, inUtf32));
            }
        }
        return new LocationMappings(mappings);
    }

    private LocationMappings(List<LocationMapping> mappings) {
        final int mappingsSize = mappings.size();
        inUtf16s = new int[mappings.size()];
        inUtf32s = new int[mappings.size()];
        for (int i = 0; i < mappingsSize; i++) {
            LocationMapping mapping = mappings.get(i);
            inUtf16s[i] = mapping.inUtf16;
            inUtf32s[i] = mapping.inUtf32;
        }
    }

    public Location toUtf16(int beginInUtf32, int endInUtf32, int baseInUtf16) {
        return new Location(toUtf16(beginInUtf32) + baseInUtf16, toUtf16(endInUtf32) + baseInUtf16);
    }

    private int toUtf16(int inUtf32) {
        int foundIndex = Arrays.binarySearch(inUtf32s, inUtf32);
        if (foundIndex >= 0) {
            return inUtf16s[foundIndex] - inUtf32s[foundIndex] + inUtf32;
        } else {
            int indexToCheck = (- foundIndex - 1) - 1;
            if (indexToCheck < 0) {
                return inUtf32;
            } else {
                return inUtf16s[indexToCheck] - inUtf32s[indexToCheck] + inUtf32;
            }
        }
    }

    public static class LocationMapping {
        private int inUtf16;
        private int inUtf32;

        private LocationMapping(int inUtf16, int inUtf32) {
            this.inUtf16 = inUtf16;
            this.inUtf32 = inUtf32;
        }
    }
}
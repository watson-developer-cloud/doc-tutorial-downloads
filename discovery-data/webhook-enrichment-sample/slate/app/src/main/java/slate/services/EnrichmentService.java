package slate.services;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.ObjectMapper;

import slate.models.Document;
import slate.models.DocumentFeature;
import slate.models.Location;
import slate.models.LocationMappings;
import slate.models.ScoringInput;
import slate.models.ScoringOutput;
import slate.models.WebhookEvent;
import slate.models.WebhookEventData;
import slate.models.DocumentFeature.AnnotationFeatureProperties;
import slate.models.DocumentFeature.AnnotationType;
import slate.models.DocumentFeature.FeaturePropertyType;
import slate.models.DocumentFeature.FieldFeatureProperties;
import slate.models.DocumentFeature.NoticeFeatureProperties;
import slate.models.ScoringOutput.Mention;
import io.netty.channel.ChannelOption;
import io.netty.handler.ssl.SslContext;
import io.netty.handler.ssl.SslContextBuilder;
import io.netty.handler.ssl.util.InsecureTrustManagerFactory;
import io.netty.handler.timeout.ReadTimeoutHandler;
import io.netty.handler.timeout.WriteTimeoutHandler;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.core.io.buffer.DataBuffer;
import org.springframework.core.io.buffer.DataBufferUtils;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.client.MultipartBodyBuilder;
import org.springframework.http.client.reactive.ReactorClientHttpConnector;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.BodyExtractors;
import org.springframework.web.reactive.function.BodyInserters;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.core.publisher.Flux;
import reactor.netty.http.client.HttpClient;

import java.io.*;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collections;
import java.util.List;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;

@Service
public class EnrichmentService {

    private static final Logger logger = LoggerFactory.getLogger(EnrichmentService.class);
    private static final ObjectMapper mapper = new ObjectMapper();
    private static final WebClient webClient;

    private static final String WD_API_URL = System.getenv("WD_API_URL");
    private static final String WD_API_AUTH_HEADER = 
        "Basic " + Base64.getEncoder().encodeToString(("apikey:" + System.getenv("WD_API_KEY")).getBytes(StandardCharsets.UTF_8));
    private static final String SCORING_URL = 
        "https://" + System.getenv("SCORING_API_HOSTNAME") + "/ml/v4/deployments/" + System.getenv("SCORING_DEPLOYMENT_ID") + "/predictions?version=2021-05-01";
    private static final String SCORING_API_AUTH_HEADER = "Bearer " + System.getenv("SCORING_API_TOKEN");
    private static final String TEXT_FIELD_NAME = "text";
    private static final byte[] dummyBytes;

    static {
        try {
            SslContext sslContext = SslContextBuilder.forClient().trustManager(InsecureTrustManagerFactory.INSTANCE).build();
            HttpClient httpClient = HttpClient.create()
                .wiretap(true)
                .secure(t -> t.sslContext(sslContext))
                .option(ChannelOption.CONNECT_TIMEOUT_MILLIS, 600000)
                .responseTimeout(Duration.ofMillis(600000))
                .doOnConnected(conn -> conn.addHandlerLast(new ReadTimeoutHandler(600000, TimeUnit.MILLISECONDS))
                        .addHandlerLast(new WriteTimeoutHandler(600000, TimeUnit.MILLISECONDS))
                );
            webClient = WebClient.builder()
                .clientConnector(new ReactorClientHttpConnector(httpClient))
                .build();

        } catch (Exception e) {
            throw new RuntimeException(e);
        }

        try (ByteArrayOutputStream dummyStream = new ByteArrayOutputStream();
            GZIPOutputStream gzipStream = new GZIPOutputStream(dummyStream)) {
            gzipStream.write("\n".getBytes(StandardCharsets.UTF_8));
            dummyBytes = dummyStream.toByteArray();
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
    }

    @Async("asyncRequestExecutor")
    public void enrich(WebhookEvent event) {
        WebhookEventData.ForEnrichmentBatchCreated eventData = (WebhookEventData.ForEnrichmentBatchCreated) event.getData();
        String batchApiPath = WD_API_URL + "/v2/projects/" + eventData.getProjectId() +
                "/collections/" + eventData.getCollectionId() +
                "/batches/" + eventData.getBatchId() +
                "?version=" + event.getVersion();

        // pull enrichment batch from Watson Discovery
        Flux<DataBuffer> body = webClient.get().uri(batchApiPath)
                .header(HttpHeaders.AUTHORIZATION, WD_API_AUTH_HEADER)
                .header(HttpHeaders.ACCEPT_ENCODING, "gzip")
                .exchangeToFlux(response -> response.body(BodyExtractors.toDataBuffers()));
        
        byte[] pulledBytes;
        try (ByteArrayOutputStream outputStream = new ByteArrayOutputStream();) {
            CountDownLatch completed = new CountDownLatch(1);
            DataBufferUtils.write(body, outputStream)
                .doOnComplete(() -> {
                    completed.countDown();
                    try {
                        outputStream.close();
                    } catch (Exception e) {
                        logger.warn("failed to close output stream", e);
                    }
                })
                .subscribe(DataBufferUtils.releaseConsumer());
            completed.await();
            pulledBytes = outputStream.toByteArray();
        } catch (Exception e) {
            logger.warn("failed to pull enrichment batch " + eventData.getBatchId() + 
                        " of collection " + eventData.getCollectionId() + 
                        " from " + batchApiPath, e);
            pulledBytes = null;
        }

        // add annotations using slate model deployed on on-prem CP4D
        byte[] bytesToUpload;
        if (pulledBytes == null) {
            bytesToUpload = dummyBytes;
        } else {
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(new GZIPInputStream(new ByteArrayInputStream(pulledBytes))));
                GZIPOutputStream compressStream = new GZIPOutputStream(buffer);) {
                reader.lines()
                    .map(this::parseToDocument)
                    .filter(document -> document != null)
                    .map(this::enrichWithScoringAPI)
                    .forEach(document -> {
                        try {
                            compressStream.write((mapper.writeValueAsString(document) + "\n").getBytes(StandardCharsets.UTF_8));
                        } catch (IOException e) {
                            logger.warn("failed to make a batch due to document " + document.getDocumentId(), e);
                        }
                    });
                compressStream.finish();
                bytesToUpload = buffer.toByteArray();
            } catch (Exception e) {
                logger.warn("failed to enrich documents", e);
                bytesToUpload = dummyBytes;
            }
        }

        // push enrichment batch from Watson Discovery
        MultipartBodyBuilder builder = new MultipartBodyBuilder();
        builder.part("file", new MultiPartResource(bytesToUpload, "data.ndjson.gz"), MediaType.parseMediaType("application/x-ndjson"));
        try {
            webClient.post().uri(batchApiPath)
                .header(HttpHeaders.AUTHORIZATION, WD_API_AUTH_HEADER)
                .body(BodyInserters.fromMultipartData(builder.build()))
                .exchangeToMono(response -> {
                    if (response.statusCode().equals(HttpStatus.ACCEPTED)) {
                        return response.bodyToMono(PushBatchResponse.class);
                    } else {
                        return response.createError();
                    }
                })
                .block();
            logger.info("successfully pushed enrichment batch " + eventData.getBatchId() + " to " + batchApiPath);
        } catch (Exception e) {
            logger.info("failed to push enrichment batch " + eventData.getBatchId() + " to " + batchApiPath, e);
        }

    }

    @Async("asyncStreamExecutor")
    private CompletableFuture<byte[]> getBytes(PipedInputStream stream) throws IOException {
        byte[] bytes = new byte[stream.available()];
        stream.read(bytes, 0, bytes.length);
        return CompletableFuture.completedFuture(bytes);
    }

    private Document parseToDocument(String jsonLine) {
        try {
            return mapper.readValue(jsonLine, Document.class);
        } catch (Exception e) {
            logger.warn("failed to parse document", e);
        }
        return null;
    }


    private Document enrichWithScoringAPI(Document document) {
        List<DocumentFeature> textFieldFeatures = extractTextFieldFeatures(document);
        List<List<String>> textFieldValues = textFieldFeatures.stream()
            .map(feature -> Collections.singletonList(
                document.getArtifact().substring(feature.getLocation().getBegin(), feature.getLocation().getEnd())))
            .toList();
        ScoringInput input = new ScoringInput(Collections.singletonList(
                new ScoringInput.InputField(Collections.singletonList("text"), textFieldValues)
            ));
        
        ScoringOutput output = null;
        List<DocumentFeature> annotationFeatures = new ArrayList<>();
        try {
            output = requestToScoringAPI(input, document.getDocumentId());
        } catch (Exception e) {
            logger.warn("failed to predict with scoring API " + SCORING_URL + " for document " + document.getDocumentId(), e);
            annotationFeatures.add(new DocumentFeature(FeaturePropertyType.NOTICE, null, new NoticeFeatureProperties(e.getMessage(), System.currentTimeMillis())));
        }

        if (output != null) {
            for (int i = 0; i < textFieldFeatures.size(); i++) {
                DocumentFeature textFieldFeature = textFieldFeatures.get(i);
                String textFieldValue = textFieldValues.get(i).get(0);
                List<Mention> mentions = output.getPredictions().get(0).getValues().get(0).get(i).getMentions();
                LocationMappings mappings = LocationMappings.generateLocationMappings(textFieldValue);
                for (Mention mention : mentions) {
                    // Since the offset from slate model is calculated based on utf-32(python), we need to recalculate offsets based on utf-16(java) to treat them in java program
                    Location location = mappings.toUtf16(mention.getSpan().getBegin(), mention.getSpan().getEnd(), textFieldFeature.getLocation().getBegin());
                    annotationFeatures.add(new DocumentFeature(
                        FeaturePropertyType.ANNOTATION,
                        location,
                        new AnnotationFeatureProperties(AnnotationType.ENTITIES, mention.getConfidence(), mention.getType(), mention.getSpan().getText())
                    ));
                }
            }
        }
        return new Document(document.getDocumentId(), annotationFeatures);
    }

    private List<DocumentFeature> extractTextFieldFeatures(Document document) {
        return document.getFeatures().stream()
            .filter(feature -> feature.getType() == FeaturePropertyType.FIELD)
            .filter(feature -> ((FieldFeatureProperties)feature.getProperties()).getFieldName().equals(TEXT_FIELD_NAME))
            .sorted((a, b) -> {
                Integer aIndex = (Integer)((FieldFeatureProperties)a.getProperties()).getFieldIndex();
                Integer bIndex = (Integer)((FieldFeatureProperties)b.getProperties()).getFieldIndex();
                return aIndex.compareTo(bIndex);
            })
            .toList();
    }

    private ScoringOutput requestToScoringAPI(ScoringInput input, String documentId) {
        return webClient.post().uri(SCORING_URL)
            .header(HttpHeaders.ACCEPT, "application/json")
            .header(HttpHeaders.AUTHORIZATION, SCORING_API_AUTH_HEADER)
            .header(HttpHeaders.CONTENT_TYPE, "application/json; charset=UTF-8")
            .body(BodyInserters.fromValue(input))
            .exchangeToMono(response -> {
                if (response.statusCode().equals(HttpStatus.OK)) {
                    return response.bodyToMono(ScoringOutput.class);
                } else {
                    return response.createError();
                }
            })
            .block();
    }

    private static final class PushBatchResponse {
        @JsonProperty("accepted")
        private boolean accepted;
    }

    private static class MultiPartResource extends ByteArrayResource {

        private String filename;
      
        public MultiPartResource(byte[] byteArray, String filename) {
          super(byteArray);
          this.filename = filename;
        }
      
        @Override
        public String getFilename() {
          return filename;
        }
    }
}

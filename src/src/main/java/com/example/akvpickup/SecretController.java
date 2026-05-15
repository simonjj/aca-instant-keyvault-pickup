package com.example.akvpickup;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Duration;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

@RestController
public class SecretController {

    private static final Logger log = LoggerFactory.getLogger(SecretController.class);

    private final SecretCache cache;

    public SecretController(SecretCache cache) {
        this.cache = cache;
    }

    @GetMapping("/")
    public ResponseEntity<Map<String, Object>> index() {
        try {
            return ResponseEntity.ok(describe("ok", cache.get(false)));
        } catch (Exception ex) {
            log.error("Failed to read secret", ex);
            return ResponseEntity.status(500).body(error(ex));
        }
    }

    @GetMapping("/refresh")
    public ResponseEntity<Map<String, Object>> refreshGet() {
        return forceRefresh();
    }

    @PostMapping("/refresh")
    public ResponseEntity<Map<String, Object>> refreshPost() {
        return forceRefresh();
    }

    @GetMapping("/healthz")
    public ResponseEntity<Map<String, Object>> healthz() {
        return ResponseEntity.ok(Map.of("status", "ok"));
    }

    private ResponseEntity<Map<String, Object>> forceRefresh() {
        try {
            return ResponseEntity.ok(describe("refreshed", cache.get(true)));
        } catch (Exception ex) {
            log.error("Forced refresh failed", ex);
            return ResponseEntity.status(500).body(error(ex));
        }
    }

    private Map<String, Object> describe(String status, SecretCache.CachedSecret entry) {
        Duration ttl = cache.getTtl();
        double age = Duration.between(entry.fetchedAt(), Instant.now()).toMillis() / 1000.0;
        double untilRefresh = Math.max(0, ttl.toSeconds() - age);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("status", status);
        body.put("secret_name", cache.getSecretName());
        body.put("secret_value", entry.value());
        body.put("secret_version", entry.version());
        body.put("fetched_at_epoch", entry.fetchedAt().getEpochSecond());
        body.put("age_seconds", round(age));
        body.put("ttl_seconds", ttl.toSeconds());
        body.put("seconds_until_refresh", round(untilRefresh));
        body.put("vault_url", cache.getVaultUrl());
        return body;
    }

    private Map<String, Object> error(Exception ex) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("status", "error");
        body.put("error", ex.getMessage());
        return body;
    }

    private double round(double v) {
        return Math.round(v * 100.0) / 100.0;
    }
}

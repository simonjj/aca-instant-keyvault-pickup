package com.example.akvpickup;

import com.azure.core.credential.TokenCredential;
import com.azure.identity.DefaultAzureCredentialBuilder;
import com.azure.identity.ManagedIdentityCredentialBuilder;
import com.azure.security.keyvault.secrets.SecretClient;
import com.azure.security.keyvault.secrets.SecretClientBuilder;
import com.azure.security.keyvault.secrets.models.KeyVaultSecret;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.locks.ReentrantLock;

@Component
public class SecretCache {

    private static final Logger log = LoggerFactory.getLogger(SecretCache.class);

    private final String vaultName;
    private final String vaultUrl;
    private final String secretName;
    private final Duration ttl;
    private final String managedIdentityClientId;

    private final ReentrantLock lock = new ReentrantLock();
    private volatile SecretClient client;
    private volatile CachedSecret cached;

    public SecretCache(
            @Value("${KEY_VAULT_NAME:}") String vaultName,
            @Value("${SECRET_NAME:demo-secret}") String secretName,
            @Value("${SECRET_TTL_SECONDS:30}") int ttlSeconds,
            @Value("${AZURE_CLIENT_ID:}") String managedIdentityClientId) {
        this.vaultName = vaultName;
        this.vaultUrl = vaultName == null || vaultName.isBlank()
                ? ""
                : "https://" + vaultName + ".vault.azure.net";
        this.secretName = secretName;
        this.ttl = Duration.ofSeconds(ttlSeconds);
        this.managedIdentityClientId = managedIdentityClientId;
        if (this.vaultUrl.isEmpty()) {
            log.warn("KEY_VAULT_NAME is not set. Secret reads will fail until it is configured.");
        }
    }

    public CachedSecret get(boolean forceRefresh) {
        CachedSecret current = cached;
        if (!forceRefresh && current != null && !isStale(current)) {
            return current;
        }
        lock.lock();
        try {
            if (!forceRefresh && cached != null && !isStale(cached)) {
                return cached;
            }
            cached = fetch();
            return cached;
        } finally {
            lock.unlock();
        }
    }

    public String getSecretName() {
        return secretName;
    }

    public Duration getTtl() {
        return ttl;
    }

    public String getVaultUrl() {
        return vaultUrl;
    }

    private boolean isStale(CachedSecret entry) {
        return Duration.between(entry.fetchedAt(), Instant.now()).compareTo(ttl) >= 0;
    }

    private CachedSecret fetch() {
        SecretClient c = clientOrCreate();
        log.info("Fetching secret '{}' from {}", secretName, vaultUrl);
        KeyVaultSecret secret = c.getSecret(secretName);
        String version = secret.getProperties() == null ? null : secret.getProperties().getVersion();
        return new CachedSecret(secret.getValue(), version, Instant.now());
    }

    private SecretClient clientOrCreate() {
        SecretClient c = client;
        if (c != null) {
            return c;
        }
        if (vaultUrl.isEmpty()) {
            throw new IllegalStateException("KEY_VAULT_NAME is not configured");
        }
        TokenCredential credential;
        if (managedIdentityClientId != null && !managedIdentityClientId.isBlank()) {
            log.info("Using ManagedIdentityCredential with client id {}", managedIdentityClientId);
            credential = new ManagedIdentityCredentialBuilder()
                    .clientId(managedIdentityClientId)
                    .build();
        } else {
            log.info("Using DefaultAzureCredential");
            credential = new DefaultAzureCredentialBuilder().build();
        }
        c = new SecretClientBuilder()
                .vaultUrl(vaultUrl)
                .credential(credential)
                .buildClient();
        client = c;
        return c;
    }

    public record CachedSecret(String value, String version, Instant fetchedAt) {
    }
}

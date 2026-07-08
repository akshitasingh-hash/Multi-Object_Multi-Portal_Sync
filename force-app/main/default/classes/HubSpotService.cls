/**
 * Thin HubSpot CRM v3 client, generic across object types. The object's HubSpot
 * endpoint path and match key come from PortalSyncConfig.ObjectConfig, so the
 * same code drives contacts, companies, or any configured object.
 *
 * Auth is supplied by the per-portal Named Credential (an External Credential
 * should inject the "Authorization: Bearer <private-app-token>" header), so no
 * tokens live in Apex. Match key is the object's custom sf-id property
 * (cfg.sfIdProperty), not email.
 */
public with sharing class HubSpotService {

    private static String objectPath(PortalSyncConfig.ObjectConfig cfg) {
        return '/crm/v3/objects/' + cfg.hubSpotPath;
    }

    // Map a record's fields to HubSpot properties FOR A SPECIFIC (object, portal):
    // only the fields whose mapping row opts into `portalValue` (Syncs_To_*) are
    // included, so different portals can receive different subsets of the record.
    public static Map<String, Object> mapProperties(SObject record, String sObjectName, String portalValue) {
        Map<String, Object> props = new Map<String, Object>();
        Map<String, String> fieldMap = PortalSyncConfig.fieldMapFor(sObjectName, portalValue);
        for (String sfField : fieldMap.keySet()) {
            Object v = record.get(sfField);
            if (v != null) {
                props.put(fieldMap.get(sfField), String.valueOf(v));
            }
        }
        return props;
    }

    // ---- Bulk (batch) operations -------------------------------------------
    // HubSpot batch endpoints process up to 100 records per callout, so mass
    // changes cost O(portals) callouts instead of O(records). All match on the
    // unique cfg.sfIdProperty via idProperty, so no per-record search is needed.

    private static final Integer BATCH_LIMIT = 100; // HubSpot cap per batch call.

    /**
     * Bulk create-or-update by the object's sf-id property via the batch upsert
     * endpoint, which matches on the alternate unique id (idProperty =
     * cfg.sfIdProperty). One callout per 100 records replaces the per-record
     * search+write.
     *
     * NOTE: cfg.sfIdProperty must be configured as a UNIQUE property in HubSpot --
     * that is what makes idProperty upsert legal. If it is not unique HubSpot
     * rejects the whole batch (400) and the reason is captured below.
     *
     * propsBySfId: Salesforce record id -> mapped HubSpot properties.
     * Returns sfId -> failure detail for records that did NOT sync (empty => all
     * succeeded). HTTP 200 means the entire chunk succeeded; a 207 multi-status is
     * inspected per record; any other status fails the chunk. The HubSpot status +
     * body is carried in the detail so the dead letter is actually diagnosable.
     */
    public static Map<String, String> batchUpsertBySfId(PortalSyncConfig.ObjectConfig cfg, String portalValue, Map<String, Map<String, Object>> propsBySfId) {
        Map<String, String> failed = new Map<String, String>();
        String idProperty = cfg.sfIdProperty;
        List<String> sfIds = new List<String>(propsBySfId.keySet());
        for (Integer i = 0; i < sfIds.size(); i += BATCH_LIMIT) {
            Integer stop = Math.min(i + BATCH_LIMIT, sfIds.size());
            List<Object> inputs = new List<Object>();
            List<String> chunkIds = new List<String>();
            for (Integer j = i; j < stop; j++) {
                String sfId = sfIds[j];
                chunkIds.add(sfId);
                Map<String, Object> props = propsBySfId.get(sfId);
                props.put(idProperty, sfId);
                inputs.add(new Map<String, Object>{
                    'idProperty' => idProperty,
                    'id'         => sfId,
                    'properties' => props
                });
            }
            String body = JSON.serialize(new Map<String, Object>{ 'inputs' => inputs });
            HttpResponse res;
            try {
                res = send(portalValue, 'POST', objectPath(cfg) + '/batch/upsert', body);
            } catch (Exception e) {
                // A callout-level error (timeout, connection, bad Named Credential)
                // must not abort the run -- fail just this chunk and keep going.
                for (String sfId : chunkIds) failed.put(sfId, 'Callout error: ' + e.getMessage());
                continue;
            }
            Integer code = res.getStatusCode();
            if (code == 200) {
                continue; // COMPLETE -> every input in the chunk succeeded
            }
            // 207: results[] holds the successes (echoing the sf-id property); the
            // rest failed. Any other status: the whole chunk failed.
            Set<String> ok = (code == 207) ? sfIdsFromResults(res.getBody(), idProperty) : new Set<String>();
            String detail = errorDetail(res);
            for (String sfId : chunkIds) {
                if (!ok.contains(sfId)) failed.put(sfId, detail);
            }
        }
        return failed;
    }

    /**
     * Bulk archive by the object's sf-id property. Archive takes HubSpot object
     * ids, so each chunk is first resolved through batch read (idProperty =
     * cfg.sfIdProperty); ids HubSpot does not know are already absent and count as
     * success (matching the old single-record no-op). Returns sfId -> failure detail.
     */
    public static Map<String, String> batchArchiveBySfId(PortalSyncConfig.ObjectConfig cfg, String portalValue, Set<String> sfIds) {
        Map<String, String> failed = new Map<String, String>();
        List<String> ids = new List<String>(sfIds);
        for (Integer i = 0; i < ids.size(); i += BATCH_LIMIT) {
            Integer stop = Math.min(i + BATCH_LIMIT, ids.size());
            List<String> chunkIds = new List<String>();
            for (Integer j = i; j < stop; j++) chunkIds.add(ids[j]);

            Map<String, String> hsIdBySfId = resolveHubSpotIds(cfg, portalValue, chunkIds, failed);
            if (hsIdBySfId.isEmpty()) continue; // nothing present -> nothing to archive

            List<Object> inputs = new List<Object>();
            for (String hsId : hsIdBySfId.values()) {
                inputs.add(new Map<String, Object>{ 'id' => hsId });
            }
            String body = JSON.serialize(new Map<String, Object>{ 'inputs' => inputs });
            HttpResponse res;
            try {
                res = send(portalValue, 'POST', objectPath(cfg) + '/batch/archive', body);
            } catch (Exception e) {
                for (String sfId : hsIdBySfId.keySet()) failed.put(sfId, 'Callout error: ' + e.getMessage());
                continue;
            }
            if (res.getStatusCode() != 204 && !isOk(res)) {
                String detail = errorDetail(res);
                for (String sfId : hsIdBySfId.keySet()) failed.put(sfId, detail);
            }
        }
        return failed;
    }

    /** Resolve sfId -> HubSpot object id for a chunk. Ids the read callout fails
     *  on are added to `failed` with detail; ids simply not found are omitted
     *  (absent = archive no-op). */
    private static Map<String, String> resolveHubSpotIds(PortalSyncConfig.ObjectConfig cfg, String portalValue, List<String> sfIds, Map<String, String> failed) {
        Map<String, String> hsIdBySfId = new Map<String, String>();
        String idProperty = cfg.sfIdProperty;
        List<Object> inputs = new List<Object>();
        for (String sfId : sfIds) {
            inputs.add(new Map<String, Object>{ 'id' => sfId });
        }
        Map<String, Object> body = new Map<String, Object>{
            'idProperty' => idProperty,
            'properties' => new List<String>{ idProperty },
            'inputs'     => inputs
        };
        HttpResponse res;
        try {
            res = send(portalValue, 'POST', objectPath(cfg) + '/batch/read', JSON.serialize(body));
        } catch (Exception e) {
            for (String sfId : sfIds) failed.put(sfId, 'READ callout error: ' + e.getMessage());
            return hsIdBySfId; // can't resolve -> can't archive this chunk; skip it
        }
        if (!isOk(res)) {
            String detail = 'READ ' + errorDetail(res);
            for (String sfId : sfIds) failed.put(sfId, detail); // can't resolve -> can't safely archive
            return hsIdBySfId;
        }
        for (Object o : resultsOf(res.getBody())) {
            Map<String, Object> r = (Map<String, Object>) o;
            String hsId = (String) r.get('id');
            Map<String, Object> props = (Map<String, Object>) r.get('properties');
            String sfId = (props != null) ? (String) props.get(idProperty) : null;
            if (hsId != null && sfId != null) hsIdBySfId.put(sfId, hsId);
        }
        return hsIdBySfId;
    }

    /** sf-ids present in a batch response's results[].properties, read under the
     *  object's idProperty. */
    private static Set<String> sfIdsFromResults(String responseBody, String idProperty) {
        Set<String> out = new Set<String>();
        for (Object o : resultsOf(responseBody)) {
            Map<String, Object> props = (Map<String, Object>) ((Map<String, Object>) o).get('properties');
            if (props != null && props.get(idProperty) != null) {
                out.add((String) props.get(idProperty));
            }
        }
        return out;
    }

    private static List<Object> resultsOf(String responseBody) {
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
        List<Object> results = (List<Object>) parsed.get('results');
        return (results != null) ? results : new List<Object>();
    }

    private static Boolean isOk(HttpResponse res) {
        return res.getStatusCode() >= 200 && res.getStatusCode() < 300;
    }

    /** HubSpot status + body, trimmed for the dead-letter Error__c field. */
    private static String errorDetail(HttpResponse res) {
        String b = res.getBody();
        if (b != null && b.length() > 240) b = b.substring(0, 240);
        return 'HTTP ' + res.getStatusCode() + ': ' + b;
    }

    private static HttpResponse send(String portalValue, String method, String path, String body) {
        String namedCred = PortalSyncConfig.PORTAL_TO_NAMED_CREDENTIAL.get(portalValue);
        if (String.isBlank(namedCred)) {
            throw new CalloutException('No Named Credential mapped for portal: ' + portalValue);
        }
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + namedCred + path);
        req.setMethod(method);
        req.setTimeout(120000);
        if (body != null) {
            req.setHeader('Content-Type', 'application/json');
            req.setBody(body);
        }
        return new Http().send(req);
    }
}

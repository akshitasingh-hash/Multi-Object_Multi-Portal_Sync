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
     *  (absent = the record is not in this portal yet). Public so the association
     *  router can resolve both ends of a link to their HubSpot ids per portal. */
    public static Map<String, String> resolveHubSpotIds(PortalSyncConfig.ObjectConfig cfg, String portalValue, List<String> sfIds, Map<String, String> failed) {
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

    // ---- Associations (CRM v4) ---------------------------------------------
    // Associations LINK two records by their HubSpot object ids (not by sf-id),
    // so both ends must already exist in the portal -- the caller resolves each
    // side with resolveHubSpotIds first. All three endpoints are per portal and
    // chunk at 100 like the object batch calls.

    /** One directional link, in HubSpot-id space. */
    public class AssocInput {
        public String fromId;
        public String toId;
        public AssocInput(String fromId, String toId) { this.fromId = fromId; this.toId = toId; }
        public String key() { return fromId + '>' + toId; }
    }

    private static String assocPath(String fromPath, String toPath, String op) {
        return '/crm/v4/associations/' + fromPath + '/' + toPath + '/batch/' + op;
    }

    /**
     * Read existing associations for a set of from-record HubSpot ids, returning
     * fromHsId -> set of toHsId, filtered to the given (category, typeId) so the
     * diff only manages associations of the type this row owns. A null typeId
     * matches any type. from-ids whose read callout fails are recorded in `failed`
     * (keyed by fromHsId) so the caller can suppress removals for them.
     */
    public static Map<String, Set<String>> batchReadAssociations(
            String fromPath, String toPath, String portalValue,
            List<String> fromHsIds, String category, Integer typeId, Map<String, String> failed) {
        Map<String, Set<String>> existing = new Map<String, Set<String>>();
        for (Integer i = 0; i < fromHsIds.size(); i += BATCH_LIMIT) {
            Integer stop = Math.min(i + BATCH_LIMIT, fromHsIds.size());
            List<Object> inputs = new List<Object>();
            List<String> chunkIds = new List<String>();
            for (Integer j = i; j < stop; j++) {
                chunkIds.add(fromHsIds[j]);
                inputs.add(new Map<String, Object>{ 'id' => fromHsIds[j] });
            }
            String body = JSON.serialize(new Map<String, Object>{ 'inputs' => inputs });
            HttpResponse res;
            try {
                res = send(portalValue, 'POST', assocPath(fromPath, toPath, 'read'), body);
            } catch (Exception e) {
                for (String id : chunkIds) failed.put(id, 'ASSOC READ callout error: ' + e.getMessage());
                continue;
            }
            if (!isOk(res)) {
                String detail = 'ASSOC READ ' + errorDetail(res);
                for (String id : chunkIds) failed.put(id, detail);
                continue;
            }
            for (Object o : resultsOf(res.getBody())) {
                Map<String, Object> r = (Map<String, Object>) o;
                Map<String, Object> fromNode = (Map<String, Object>) r.get('from');
                String fromId = (fromNode != null) ? String.valueOf(fromNode.get('id')) : null;
                if (fromId == null) continue;
                if (!existing.containsKey(fromId)) existing.put(fromId, new Set<String>());
                List<Object> tos = (List<Object>) r.get('to');
                if (tos == null) continue;
                for (Object t : tos) {
                    Map<String, Object> toNode = (Map<String, Object>) t;
                    Object toIdObj = (toNode.get('toObjectId') != null) ? toNode.get('toObjectId') : toNode.get('id');
                    if (toIdObj == null) continue;
                    if (typeId == null || matchesType(toNode, category, typeId)) {
                        existing.get(fromId).add(String.valueOf(toIdObj));
                    }
                }
            }
        }
        return existing;
    }

    private static Boolean matchesType(Map<String, Object> toEntry, String category, Integer typeId) {
        List<Object> types = (List<Object>) toEntry.get('associationTypes');
        if (types == null) return false;
        for (Object o : types) {
            Map<String, Object> t = (Map<String, Object>) o;
            Object tid = t.get('typeId');
            // JSON numbers deserialize as Integer/Long/Decimal -- compare as text.
            Boolean idOk = (tid != null) && (String.valueOf(tid) == String.valueOf(typeId));
            Object cat = t.get('category');
            Boolean catOk = (category == null) || (cat == null)
                || category.equalsIgnoreCase(String.valueOf(cat));
            if (idOk && catOk) return true;
        }
        return false;
    }

    /** Bulk create associations of one (category, typeId). Returns 'fromHs>toHs'
     *  -> failure detail for links that did NOT create (empty => all created). */
    public static Map<String, String> batchCreateAssociations(
            String fromPath, String toPath, String portalValue,
            String category, Integer typeId, List<AssocInput> links) {
        Map<String, String> failed = new Map<String, String>();
        for (Integer i = 0; i < links.size(); i += BATCH_LIMIT) {
            Integer stop = Math.min(i + BATCH_LIMIT, links.size());
            List<Object> inputs = new List<Object>();
            List<AssocInput> chunk = new List<AssocInput>();
            for (Integer j = i; j < stop; j++) {
                AssocInput link = links[j];
                chunk.add(link);
                inputs.add(new Map<String, Object>{
                    'from'  => new Map<String, Object>{ 'id' => link.fromId },
                    'to'    => new Map<String, Object>{ 'id' => link.toId },
                    'types' => new List<Object>{
                        new Map<String, Object>{
                            'associationCategory' => category,
                            'associationTypeId'   => typeId
                        }
                    }
                });
            }
            String body = JSON.serialize(new Map<String, Object>{ 'inputs' => inputs });
            HttpResponse res;
            try {
                res = send(portalValue, 'POST', assocPath(fromPath, toPath, 'create'), body);
            } catch (Exception e) {
                for (AssocInput link : chunk) failed.put(link.key(), 'Callout error: ' + e.getMessage());
                continue;
            }
            if (!isOk(res)) {
                String detail = errorDetail(res);
                for (AssocInput link : chunk) failed.put(link.key(), detail);
            }
        }
        return failed;
    }

    /** Bulk archive associations between the given pairs. Note: HubSpot's v4
     *  batch archive removes ALL association types between a from/to pair, so this
     *  is used only for pairs Salesforce no longer relates at all. Returns
     *  'fromHs>toHs' -> failure detail (empty => all archived). */
    public static Map<String, String> batchArchiveAssociations(
            String fromPath, String toPath, String portalValue, List<AssocInput> links) {
        Map<String, String> failed = new Map<String, String>();
        for (Integer i = 0; i < links.size(); i += BATCH_LIMIT) {
            Integer stop = Math.min(i + BATCH_LIMIT, links.size());
            List<Object> inputs = new List<Object>();
            List<AssocInput> chunk = new List<AssocInput>();
            for (Integer j = i; j < stop; j++) {
                AssocInput link = links[j];
                chunk.add(link);
                inputs.add(new Map<String, Object>{
                    'from' => new Map<String, Object>{ 'id' => link.fromId },
                    'to'   => new Map<String, Object>{ 'id' => link.toId }
                });
            }
            String body = JSON.serialize(new Map<String, Object>{ 'inputs' => inputs });
            HttpResponse res;
            try {
                res = send(portalValue, 'POST', assocPath(fromPath, toPath, 'archive'), body);
            } catch (Exception e) {
                for (AssocInput link : chunk) failed.put(link.key(), 'Callout error: ' + e.getMessage());
                continue;
            }
            if (res.getStatusCode() != 204 && !isOk(res)) {
                String detail = errorDetail(res);
                for (AssocInput link : chunk) failed.put(link.key(), detail);
            }
        }
        return failed;
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

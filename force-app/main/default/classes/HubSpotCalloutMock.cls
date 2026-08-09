@isTest
public class HubSpotCalloutMock implements HttpCalloutMock {

    // Flip to simulate contacts already existing in a portal (so batch/read and
    // /search resolve them; batch/upsert always echoes its inputs as succeeded).
    public Boolean returnExisting = false;

    // Flip to make every batch endpoint return 500, exercising the failure paths
    // (dead-letter buffering, Failed status, retry increment).
    public Boolean failBatch = false;

    // Flip to make batch/upsert return 207 with the FIRST input missing from
    // results -> that record is treated as failed, the rest succeed.
    public Boolean partialUpsert = false;

    // Flip to throw a CalloutException at the callout layer (timeout/connection),
    // exercising the "don't abort the batch on a callout error" path.
    public Boolean throwCallout = false;

    // Flip to fail ONLY the v4 association endpoints (500) while object upserts
    // still succeed -- exercises association dead-lettering without failing the
    // record's field sync.
    public Boolean failAssociations = false;

    // Flip to make an association batch/read report each from-record as already
    // linked to a stale to-record (id 777001) of the requested type, so the diff
    // produces an archive.
    public Boolean returnExistingAssociations = false;

    // Owner resolution (/crm/v3/owners): when set, the owners list returns one
    // owner with this email/id; leave null to simulate no matching owner.
    public String ownerEmailToMatch = null;
    public String ownerHsId = '555001';

    // Flip to make the owners list endpoint return 500, exercising the
    // "don't fail the record over an unresolved owner" path.
    public Boolean failOwners = false;

    // sfId -> the properties map actually sent on the last /batch/upsert call,
    // so tests can assert on the parsed payload (e.g. hubspot_owner_id) rather
    // than raw JSON.
    public Map<String, Map<String, Object>> capturedUpsertProps = new Map<String, Map<String, Object>>();

    public HttpResponse respond(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');

        String endpoint = req.getEndpoint();
        Boolean isAssoc = endpoint.contains('/crm/v4/associations/');
        Boolean isOwners = endpoint.contains('/crm/v3/owners');
        if (isOwners) {
            if (failOwners) {
                res.setStatusCode(500);
                res.setBody('{"status":"error","message":"simulated owners failure"}');
                return res;
            }
            List<Object> results = new List<Object>();
            if (ownerEmailToMatch != null) {
                results.add(new Map<String, Object>{
                    'id' => ownerHsId, 'email' => ownerEmailToMatch, 'archived' => false
                });
            }
            res.setStatusCode(200);
            res.setBody(JSON.serialize(new Map<String, Object>{ 'results' => results }));
            return res;
        }
        if (throwCallout && endpoint.contains('/batch/')) {
            // Simulate a timeout / connection / auth error at the callout layer.
            throw new CalloutException('simulated callout failure');
        }
        if ((failBatch || (failAssociations && isAssoc)) && endpoint.contains('/batch/')) {
            res.setStatusCode(500);
            res.setBody('{"status":"error","message":"simulated failure"}');
            return res;
        }
        if (isAssoc) {
            if (endpoint.endsWith('/batch/read')) {
                res.setStatusCode(200);
                res.setBody(echoAssociationRead(req.getBody()));
            } else if (endpoint.endsWith('/batch/create')) {
                res.setStatusCode(201);
                res.setBody('{"status":"COMPLETE","results":[]}');
            } else if (endpoint.endsWith('/batch/archive')) {
                res.setStatusCode(204);
            } else {
                res.setStatusCode(200);
                res.setBody('{"results":[]}');
            }
            return res;
        }
        if (endpoint.endsWith('/batch/upsert')) {
            captureUpsertProps(req.getBody());
            if (partialUpsert) {
                // 207 multi-status: echo all inputs except the first (which failed).
                res.setStatusCode(207);
                res.setBody(echoResults(req.getBody(), 1));
            } else {
                // Every input succeeds.
                res.setStatusCode(200);
                res.setBody(echoResults(req.getBody(), 0));
            }
        } else if (endpoint.endsWith('/batch/read')) {
            res.setStatusCode(200);
            // Not present -> empty results -> archive is a no-op (success).
            res.setBody(returnExisting ? echoResults(req.getBody(), 0) : '{"results":[]}');
        } else if (endpoint.endsWith('/batch/archive')) {
            res.setStatusCode(204);
        } else if (endpoint.contains('/search')) {
            res.setStatusCode(200);
            res.setBody(returnExisting ? '{"results":[{"id":"12345"}]}' : '{"results":[]}');
        } else if (req.getMethod() == 'DELETE') {
            res.setStatusCode(204);
        } else {
            // POST create or PATCH update
            res.setStatusCode(200);
            res.setBody('{"id":"12345"}');
        }
        return res;
    }

    // Build a v4 association batch/read response: one result per input from-id.
    // `to` is empty by default (so every desired link is a create); when
    // returnExistingAssociations is set, each from-record already has a stale link
    // to 777001 tagged with both default types, so the diff yields an archive.
    private String echoAssociationRead(String requestBody) {
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(requestBody);
        List<Object> inputs = (List<Object>) parsed.get('inputs');
        List<Object> results = new List<Object>();
        if (inputs != null) {
            for (Object o : inputs) {
                String fromId = String.valueOf(((Map<String, Object>) o).get('id'));
                List<Object> tos = new List<Object>();
                if (returnExistingAssociations) {
                    tos.add(new Map<String, Object>{
                        'toObjectId'       => '777001',
                        'associationTypes' => new List<Object>{
                            new Map<String, Object>{ 'category' => 'HUBSPOT_DEFINED', 'typeId' => 279 },
                            new Map<String, Object>{ 'category' => 'HUBSPOT_DEFINED', 'typeId' => 4 }
                        }
                    });
                }
                results.add(new Map<String, Object>{
                    'from' => new Map<String, Object>{ 'id' => fromId },
                    'to'   => tos
                });
            }
        }
        return JSON.serialize(new Map<String, Object>{ 'results' => results });
    }

    // Build a batch response echoing each input's id as a result carrying that
    // value under the request's OWN idProperty (per-input for upsert, top-level
    // for batch/read), plus a synthetic HubSpot object id. Reading the idProperty
    // from the request keeps the mock generic across objects (contact_id_sf,
    // account_id_sf, ...). `skipFirst` inputs are omitted from results (to
    // simulate per-record failures on 207).
    private String echoResults(String requestBody, Integer skipFirst) {
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(requestBody);
        String topIdProp = (String) parsed.get('idProperty');
        List<Object> inputs = (List<Object>) parsed.get('inputs');
        List<Object> results = new List<Object>();
        Integer n = 0;
        if (inputs != null) {
            for (Object o : inputs) {
                if (n >= skipFirst) {
                    Map<String, Object> input = (Map<String, Object>) o;
                    String idProp = (input.get('idProperty') != null)
                        ? (String) input.get('idProperty') : topIdProp;
                    String sfId = String.valueOf(input.get('id'));
                    results.add(new Map<String, Object>{
                        'id'         => '99900' + n,
                        'properties' => new Map<String, Object>{ idProp => sfId }
                    });
                }
                n++;
            }
        }
        return JSON.serialize(new Map<String, Object>{ 'results' => results });
    }

    // Record the properties actually sent per sfId on a /batch/upsert call, so
    // tests can assert on the parsed payload (e.g. hubspot_owner_id) instead of
    // raw JSON.
    private void captureUpsertProps(String requestBody) {
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(requestBody);
        List<Object> inputs = (List<Object>) parsed.get('inputs');
        if (inputs == null) return;
        for (Object o : inputs) {
            Map<String, Object> input = (Map<String, Object>) o;
            String sfId = String.valueOf(input.get('id'));
            capturedUpsertProps.put(sfId, (Map<String, Object>) input.get('properties'));
        }
    }
}
